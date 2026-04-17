// Databricks notebook source
// =============================================================================
// 04 — Neo4j Graph Export
// =============================================================================
// Reads gold Delta tables and writes nodes/relationships to Neo4j using the
// Neo4j Spark Connector. This creates the property graph used for fraud
// ring detection via Cypher traversals.
//
// Prerequisites:
//   - Neo4j instance running and reachable from Databricks (ACI/public endpoint)
//   - Neo4j Spark Connector library installed on the cluster
//   - Gold layer tables populated (03-gold-aggregation)
//
// Connector: org.neo4j.spark:neo4j-connector-apache-spark_2.13:5.3.1_for_spark_3
// =============================================================================

// COMMAND ----------

// MAGIC %md
// MAGIC ## Configuration
// MAGIC All values are read from the Key-Vault-backed secret scope `fraud-detection`.

// COMMAND ----------

val scope = "fraud-detection"

def getConfig(key: String, fallback: String = ""): String = {
  try { dbutils.secrets.get(scope, key) } catch { case _: Exception => fallback }
}

val goldPath      = getConfig("gold-path", "/mnt/fraud/gold")
val neo4jUrl      = getConfig("neo4j-url", "bolt://localhost:7687") // local dev fallback
val neo4jUser     = getConfig("neo4j-user", "neo4j")
val neo4jPassword = getConfig("neo4j-password", "fraud-demo-2026")
val neo4jBrowserUrl = neo4jUrl
  .replace("bolt://", "http://")
  .replace("neo4j://", "http://")
  .replace(":7687", ":7474")

println(s"Gold path: $goldPath")
println(s"Neo4j URL: $neo4jUrl")

// COMMAND ----------

import org.apache.spark.sql.functions._
import org.apache.spark.sql.types.DecimalType

// Neo4j Spark Connector does not support Spark DecimalType.
// Cast all Decimal columns to Double before writing.
def decimalsToDoubles(df: org.apache.spark.sql.DataFrame): org.apache.spark.sql.DataFrame = {
  df.schema.fields.foldLeft(df) { (acc, f) =>
    f.dataType match {
      case _: DecimalType => acc.withColumn(f.name, col(s"`${f.name}`").cast("double"))
      case _ => acc
    }
  }
}

// Common Neo4j write options
def neo4jOpts(df: org.apache.spark.sql.DataFrameWriter[org.apache.spark.sql.Row]) = {
  df.format("org.neo4j.spark.DataSource")
    .option("url", neo4jUrl)
    .option("authentication.type", "basic")
    .option("authentication.basic.username", neo4jUser)
    .option("authentication.basic.password", neo4jPassword)
}

// COMMAND ----------

// MAGIC %md
// MAGIC ## 1. Export Customer Nodes
// MAGIC Properties: customer_id, name, country, risk_score, total_txn_count, pct_flagged

// COMMAND ----------

val customerNodes = spark.read.format("delta")
  .load(s"$goldPath/gold_customer_features")
  .select(
    col("customer_id"),
    col("name"),
    col("country"),
    col("risk_score"),
    col("total_txn_count"),
    col("avg_amount"),
    col("max_single_txn"),
    col("pct_flagged"),
    col("unique_merchants_total"),
    col("international_txn_count")
  )

neo4jOpts(decimalsToDoubles(customerNodes).write)
  .option("labels", ":Customer")
  .option("node.keys", "customer_id")
  .option("schema.optimization.type", "NODE_CONSTRAINTS")
  .mode("overwrite")
  .save()

println(s"✓ Customer nodes exported: ${customerNodes.count()}")

// COMMAND ----------

// MAGIC %md
// MAGIC ## 2. Export Account Nodes
// MAGIC Properties: account_id, account_type, currency, balance, status, dormancy_days

// COMMAND ----------

val accountNodes = spark.read.format("delta")
  .load(s"$goldPath/gold_account_features")
  .select(
    col("account_id"),
    col("customer_id"),
    col("account_type"),
    col("currency"),
    col("balance"),
    col("status"),
    col("total_txn_count"),
    col("total_amount"),
    col("dormancy_days"),
    col("balance_velocity"),
    col("avg_daily_volume"),
    col("night_txn_pct")
  )

neo4jOpts(decimalsToDoubles(accountNodes).write)
  .option("labels", ":Account")
  .option("node.keys", "account_id")
  .option("schema.optimization.type", "NODE_CONSTRAINTS")
  .mode("overwrite")
  .save()

println(s"✓ Account nodes exported: ${accountNodes.count()}")

// COMMAND ----------

// MAGIC %md
// MAGIC ## 3. Export Merchant Nodes
// MAGIC Properties: merchant_id, name, category, country, risk_tier, flag_rate

// COMMAND ----------

val merchantNodes = spark.read.format("delta")
  .load(s"$goldPath/gold_merchant_risk")
  .select(
    col("merchant_id"),
    col("name"),
    col("category"),
    col("country"),
    col("risk_tier"),
    col("total_txns"),
    col("flagged_txns"),
    col("flag_rate"),
    col("unique_customers"),
    col("avg_txn_amount"),
    col("total_volume")
  )

neo4jOpts(decimalsToDoubles(merchantNodes).write)
  .option("labels", ":Merchant")
  .option("node.keys", "merchant_id")
  .option("schema.optimization.type", "NODE_CONSTRAINTS")
  .mode("overwrite")
  .save()

println(s"✓ Merchant nodes exported: ${merchantNodes.count()}")

// COMMAND ----------

// MAGIC %md
// MAGIC ## 4. Export OWNS Relationships (Customer → Account)

// COMMAND ----------

val ownsRels = decimalsToDoubles(
  spark.read.format("delta")
    .load(s"$goldPath/gold_account_features")
  ).select(
    col("customer_id").as("source.customer_id"),
    col("account_id").as("target.account_id"),
    col("account_type"),
    col("status")
  )

neo4jOpts(ownsRels.write)
  .option("relationship", "OWNS")
  .option("relationship.save.strategy", "keys")
  .option("relationship.source.labels", ":Customer")
  .option("relationship.source.node.keys", "source.customer_id:customer_id")
  .option("relationship.target.labels", ":Account")
  .option("relationship.target.node.keys", "target.account_id:account_id")
  .mode("overwrite")
  .save()

println(s"✓ OWNS relationships exported: ${ownsRels.count()}")

// COMMAND ----------

// MAGIC %md
// MAGIC ## 5. Export TRANSACTED_WITH Relationships (Account → Account)
// MAGIC Aggregated edges from the gold transaction pairs table.

// COMMAND ----------

val transactedRels = decimalsToDoubles(
  spark.read.format("delta")
    .load(s"$goldPath/gold_transaction_pairs")
  ).select(
    col("from_account_id").as("source.account_id"),
    col("to_account_id").as("target.account_id"),
    col("txn_count"),
    col("total_amount"),
    col("avg_amount"),
    col("min_amount"),
    col("max_amount"),
    col("first_txn"),
    col("last_txn"),
    col("has_flagged_txn")
  )

neo4jOpts(transactedRels.write)
  .option("relationship", "TRANSACTED_WITH")
  .option("relationship.save.strategy", "keys")
  .option("relationship.source.labels", ":Account")
  .option("relationship.source.node.keys", "source.account_id:account_id")
  .option("relationship.target.labels", ":Account")
  .option("relationship.target.node.keys", "target.account_id:account_id")
  .mode("overwrite")
  .save()

println(s"✓ TRANSACTED_WITH relationships exported: ${transactedRels.count()}")

// COMMAND ----------

// MAGIC %md
// MAGIC ## Summary

// COMMAND ----------

println("\n" + "=" * 60)
println("Neo4j Graph Export — Complete")
println("=" * 60)
println(s"  Customer nodes:             ${customerNodes.count()}")
println(s"  Account nodes:              ${accountNodes.count()}")
println(s"  Merchant nodes:             ${merchantNodes.count()}")
println(s"  OWNS relationships:         ${ownsRels.count()}")
println(s"  TRANSACTED_WITH relationships: ${transactedRels.count()}")
println(s"\n  Neo4j URL: $neo4jUrl")
println(s"  Connect via Neo4j Browser:  $neo4jBrowserUrl")
println("=" * 60)
