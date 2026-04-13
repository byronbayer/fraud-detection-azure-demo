# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------

output "resource_group_name" {
  description = "Name of the resource group."
  value       = azurerm_resource_group.main.name
}

# -----------------------------------------------------------------------------
# PostgreSQL
# -----------------------------------------------------------------------------

output "postgresql_fqdn" {
  description = "Fully qualified domain name of the PostgreSQL server."
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "postgresql_database_name" {
  description = "Name of the fraud detection database."
  value       = azurerm_postgresql_flexible_server_database.fraud.name
}

output "postgresql_admin_username" {
  description = "Administrator login for PostgreSQL."
  value       = azurerm_postgresql_flexible_server.main.administrator_login
  sensitive   = true
}

output "postgresql_jdbc_url" {
  description = "JDBC connection string for Databricks Spark (without password)."
  value       = "jdbc:postgresql://${azurerm_postgresql_flexible_server.main.fqdn}:5432/${azurerm_postgresql_flexible_server_database.fraud.name}?sslmode=require"
}

# -----------------------------------------------------------------------------
# Databricks
# -----------------------------------------------------------------------------

output "databricks_workspace_url" {
  description = "URL of the Databricks workspace."
  value       = "https://${azurerm_databricks_workspace.main.workspace_url}"
}

output "databricks_workspace_id" {
  description = "Resource ID of the Databricks workspace."
  value       = azurerm_databricks_workspace.main.id
}

# -----------------------------------------------------------------------------
# Azure OpenAI
# -----------------------------------------------------------------------------

output "openai_endpoint" {
  description = "Endpoint URL for the Azure OpenAI service."
  value       = azurerm_cognitive_account.openai.endpoint
}

output "openai_primary_key" {
  description = "Primary access key for the Azure OpenAI service."
  value       = azurerm_cognitive_account.openai.primary_access_key
  sensitive   = true
}

output "openai_deployment_name" {
  description = "Name of the GPT-4o deployment."
  value       = azurerm_cognitive_deployment.gpt4o.name
}

# -----------------------------------------------------------------------------
# Key Vault
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Neo4j (Azure Container Instance)
# -----------------------------------------------------------------------------

output "neo4j_fqdn" {
  description = "Fully qualified domain name of the Neo4j container."
  value       = azurerm_container_group.neo4j.fqdn
}

output "neo4j_bolt_url" {
  description = "Bolt connection URL for Neo4j."
  value       = "bolt://${azurerm_container_group.neo4j.fqdn}:7687"
}

output "neo4j_browser_url" {
  description = "Neo4j Browser HTTP URL."
  value       = "http://${azurerm_container_group.neo4j.fqdn}:7474"
}

# -----------------------------------------------------------------------------
# Key Vault
# -----------------------------------------------------------------------------

output "keyvault_name" {
  description = "Name of the Key Vault."
  value       = azurerm_key_vault.main.name
}

output "keyvault_uri" {
  description = "URI of the Key Vault."
  value       = azurerm_key_vault.main.vault_uri
}

output "keyvault_resource_id" {
  description = "Resource ID of the Key Vault."
  value       = azurerm_key_vault.main.id
}

# -----------------------------------------------------------------------------
# Databricks Workspace Resources
# -----------------------------------------------------------------------------

output "databricks_cluster_id" {
  description = "ID of the Databricks compute cluster."
  value       = databricks_cluster.demo.id
}

output "databricks_cluster_name" {
  description = "Name of the Databricks compute cluster."
  value       = databricks_cluster.demo.cluster_name
}

output "databricks_secret_scope_name" {
  description = "Name of the Key-Vault-backed secret scope."
  value       = databricks_secret_scope.fraud_detection.name
}
