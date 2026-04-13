module "locations" {
  source   = "azurerm/locations/azure"
  version  = ">= 0.2.0"
  location = var.location
}

module "naming" {
  source  = "Azure/naming/azurerm"
  version = ">= 0.4.0"

  prefix = local.name_prefix
}