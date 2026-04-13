resource "azurerm_databricks_workspace" "main" {
  name                = module.naming.databricks_workspace.name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = var.databricks_sku
  tags                = local.common_tags
}
