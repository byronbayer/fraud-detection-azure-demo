# -----------------------------------------------------------------------------
# Databricks Workspace Configuration
# -----------------------------------------------------------------------------
# Resources provisioned *inside* the Databricks workspace via the Databricks
# provider.  These depend on the workspace existing first — the provider
# block in versions.tf references azurerm_databricks_workspace.main, so
# Terraform handles the ordering automatically.
# -----------------------------------------------------------------------------


# -----------------------------------------------------------------------------
# Key-Vault-Backed Secret Scope
# -----------------------------------------------------------------------------
# Replaces: infra/scripts/create-secret-scope.ps1
#
# Notebooks read config via dbutils.secrets.get("fraud-detection", "<key>").
# The scope is backed by Azure Key Vault — any secret stored there is
# automatically available without manual syncing.
# -----------------------------------------------------------------------------

resource "databricks_secret_scope" "fraud_detection" {
  name = var.databricks_secret_scope_name

  keyvault_metadata {
    resource_id = azurerm_key_vault.main.id
    dns_name    = azurerm_key_vault.main.vault_uri
  }
}


# -----------------------------------------------------------------------------
# Compute Cluster
# -----------------------------------------------------------------------------
# Replaces: infra/scripts/create-cluster.ps1
#
# Single-node, auto-terminating cluster with the Neo4j Spark Connector
# pre-installed.  Auto-terminates after var.databricks_cluster_autotermination
# minutes of inactivity.
# -----------------------------------------------------------------------------

data "databricks_spark_version" "lts" {
  long_term_support = true

  depends_on = [azurerm_databricks_workspace.main]
}

data "databricks_node_type" "default" {
  local_disk    = true
  min_memory_gb = 16

  depends_on = [azurerm_databricks_workspace.main]
}

resource "databricks_cluster" "demo" {
  cluster_name            = var.databricks_cluster_name
  spark_version           = data.databricks_spark_version.lts.id
  node_type_id            = data.databricks_node_type.default.id
  autotermination_minutes = var.databricks_cluster_autotermination
  num_workers             = 0

  spark_conf = {
    "spark.databricks.cluster.profile" = "singleNode"
    "spark.master"                     = "local[*]"
  }

  custom_tags = {
    "ResourceClass" = "SingleNode"
    "Project"       = "FraudDetection"
    "Environment"   = var.environment
  }

  # Neo4j Spark Connector — required for notebook 04 (graph export)
  library {
    maven {
      coordinates = "org.neo4j:neo4j-connector-apache-spark_2.13:5.3.1_for_spark_3"
    }
  }
}


# -----------------------------------------------------------------------------
# Notebooks
# -----------------------------------------------------------------------------
# Replaces: infra/scripts/push-notebooks.ps1
#
# Each .scala file in databricks/notebooks/ is uploaded to the workspace under
# var.databricks_notebook_path.  Terraform tracks content changes — modifying
# a local notebook file will update it in the workspace on the next apply.
# -----------------------------------------------------------------------------

resource "databricks_directory" "pipeline" {
  path = var.databricks_notebook_path
}

resource "databricks_notebook" "pipeline" {
  depends_on = [databricks_directory.pipeline]
  for_each = toset([
    "01-bronze-ingestion",
    "02-silver-transformation",
    "03-gold-aggregation",
    "04-neo4j-export",
    "05-ai-query-interface",
  ])

  path     = "${var.databricks_notebook_path}/${each.key}"
  language = "SCALA"
  source   = "${path.module}/../databricks/notebooks/${each.key}.scala"
}
