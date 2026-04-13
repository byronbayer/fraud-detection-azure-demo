# -----------------------------------------------------------------------------
# Azure Key Vault
# -----------------------------------------------------------------------------
# Stores all configuration for the fraud detection pipeline.  Databricks
# accesses these via a Key-Vault-backed secret scope, so notebooks never
# need credentials passed as parameters.
# -----------------------------------------------------------------------------

resource "azurerm_key_vault" "main" {
  name                       = module.naming.key_vault.name
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = false # allow clean destroy for demo
  rbac_authorization_enabled = true

  tags = local.common_tags
}

# Grant the deployer full secret access (read/write/delete)
resource "azurerm_role_assignment" "deployer_secrets" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Grant Azure Databricks service principal read-only secret access (required for
# Key-Vault-backed secret scopes — app ID 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d)
resource "azurerm_role_assignment" "databricks_secrets" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = data.azuread_service_principal.databricks.object_id
}

# -----------------------------------------------------------------------------
# PostgreSQL Secrets
# -----------------------------------------------------------------------------

resource "azurerm_key_vault_secret" "pg_host" {
  name         = "pg-host"
  value        = azurerm_postgresql_flexible_server.main.fqdn
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.deployer_secrets]
}

resource "azurerm_key_vault_secret" "pg_port" {
  name         = "pg-port"
  value        = "5432"
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.deployer_secrets]
}

resource "azurerm_key_vault_secret" "pg_database" {
  name         = "pg-database"
  value        = azurerm_postgresql_flexible_server_database.fraud.name
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.deployer_secrets]
}

resource "azurerm_key_vault_secret" "pg_user" {
  name         = "pg-user"
  value        = var.postgresql_admin_username
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.deployer_secrets]
}

resource "azurerm_key_vault_secret" "pg_password" {
  name         = "pg-password"
  value        = var.postgresql_admin_password
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.deployer_secrets]
}

# -----------------------------------------------------------------------------
# Azure OpenAI Secrets
# -----------------------------------------------------------------------------

resource "azurerm_key_vault_secret" "openai_endpoint" {
  name         = "openai-endpoint"
  value        = azurerm_cognitive_account.openai.endpoint
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.deployer_secrets]
}

resource "azurerm_key_vault_secret" "openai_key" {
  name         = "openai-key"
  value        = azurerm_cognitive_account.openai.primary_access_key
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.deployer_secrets]
}

resource "azurerm_key_vault_secret" "openai_deployment" {
  name         = "openai-deployment"
  value        = azurerm_cognitive_deployment.gpt4o.name
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.deployer_secrets]
}

# -----------------------------------------------------------------------------
# Neo4j Config (stored in Key Vault for convenience)
# -----------------------------------------------------------------------------

resource "azurerm_key_vault_secret" "neo4j_url" {
  name         = "neo4j-url"
  value        = "bolt://${azurerm_container_group.neo4j.fqdn}:7687"
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.deployer_secrets]
}

resource "azurerm_key_vault_secret" "neo4j_user" {
  name         = "neo4j-user"
  value        = "neo4j"
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.deployer_secrets]
}

resource "azurerm_key_vault_secret" "neo4j_password" {
  name         = "neo4j-password"
  value        = var.neo4j_password
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.deployer_secrets]
}

# -----------------------------------------------------------------------------
# Data Layer Paths (non-secret config, but simpler to keep in one place)
# -----------------------------------------------------------------------------

resource "azurerm_key_vault_secret" "bronze_path" {
  name         = "bronze-path"
  value        = "/mnt/fraud/bronze"
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.deployer_secrets]
}

resource "azurerm_key_vault_secret" "silver_path" {
  name         = "silver-path"
  value        = "/mnt/fraud/silver"
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.deployer_secrets]
}

resource "azurerm_key_vault_secret" "gold_path" {
  name         = "gold-path"
  value        = "/mnt/fraud/gold"
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.deployer_secrets]
}
