resource "azurerm_cognitive_account" "openai" {
  name                = module.naming.cognitive_account.name
  resource_group_name = azurerm_resource_group.main.name
  location            = local.openai_location
  kind                = "OpenAI"
  sku_name            = "S0"
  tags                = local.common_tags
}

resource "azurerm_cognitive_deployment" "gpt4o" {
  name                 = var.openai_model_name
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = var.openai_model_name
    version = var.openai_model_version
  }

  sku {
    name     = "GlobalStandard"
    capacity = 10
  }
}
