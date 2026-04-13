#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Tears down all Azure infrastructure for the Fraud Detection Data Architecture Demo.
.DESCRIPTION
    Displays the current Terraform state, requires explicit confirmation (type the
    resource group name), then runs terraform destroy. Optionally cleans up local
    state files.
.PARAMETER Force
    Skip the interactive confirmation (use with caution).
.PARAMETER CleanupState
    Remove local Terraform state files after successful destruction.
.EXAMPLE
    ./destroy.ps1
    ./destroy.ps1 -Force -CleanupState
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$CleanupState
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_common.ps1')

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

Write-Banner "DESTROY — Fraud Detection Demo Infrastructure" -Colour Red

Push-Location $InfraDir
try {
    # -------------------------------------------------------------------------
    # 1. Show current state
    # -------------------------------------------------------------------------

    Write-Step 1 "Current Terraform-managed resources:"
    Write-Host ""

    $stateList = terraform state list 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  No Terraform state found. Nothing to destroy." -ForegroundColor Yellow
        exit 0
    }

    $stateList | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    $resourceCount = ($stateList | Measure-Object).Count
    Write-Host ""
    Write-Host "  Total: $resourceCount resource(s)" -ForegroundColor White

    # -------------------------------------------------------------------------
    # 2. Confirmation
    # -------------------------------------------------------------------------

    if (-not $Force) {
        Write-Host ""
        Write-Host "  WARNING: This will permanently destroy ALL the above Azure resources." -ForegroundColor Red
        Write-Host "  This action cannot be undone." -ForegroundColor Red
        Write-Host ""

        # Get the resource group name for confirmation
        $rgName = ""
        try {
            $rgName = (terraform output -raw resource_group_name 2>&1)
        } catch {
            $rgName = "UNKNOWN"
        }

        $confirmation = Read-Host "  Type the resource group name to confirm [$rgName]"
        if ($confirmation -ne $rgName) {
            Write-Host ""
            Write-Host "  Name did not match. Destruction cancelled." -ForegroundColor Yellow
            exit 0
        }
    }

    # -------------------------------------------------------------------------
    # 3. Destroy
    # -------------------------------------------------------------------------

    Write-Step 2 "Destroying infrastructure..."
    Write-Host ""

    terraform destroy -auto-approve
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "  terraform destroy failed. Some resources may remain." -ForegroundColor Red
        Write-Host "  Check the Azure Portal and retry, or delete the resource group manually." -ForegroundColor Yellow
        exit 1
    }

    Write-Success "All Azure resources destroyed"

    # -------------------------------------------------------------------------
    # 4. Clean up local files
    # -------------------------------------------------------------------------

    # Remove .env file
    $envPath = Join-Path $ProjectRoot ".env"
    if (Test-Path $envPath) {
        Remove-Item $envPath
        Write-Success "Removed .env file"
    }

    # Remove plan file
    $planPath = Join-Path $InfraDir "tfplan"
    if (Test-Path $planPath) {
        Remove-Item $planPath
        Write-Success "Removed tfplan"
    }

    if ($CleanupState) {
        Write-Step 3 "Cleaning up local state files..."

        $stateFiles = @("terraform.tfstate", "terraform.tfstate.backup")
        foreach ($f in $stateFiles) {
            $p = Join-Path $InfraDir $f
            if (Test-Path $p) {
                Remove-Item $p
                Write-Success "Removed $f"
            }
        }
    }

    # -------------------------------------------------------------------------
    # 5. Summary
    # -------------------------------------------------------------------------

    Write-Host ""
    Write-Host "  Destruction complete. All Azure resources have been removed." -ForegroundColor Green
    Write-Host "  No further billing will be incurred for these resources." -ForegroundColor Green
    Write-Host ""

} finally {
    Pop-Location
}
