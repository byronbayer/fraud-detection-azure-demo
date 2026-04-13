# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------

variable "subscription_id" {
  description = "Azure subscription ID. Can also be set via ARM_SUBSCRIPTION_ID environment variable."
  type        = string
}

variable "location" {
  description = "Primary Azure region for all resources."
  type        = string
  default     = "uksouth"
}

variable "environment" {
  description = "Deployment environment (dev, test, prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "Environment must be one of: dev, test, prod."
  }
}

variable "workload" {
  description = "Workload or application identifier for the naming convention."
  type        = string
  default     = "fraud"
}

variable "instance" {
  description = "Instance identifier for blue/green or multi-instance deployments."
  type        = string
  default     = "01"
}

variable "owner" {
  description = "Owner tag — email or team name."
  type        = string
  default     = "xan"
}

variable "cost_centre" {
  description = "Cost centre for billing attribution."
  type        = string
  default     = "demo"
}

variable "application" {
  description = "Application name tag."
  type        = string
  default     = "fraud-detection-demo"
}

variable "additional_tags" {
  description = "Additional tags to merge with the common tag set."
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# PostgreSQL
# -----------------------------------------------------------------------------

variable "postgresql_admin_username" {
  description = "Administrator login for PostgreSQL Flexible Server."
  type        = string
  default     = "pgadmin"
}

variable "postgresql_admin_password" {
  description = "Administrator password for PostgreSQL Flexible Server."
  type        = string
  sensitive   = true
}

variable "postgresql_sku_name" {
  description = "SKU name for PostgreSQL Flexible Server (e.g. B_Standard_B1ms)."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgresql_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "16"
}

variable "client_ip_address" {
  description = "Client IP address to allow through the PostgreSQL firewall. Leave empty to skip."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Databricks
# -----------------------------------------------------------------------------

variable "databricks_sku" {
  description = "Pricing tier for the Databricks workspace."
  type        = string
  default     = "premium"
}

variable "databricks_cluster_name" {
  description = "Display name for the Databricks compute cluster."
  type        = string
  default     = "fraud-detection-demo"
}

variable "databricks_cluster_autotermination" {
  description = "Minutes of inactivity before the cluster auto-terminates."
  type        = number
  default     = 10
}

variable "databricks_secret_scope_name" {
  description = "Name of the Key-Vault-backed Databricks secret scope."
  type        = string
  default     = "fraud-detection"
}

variable "databricks_notebook_path" {
  description = "Workspace path where notebooks are uploaded."
  type        = string
  default     = "/FraudDetection"
}

# -----------------------------------------------------------------------------
# Azure OpenAI
# -----------------------------------------------------------------------------

variable "openai_location" {
  description = "Azure region for the OpenAI resource. Defaults to the primary location."
  type        = string
  default     = ""
}

variable "openai_model_name" {
  description = "OpenAI model to deploy (e.g. gpt-4o)."
  type        = string
  default     = "gpt-4o"
}

variable "openai_model_version" {
  description = "Version of the OpenAI model to deploy."
  type        = string
  default     = "2024-11-20"
}

# -----------------------------------------------------------------------------
# Neo4j
# -----------------------------------------------------------------------------

variable "neo4j_password" {
  description = "Password for the Neo4j database."
  type        = string
  default     = "fraud-demo-2026"
  sensitive   = true
}
