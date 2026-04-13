# Lessons Learnt

A record of issues encountered, root causes identified, and resolutions applied during the build-out of the Fraud Detection Data Platform demo.

---

## 1. Neo4j 5.x Configuration Namespace

**Problem:** Neo4j Azure Container Instance crashed on startup with `ExitCode 1` within ~8 seconds. No logs were captured because the container died too quickly.

**Root Cause:** The environment variable `NEO4J_dbms_connector_bolt_advertised__address` uses the Neo4j **4.x** configuration namespace. Neo4j 5.x moved all connector settings under `server.*`.

**Resolution:** Replaced the deprecated 4.x variables with the correct 5.x equivalents:

| Wrong (4.x) | Correct (5.x) |
|---|---|
| `NEO4J_dbms_connector_bolt_advertised__address` | `NEO4J_server_bolt_advertised__address` |
| — | `NEO4J_server_bolt_listen__address` |
| — | `NEO4J_server_http_listen__address` |
| — | `NEO4J_server_http_advertised__address` |

**Takeaway:** Always cross-reference environment variable names against the specific major version of the image you are deploying. Neo4j's migration from `dbms.*` to `server.*` is not backward-compatible.

---

## 2. Neo4j Graph Data Science Plugin Requires Enterprise Edition

**Problem:** ACI container crashed immediately when `NEO4J_PLUGINS=["apoc", "graph-data-science"]` was set.

**Root Cause:** The Graph Data Science (GDS) library is only available in Neo4j **Enterprise Edition**. The `neo4j:5.26-community` image silently fails when asked to load it.

**Resolution:** Removed `graph-data-science` from the plugin list. APOC alone works fine on Community Edition, though for this deployment we ultimately removed all plugins to keep the container minimal.

**Takeaway:** Check plugin compatibility with the edition (Community vs Enterprise) before including them in container configuration.

---

## 3. Databricks Cannot Reach localhost Services

**Problem:** Notebook 04 (Neo4j Export) failed with `Connection refused` when connecting to `bolt://localhost:7687`.

**Root Cause:** Databricks clusters run in a managed Azure environment. They have no network path to `localhost` on a developer's machine — Docker Compose services running locally are unreachable.

**Resolution:** Deployed Neo4j as an Azure Container Instance (ACI) with a public IP and DNS label, then stored the Bolt URL in Key Vault so Databricks notebooks resolve it dynamically.

**Takeaway:** Any service that Databricks needs to connect to must be network-reachable from the Databricks VNet. For demos, ACI with a public IP is the simplest option. For production, use Private Link or VNet injection.

---

## 4. Databricks Service Principal Needs Key Vault Secret Access

**Problem:** `dbutils.secrets.get("fraud-detection", "pg-host")` returned silently empty values, causing notebooks to fall back to hardcoded defaults.

**Root Cause:** The Databricks service principal (`2ff814a6-3304-4ab8-85cb-cd0e6f879c1d`) had no RBAC role assignment on the Key Vault. Key Vault-backed secret scopes require the Databricks first-party SP to have explicit secret read access.

**Resolution:** Added the `azuread` Terraform provider to look up the SP's object ID, then created an RBAC role assignment granting it `Key Vault Secrets User`.

```hcl
data "azuread_service_principal" "databricks" {
  client_id = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
}

resource "azurerm_role_assignment" "databricks_secrets" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = data.azuread_service_principal.databricks.object_id
}
```

**Takeaway:** When using Azure Key Vault-backed secret scopes, always grant the Databricks first-party service principal (`2ff814a6-3304-4ab8-85cb-cd0e6f879c1d`) explicit access. The Databricks workspace identity is **not** the same as the deployer's identity.

---

## 5. PowerShell Backtick Escaping in Passwords

**Problem:** PostgreSQL authentication failed when passing the password `Wj]2G` `` ` `` `FxtU?z2NWeIccuZq3!` via PowerShell environment variables or inline strings.

**Root Cause:** The backtick (`` ` ``) is PowerShell's escape character. When embedded in a single-quoted string assigned to `$env:PGPASSWORD`, it gets consumed as an escape sequence rather than passed literally.

**Resolution:** Used Python's `chr(96)` to construct the password string, bypassing PowerShell's string interpolation entirely:

```python
pw = 'Wj]2G' + chr(96) + 'FxtU?z2NWeIccuZq3!'
```

**Takeaway:** Avoid backticks in auto-generated passwords. If unavoidable, construct the string in the target language (Python, Scala) rather than relying on shell escaping. Terraform's `random_password` resource could also be configured to exclude problematic characters.

---

## 6. Azure Resource Naming — Convention Over Chaos

**Problem:** Initial resource names (`fraud-rg`, `fraud-kv-d5g9`) used type-prefixed naming with random suffixes. This scattered related resources across the Azure Portal, violated consistent conventions, and made names unpredictable.

**Root Cause:** Following the old Microsoft CAF pattern of type-first naming, combined with `name_unique` outputs from the naming module which append random strings.

**Resolution:** Adopted a suffix-based naming convention: `[Owner]-[Workload]-[Environment]-[Region]-[Instance]-[ResourceType]`. Used `module.naming.*.name` instead of `*.name_unique` to eliminate random suffixes. The prefix components are defined once in `locals.tf` as a list — a single source of truth consumed by the naming module and any custom resource names:

```hcl
# locals.tf — single source of truth
name_prefix = [
  var.owner,       # xan
  var.workload,    # fraud
  var.environment, # dev
  module.locations.short_name, # uks
  var.instance     # 01
]

# naming.tf — consumes the list directly
module "naming" {
  prefix = local.name_prefix
}

# neo4j.tf — derives a string form for custom names
name = "${join("-", local.name_prefix)}-neo4j"
```

| Before | After |
|---|---|
| `fraud-rg` | `xan-fraud-dev-uks-01-rg` |
| `fraud-kv-d5g9` | `xan-fraud-dev-uks-01-kv` |
| `fraud-psql-d5g9` | `xan-fraud-dev-uks-01-psql` |

**Takeaway:** Naming conventions should be established at project inception. Changing them later forces a full teardown and rebuild of all resources. Keep the owner/prefix short — Key Vault has a 24-character limit that is easily exceeded with longer prefixes.

---

## 7. Naming Convention Changes Destroy All Resources

**Problem:** Updating the Terraform naming prefix from `[fraud]` to `[xan, fraud, dev, uks, 01]` produced a plan to destroy and recreate all 24 resources.

**Root Cause:** Azure resource names are immutable. Changing a name in Terraform is treated as a destroy-and-create operation, not an in-place update.

**Resolution:** Accepted the full rebuild. After applying, re-ran all post-deployment steps:
1. PostgreSQL schema creation (`create_tables.sql`)
2. Data seeding (`generate_data.py`)

**Takeaway:** Lock down your naming convention before deploying to shared or production environments. In a demo context, rebuilds are acceptable. In production, use `moved` blocks or `terraform state mv` to avoid data loss.

---

## 8. ACI Container Debugging with No Logs

**Problem:** When the Neo4j container crashed within seconds, `az container logs` returned `None` — the container terminated before flushing any output.

**Root Cause:** ACI captures stdout/stderr only while the container is running. A sub-10-second crash leaves no log buffer.

**Resolution:** Used iterative simplification to isolate the fault:
1. Removed plugins → still crashed
2. Moved auth to `secure_environment_variables` → still crashed
3. Removed all env vars except auth → still crashed
4. Fixed the config namespace (4.x → 5.x) → **success**

**Takeaway:** When container logs are empty, debug by progressively stripping configuration until you find the minimal failing set. ACI's `az container show --query "containers[0].instanceView"` is more useful than `az container logs` for diagnosing crash loops — it shows exit codes, restart counts, and event timelines.

---

## 9. Terraform `target` Flag and PowerShell Quoting

**Problem:** `terraform apply -auto-approve -target=azurerm_container_group.neo4j -target=azurerm_key_vault_secret.neo4j_password` failed with "Too many command line arguments".

**Root Cause:** PowerShell splits unquoted `-target=value` pairs at spaces. Multiple `-target` flags need to be individually quoted.

**Resolution:** Wrap each target in single quotes:

```powershell
terraform apply -auto-approve `
  '-target=azurerm_container_group.neo4j' `
  '-target=azurerm_key_vault_secret.neo4j_password'
```

**Takeaway:** In PowerShell, always quote Terraform `-target` arguments, especially when using multiple targets or resource addresses containing special characters like dots and square brackets.

---

## 10. The `locations` Module Is Easy to Forget

**Problem:** The `azurerm/locations/azure` module was declared but never referenced — `module.locations.name` and `module.locations.short_name` were unused.

**Root Cause:** The module was included as best practice but the initial resource definitions hardcoded `var.location` for the resource group location and used `var.prefix` alone for naming.

**Resolution:** Integrated `module.locations.short_name` into the naming prefix and used `module.locations.name` for the resource group location.

**Takeaway:** If you declare a module or data source, wire it into at least one resource immediately. Unused declarations are technical debt waiting to become confusion.

---

## 11. Neo4j Spark Connector Does Not Support DecimalType

**Problem:** Notebook 04 (Neo4j Export) failed with `Unable to convert org.apache.spark.sql.types.Decimal to Neo4j Value` when writing customer nodes.

**Root Cause:** The Neo4j Spark Connector (`5.3.1_for_spark_3`) cannot serialise Spark's `DecimalType`. Gold layer aggregations (e.g., `avg_amount_30d`, `pct_flagged`) produce `DecimalType` columns by default.

**Resolution:** Created a `decimalsToDoubles` helper function that casts all `DecimalType` columns to `DoubleType` before writing:

```scala
def decimalsToDoubles(df: DataFrame): DataFrame = {
  df.schema.fields.foldLeft(df) { (acc, f) =>
    f.dataType match {
      case _: org.apache.spark.sql.types.DecimalType =>
        acc.withColumn(s"`${f.name}`", col(s"`${f.name}`").cast("double"))
      case _ => acc
    }
  }
}
```

Applied to all five write operations (customer nodes, account nodes, merchant nodes, transaction nodes, and relationships).

**Takeaway:** Always check connector documentation for type compatibility. The Neo4j Spark Connector supports `Double` but not `Decimal` — cast early, before the write call.

---

## 12. Spark `col()` Interprets Dots as Nested Field References

**Problem:** The `decimalsToDoubles` function failed with `UNRESOLVED_COLUMN.WITH_SUGGESTION` for columns like `rel.total_amount`. Spark suggested `rel` as a possible match.

**Root Cause:** `col("rel.total_amount")` tells Spark to look for a nested field `total_amount` inside a struct column `rel`. The actual column name is literally `rel.total_amount` (a flat string with a dot).

**Resolution:** Wrapped all column name references in backticks to force Spark to treat them as literal names:

```scala
col(s"`${f.name}`").cast("double")
```

**Subsequent fix:** The `rel.` prefix on relationship columns was later removed entirely (see Lesson 17). The backtick-escaping remains in `decimalsToDoubles` as a safety measure for any future dotted column names.

**Takeaway:** When column names contain dots, square brackets, or other special characters, always backtick-escape them in Spark `col()` references. This is especially important in generic helper functions that iterate over `df.schema.fields`.

---

## 13. Neo4j Spark Connector Rejects LIMIT and SKIP

**Problem:** GPT-4o generated Cypher queries with `LIMIT 10`, which failed with `IllegalArgumentException: SKIP/LIMIT are not allowed at the end of the query`.

**Root Cause:** The Neo4j Spark Connector wraps user queries internally for partitioning and result management. It appends its own `SKIP`/`LIMIT` clauses, so user-supplied ones conflict.

**Resolution:** Two-layer fix:
1. Updated the GPT-4o system prompt to instruct: "For Cypher queries, NEVER use LIMIT or SKIP — the connector handles pagination."
2. Added a regex safety strip before execution as a fallback:

```scala
val cleanedQuery = response.query
  .replaceAll("(?i)\\s+LIMIT\\s+\\d+\\s*$", "")
  .replaceAll("(?i)\\s+SKIP\\s+\\d+\\s*$", "")
```

**Takeaway:** When executing AI-generated queries through connectors or ORMs, always sanitise the output for connector-specific restrictions. Defence in depth — prompt engineering reduces the problem, but runtime stripping catches edge cases.

---

## 14. `scala.util.parsing.json.JSON` Is Deprecated

**Problem:** Notebook 05 produced a deprecation warning: `scala.util.parsing.json.JSON is deprecated (since 1.0.6)`.

**Root Cause:** The Scala standard library deprecated its built-in JSON parser. Using it triggers compiler warnings that clutter notebook output.

**Resolution:** Replaced the `JSON.parseFull` call with a simple regex-based field extraction function:

```scala
def extractField(json: String, field: String): String = {
  val pattern = s""""$field"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"""".r
  pattern.findFirstMatchIn(json).map(_.group(1)).getOrElse("")
}
```

This is sufficient for the structured, predictable JSON format returned by GPT-4o (three known fields: `target`, `query`, `explanation`).

**Takeaway:** For simple, well-structured JSON with known fields, regex extraction avoids external library dependencies. For complex or variable JSON, use a proper library like `circe` or `json4s`.

---

## 15. PostgreSQL Firewall — Stale Client IP Causes Silent Timeout

**Problem:** The `generate_data.py` seed script hung indefinitely at "Connecting to PostgreSQL..." and eventually failed with `psycopg.errors.ConnectionTimeout`.

**Root Cause:** The PostgreSQL Flexible Server firewall rule `AllowClientIP` was set to the public IP recorded at deployment time (`84.9.18.32`). The machine's public IP had since changed to `145.224.90.29` — the connection was silently dropped at the Azure network layer with no rejection or error message.

**Resolution:** Updated the firewall rule to the current public IP:

```powershell
$currentIp = (Invoke-RestMethod -Uri "https://api.ipify.org")
az postgres flexible-server firewall-rule update `
  --resource-group xan-fraud-dev-uks-01-rg `
  --name xan-fraud-dev-uks-01-psql `
  --rule-name AllowClientIP `
  --start-ip-address $currentIp `
  --end-ip-address $currentIp
```

**Takeaway:** Azure PaaS firewall rules use exact IP matching. If your public IP changes (VPN reconnect, ISP reassignment, different network), connections silently time out rather than returning a "connection refused" error. Always verify your current IP against the firewall rule before debugging connectivity issues. Consider adding a pre-flight IP check to deployment scripts.

---

## 16. Neo4j Spark Connector — Scala Version Must Match the Databricks Runtime

**Problem:** Notebook 04 (Neo4j export) failed with `NoClassDefFoundError: scala/Serializable` when writing customer nodes to Neo4j.

**Root Cause:** The Neo4j Spark Connector was pinned to the Scala 2.12 build (`neo4j-connector-apache-spark_2.12:5.3.1_for_spark_3`), but the Databricks cluster was running Runtime 17.3 LTS which uses **Scala 2.13**. The `_2.12` suffix in Maven coordinates specifies the Scala version the JAR was compiled against — loading a 2.12 JAR into a 2.13 runtime causes `NoClassDefFoundError` for core Scala traits like `Serializable`.

**Resolution:** Changed the Maven coordinates in `databricks-config.tf` from `_2.12` to `_2.13`:

```hcl
library {
  maven {
    coordinates = "org.neo4j:neo4j-connector-apache-spark_2.13:5.3.1_for_spark_3"
  }
}
```

**Takeaway:** When using `data.databricks_spark_version.lts` to track the latest LTS runtime, the Scala major version can change between LTS releases (e.g. Runtime 14.x used Scala 2.12, Runtime 15.x+ uses Scala 2.13). Any Maven library with a `_2.1x` suffix in its coordinates must match. Pin the Scala version explicitly or add a validation check after the data source resolves.

---

## 17. Neo4j Spark Connector — `rel.` Column Prefix Is Stored Verbatim

**Problem:** After exporting TRANSACTED_WITH relationships from notebook 04, Cypher queries returned `UnknownPropertyKeyWarning` for `txn_count`, `total_amount`, etc. The properties appeared to be missing entirely.

**Root Cause:** Column aliases like `.as("rel.txn_count")` were intended to follow a `rel.` prefix convention for the Neo4j Spark Connector's `keys` save strategy. However, the connector does **not** strip the `rel.` prefix — it stores the column name verbatim as the Neo4j property name. The relationships were written with properties named `rel.txn_count` instead of `txn_count`.

The `source.*` and `target.*` prefixes work differently because they are explicitly mapped via `relationship.source.node.keys` and `relationship.target.node.keys` options (e.g. `source.account_id:account_id`). There is no equivalent mapping for relationship properties — the column name **is** the property name.

**Resolution:** Removed the `rel.` prefix from all relationship property column aliases:

```scala
// Before (properties stored as rel.txn_count, rel.total_amount, etc.)
col("txn_count").as("rel.txn_count"),
col("total_amount").as("rel.total_amount")

// After (properties stored as txn_count, total_amount — correct)
col("txn_count"),
col("total_amount")
```

**Takeaway:** With the Neo4j Spark Connector's `keys` save strategy, only `source.*` and `target.*` column prefixes are consumed by node key mappings. All other columns become relationship properties using their exact column names. Do not add a `rel.` prefix unless you want it as part of the property name in Neo4j.

---

## 18. Neo4j Spark Connector Hangs on Complex Cypher Reads

**Problem:** Notebook 05 (AI query interface) hung indefinitely when executing GPT-4o-generated Cypher queries through `spark.read.format("org.neo4j.spark.DataSource")`. The Spark job would never complete — no error, no timeout, just an infinite hang.

**Root Cause:** The Neo4j Spark Connector performs schema inference before returning results. For complex graph traversals (circular ring detection, multi-hop paths), the connector's internal query wrapping and partitioning logic causes combinatorial explosion. The connector is designed for bulk data transfer, not ad-hoc analytical queries.

**Resolution:** Replaced the Spark Connector read path with direct HTTP POST calls to Neo4j's transaction API (`/db/neo4j/tx/commit`). The response JSON is parsed into a Spark DataFrame using `spark.read.json()` with `explode()` to flatten the nested result structure.

```scala
val conn = new URL(s"$neo4jHttpUrl/db/neo4j/tx/commit")
  .openConnection().asInstanceOf[HttpURLConnection]
conn.setRequestMethod("POST")
conn.setRequestProperty("Authorization", s"Basic $neo4jAuth")
// POST Cypher, parse JSON response into DataFrame
```

The Spark Connector is still used for **writes** in notebook 04 — it excels at bulk node/relationship loading.

**Takeaway:** The Neo4j Spark Connector is optimised for batch ETL (reads of full labels/types, writes of DataFrames). For ad-hoc Cypher queries with complex traversals, use the HTTP transaction API directly. Choose the right tool for the access pattern.

---

## 19. Scala 2.13 `ClassCastException` with `getAs[Seq[String]]`

**Problem:** Notebook 05 failed with `ClassCastException: scala.collection.immutable.$colon$colon cannot be cast to scala.collection.immutable.Seq` when extracting column names from a Neo4j HTTP API response DataFrame.

**Root Cause:** Scala 2.13 changed the collection hierarchy. `getAs[Seq[String]]` resolves to `scala.collection.immutable.Seq` in Scala 2.13, but the Spark Row internally stores the value as `scala.collection.Seq`. The types are not assignment-compatible across the collection repackaging in 2.13.

**Resolution:** Changed the type parameter to `scala.collection.Seq[String]` and added `.toList` to materialise the collection:

```scala
// Before (fails on Scala 2.13)
row.getAs[Seq[String]](0)

// After (works on both 2.12 and 2.13)
row.getAs[scala.collection.Seq[String]](0).toList
```

**Takeaway:** When writing Spark code on Databricks Runtime 15.x+ (Scala 2.13), always use `scala.collection.Seq` instead of bare `Seq` in `getAs[]` type parameters. The Scala 2.13 collection repackaging broke backward compatibility for generic collection types in Spark Row access.

---

## 20. Azure OpenAI Returns Unicode Escape Sequences in JSON

**Problem:** Queries 3 and 6 in notebook 05 failed because GPT-4o returned Cypher/SQL containing `\u003e` (Unicode for `>`) and `\u003c` (Unicode for `<`) instead of the literal characters. The regex-based JSON parser extracted these escape sequences verbatim, producing invalid query syntax.

**Root Cause:** Azure OpenAI's `response_format: {"type": "json_object"}` mode serialises certain characters as Unicode escape sequences in the JSON response body. The `>` and `<` characters are valid JSON but the regex-based `extractField` function returned them without unescaping.

**Resolution:** Added a Unicode unescape step to the `extractField` function:

```scala
val unicodeRe = """\\u([0-9a-fA-F]{4})""".r
unicodeRe.replaceAllIn(rawValue, mg => {
  java.util.regex.Matcher.quoteReplacement(
    new String(Character.toChars(Integer.parseInt(mg.group(1), 16)))
  )
}).replace("\\\\", "\\")
```

**Takeaway:** When parsing JSON from LLM APIs using regex (rather than a proper JSON library), always handle Unicode escape sequences (`\uXXXX`). This is valid JSON encoding that a regex extractor will miss. A proper JSON parser handles this automatically — the trade-off of regex simplicity is manual handling of edge cases like this.
