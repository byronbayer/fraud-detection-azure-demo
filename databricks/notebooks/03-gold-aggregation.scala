// Databricks notebook source
// =============================================================================
// 03 — Gold Layer Aggregation
// =============================================================================
// Reads silver Delta tables and engineers features for fraud detection:
//   - gold_customer_features:  per-customer transaction behaviour
//   - gold_account_features:   per-account balance velocity & dormancy
//   - gold_transaction_pairs:  account-to-account edges for Neo4j graph loading
//   - gold_merchant_risk:      per-merchant fraud flag rates
//
// Depends on: 02-silver-transformation (silver tables must exist)
// =============================================================================

// COMMAND ----------

// MAGIC %md
// MAGIC ## Configuration
// MAGIC All values are read from the Key-Vault-backed secret scope `fraud-detection`.

// COMMAND ----------

val scope = "fraud-detection"

val silverPath = try { dbutils.secrets.get(scope, "silver-path") } catch { case _: Exception => "/mnt/fraud/silver" }
val goldPath   = try { dbutils.secrets.get(scope, "gold-path") } catch { case _: Exception => "/mnt/fraud/gold" }

println(s"Silver path: $silverPath")
println(s"Gold path:   $goldPath")

// COMMAND ----------

import org.apache.spark.sql.functions._
import org.apache.spark.sql.expressions.Window

// Load silver tables
val silverTxn      = spark.read.format("delta").load(s"$silverPath/silver_transaction")
val silverCustomer = spark.read.format("delta").load(s"$silverPath/silver_customer")
val silverAccount  = spark.read.format("delta").load(s"$silverPath/silver_account")
val silverMerchant = spark.read.format("delta").load(s"$silverPath/silver_merchant")

// Reference timestamp for relative calculations
val refTimestamp = current_timestamp()

// COMMAND ----------

// MAGIC %md
// MAGIC ## 1. Gold Customer Features
// MAGIC Per-customer aggregated transaction behaviour over multiple time windows.

// COMMAND ----------

// Transactions with customer context (via from_customer_id)
val custTxns = silverTxn.select(
  col("from_customer_id").as("customer_id"),
  col("txn_id"),
  col("amount"),
  col("txn_timestamp"),
  col("merchant_id"),
  col("is_flagged"),
  col("is_international"),
  col("hour_of_day")
)

val goldCustomerFeatures = custTxns
  .groupBy("customer_id")
  .agg(
    // Volume metrics
    count("txn_id").as("total_txn_count"),
    count(when(col("txn_timestamp") > date_sub(refTimestamp, 1), col("txn_id"))).as("txn_count_24h"),
    count(when(col("txn_timestamp") > date_sub(refTimestamp, 7), col("txn_id"))).as("txn_count_7d"),
    count(when(col("txn_timestamp") > date_sub(refTimestamp, 30), col("txn_id"))).as("txn_count_30d"),

    // Amount metrics
    round(avg("amount"), 2).as("avg_amount"),
    round(avg(when(col("txn_timestamp") > date_sub(refTimestamp, 30), col("amount"))), 2).as("avg_amount_30d"),
    round(stddev("amount"), 2).as("stddev_amount"),
    round(stddev(when(col("txn_timestamp") > date_sub(refTimestamp, 30), col("amount"))), 2).as("stddev_amount_30d"),
    round(max("amount"), 2).as("max_single_txn"),
    round(min("amount"), 2).as("min_single_txn"),

    // Diversity metrics
    countDistinct("merchant_id").as("unique_merchants_total"),
    countDistinct(when(col("txn_timestamp") > date_sub(refTimestamp, 7), col("merchant_id"))).as("unique_merchants_7d"),

    // Risk indicators
    count(when(col("is_flagged") === true, col("txn_id"))).as("flagged_count"),
    round(
      count(when(col("is_flagged") === true, col("txn_id"))).cast("double") /
      count("txn_id").cast("double") * 100, 2
    ).as("pct_flagged"),

    // Behavioural
    count(when(col("is_international") === true, col("txn_id"))).as("international_txn_count"),
    round(avg("hour_of_day"), 1).as("avg_txn_hour")
  )
  // Join customer details
  .join(
    silverCustomer.select("customer_id", "name", "country", "risk_score"),
    Seq("customer_id"),
    "inner"
  )

goldCustomerFeatures.write
  .format("delta")
  .mode("overwrite")
  .option("overwriteSchema", "true")
  .save(s"$goldPath/gold_customer_features")

println(s"✓ gold_customer_features: ${goldCustomerFeatures.count()} rows")

// COMMAND ----------

// MAGIC %md
// MAGIC ## 2. Gold Account Features
// MAGIC Per-account balance velocity, dormancy, and daily volume metrics.

// COMMAND ----------

val acctTxns = silverTxn.select(
  col("from_account_id").as("account_id"),
  col("txn_id"),
  col("amount"),
  col("txn_timestamp"),
  col("txn_date"),
  col("hour_of_day")
)

// Daily volume per account
val dailyVolume = acctTxns
  .groupBy("account_id", "txn_date")
  .agg(
    sum("amount").as("daily_amount"),
    count("txn_id").as("daily_txn_count")
  )

val goldAccountFeatures = acctTxns
  .groupBy("account_id")
  .agg(
    count("txn_id").as("total_txn_count"),
    round(sum("amount"), 2).as("total_amount"),
    round(avg("amount"), 2).as("avg_txn_amount"),
    max("txn_timestamp").as("last_txn_at"),
    min("txn_timestamp").as("first_txn_at"),

    // Peak hour analysis — percentage of txns during night hours (22-06)
    round(
      count(when(col("hour_of_day") >= 22 || col("hour_of_day") < 6, col("txn_id"))).cast("double") /
      count("txn_id").cast("double") * 100, 2
    ).as("night_txn_pct")
  )
  // Derive dormancy (days since last transaction)
  .withColumn("dormancy_days",
    datediff(refTimestamp, col("last_txn_at"))
  )
  // Derive active period span
  .withColumn("active_span_days",
    datediff(col("last_txn_at"), col("first_txn_at"))
  )
  // Balance velocity: total amount / active span (daily throughput)
  .withColumn("balance_velocity",
    when(col("active_span_days") > 0,
      round(col("total_amount") / col("active_span_days"), 2))
    .otherwise(col("total_amount"))
  )
  // Join daily volume stats
  .join(
    dailyVolume.groupBy("account_id").agg(
      round(avg("daily_amount"), 2).as("avg_daily_volume"),
      round(max("daily_amount"), 2).as("max_daily_volume")
    ),
    Seq("account_id"),
    "left"
  )
  // Join account details
  .join(
    silverAccount.select("account_id", "customer_id", "account_type", "currency", "balance", "status"),
    Seq("account_id"),
    "inner"
  )

goldAccountFeatures.write
  .format("delta")
  .mode("overwrite")
  .option("overwriteSchema", "true")
  .save(s"$goldPath/gold_account_features")

println(s"✓ gold_account_features: ${goldAccountFeatures.count()} rows")

// COMMAND ----------

// MAGIC %md
// MAGIC ## 3. Gold Transaction Pairs
// MAGIC Aggregated account-to-account edges for Neo4j graph loading.
// MAGIC Only includes transfer transactions (account-to-account).

// COMMAND ----------

val goldTransactionPairs = silverTxn
  .filter(col("to_account_id").isNotNull)
  .groupBy("from_account_id", "to_account_id")
  .agg(
    count("txn_id").as("txn_count"),
    round(sum("amount"), 2).as("total_amount"),
    round(avg("amount"), 2).as("avg_amount"),
    round(min("amount"), 2).as("min_amount"),
    round(max("amount"), 2).as("max_amount"),
    min("txn_timestamp").as("first_txn"),
    max("txn_timestamp").as("last_txn"),
    // Flag if any transaction in the pair was flagged
    max(col("is_flagged").cast("int")).as("has_flagged_txn")
  )

goldTransactionPairs.write
  .format("delta")
  .mode("overwrite")
  .option("overwriteSchema", "true")
  .save(s"$goldPath/gold_transaction_pairs")

println(s"✓ gold_transaction_pairs: ${goldTransactionPairs.count()} rows")

// COMMAND ----------

// MAGIC %md
// MAGIC ## 4. Gold Merchant Risk
// MAGIC Per-merchant fraud flag rates and anomaly indicators.

// COMMAND ----------

val goldMerchantRisk = silverTxn
  .filter(col("merchant_id").isNotNull)
  .groupBy("merchant_id")
  .agg(
    count("txn_id").as("total_txns"),
    count(when(col("is_flagged") === true, col("txn_id"))).as("flagged_txns"),
    round(
      count(when(col("is_flagged") === true, col("txn_id"))).cast("double") /
      count("txn_id").cast("double") * 100, 2
    ).as("flag_rate"),
    countDistinct("from_customer_id").as("unique_customers"),
    round(avg("amount"), 2).as("avg_txn_amount"),
    round(stddev("amount"), 2).as("stddev_txn_amount"),
    round(max("amount"), 2).as("max_txn_amount"),
    round(sum("amount"), 2).as("total_volume")
  )
  // Join merchant details
  .join(
    silverMerchant.select("merchant_id", "name", "category", "country", "risk_tier"),
    Seq("merchant_id"),
    "inner"
  )

goldMerchantRisk.write
  .format("delta")
  .mode("overwrite")
  .option("overwriteSchema", "true")
  .save(s"$goldPath/gold_merchant_risk")

println(s"✓ gold_merchant_risk: ${goldMerchantRisk.count()} rows")

// COMMAND ----------

// MAGIC %md
// MAGIC ## Summary

// COMMAND ----------

println("\n" + "=" * 60)
println("Gold Layer Aggregation — Complete")
println("=" * 60)

Seq("gold_customer_features", "gold_account_features", "gold_transaction_pairs", "gold_merchant_risk").foreach { t =>
  val count = spark.read.format("delta").load(s"$goldPath/$t").count()
  println(f"  $t%-30s $count%,8d rows")
}

// COMMAND ----------

// MAGIC %md
// MAGIC ## Validation: Top Risk Customers

// COMMAND ----------

spark.read.format("delta").load(s"$goldPath/gold_customer_features")
  .orderBy(col("pct_flagged").desc)
  .select("name", "country", "total_txn_count", "flagged_count", "pct_flagged", "max_single_txn", "avg_amount_30d")
  .show(15, truncate = false)

// COMMAND ----------

// MAGIC %md
// MAGIC ## Validation: Highest-Risk Merchants

// COMMAND ----------

spark.read.format("delta").load(s"$goldPath/gold_merchant_risk")
  .orderBy(col("flag_rate").desc)
  .select("name", "category", "country", "risk_tier", "total_txns", "flagged_txns", "flag_rate")
  .show(15, truncate = false)
