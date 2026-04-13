#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Provisions all Azure infrastructure for the Fraud Detection Data Architecture Demo.
.DESCRIPTION
    Checks prerequisites, initialises Terraform, creates a plan, and applies it.
    Captures Terraform outputs and writes a .env file for downstream scripts.
.PARAMETER SkipConfirmation
    Skip the interactive confirmation prompt before applying.
.PARAMETER TfVarsFile
    Path to the Terraform variables file (relative to infra/).
.EXAMPLE
    ./deploy.ps1
    ./deploy.ps1 -SkipConfirmation
#>

[CmdletBinding()]
param(
    [switch]$SkipConfirmation,
    [string]$TfVarsFile = "terraform.tfvars"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_common.ps1')

# -----------------------------------------------------------------------------
# 1. Prerequisites
# -----------------------------------------------------------------------------

Write-Banner "Fraud Detection Demo — Infrastructure Deployment"
Write-Step 1 "Checking prerequisites..."
Assert-Prerequisites

# -----------------------------------------------------------------------------
# 2. Terraform variables file
# -----------------------------------------------------------------------------

Write-Step 2 "Checking Terraform variables..."

Push-Location $InfraDir
try {
    $tfVarsPath = Join-Path $InfraDir $TfVarsFile

    if (-not (Test-Path $tfVarsPath)) {
        Write-Host "  No $TfVarsFile found. Let's create one." -ForegroundColor Yellow
        Write-Host ""

        $account = az account show | ConvertFrom-Json
        $defaultSubId = $account.id

        $subId = Read-Host "  Subscription ID [$defaultSubId]"
        if ([string]::IsNullOrWhiteSpace($subId)) { $subId = $defaultSubId }

        $prefix = Read-Host "  Resource name prefix [fraud]"
        if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = "fraud" }

        $location = Read-Host "  Azure region [uksouth]"
        if ([string]::IsNullOrWhiteSpace($location)) { $location = "uksouth" }

        $owner = Read-Host "  Owner tag (your name or email)"
        if ([string]::IsNullOrWhiteSpace($owner)) { $owner = $account.user.name }

        $pgPassword = Read-Host "  PostgreSQL admin password (min 8 chars, mixed case + number)" -AsSecureString
        $pgPasswordPlain = [System.Net.NetworkCredential]::new('', $pgPassword).Password

        if ($pgPasswordPlain.Length -lt 8) {
            Write-Fail "Password must be at least 8 characters."
            exit 1
        }

        # Detect client IP for firewall rule
        $clientIp = ""
        try {
            $clientIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 5).Trim()
            Write-Success "Detected client IP: $clientIp"
        } catch {
            Write-Host "  Could not detect client IP — skipping firewall rule for local access." -ForegroundColor Yellow
        }

        $tfVarsContent = @"
subscription_id           = "$subId"
prefix                    = "$prefix"
location                  = "$location"
environment               = "dev"
owner                     = "$owner"
cost_centre               = "demo"
postgresql_admin_username = "pgadmin"
postgresql_admin_password = "$pgPasswordPlain"
client_ip_address         = "$clientIp"
"@
        Set-Content -Path $tfVarsPath -Value $tfVarsContent -NoNewline
        Write-Success "Created $TfVarsFile"
    } else {
        Write-Success "Using existing $TfVarsFile"
    }

    # -----------------------------------------------------------------------------
    # 3. Terraform init
    # -----------------------------------------------------------------------------

    Write-Step 3 "Initialising Terraform..."

    if (-not (Test-Path (Join-Path $InfraDir ".terraform"))) {
        terraform init
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "terraform init failed."
            exit 1
        }
    } else {
        Write-Success "Already initialised (run 'terraform init -upgrade' to update providers)"
    }

    # -----------------------------------------------------------------------------
    # 4. Terraform plan
    # -----------------------------------------------------------------------------

    Write-Step 4 "Creating Terraform plan..."

    terraform plan -out=tfplan
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "terraform plan failed."
        exit 1
    }
    Write-Success "Plan created successfully"

    # -----------------------------------------------------------------------------
    # 5. Confirm and apply
    # -----------------------------------------------------------------------------

    if (-not $SkipConfirmation) {
        Write-Host ""
        $confirm = Read-Host "  Apply this plan? (yes/no)"
        if ($confirm -ne "yes") {
            Write-Host "  Cancelled." -ForegroundColor Yellow
            Remove-Item -Path (Join-Path $InfraDir "tfplan") -ErrorAction SilentlyContinue
            exit 0
        }
    }

    Write-Step 5 "Applying Terraform plan..."

    terraform apply tfplan
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "terraform apply failed."
        exit 1
    }
    Write-Success "Infrastructure provisioned successfully"

    # -----------------------------------------------------------------------------
    # 6. Capture outputs and write .env
    # -----------------------------------------------------------------------------

    Write-Step 6 "Capturing outputs..."

    $outputs = terraform output -json | ConvertFrom-Json
    $envPath = Join-Path $ProjectRoot ".env"

    $envContent = @"
# Auto-generated by deploy.ps1 — do not commit this file
# Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

# PostgreSQL
PGHOST=$($outputs.postgresql_fqdn.value)
PGDATABASE=$($outputs.postgresql_database_name.value)
PGUSER=$($outputs.postgresql_admin_username.value)
PGPORT=5432
PGSSLMODE=require
POSTGRESQL_JDBC_URL=$($outputs.postgresql_jdbc_url.value)

# Databricks
DATABRICKS_WORKSPACE_URL=$($outputs.databricks_workspace_url.value)
DATABRICKS_WORKSPACE_ID=$($outputs.databricks_workspace_id.value)
DATABRICKS_CLUSTER_ID=$($outputs.databricks_cluster_id.value)
DATABRICKS_CLUSTER_NAME=$($outputs.databricks_cluster_name.value)
DATABRICKS_SECRET_SCOPE=$($outputs.databricks_secret_scope_name.value)

# Azure OpenAI
AZURE_OPENAI_ENDPOINT=$($outputs.openai_endpoint.value)
AZURE_OPENAI_KEY=$($outputs.openai_primary_key.value)
AZURE_OPENAI_DEPLOYMENT=$($outputs.openai_deployment_name.value)

# Azure
AZURE_RESOURCE_GROUP=$($outputs.resource_group_name.value)
"@
    Set-Content -Path $envPath -Value $envContent -NoNewline
    Write-Success "Wrote connection details to .env"

    # -----------------------------------------------------------------------------
    # 7. Summary
    # -----------------------------------------------------------------------------

    Write-Banner "Deployment Complete"
    Write-Host "  Resource Group:    $($outputs.resource_group_name.value)" -ForegroundColor White
    Write-Host "  PostgreSQL:        $($outputs.postgresql_fqdn.value)" -ForegroundColor White
    Write-Host "  Databricks:        $($outputs.databricks_workspace_url.value)" -ForegroundColor White
    Write-Host "  Cluster:           $($outputs.databricks_cluster_name.value) ($($outputs.databricks_cluster_id.value))" -ForegroundColor White
    Write-Host "  Secret Scope:      $($outputs.databricks_secret_scope_name.value)" -ForegroundColor White
    Write-Host "  OpenAI Endpoint:   $($outputs.openai_endpoint.value)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Connection details saved to: $envPath" -ForegroundColor Green
    Write-Host "  To tear down: ./scripts/destroy.ps1" -ForegroundColor Yellow
    Write-Host ""

} finally {
    Pop-Location
}
