#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Checks the health of provisioned Azure infrastructure for the Fraud Detection Demo.
.DESCRIPTION
    Reads Terraform state and outputs, then probes each endpoint to verify resources
    are reachable.
.EXAMPLE
    ./status.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_common.ps1')

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

Write-Banner "Fraud Detection Demo — Infrastructure Status"

Push-Location $InfraDir
try {
    # -------------------------------------------------------------------------
    # 1. Terraform state
    # -------------------------------------------------------------------------

    $stateList = terraform state list 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  No Terraform state found. Have you run deploy.ps1?" -ForegroundColor Yellow
        exit 0
    }

    $resourceCount = ($stateList | Measure-Object).Count
    Write-Host "  Terraform state: $resourceCount resource(s) tracked" -ForegroundColor White
    Write-Host ""

    # -------------------------------------------------------------------------
    # 2. Read outputs
    # -------------------------------------------------------------------------

    $outputs = terraform output -json 2>&1 | ConvertFrom-Json

    # -------------------------------------------------------------------------
    # 3. Check PostgreSQL
    # -------------------------------------------------------------------------

    $pgFqdn = $outputs.postgresql_fqdn.value
    $pgHealthy = Test-TcpPort -Host $pgFqdn -Port 5432
    Write-Status "PostgreSQL" $pgHealthy $pgFqdn

    # -------------------------------------------------------------------------
    # 4. Check Databricks
    # -------------------------------------------------------------------------

    $dbUrl = $outputs.databricks_workspace_url.value
    $dbHealthy = Test-HttpEndpoint -Url $dbUrl
    Write-Status "Databricks" $dbHealthy $dbUrl

    # -------------------------------------------------------------------------
    # 5. Check Azure OpenAI
    # -------------------------------------------------------------------------

    $oaiEndpoint = $outputs.openai_endpoint.value
    $oaiHealthy = Test-HttpEndpoint -Url $oaiEndpoint
    Write-Status "Azure OpenAI" $oaiHealthy $oaiEndpoint

    # -------------------------------------------------------------------------
    # 6. Summary
    # -------------------------------------------------------------------------

    Write-Host ""
    $allHealthy = $pgHealthy -and $dbHealthy -and $oaiHealthy
    if ($allHealthy) {
        Write-Host "  All resources are reachable." -ForegroundColor Green
    } else {
        Write-Host "  Some resources are not reachable. Check firewall rules and provisioning status." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  Cost reminder: These resources are incurring charges while provisioned." -ForegroundColor Yellow
    Write-Host "  Run ./destroy.ps1 when you're done to avoid unnecessary costs." -ForegroundColor Yellow
    Write-Host ""

} finally {
    Pop-Location
}
