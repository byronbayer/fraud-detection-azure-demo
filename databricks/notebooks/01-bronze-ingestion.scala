// Databricks notebook source
// =============================================================================
// 01 — Bronze Layer Ingestion
// =============================================================================
// Reads all tables from Azure PostgreSQL via JDBC and writes them as Delta
// tables in the bronze layer with ingestion metadata columns.
//
// Prerequisites:
//   - PostgreSQL JDBC driver is available on the cluster (built-in on DBR 13+)
//   - Key-Vault-backed secret scope "fraud-detection" configured
//     (provisioned by Terraform — see infra/databricks-config.tf)
// =============================================================================

// COMMAND ----------

// MAGIC %md
// MAGIC ## Configuration
// MAGIC All values are read from the Key-Vault-backed secret scope `fraud-detection`.
// MAGIC Override with widgets only for ad-hoc testing.

// COMMAND ----------

val scope = "fraud-detection"

// Helper: read from Key Vault scope, fall back to widget if set
def getConfig(key: String, widgetDefault: String = ""): String = {
  try {
    dbutils.secrets.get(scope, key)
  } catch {
    case _: Exception => widgetDefault
  }
}

val pgHost     = getConfig("pg-host")
val pgPort     = getConfig("pg-port", "5432")
val pgDatabase = getConfig("pg-database", "fraud_detection")
val pgUser     = getConfig("pg-user", "pgadmin")
val pgPassword = getConfig("pg-password")
val bronzePath = getConfig("bronze-path", "/mnt/fraud/bronze")

val jdbcUrl = s"jdbc:postgresql://${pgHost}:${pgPort}/${pgDatabase}?sslmode=require"

val connectionProperties = new java.util.Properties()
connectionProperties.put("user", pgUser)
connectionProperties.put("password", pgPassword)
connectionProperties.put("driver", "org.postgresql.Driver")

println(s"JDBC URL: jdbc:postgresql://${pgHost}:${pgPort}/${pgDatabase}?sslmode=require")
println(s"Bronze path: $bronzePath")

// COMMAND ----------

// MAGIC %md
// MAGIC ## Ingestion Metadata
// MAGIC Every bronze table gets three metadata columns for lineage tracking.

// COMMAND ----------

import org.apache.spark.sql.{DataFrame, SparkSession}
import org.apache.spark.sql.functions._
import java.time.Instant

val batchId = java.util.UUID.randomUUID().toString
val ingestedAt = Instant.now().toString

def addIngestionMetadata(df: DataFrame, sourceTable: String): DataFrame = {
  df.withColumn("_ingested_at", lit(ingestedAt).cast("timestamp"))
    .withColumn("_source_table", lit(sourceTable))
    .withColumn("_batch_id", lit(batchId))
}

println(s"Batch ID: $batchId")
println(s"Ingestion timestamp: $ingestedAt")

// COMMAND ----------

// MAGIC %md
// MAGIC ## Read & Write Helper

// COMMAND ----------

def ingestTable(tableName: String): Long = {
  println(s"Reading $tableName from PostgreSQL...")
  val df = spark.read
    .jdbc(jdbcUrl, tableName, connectionProperties)

  val enriched = addIngestionMetadata(df, tableName)

  val outputPath = s"$bronzePath/bronze_$tableName"
  enriched.write
    .format("delta")
    .mode("overwrite")
    .option("overwriteSchema", "true")
    .save(outputPath)

  val count = enriched.count()
  println(s"  ✓ bronze_$tableName: $count rows → $outputPath")
  count
}

// COMMAND ----------

// MAGIC %md
// MAGIC ## Ingest All Tables

// COMMAND ----------

val tables = Seq("dim_customer", "dim_merchant", "dim_account", "fact_transaction")

println("=" * 60)
println("Bronze Layer Ingestion — Starting")
println("=" * 60)

val counts = tables.map { t =>
  val count = ingestTable(t)
  (t, count)
}

// COMMAND ----------

// MAGIC %md
// MAGIC ## Summary

// COMMAND ----------

println("\n" + "=" * 60)
println("Bronze Layer Ingestion — Complete")
println("=" * 60)

counts.foreach { case (table, count) =>
  println(f"  bronze_$table%-30s $count%,8d rows")
}

val totalRows = counts.map(_._2).sum
println(s"\n  Total rows ingested: ${"%,d".format(totalRows)}")
println(s"  Batch ID: $batchId")

// COMMAND ----------

// MAGIC %md
// MAGIC ## Quick Validation
// MAGIC Verify a sample from each bronze table.

// COMMAND ----------

tables.foreach { t =>
  println(s"\n--- bronze_$t (first 3 rows) ---")
  spark.read.format("delta").load(s"$bronzePath/bronze_$t").show(3, truncate = false)
}
