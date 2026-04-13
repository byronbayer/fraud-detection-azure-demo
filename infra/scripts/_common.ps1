#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Shared helper functions for the Fraud Detection Demo infrastructure scripts.
.DESCRIPTION
    Dot-source this file from deploy.ps1, destroy.ps1, and status.ps1 to avoid
    duplicating common output formatting, prerequisite checks, and connectivity tests.
#>

# -----------------------------------------------------------------------------
# Common paths
# -----------------------------------------------------------------------------

$script:InfraDir    = $PSScriptRoot | Split-Path -Parent
$script:ProjectRoot = $script:InfraDir | Split-Path -Parent

# -----------------------------------------------------------------------------
# Output formatting
# -----------------------------------------------------------------------------

function Write-Banner {
    param(
        [string]$Message,
        [ConsoleColor]$Colour = 'Cyan'
    )
    $line = "=" * 70
    Write-Host ""
    Write-Host $line -ForegroundColor $Colour
    Write-Host "  $Message" -ForegroundColor $Colour
    Write-Host $line -ForegroundColor $Colour
    Write-Host ""
}

function Write-Step {
    param([int]$Number, [string]$Message)
    Write-Host "  [$Number] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Write-Status {
    param([string]$Resource, [bool]$Healthy, [string]$Detail = "")
    if ($Healthy) {
        Write-Host "  [UP]   " -ForegroundColor Green -NoNewline
    } else {
        Write-Host "  [DOWN] " -ForegroundColor Red -NoNewline
    }
    Write-Host "$Resource" -NoNewline
    if ($Detail) {
        Write-Host " — $Detail" -ForegroundColor DarkGray
    } else {
        Write-Host ""
    }
}

# -----------------------------------------------------------------------------
# Prerequisite checks
# -----------------------------------------------------------------------------

function Test-Command {
    param([string]$Command)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Assert-Prerequisites {
    <#
    .SYNOPSIS
        Checks that terraform and az CLI are available and logged in.
        Exits with code 1 if any check fails.
    #>
    $failed = $false

    if (-not (Test-Command "terraform")) {
        Write-Fail "Terraform CLI not found. Install from https://developer.hashicorp.com/terraform/install"
        $failed = $true
    } else {
        $tfVersion = (terraform version -json | ConvertFrom-Json).terraform_version
        Write-Success "Terraform $tfVersion"
    }

    if (-not (Test-Command "az")) {
        Write-Fail "Azure CLI not found. Install from https://learn.microsoft.com/cli/azure/install-azure-cli"
        $failed = $true
    } else {
        $azAccount = az account show 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Azure CLI not logged in. Run 'az login' first."
            $failed = $true
        } else {
            $account = $azAccount | ConvertFrom-Json
            Write-Success "Azure CLI logged in — subscription: $($account.name) ($($account.id))"
        }
    }

    if ($failed) {
        Write-Host ""
        Write-Host "  Fix the above issues and re-run." -ForegroundColor Red
        exit 1
    }
}

# -----------------------------------------------------------------------------
# Connectivity tests
# -----------------------------------------------------------------------------

function Test-TcpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 3000)
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $task = $client.ConnectAsync($HostName, $Port)
        $completed = $task.Wait($TimeoutMs)
        $client.Dispose()
        return $completed -and -not $task.IsFaulted
    } catch {
        return $false
    }
}

function Test-HttpEndpoint {
    param([string]$Url, [int]$TimeoutSec = 5)
    try {
        $null = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        return $true
    } catch [System.Net.WebException] {
        # 403/401 still means the endpoint is reachable
        return $true
    } catch {
        return $false
    }
}
