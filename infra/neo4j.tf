# -----------------------------------------------------------------------------
# Neo4j — Azure Container Instance
# -----------------------------------------------------------------------------
# Deploys Neo4j Community Edition as a container in Azure so Databricks can
# connect to it directly over the network (no ngrok / local tunnelling needed).
#
# Ports:
#   7474 — HTTP browser (Neo4j Browser)
#   7687 — Bolt protocol (Spark Connector + Cypher Shell)
# -----------------------------------------------------------------------------

resource "azurerm_container_group" "neo4j" {
  name                = "${join("-", local.name_prefix)}-neo4j"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  ip_address_type     = "Public"
  dns_name_label      = "${join("-", local.name_prefix)}-neo4j"

  container {
    name   = "neo4j"
    image  = "neo4j:5.26-community"
    cpu    = 2
    memory = 4

    ports {
      port     = 7474
      protocol = "TCP"
    }

    ports {
      port     = 7687
      protocol = "TCP"
    }

    environment_variables = {
      NEO4J_server_bolt_listen__address     = "0.0.0.0:7687"
      NEO4J_server_http_listen__address     = "0.0.0.0:7474"
      NEO4J_server_bolt_advertised__address = ":7687"
      NEO4J_server_http_advertised__address = ":7474"
    }

    secure_environment_variables = {
      NEO4J_AUTH = "neo4j/${var.neo4j_password}"
    }
  }

  tags = local.common_tags
}
