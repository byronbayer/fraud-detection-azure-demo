// Databricks notebook source
// =============================================================================
// 05 — Azure OpenAI Natural Language Query Interface
// =============================================================================
// Accepts a natural language question, uses Azure OpenAI (GPT-4o) to classify
// the question and generate either SQL (for PostgreSQL gold tables) or Cypher
// (for Neo4j graph), then executes the generated query and returns results.
//
// Demonstrates the "democratise data access" pillar of the architecture —
// non-technical stakeholders can query fraud data in plain English.
//
// Prerequisites:
//   - Azure OpenAI endpoint + API key (from Terraform outputs)
//   - Gold layer tables loaded (03-gold-aggregation)
//   - Neo4j populated (04-neo4j-export) — for graph queries
//   - PostgreSQL with gold views or Spark SQL tables registered
// =============================================================================

// COMMAND ----------

// MAGIC %md
// MAGIC ## Configuration

// COMMAND ----------

// All values are read from the Key-Vault-backed secret scope.
val scope = "fraud-detection"

def getConfig(key: String, fallback: String = ""): String = {
  try { dbutils.secrets.get(scope, key) } catch { case _: Exception => fallback }
}

val openaiEndpoint   = getConfig("openai-endpoint")
val openaiKey        = getConfig("openai-key")
val openaiDeployment = getConfig("openai-deployment", "gpt-4o")
val goldPath         = getConfig("gold-path", "/mnt/fraud/gold")
val neo4jUrl         = getConfig("neo4j-url", "bolt://localhost:7687") // local dev fallback
val neo4jUser        = getConfig("neo4j-user", "neo4j")
val neo4jPassword    = getConfig("neo4j-password", "fraud-demo-2026")

println(s"OpenAI endpoint: $openaiEndpoint")
println(s"Gold path: $goldPath")
println(s"Neo4j URL: $neo4jUrl")

// COMMAND ----------

// MAGIC %md
// MAGIC ## Register Gold Tables as Spark SQL Views
// MAGIC This allows us to run generated SQL directly through Spark SQL.

// COMMAND ----------

Seq("gold_customer_features", "gold_account_features", "gold_transaction_pairs", "gold_merchant_risk").foreach { table =>
  spark.read.format("delta").load(s"$goldPath/$table").createOrReplaceTempView(table)
  println(s"✓ Registered view: $table")
}

// COMMAND ----------

// MAGIC %md
// MAGIC ## Load System Prompt

// COMMAND ----------

// The system prompt contains schema context, rules, and few-shot examples.
// In production this would be loaded from a file; here we embed it.

val systemPrompt = """You are a data query assistant for a fraud detection system. You have access to two database backends:

1. **PostgreSQL / Spark SQL** (gold layer tables): gold_customer_features, gold_account_features, gold_merchant_risk, gold_transaction_pairs
2. **Neo4j** (graph): Customer, Account, Merchant nodes with OWNS and TRANSACTED_WITH relationships

Classify each question and return ONLY a JSON object:
{
  "target": "sql" or "cypher",
  "query": "<executable query>",
  "explanation": "<one sentence>"
}

Rules:
- Use SQL for aggregations, rankings, filtering, tabular reports
- Use Cypher for relationships, paths, patterns, rings, networks
- PostgreSQL-compatible SQL dialect
- Neo4j 5.x Cypher
- Read-only queries only — never DELETE, DROP, SET, CREATE, MERGE, or REMOVE
- For SQL queries, default LIMIT 20 unless specified
- For Cypher queries, default LIMIT 20 unless specified
- NEVER use variable-length path patterns like [:TRANSACTED_WITH*] — they are combinatorially explosive
- Always use fixed-length explicit hops (e.g. 3 hops for circular rings)
- Keep Cypher queries simple and bounded

Key tables/schema:
- gold_customer_features: customer_id, name, country, risk_score, total_txn_count, txn_count_24h, txn_count_7d, avg_amount, avg_amount_30d, stddev_amount, max_single_txn, unique_merchants_total, unique_merchants_7d, flagged_count, pct_flagged, international_txn_count
- gold_account_features: account_id, customer_id, account_type, currency, balance, status, total_txn_count, total_amount, dormancy_days, balance_velocity, avg_daily_volume, night_txn_pct
- gold_merchant_risk: merchant_id, name, category, country, risk_tier, total_txns, flagged_txns, flag_rate, unique_customers, avg_txn_amount, total_volume
- gold_transaction_pairs: from_account_id, to_account_id, txn_count, total_amount, avg_amount, has_flagged_txn

Neo4j nodes: Customer(customer_id, name, country, risk_score), Account(account_id, account_type, balance, status), Merchant(merchant_id, name, category, risk_tier)
Neo4j rels: (Customer)-[:OWNS]->(Account), (Account)-[:TRANSACTED_WITH {txn_count, total_amount, has_flagged_txn}]->(Account)

Example Cypher queries:
- Circular rings (3-hop): MATCH (a1:Account)-[:TRANSACTED_WITH]->(a2:Account)-[:TRANSACTED_WITH]->(a3:Account)-[:TRANSACTED_WITH]->(a1) WHERE a1 <> a2 AND a2 <> a3 RETURN a1.account_id AS account_1, a2.account_id AS account_2, a3.account_id AS account_3 LIMIT 20
- Money mules (intermediaries): MATCH (src:Account)-[:TRANSACTED_WITH]->(hub:Account)-[:TRANSACTED_WITH]->(dst:Account) WHERE src <> dst WITH hub, count(DISTINCT src) AS in_degree, count(DISTINCT dst) AS out_degree WHERE in_degree >= 3 AND out_degree >= 3 RETURN hub.account_id, in_degree, out_degree ORDER BY in_degree + out_degree DESC LIMIT 20
- High-velocity pairs: MATCH (a1:Account)-[r:TRANSACTED_WITH]->(a2:Account) WHERE r.txn_count >= 5 RETURN a1.account_id, a2.account_id, r.txn_count, r.total_amount ORDER BY r.txn_count DESC LIMIT 20
- Cross-border flows: MATCH (c1:Customer)-[:OWNS]->(a1:Account)-[:TRANSACTED_WITH]->(a2:Account)<-[:OWNS]-(c2:Customer) WHERE c1.country <> c2.country RETURN c1.name, c1.country, a1.account_id, a2.account_id, c2.name, c2.country LIMIT 20
"""

// COMMAND ----------

// MAGIC %md
// MAGIC ## Azure OpenAI API Client

// COMMAND ----------

import java.net.{HttpURLConnection, URL}
import java.io.{BufferedReader, InputStreamReader, OutputStreamWriter}

/**
 * Calls the Azure OpenAI Chat Completions API.
 * Uses the REST API directly — no external SDK dependency required.
 */
def callAzureOpenAI(userMessage: String): String = {
  val apiVersion = "2024-06-01"
  val url = new URL(
    s"${openaiEndpoint}openai/deployments/$openaiDeployment/chat/completions?api-version=$apiVersion"
  )

  val requestBody = s"""{
    "messages": [
      {"role": "system", "content": ${escapeJson(systemPrompt)}},
      {"role": "user", "content": ${escapeJson(userMessage)}}
    ],
    "temperature": 0.1,
    "max_tokens": 1000,
    "response_format": {"type": "json_object"}
  }"""

  val conn = url.openConnection().asInstanceOf[HttpURLConnection]
  try {
    conn.setRequestMethod("POST")
    conn.setRequestProperty("Content-Type", "application/json")
    conn.setRequestProperty("api-key", openaiKey)
    conn.setDoOutput(true)

    val writer = new OutputStreamWriter(conn.getOutputStream, "UTF-8")
    writer.write(requestBody)
    writer.flush()
    writer.close()

    val responseCode = conn.getResponseCode
    val stream = if (responseCode >= 200 && responseCode < 300)
      conn.getInputStream else conn.getErrorStream

    val reader = new BufferedReader(new InputStreamReader(stream, "UTF-8"))
    val response = new StringBuilder
    var line = reader.readLine()
    while (line != null) {
      response.append(line)
      line = reader.readLine()
    }
    reader.close()

    if (responseCode >= 400) {
      throw new RuntimeException(s"Azure OpenAI API error ($responseCode): ${response.toString}")
    }

    response.toString
  } finally {
    conn.disconnect()
  }
}

/** Escape a string for safe JSON embedding. */
def escapeJson(s: String): String = {
  "\"" + s.replace("\\", "\\\\")
          .replace("\"", "\\\"")
          .replace("\n", "\\n")
          .replace("\r", "\\r")
          .replace("\t", "\\t") + "\""
}

// COMMAND ----------

// MAGIC %md
// MAGIC ## Response Parser

// COMMAND ----------

case class QueryResponse(target: String, query: String, explanation: String)

def parseOpenAIResponse(raw: String): QueryResponse = {
  // Extract the content field from the Chat Completions response
  val contentPattern = """"content"\s*:\s*"((?:[^"\\]|\\.)*)"""".r
  val content = contentPattern.findFirstMatchIn(raw) match {
    case Some(m) => m.group(1)
      .replace("\\n", "\n")
      .replace("\\\"", "\"")
      .replace("\\\\", "\\")
    case None => throw new RuntimeException(s"Could not extract content from response: ${raw.take(500)}")
  }

  // Extract fields from the JSON content using regex (avoids deprecated scala.util.parsing.json)
  def extractField(json: String, field: String): String = {
    val pattern = s""""$field"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"""".r
    pattern.findFirstMatchIn(json) match {
      case Some(m) =>
        val step1 = m.group(1)
          .replace("\\n", "\n")
          .replace("\\\"", "\"")
          .replace("\\/", "/")
        // Unescape Unicode sequences (\u003e -> >, \u003c -> <, etc.)
        val unicodeRe = """\\u([0-9a-fA-F]{4})""".r
        unicodeRe.replaceAllIn(step1, mg => {
          java.util.regex.Matcher.quoteReplacement(
            new String(Character.toChars(Integer.parseInt(mg.group(1), 16)))
          )
        }).replace("\\\\", "\\")
      case None => ""
    }
  }

  QueryResponse(
    target = extractField(content, "target"),
    query = extractField(content, "query"),
    explanation = extractField(content, "explanation")
  )
}

// COMMAND ----------

// MAGIC %md
// MAGIC ## Query Executor

// COMMAND ----------

def executeQuery(response: QueryResponse): Unit = {
  println(s"\n${"=" * 70}")
  println(s"Target:      ${response.target.toUpperCase}")
  println(s"Explanation: ${response.explanation}")
  println(s"${"=" * 70}")
  println(s"\nGenerated Query:\n${response.query}\n")

  response.target.toLowerCase match {
    case "sql" =>
      println(s"${"-" * 70}")
      println("Results (via Spark SQL):")
      println(s"${"-" * 70}")
      val df = spark.sql(response.query)
      df.show(20, truncate = false)

    case "cypher" =>
      println(s"${"-" * 70}")
      println("Results (via Neo4j):")
      println(s"${"-" * 70}")
      // Use Neo4j HTTP API directly — the Spark Connector's read mode wraps
      // queries for schema inference and pagination, which can hang on complex
      // graph traversal patterns. The HTTP API executes the query as-is.
      val neo4jHttpUrl = neo4jUrl
        .replace("bolt://", "http://")
        .replace("neo4j://", "http://")
        .replace(":7687", ":7474") + "/db/neo4j/tx/commit"
      val neo4jAuth = java.util.Base64.getEncoder.encodeToString(
        s"$neo4jUser:$neo4jPassword".getBytes("UTF-8")
      )
      val cypherBody = s"""{"statements":[{"statement":${escapeJson(response.query)}}]}"""
      val cypherUrl = new URL(neo4jHttpUrl)
      val cypherConn = cypherUrl.openConnection().asInstanceOf[HttpURLConnection]
      try {
        cypherConn.setRequestMethod("POST")
        cypherConn.setRequestProperty("Content-Type", "application/json")
        cypherConn.setRequestProperty("Authorization", s"Basic $neo4jAuth")
        cypherConn.setConnectTimeout(30000)
        cypherConn.setReadTimeout(120000)
        cypherConn.setDoOutput(true)
        val cw = new OutputStreamWriter(cypherConn.getOutputStream, "UTF-8")
        cw.write(cypherBody)
        cw.flush()
        cw.close()
        val cypherCode = cypherConn.getResponseCode
        val cypherStream = if (cypherCode >= 200 && cypherCode < 300)
          cypherConn.getInputStream else cypherConn.getErrorStream
        val cr = new BufferedReader(new InputStreamReader(cypherStream, "UTF-8"))
        val cypherSb = new StringBuilder
        var cl = cr.readLine()
        while (cl != null) { cypherSb.append(cl); cl = cr.readLine() }
        cr.close()
        if (cypherCode >= 400) {
          throw new RuntimeException(s"Neo4j API error ($cypherCode): ${cypherSb.toString.take(500)}")
        }
        // Parse Neo4j HTTP response into a DataFrame
        import spark.implicits._
        import org.apache.spark.sql.functions.{col, explode}
        val jsonDs = Seq(cypherSb.toString).toDS()
        val parsed = spark.read.json(jsonDs)
        val resultRow = parsed.select(explode(col("results")).as("r"))
        val columns = resultRow.select(col("r.columns")).first().getAs[scala.collection.Seq[String]](0).toList
        val rows = resultRow.select(explode(col("r.data")).as("d")).select(col("d.row").as("row"))
        if (rows.isEmpty) {
          println("No results found.")
        } else {
          val namedDf = rows.select(
            columns.zipWithIndex.map { case (name, idx) =>
              col("row").getItem(idx).cast("string").as(name)
            }: _*
          )
          namedDf.show(20, truncate = false)
          println(s"(${namedDf.count()} rows)")
        }
      } finally {
        cypherConn.disconnect()
      }

    case other =>
      println(s"Unknown target: $other")
  }
}

// COMMAND ----------

// MAGIC %md
// MAGIC ## Main Query Function

// COMMAND ----------

/**
 * Ask a natural language question about fraud data.
 * GPT-4o classifies the question and generates SQL or Cypher.
 */
def askFraudQuestion(question: String): Unit = {
  println(s"\n🔍 Question: $question")

  try {
    // 1. Call Azure OpenAI
    val rawResponse = callAzureOpenAI(question)

    // 2. Parse response
    val parsed = parseOpenAIResponse(rawResponse)

    // 3. Execute or display
    executeQuery(parsed)
  } catch {
    case e: Exception =>
      println(s"\n❌ Error processing question: ${e.getMessage}")
      e.printStackTrace()
  }
}

// COMMAND ----------

// MAGIC %md
// MAGIC ## Demo Queries
// MAGIC Run these cells to demonstrate the natural language interface.

// COMMAND ----------

// MAGIC %md
// MAGIC ### Query 1: Simple aggregation (should generate SQL)

// COMMAND ----------

askFraudQuestion("Show me the top 10 customers with the highest fraud flag rate")

// COMMAND ----------

// MAGIC %md
// MAGIC ### Query 2: Graph pattern (should generate Cypher)

// COMMAND ----------

askFraudQuestion("Find circular transaction patterns where money flows in a ring between accounts")

// COMMAND ----------

// MAGIC %md
// MAGIC ### Query 3: Merchant analysis (should generate SQL)

// COMMAND ----------

askFraudQuestion("Which merchants have a fraud flag rate above 15% and what categories are they in?")

// COMMAND ----------

// MAGIC %md
// MAGIC ### Query 4: Network analysis (should generate Cypher)

// COMMAND ----------

askFraudQuestion("Show me accounts that act as intermediaries, receiving money from many accounts and sending to many others")

// COMMAND ----------

// MAGIC %md
// MAGIC ### Query 5: Cross-border risk (should generate Cypher)

// COMMAND ----------

askFraudQuestion("Find cross-border transaction flows where sender and receiver are in different countries")

// COMMAND ----------

// MAGIC %md
// MAGIC ### Query 6: Dormant account risk (should generate SQL)

// COMMAND ----------

askFraudQuestion("Which accounts have been dormant for more than 30 days but had high transaction velocity before going quiet?")

// COMMAND ----------

// MAGIC %md
// MAGIC ### Interactive Query
// MAGIC Uncomment and edit the question below to try your own queries.

// COMMAND ----------

// askFraudQuestion("Your question here")
