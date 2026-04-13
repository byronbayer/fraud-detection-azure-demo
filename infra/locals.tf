locals {
  common_tags = merge({
    Environment = var.environment
    CostCentre  = var.cost_centre
    Owner       = var.owner
    Application = var.application
    ManagedBy   = "Terraform"
  }, var.additional_tags)

  openai_location = var.openai_location != "" ? var.openai_location : var.location

  # Single source of truth for naming convention components
  # Convention: [Owner]-[Workload]-[Environment]-[Region]-[Instance]-[ResourceType]
  # See: https://medium.com/@byronbayer/stop-naming-your-azure-resources-like-its-2010-5dbde06099d8
  name_prefix = [
    var.owner,
    var.workload,
    var.environment,
    module.locations.short_name,
    var.instance
  ]
}
