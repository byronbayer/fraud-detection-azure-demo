data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

# Azure Databricks first-party service principal
# Required for Key-Vault-backed secret scopes
data "azuread_service_principal" "databricks" {
  client_id = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
}
