resource "azurerm_resource_group" "main" {
  name     = module.naming.resource_group.name
  location = module.locations.name
  tags     = local.common_tags
}
