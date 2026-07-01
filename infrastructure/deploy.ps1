# ========================================
# Agency Asset Infrastructure Deployment Script
# ========================================
#
# Purpose: Orchestrates the complete Azure infrastructure provisioning and post-deploy setup.
#
# Workflow:
#   1. Validates and loads deployment parameters from parameters.json
#   2. Creates or uses existing Azure Resource Group
#   3. Retrieves current user's Azure AD object ID (for RBAC assignments)
#   4. Deploys infrastructure via Bicep (Key Vault, SQL, App Service, Storage, RBAC roles)
#   5. Executes setup.sql to create database schema, stored procedures, Managed Identity user
#   6. Seeds initial sample data via ResetAssetsTable procedure
#   7. Sets environment variables for downstream scripts (automation/Run-AgencyAudit.ps1)
#
# Usage:
#   .\deploy.ps1
#   .\deploy.ps1 -ResourceGroupName "my-rg" -Location "eastus"
#
# Prerequisites:
#   - Azure CLI installed and authenticated: az login
#   - Resource Group Contributor role in the target subscription
#   - SqlServer PowerShell module (auto-installed if missing)

# ========================================
# Parameters and Configuration Loading
# ========================================
param(
    [string]$ResourceGroupName = "agency-asset-rg",
    [string]$Location = "westus3"
)

$root = $PSScriptRoot
$paramsPath = Join-Path $root "parameters.json"

# Validate parameters.json exists
if (-not (Test-Path $paramsPath)) {
    Write-Error "parameters.json not found"
    exit 1
}

# Extract deployment parameters
$params = Get-Content $paramsPath | ConvertFrom-Json
$appName = $params.parameters.appName.value
$webAppName = $params.parameters.webAppName.value
$sqlAdmin = $params.parameters.sqlAdminLogin.value
$sqlPass = $params.parameters.sqlAdminPassword.value

# ========================================
# Section 1: Create Resource Group and Deploy Infrastructure
# ========================================
Write-Host "Deploying infrastructure to Azure..." -ForegroundColor Cyan

# Create or ensure resource group exists
az group create --name $ResourceGroupName --location $Location --output none

# Retrieve the Azure AD object ID of the current signed-in user
# Used by Bicep for assigning "Key Vault Secrets User" and "Storage Blob Data Contributor" RBAC roles
Write-Host "Retrieving current Azure CLI user identity..." -ForegroundColor Yellow
$currentUserObjectId = az ad signed-in-user show --query id -o tsv

# Execute Bicep deployment
# The Bicep template provisions:
#   - Key Vault (stores API key)
#   - Azure SQL Server + serverless Database (compliance data)
#   - App Service Plan (F1) + Web App (Managed Identity enabled)
#   - Storage Account + audit-history container
#   - RBAC role assignments for Managed Identity and deployer
$deployment = az deployment group create `
  --resource-group $ResourceGroupName `
  --template-file (Join-Path $root "main.bicep") `
  --parameters $paramsPath deployerObjectId=$currentUserObjectId `
  --output json | ConvertFrom-Json

Write-Host "Infrastructure provisioning successful" -ForegroundColor Green

# ========================================
# Section 2: Post-Deployment Database Setup
# ========================================
# Installs SqlServer PowerShell module if not already present
# This module is required by Invoke-Sqlcmd to connect to Azure SQL
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Host "Installing SqlServer PowerShell module..." -ForegroundColor Yellow
    Install-Module -Name SqlServer -AllowClobber -Force -Scope CurrentUser
}

# Load setup.sql and perform token replacement
# $(WebAppName) placeholder is replaced with the actual web app name
# This ensures the Managed Identity user is created with the correct principal name
$sqlServerFqdn = $deployment.properties.outputs.sqlServerFqdn.value
$sqlScriptText = Get-Content (Join-Path $root "setup.sql") -Raw

# Token substitution: Replace $(WebAppName) with the actual app name
# Example: $(WebAppName) → "agencyasset-api"
$sqlScriptText = $sqlScriptText.Replace('$(WebAppName)', $webAppName)

Write-Host "Applying database schema, structures, identities, and core data seed tables..." -ForegroundColor Cyan

# Execute setup.sql against the newly created database
# Uses SQL Admin credentials (temporary; Managed Identity user is created in setup.sql)
Invoke-Sqlcmd -ServerInstance $sqlServerFqdn `
              -Database "AgencyAssetDB" `
              -Username $sqlAdmin `
              -Password $sqlPass `
              -Query $sqlScriptText

Write-Host "✅ Full environment setup complete" -ForegroundColor Green
Write-Host "Live App Base Endpoint: $($deployment.properties.outputs.appServiceUrl.value)" -ForegroundColor Cyan

# ========================================
# Section 3: Configure Environment Variables for Automation Scripts
# ========================================
# Sets up environment variables for Run-AgencyAudit.ps1 and other tools
# Variables are set both in current session and persisted to user profile for future sessions

Write-Host "Configuring local environment variables for automation scripts..." -ForegroundColor Yellow

$appUrl = $deployment.properties.outputs.appServiceUrl.value
$kvName = $params.parameters.keyVaultName.value
$storageAccount = $params.parameters.storageAccountName.value

# Temporarily set for current PowerShell session and persist to user environment
$vars = @{ 
    "AGENCY_API_URL" = $appUrl
    "AGENCY_KV_NAME" = $kvName
    "AGENCY_STORAGE_ACCOUNT" = $storageAccount
}

# Check for existing values (session or user) and prompt before overwriting
$existing = @()
foreach ($name in $vars.Keys) {
    $sessionVal = (Get-Item -Path env:$name -ErrorAction SilentlyContinue).Value
    $userVal = [Environment]::GetEnvironmentVariable($name, "User")
    if (-not [string]::IsNullOrEmpty($sessionVal) -or -not [string]::IsNullOrEmpty($userVal)) {
        $existing += [PSCustomObject]@{ Name = $name; Session = $sessionVal; User = $userVal }
    }
}

$setVars = $true
if ($existing.Count -gt 0) {
    Write-Host "The following environment variables already exist and will be overwritten if you proceed:" -ForegroundColor Yellow
    foreach ($e in $existing) {
        $s = if (-not [string]::IsNullOrEmpty($e.Session)) { $e.Session } else { "<not set>" }
        $u = if (-not [string]::IsNullOrEmpty($e.User)) { $e.User } else { "<not set>" }
        Write-Host (" - {0}: session='{1}', user='{2}'" -f $e.Name, $s, $u)
    }
    Write-Host ""
    Write-Host "If you choose not to overwrite them, parts of the project may not work without properly set environment variables." -ForegroundColor Yellow
    $confirm = Read-Host "Do you want to overwrite these values? (yes/no)"
    if ($confirm -notmatch '^(?i:y(es)?)$') {
        Write-Host "Skipping environment variable updates. Note: parts of the project might not work without correct values." -ForegroundColor Yellow
        $setVars = $false
    }
}

if ($setVars) {
    # Temporarily set for current PowerShell session
    foreach ($name in $vars.Keys) {
        $env:$name = $vars[$name]
    }

    # Persistently set in Windows User environment (survives reboot and new shell sessions)
    foreach ($name in $vars.Keys) {
        [Environment]::SetEnvironmentVariable($name, $vars[$name], "User")
    }

    Write-Host "Environment variables for API, Key Vault, and Storage successfully configured" -ForegroundColor Green
}
