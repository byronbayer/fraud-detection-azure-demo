# Design Decisions

Rationale behind each technology choice in the fraud detection architecture.

---

## 1. Why PostgreSQL for the Source Database

**Decision:** Azure Database for PostgreSQL Flexible Server (Burstable B_Standard_B1ms, v16)

**Rationale:**
- **ACID compliance** — Financial transaction data demands transactional integrity; PostgreSQL guarantees this natively.
- **Star schema support** — Dimension/fact separation with foreign keys and CHECK constraints provides strong data governance at the source.
- **Azure-managed** — Flexible Server offers automated backups, patching, and high availability without operational overhead.
- **JDBC ecosystem** — First-class JDBC driver support for Databricks Spark ingestion.
- **Cost efficiency** — Burstable B1ms tier costs ~£12/month, appropriate for a demo that needs to persist data but not handle production load.

**Alternatives Considered:**
- *Azure SQL Database* — Higher cost, SQL Server syntax less portable.
- *Cosmos DB* — Document model doesn't suit the structured star schema; more expensive per-GB.
- *Azure Data Lake (raw files)* — No transactional guarantees or query capabilities at the source layer.

---

## 2. Why Neo4j for Fraud Detection

**Decision:** Neo4j 5.26 Community Edition on Azure Container Instance (with Docker Compose as local alternative)

**Rationale:**
- **Relationship-first model** — Fraud detection is fundamentally about relationships: who transacts with whom, through which accounts, in what patterns. Graph databases model this natively.
- **Pattern matching** — Cypher's `MATCH` clause can express circular money flows, fan-out/fan-in patterns, and multi-hop traversals concisely — queries that would require recursive CTEs or self-joins in SQL.
- **Traversal performance** — Index-free adjacency means relationship traversal is O(1) per hop regardless of graph size, compared to O(n log n) join performance in relational databases.
- **Visual exploration** — Neo4j Browser provides immediate visual graph rendering, powerful for demonstrating fraud networks.
- **Spark Connector** — The official Neo4j Spark Connector (`5.3.1_for_spark_3`) enables direct writes from Databricks gold layer tables. For ad-hoc Cypher reads (e.g. the AI query interface), the HTTP transaction API is used instead — the Spark Connector's schema inference causes complex traversals to hang.

**Alternatives Considered:**
- *Azure Cosmos DB (Gremlin API)* — Fully managed but more complex query syntax, higher cost, less mature tooling.
- *Amazon Neptune* — Not Azure-native; adds cross-cloud complexity.
- *JanusGraph* — Open source but operationally complex, weaker tooling.

**Deployment:** Neo4j is deployed as an Azure Container Instance (ACI) provisioned by Terraform, with a public DNS label so Databricks can connect directly. Credentials are stored in Key Vault and accessed via the Databricks secret scope. Docker Compose (`neo4j/docker-compose.yml`) remains available for local development.

---

## 3. Why Databricks with Scala

**Decision:** Azure Databricks Premium tier, Scala notebooks, Delta Lake storage

**Rationale:**
- **Unified analytics platform** — Databricks combines ETL, data engineering, and interactive exploration in a single workspace.
- **Scala on Spark** — Type-safe, compiled, and performant. Scala is Spark's native language; using it demonstrates deeper platform expertise than PySpark alone.
- **Delta Lake** — ACID transactions on data lake storage, schema enforcement, time travel (versioned data), and merge/upsert operations. Ideal for the medallion architecture.
- **Premium tier** — Required for Unity Catalog, RBAC, and audit logging. Also includes Repos integration for notebook version control.
- **Azure-native integration** — Native connectivity to Azure PostgreSQL (JDBC), Azure OpenAI (REST), and Azure Key Vault (secrets).

**Alternatives Considered:**
- *Azure Synapse Analytics* — Less flexible notebook experience, weaker Scala support.
- *Azure Data Factory* — Visual ETL; doesn't showcase coding ability.
- *Self-managed Spark on VMs* — Unnecessary operational burden for a demo.

---

## 4. Why Medallion Architecture (Bronze / Silver / Gold)

**Decision:** Three-layer data quality pipeline with Delta Lake at each stage

**Rationale:**
- **Data quality lineage** — Each layer has a clear contract: Bronze (raw), Silver (validated), Gold (aggregated). Issues can be traced to the exact transformation that introduced them.
- **Reprocessing** — If a silver transformation bug is found, bronze data is intact. Fix the logic and rerun — no need to re-ingest from source.
- **Separation of concerns** — Ingestion logic (Bronze) is decoupled from business rules (Silver) and feature engineering (Gold). Teams can work independently.
- **Industry standard** — Medallion architecture is the de facto pattern for Lakehouse platforms. Using it demonstrates fluency with modern data engineering practices.

**Layer Responsibilities:**
| Layer | Input | Transformation | Output |
|-------|-------|---------------|--------|
| Bronze | PostgreSQL (JDBC) | 1:1 copy + metadata columns | Raw Delta tables |
| Silver | Bronze Delta | Dedup, validate, join, derive | Clean Delta tables |
| Gold | Silver Delta | Aggregate, feature-engineer | Analytical features |

---

## 5. Why Azure OpenAI for the Query Interface

**Decision:** Azure OpenAI Service with GPT-4o deployment (GlobalStandard SKU)

**Rationale:**
- **Democratise data access** — Non-technical stakeholders (compliance officers, fraud analysts) can query the system in plain English without knowing SQL or Cypher.
- **Multi-backend routing** — GPT-4o classifies questions and generates the appropriate query language (SQL for tabular data, Cypher for graph data) based on the question's intent.
- **Schema grounding** — The system prompt includes full schema context and few-shot examples, reducing hallucination and ensuring generated queries match the actual data model.
- **Azure-native** — Integrated with Azure RBAC, virtual networks, and monitoring. The API key is managed alongside other Terraform outputs.
- **Cost efficient** — Per-token pricing with GlobalStandard SKU; demo usage costs pennies.

**Alternatives Considered:**
- *OpenAI API directly* — No Azure integration, data leaves the Azure tenant.
- *Fine-tuned model* — Unnecessary complexity for a demo; few-shot prompting achieves sufficient accuracy.
- *Custom NLP pipeline* — Would require training data and significant development time for inferior results.

**Safety:** The system prompt explicitly prohibits write operations (`DELETE`, `DROP`, `CREATE`, etc.). Only read queries are generated.

---

## 6. Why Terraform for Infrastructure

**Decision:** Terraform >= 1.9.0 with azurerm provider 4.x

**Rationale:**
- **Reproducibility** — `terraform apply` creates identical infrastructure every time. No portal click-ops, no configuration drift.
- **Version control** — Infrastructure changes are tracked in git alongside application code. Code review applies to infrastructure.
- **Dependency management** — Terraform's resource graph handles creation order automatically (e.g., resource group before PostgreSQL before database).
- **Multi-resource orchestration** — A single `apply` provisions Resource Group, PostgreSQL, Databricks, and Azure OpenAI with correct dependencies.
- **Teardown** — `terraform destroy` removes everything cleanly, preventing orphaned resources and unexpected billing.

**Conventions Used:**
- `versions.tf` for provider configuration
- `main.tf` for documentation only (no resources)
- One resource per file (`postgresql.tf`, `databricks.tf`, `openai.tf`)
- Azure naming module for consistent resource names
- Azure locations module for region validation
- Common tags via `locals.tf` merge pattern
- Sensitive outputs marked appropriately

**Alternatives Considered:**
- *Azure Bicep* — Azure-only; Terraform skills are more broadly applicable.
- *Pulumi* — Less mature ecosystem, smaller community.
- *ARM Templates* — Verbose, hard to read, no state management.

---

## 7. Design Trade-offs

| Decision | Trade-off | Mitigation |
|----------|-----------|------------|
| Neo4j on ACI (Community) | No clustering or enterprise features | Sufficient for demo; upgrade path to AuraDB is clear |
| Burstable PostgreSQL SKU | Limited performance | Sufficient for ~10K rows; upgrade path is clear |
| REST API for OpenAI calls | No SDK dependency management | Simpler deployment; works on any Databricks runtime |
| Regex-based JSON parsing | Less robust than a JSON library | Avoids deprecated `scala.util.parsing.json`; sufficient for structured GPT responses. Requires manual Unicode unescape |
| Single Databricks cluster | No job/cluster separation | For demo purposes; production would use job clusters |
| Sample data in Python | Not dbt/Spark-generated | Demonstrates data engineering skills; realistic volumes |
