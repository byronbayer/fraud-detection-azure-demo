// Databricks notebook source
// =============================================================================
// 02 — Silver Layer Transformation
// =============================================================================
// Reads bronze Delta tables, applies data quality checks, deduplication,
// type validation, dimension joins, and derived field calculations.
// Writes cleaned/enriched data to the silver layer.
//
// Depends on: 01-bronze-ingestion (bronze tables must exist)
// =============================================================================

// COMMAND ----------

// MAGIC %md
// MAGIC ## Configuration
// MAGIC All values are read from the Key-Vault-backed secret scope `fraud-detection`.

// COMMAND ----------

val scope = "fraud-detection"

val bronzePath = try { dbutils.secrets.get(scope, "bronze-path") } catch { case _: Exception => "/mnt/fraud/bronze" }
val silverPath = try { dbutils.secrets.get(scope, "silver-path") } catch { case _: Exception => "/mnt/fraud/silver" }

println(s"Bronze path: $bronzePath")
println(s"Silver path: $silverPath")

// COMMAND ----------

import org.apache.spark.sql.{DataFrame, SparkSession}
import org.apache.spark.sql.functions._
import org.apache.spark.sql.types._

// COMMAND ----------

// MAGIC %md
// MAGIC ## 1. Silver Customer
// MAGIC - Validate email format
// MAGIC - Normalise country codes to uppercase
// MAGIC - Deduplicate on email (keep latest)
// MAGIC - Null checks on required fields

// COMMAND ----------

val bronzeCustomer = spark.read.format("delta").load(s"$bronzePath/bronze_dim_customer")

val silverCustomer = bronzeCustomer
  // Deduplicate: keep the most recently created record per email
  .withColumn("_row_num", row_number().over(
    org.apache.spark.sql.expressions.Window
      .partitionBy("email")
      .orderBy(col("created_at").desc)
  ))
  .filter(col("_row_num") === 1)
  .drop("_row_num")
  // Validate email — basic pattern check
  .filter(col("email").rlike("^[^@]+@[^@]+\\.[^@]+$"))
  // Normalise country codes
  .withColumn("country", upper(trim(col("country"))))
  // Drop rows missing required fields
  .filter(col("name").isNotNull && col("email").isNotNull && col("country").isNotNull)
  // Ensure risk_score is within bounds
  .withColumn("risk_score", when(col("risk_score") < 0, lit(0.0))
    .when(col("risk_score") > 100, lit(100.0))
    .otherwise(col("risk_score")))
  // Drop bronze metadata (will be replaced with silver metadata if needed)
  .drop("_ingested_at", "_source_table", "_batch_id")

silverCustomer.write
  .format("delta")
  .mode("overwrite")
  .option("overwriteSchema", "true")
  .save(s"$silverPath/silver_customer")

println(s"✓ silver_customer: ${silverCustomer.count()} rows")

// COMMAND ----------

// MAGIC %md
// MAGIC ## 2. Silver Merchant
// MAGIC - Standardise category names to lowercase
// MAGIC - Validate risk_tier enum
// MAGIC - Deduplicate on name + country

// COMMAND ----------

val bronzeMerchant = spark.read.format("delta").load(s"$bronzePath/bronze_dim_merchant")

val validRiskTiers = Seq("low", "medium", "high")

val silverMerchant = bronzeMerchant
  // Standardise category to lowercase
  .withColumn("category", lower(trim(col("category"))))
  // Validate risk_tier
  .withColumn("risk_tier", lower(trim(col("risk_tier"))))
  .filter(col("risk_tier").isin(validRiskTiers: _*))
  // Normalise country
  .withColumn("country", upper(trim(col("country"))))
  // Deduplicate on name + country
  .withColumn("_row_num", row_number().over(
    org.apache.spark.sql.expressions.Window
      .partitionBy("name", "country")
      .orderBy(col("created_at").desc)
  ))
  .filter(col("_row_num") === 1)
  .drop("_row_num")
  .drop("_ingested_at", "_source_table", "_batch_id")

silverMerchant.write
  .format("delta")
  .mode("overwrite")
  .option("overwriteSchema", "true")
  .save(s"$silverPath/silver_merchant")

println(s"✓ silver_merchant: ${silverMerchant.count()} rows")

// COMMAND ----------

// MAGIC %md
// MAGIC ## 3. Silver Account
// MAGIC - Join customer name and country for denormalisation
// MAGIC - Validate status enum
// MAGIC - Filter out invalid states (closed but no closed_at)

// COMMAND ----------

val bronzeAccount = spark.read.format("delta").load(s"$bronzePath/bronze_dim_account")
val custLookup = silverCustomer.select(
  col("customer_id"),
  col("name").as("customer_name"),
  col("country").as("customer_country")
)

val validStatuses = Seq("active", "suspended", "closed")

val silverAccount = bronzeAccount
  // Validate status
  .withColumn("status", lower(trim(col("status"))))
  .filter(col("status").isin(validStatuses: _*))
  // Fix inconsistency: closed accounts must have a closed_at date
  .withColumn("status", when(col("status") === "closed" && col("closed_at").isNull, lit("active"))
    .otherwise(col("status")))
  // Join customer dimension
  .join(custLookup, Seq("customer_id"), "inner")
  .drop("_ingested_at", "_source_table", "_batch_id")

silverAccount.write
  .format("delta")
  .mode("overwrite")
  .option("overwriteSchema", "true")
  .save(s"$silverPath/silver_account")

println(s"✓ silver_account: ${silverAccount.count()} rows")

// COMMAND ----------

// MAGIC %md
// MAGIC ## 4. Silver Transaction
// MAGIC - Join all dimension tables
// MAGIC - Derive: `hour_of_day`, `day_of_week`, `is_international`, `amount_bucket`
// MAGIC - Remove duplicates on `txn_id`
// MAGIC - Validate amount > 0

// COMMAND ----------

val bronzeTxn = spark.read.format("delta").load(s"$bronzePath/bronze_fact_transaction")

// Prepare dimension lookups
val acctFrom = silverAccount.select(
  col("account_id").as("from_account_id"),
  col("customer_id").as("from_customer_id"),
  col("customer_name").as("from_customer_name"),
  col("customer_country").as("from_country"),
  col("account_type").as("from_account_type")
)

val acctTo = silverAccount.select(
  col("account_id").as("to_account_id"),
  col("customer_country").as("to_country")
)

val merchLookup = silverMerchant.select(
  col("merchant_id"),
  col("name").as("merchant_name"),
  col("category").as("merchant_category"),
  col("country").as("merchant_country"),
  col("risk_tier").as("merchant_risk_tier")
)

val silverTransaction = bronzeTxn
  // Deduplicate on txn_id
  .dropDuplicates("txn_id")
  // Validate amount
  .filter(col("amount") > 0)
  // Join source account
  .join(acctFrom, Seq("from_account_id"), "inner")
  // Join destination account (left — nullable for merchant payments)
  .join(acctTo, Seq("to_account_id"), "left")
  // Join merchant (left — nullable for P2P transfers)
  .join(merchLookup, Seq("merchant_id"), "left")
  // Derive temporal fields
  .withColumn("hour_of_day", hour(col("txn_timestamp")))
  .withColumn("day_of_week", dayofweek(col("txn_timestamp")))
  .withColumn("txn_date", to_date(col("txn_timestamp")))
  // Derive cross-border flag
  .withColumn("is_international",
    when(col("merchant_country").isNotNull,
      col("from_country") =!= col("merchant_country"))
    .when(col("to_country").isNotNull,
      col("from_country") =!= col("to_country"))
    .otherwise(lit(false))
  )
  // Derive amount bucket
  .withColumn("amount_bucket",
    when(col("amount") < 50, lit("micro"))
    .when(col("amount") < 500, lit("small"))
    .when(col("amount") < 5000, lit("medium"))
    .when(col("amount") < 10000, lit("large"))
    .otherwise(lit("xlarge"))
  )
  .drop("_ingested_at", "_source_table", "_batch_id")

silverTransaction.write
  .format("delta")
  .mode("overwrite")
  .option("overwriteSchema", "true")
  .save(s"$silverPath/silver_transaction")

println(s"✓ silver_transaction: ${silverTransaction.count()} rows")

// COMMAND ----------

// MAGIC %md
// MAGIC ## Summary

// COMMAND ----------

println("\n" + "=" * 60)
println("Silver Layer Transformation — Complete")
println("=" * 60)

Seq("silver_customer", "silver_merchant", "silver_account", "silver_transaction").foreach { t =>
  val count = spark.read.format("delta").load(s"$silverPath/$t").count()
  println(f"  $t%-30s $count%,8d rows")
}

// COMMAND ----------

// MAGIC %md
// MAGIC ## Validation: Derived Fields Sample

// COMMAND ----------

spark.read.format("delta").load(s"$silverPath/silver_transaction")
  .select("txn_id", "amount", "amount_bucket", "hour_of_day", "day_of_week", "is_international", "from_customer_name", "merchant_name")
  .show(10, truncate = false)
