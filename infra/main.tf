# =============================================================================
# Fraud Detection Data Architecture Demo — Terraform Infrastructure
# =============================================================================
#
# This project provisions the Azure infrastructure required for a fraud
# detection data architecture demo, showcasing:
#
#   - Azure Database for PostgreSQL Flexible Server (transactional source data)
#   - Azure Databricks Workspace (Scala/Spark ETL, medallion architecture)
#   - Azure OpenAI Service (natural language query interface)
#   - Neo4j (graph database — Azure Container Instance)
#
# Architecture:
#   PostgreSQL → Databricks (Bronze → Silver → Gold) → Neo4j → Azure OpenAI
#
# Usage:
#   cd infra
#   terraform init
#   terraform plan -out=tfplan
#   terraform apply tfplan
#
# Or use the PowerShell scripts:
#   ./scripts/deploy.ps1    — Provision all resources
#   ./scripts/status.ps1    — Check resource health
#   ./scripts/destroy.ps1   — Tear down all resources
# =============================================================================
