#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    DEPRECATED — Use 'terraform apply' instead.

    This script has been superseded by the databricks_notebook resources in
    infra/databricks-config.tf.  It is retained for reference only.

.DESCRIPTION
    Previously used the Databricks Workspace REST API to upload notebooks.
    Notebooks are now managed declaratively by Terraform — any local changes
    are pushed to the workspace on the next 'terraform apply'.

.EXAMPLE
    pwsh infra/scripts/push-notebooks.ps1
    pwsh infra/scripts/push-notebooks.ps1 -WorkspacePath "/Shared/FraudDetection"
#>

param(
    [string]$WorkspacePath = "/FraudDetection"
)

# Dot-source shared helpers
. "$PSScriptRoot/_common.ps1"

Write-Banner "Push Notebooks to Databricks"

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
Write-Step 1 "Checking prerequisites"

if (-not (Test-Command "az")) {
    Write-Fail "Azure CLI not found."
    exit 1
}

$azAccount = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Azure CLI not logged in. Run 'az login' first."
    exit 1
}
Write-Success "Azure CLI logged in"

if (-not (Test-Command "terraform")) {
    Write-Fail "Terraform CLI not found."
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Get workspace URL from Terraform outputs
# ---------------------------------------------------------------------------
Write-Step 2 "Reading Databricks workspace URL from Terraform outputs"

Push-Location $script:InfraDir
try {
    $workspaceUrl = (terraform output -raw databricks_workspace_url 2>&1).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($workspaceUrl)) {
        Write-Fail "Could not read databricks_workspace_url from Terraform outputs."
        Write-Fail "Have you run 'terraform apply'?"
        exit 1
    }
} finally {
    Pop-Location
}

# Ensure no trailing slash
$workspaceUrl = $workspaceUrl.TrimEnd('/')
Write-Success "Workspace: $workspaceUrl"

# ---------------------------------------------------------------------------
# 3. Obtain AAD token for Databricks
# ---------------------------------------------------------------------------
Write-Step 3 "Acquiring Azure AD token for Databricks"

# The Databricks resource ID for Azure AD token requests
$databricksResourceId = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
$tokenJson = az account get-access-token --resource $databricksResourceId 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to acquire Databricks AAD token: $tokenJson"
    exit 1
}
$token = ($tokenJson | ConvertFrom-Json).accessToken
Write-Success "Token acquired"

# ---------------------------------------------------------------------------
# 4. Ensure target directory exists
# ---------------------------------------------------------------------------
Write-Step 4 "Creating workspace directory: $WorkspacePath"

$mkdirsBody = @{ path = $WorkspacePath } | ConvertTo-Json -Compress
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

try {
    $null = Invoke-RestMethod `
        -Uri "$workspaceUrl/api/2.0/workspace/mkdirs" `
        -Method POST `
        -Headers $headers `
        -Body $mkdirsBody
    Write-Success "Directory ready"
} catch {
    $err = $_.ErrorDetails.Message
    Write-Fail "Could not create directory: $err"
    exit 1
}

# ---------------------------------------------------------------------------
# 5. Upload each notebook
# ---------------------------------------------------------------------------
Write-Step 5 "Uploading notebooks"

$notebooksDir = Join-Path $script:ProjectRoot "databricks" "notebooks"
$notebooks = Get-ChildItem -Path $notebooksDir -Filter "*.scala" | Sort-Object Name

if ($notebooks.Count -eq 0) {
    Write-Fail "No .scala notebooks found in $notebooksDir"
    exit 1
}

$uploaded = 0
$failed   = 0

foreach ($nb in $notebooks) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($nb.Name)
    $targetPath = "$WorkspacePath/$name"

    # Read file content and base64 encode
    $content = Get-Content -Path $nb.FullName -Raw
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content))

    $importBody = @{
        path      = $targetPath
        format    = "SOURCE"
        language  = "SCALA"
        content   = $b64
        overwrite = $true
    } | ConvertTo-Json -Compress

    try {
        $null = Invoke-RestMethod `
            -Uri "$workspaceUrl/api/2.0/workspace/import" `
            -Method POST `
            -Headers $headers `
            -Body $importBody
        Write-Success "$($nb.Name) -> $targetPath"
        $uploaded++
    } catch {
        $err = $_.ErrorDetails.Message
        Write-Fail "$($nb.Name): $err"
        $failed++
    }
}

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Banner "Upload Complete"
Write-Host "  Uploaded:  $uploaded notebooks" -ForegroundColor Green
if ($failed -gt 0) {
    Write-Host "  Failed:    $failed notebooks" -ForegroundColor Red
}
Write-Host "  Location:  $workspaceUrl/#workspace$WorkspacePath" -ForegroundColor Cyan
Write-Host ""
