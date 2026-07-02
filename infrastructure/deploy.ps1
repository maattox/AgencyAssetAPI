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
    [string]$ResourceGroupName = $null,
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

# If no Resource Group Name was passed via CLI parameter, dynamically build it from appName
if ([string]::IsNullOrEmpty($ResourceGroupName)) {
    $ResourceGroupName = "$appName-rg"
}

# ========================================
# Helper Function: Clean up empty Resource Group
# ========================================
function Cleanup-EmptyResourceGroup {
    param([string]$RgName)

    if (-not $RgName) { return }

    Write-Host "Checking if resource group '$RgName' is empty for cleanup..." -ForegroundColor Gray
    
    # Check if RG exists
    $rgExists = az group exists --name $RgName -o tsv
    if ($rgExists -ne 'true') { return }

    # Count resources in the group
    $resourceCount = az resource list --resource-group $RgName --query "length(@)" -o tsv
    
    if ([int]$resourceCount -eq 0) {
        Write-Host "Resource group '$RgName' is empty. Deleting it..." -ForegroundColor Yellow
        az group delete --name $RgName --yes --no-wait
        Write-Host "Empty resource group '$RgName' has been queued for deletion." -ForegroundColor Green
    } else {
        Write-Host "Resource group '$RgName' contains $resourceCount resource(s). Manual cleanup may be required." -ForegroundColor Yellow
    }
}

# ========================================
# Section 1: Create Resource Group and Deploy Infrastructure
# ========================================
Write-Host "Retrieving current Azure CLI user identity..." -ForegroundColor Yellow
$currentUserObjectId = az ad signed-in-user show --query id -o tsv
$currentUserPrincipalName = az ad signed-in-user show --query userPrincipalName -o tsv

Write-Host "Detecting public IP address for SQL firewall rule..." -ForegroundColor Yellow
try {
    $myIp = (Invoke-RestMethod -Uri "https://api.ipify.org?format=text" -TimeoutSec 10).Trim()
    Write-Host "Detected public IP: $myIp" -ForegroundColor Gray
} catch {
    Write-Warning "Could not automatically detect public IP address. The database setup step may fail unless this machine is already allow-listed."
    $myIp = ''
}

$maxAttempts = 3
$attempt = 1
$success = $false
$currentLocation = $Location
$triedLocations = @()
$baseResourceGroupName = $ResourceGroupName

while (-not $success) {
    $triedLocations += $currentLocation
    
    # On retries, append the location to the RG name to avoid Azure's region-lock errors
    if ($attempt -gt 1) {
        $ResourceGroupName = "$baseResourceGroupName-$currentLocation"
    }

    Write-Host "`n=== Attempt ${attempt}: Deploying to '$currentLocation' ===" -ForegroundColor Cyan
    Write-Host "Ensuring Resource Group '$ResourceGroupName' exists..." -ForegroundColor Gray
    
    az group create --name $ResourceGroupName --location $currentLocation --output none

    Write-Host "Deploying Bicep infrastructure (this may take a few minutes)..." -ForegroundColor Gray
    # Capture output as text first to prevent JSON parse errors if it fails
    $deploymentOutput = az deployment group create `
  --resource-group $ResourceGroupName `
  --template-file (Join-Path $root "main.bicep") `
  --parameters $paramsPath deployerObjectId=$currentUserObjectId deployerLoginName=$currentUserPrincipalName clientIpAddress=$myIp `
  --output json

    if ($LASTEXITCODE -eq 0) {
        $deployment = $deploymentOutput | ConvertFrom-Json
        $success = $true
        Write-Host "Infrastructure provisioning successful in $currentLocation" -ForegroundColor Green
        break
    } 
    
    Write-Host "Deployment failed in $currentLocation." -ForegroundColor Red

    # === CLEANUP: Delete empty resource group after failure ===
    Cleanup-EmptyResourceGroup -RgName $ResourceGroupName

    # Check if we hit the limit
    if ($attempt -ge $maxAttempts) {
        Write-Host "Reached maximum automated retries (${maxAttempts})." -ForegroundColor Yellow
        $continue = Read-Host "Do you want to continue trying other regions? (yes/no)"
        if ($continue -notmatch '^(?i:y(es)?)$') {
            Write-Error "Halting deployment by user request."
            exit 1
        }
        # Increase max attempts so the loop continues
        $maxAttempts++ 
    }

    Write-Host "Querying Azure for other regions supporting the F1 (Free) Linux tier..." -ForegroundColor Yellow
    # Query Azure specifically for Linux F1 availability
    $availableLocations = az appservice list-locations --sku F1 --linux-workers-enabled --query "[].name" -o tsv
    
    # Filter out regions we've already tried and grab the next available one
    $nextLocation = $availableLocations | Where-Object { $_ -notin $triedLocations } | Select-Object -First 1

    if (-not $nextLocation) {
        Write-Error "Exhausted all available regions that support the F1 Linux tier. Halting script."
        exit 1
    }

    $currentLocation = $nextLocation
    $attempt++
}

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
Write-Host "Retrieving Azure AD access token for database setup..." -ForegroundColor Yellow
$accessToken = az account get-access-token --resource https://database.windows.net --query accessToken -o tsv

$maxSqlAttempts = 3
$sqlAttempt = 1
$sqlSuccess = $false

while (-not $sqlSuccess -and $sqlAttempt -le $maxSqlAttempts) {
    try {
        Invoke-Sqlcmd -ServerInstance $sqlServerFqdn `
                      -Database "AgencyAssetDB" `
                      -AccessToken $accessToken `
                      -Query $sqlScriptText -ErrorAction Stop
        $sqlSuccess = $true
    } catch {
        if ($sqlAttempt -ge $maxSqlAttempts) {
            Write-Error "Failed to apply database setup script after $maxSqlAttempts attempts. Ensure the SQL admin credentials are correct, the server is reachable, and the deployment completed successfully. Error: $_"
            exit 1
        }
        Write-Host "SQL connection attempt $sqlAttempt failed (firewall rule may still be propagating). Retrying in 20 seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 20
        $sqlAttempt++
    }
}

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
        Set-Item -Path "env:$name" -Value $vars[$name]
    }

    # Persistently set in Windows User environment (survives reboot and new shell sessions)
    foreach ($name in $vars.Keys) {
        [Environment]::SetEnvironmentVariable($name, $vars[$name], "User")
    }

    Write-Host "Environment variables for API, Key Vault, and Storage successfully configured" -ForegroundColor Green
}

# ========================================
# Section 4: Deploy Web App Content (simple initial publish)
# ========================================
# Publish the local .NET app and deploy to the App Service so the site is live after infrastructure provisioning.
Write-Host "Preparing initial deployment of web app content..." -ForegroundColor Cyan

# Ensure required tools are available
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Warning "Azure CLI (az) not found. Skipping web app deployment. Install Azure CLI to enable deployment."
} elseif (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Warning "dotnet SDK not found. Skipping web app deployment. Install .NET SDK to enable local publish and deployment."
} else {
    try {
        # Locate a project to publish (pick the first .csproj under the repository parent folder)
        $repoRoot = Resolve-Path (Join-Path $root "..")
        $csproj = Get-ChildItem -Path $repoRoot -Recurse -Filter "*.csproj" -ErrorAction SilentlyContinue | Select-Object -First 1

        if (-not $csproj) {
            Write-Warning "No .csproj found under repository. Skipping web app publish."
        } else {
            $publishDir = Join-Path $env:TEMP ("agencyasset_publish_{0}" -f ([guid]::NewGuid().ToString()))
            New-Item -ItemType Directory -Path $publishDir | Out-Null

            Write-Host "Publishing project $($csproj.FullName) to $publishDir..." -ForegroundColor Gray
            dotnet publish $csproj.FullName -c Release -o $publishDir | Write-Host
            Write-Host "Packaging published output for App Service '$webAppName'..." -ForegroundColor Gray
            # Create a ZIP of the published output (zip deploy is robust across runtimes)
            $zipPath = Join-Path $env:TEMP ("agencyasset_publish_{0}.zip" -f ([guid]::NewGuid().ToString()))
            if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
            try {
                Compress-Archive -Path (Join-Path $publishDir '*') -DestinationPath $zipPath -Force
            } catch {
                Write-Warning "Failed to create ZIP package of published output: $_"
                throw
            }

            Write-Host "Deploying ZIP to App Service '$webAppName' in resource group '$ResourceGroupName'..." -ForegroundColor Gray
            az webapp deploy --resource-group $ResourceGroupName --name $webAppName --src-path $zipPath --type zip --output none

            if ($LASTEXITCODE -eq 0) {
                Write-Host "Web app deployed successfully to $webAppName." -ForegroundColor Green
            } else {
                Write-Warning "Web app deployment command returned non-zero exit code. Check 'az' output for details." 
            }

            # Cleanup publish folder and zip
            try { Remove-Item -Recurse -Force $publishDir } catch { }
            try { Remove-Item -Force $zipPath } catch { }
        }
    } catch {
        Write-Warning "Web app deployment failed: $_"
    }
}

# ========================================
# Section 5: Manual Step Reminder — Azure SQL Free Offer
# ========================================
# The Azure SQL "Free database offer" cannot be applied via Bicep/ARM — it must be
# enabled manually per-database in the Azure Portal after deployment.
Write-Host ""
Write-Host "=========================================================" -ForegroundColor Yellow
Write-Host "  ACTION REQUIRED: Enable the Azure SQL Free Database Offer" -ForegroundColor Yellow
Write-Host "=========================================================" -ForegroundColor Yellow
Write-Host "This can't be set via Bicep and must be turned on manually:" -ForegroundColor Yellow
Write-Host "  1. Go to the Azure Portal (portal.azure.com)" -ForegroundColor Yellow
Write-Host "  2. Navigate to: Resource Groups > $ResourceGroupName > AgencyAssetDB" -ForegroundColor Yellow
Write-Host "  3. Go to: Settings > Compute + storage" -ForegroundColor Yellow
Write-Host "  4. Switch on 'Free database offer' and save" -ForegroundColor Yellow
Write-Host "=========================================================" -ForegroundColor Yellow
Write-Host ""