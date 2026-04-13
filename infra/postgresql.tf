resource "azurerm_postgresql_flexible_server" "main" {
  name                          = module.naming.postgresql_server.name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  version                       = var.postgresql_version
  administrator_login           = var.postgresql_admin_username
  administrator_password        = var.postgresql_admin_password
  sku_name                      = var.postgresql_sku_name
  storage_mb                    = 32768
  zone                          = "2"
  public_network_access_enabled = true
  tags                          = local.common_tags
}

resource "azurerm_postgresql_flexible_server_database" "fraud" {
  name      = "fraud_detection"
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Allow Azure services (Databricks) to connect
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Allow the developer's machine to connect (conditional)
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_client" {
  count            = var.client_ip_address != "" ? 1 : 0
  name             = "AllowClientIP"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = var.client_ip_address
  end_ip_address   = var.client_ip_address
}
