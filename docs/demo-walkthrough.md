# Demo Walkthrough — Fraud Detection Data Architecture

A structured 15-minute walkthrough for a live demonstration or recorded presentation.

---

## Before You Start

- Azure resources provisioned (`pwsh infra/scripts/deploy.ps1` ✓)
- PostgreSQL loaded with sample data (`python sql/seed/generate_data.py` ✓)
- Neo4j running on ACI (`terraform output neo4j_browser_url` to verify)
- Databricks workspace open in browser
- Databricks cluster running with Neo4j Spark Connector JAR installed

---

## Part 1: Infrastructure as Code (2 minutes)

**Talking Points:**
- Open `infra/` directory — show 12 Terraform files, each with a single responsibility
- Highlight naming convention: `[Owner]-[Workload]-[Environment]-[Region]-[Instance]-[ResourceType]`
- Show `keyvault.tf` — all secrets centralised, Databricks SP granted access
- Show `neo4j.tf` — ACI deployment with public DNS label
- Show `outputs.tf` — all connection strings and endpoints as outputs
- Run `pwsh infra/scripts/status.ps1` to prove all resources are live

**Key Message:** "Every Azure resource is defined in version-controlled Terraform. Nothing is clicked in the portal."

---

## Part 2: Data Model Design (2 minutes)

**Talking Points:**
- Open `docs/data-models.md` — show the star schema ERD
- Explain dimension/fact separation: `dim_customer`, `dim_merchant`, `dim_account`, `fact_transaction`
- Show the Neo4j property graph model alongside it — same data, different perspective
- Highlight how the relational model answers "what happened" and the graph model answers "how are things connected"

**Key Message:** "The right data model for the right question — relational for reporting, graph for pattern detection."

---

## Part 3: PostgreSQL Source Data (2 minutes)

**Talking Points:**
- Show `sql/ddl/create_tables.sql` — star schema with CHECK constraints and performance indexes
- Show `sql/seed/generate_data.py` — point out the 6 fraud pattern generators
- Connect to PostgreSQL and run a quick count:
  ```sql
  SELECT
    (SELECT count(*) FROM dim_customer) AS customers,
    (SELECT count(*) FROM dim_merchant) AS merchants,
    (SELECT count(*) FROM dim_account) AS accounts,
    (SELECT count(*) FROM fact_transaction) AS transactions,
    (SELECT count(*) FROM fact_transaction WHERE is_flagged) AS flagged;
  ```
- Expected: ~500 customers, ~200 merchants, ~1,000 accounts, ~9,200 transactions, ~230 flagged

**Key Message:** "Realistic sample data with deliberate fraud patterns — not random noise."

---

## Part 4: Databricks Medallion Pipeline (4 minutes)

**Talking Points:**

### Bronze Layer (01-bronze-ingestion.scala)
- JDBC read from PostgreSQL — show the `ingestTable` helper function
- Metadata columns: `_ingested_at`, `_source_table`, `_batch_id`
- Delta Lake format — ACID guarantees, time travel

### Silver Layer (02-silver-transformation.scala)
- Data quality: email validation, deduplication, NULL handling
- Enrichment: dimension joins, derived fields (`hour_of_day`, `day_of_week`, `is_international`, `amount_bucket`)
- Show the validation summary cell output

### Gold Layer (03-gold-aggregation.scala)
- Feature engineering: `pct_flagged`, `balance_velocity`, `dormancy_days`, `night_txn_pct`
- Transaction pairs aggregation for graph loading
- Show the "Top Risk Customers" validation output

### Neo4j Export (04-neo4j-export.scala)
- Neo4j Spark Connector writes nodes and relationships
- Show the summary cell output with node/relationship counts

**Key Message:** "Each layer adds value — raw to clean to analytical features, all in Scala on Delta Lake."

---

## Part 5: Neo4j Graph Analysis (3 minutes)

**Talking Points:**
- Open Neo4j Browser via the ACI URL: `terraform output neo4j_browser_url`
- Run the graph overview query:
  ```cypher
  MATCH (n) RETURN labels(n)[0] AS label, count(n) AS count ORDER BY label;
  ```
- Run the circular ring detection query from `fraud-patterns.cypher` — show the visual graph
- Run the money mule identification query — show pass-through accounts
- Run the cross-border analysis query — show international flows

**Key Message:** "Graph databases reveal patterns that are invisible in relational tables — circular flows, intermediaries, and network clusters."

---

## Part 6: Azure OpenAI Natural Language Interface (2 minutes)

**Talking Points:**
- Open `05-ai-query-interface.scala` in Databricks
- Show the system prompt in `ai/prompts/system_prompt.md` — schema context and few-shot examples
- Run demo query: "Show me the top 10 customers with the highest fraud flag rate"
  - GPT-4o classifies as SQL, generates the query, executes via Spark SQL
- Run demo query: "Find circular transaction patterns"
  - GPT-4o classifies as Cypher, generates the query, **executes directly via Neo4j's HTTP transaction API** and displays results in the notebook
- Highlight: the model chooses the right database automatically and all queries execute inline — no external tools needed

**Key Message:** "Non-technical stakeholders can query the fraud system in plain English — the AI routes to the right database."

---

## Closing (1 minute)

**Summary Points:**
1. **Infrastructure as Code** — Terraform provisions everything reproducibly
2. **Star Schema** — PostgreSQL for structured OLTP data with deliberate fraud patterns
3. **Medallion Architecture** — Bronze/Silver/Gold in Databricks with Scala and Delta Lake
4. **Graph Analysis** — Neo4j detects relationship patterns invisible to SQL
5. **AI Integration** — Azure OpenAI democratises data access with natural language
6. **End-to-End Pipeline** — From raw data to actionable fraud insights

**Final Message:** "This demonstrates a production-ready architecture pattern, not just individual technologies — every component has a justified role in the fraud detection workflow."

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| PostgreSQL connection refused | Check IP firewall: `terraform output -raw postgresql_fqdn` |
| Databricks cluster won't start | Verify Premium SKU and region quota |
| Neo4j not reachable | Check ACI status: `az container show -g <rg> -n <name> --query instanceView.state` |
| OpenAI API 401 error | Check API key in Key Vault: `az keyvault secret show --vault-name <kv> -n openai-key` |
| No data in gold tables | Run notebooks 01–03 in sequence first |
