# ========================================
# Agency Asset Compliance Automation Script
# ========================================
#
# Purpose: Orchestrates compliance audits for the Agency Asset Management system.
#
# Workflow:
#   1. Retrieves the API key from Azure Key Vault (falls back to parameters.json if Key Vault is unavailable)
#   2. Fetches non-compliant assets via the API (/api/assets/non-audited)
#   3. Generates CSV audit report with compliance details
#   4. Simulates remediation: randomly marks one overdue asset as audited
#   5. Uploads report to Azure Blob Storage for compliance archive
#
# Usage:
#   .\Run-AgencyAudit.ps1
#   .\Run-AgencyAudit.ps1 -BaseUrl "https://your-api.azurewebsites.net" -StorageAccountName "yourstg"
#
# Prerequisites:
#   - Azure CLI installed and authenticated: az login
#   - Key Vault Secrets User RBAC role (preferred path for the API key)
#   - Storage Blob Data Contributor role for audit log upload

# ========================================
# Parameters and Configuration
# ========================================
# Parameters: explicit param > environment variable > infrastructure/parameters.json > last-resort literal
param(
    [string]$BaseUrl,
    [string]$StorageAccountName,
    [string]$KeyVaultName
)

# Resolve defaults from environment, then parameters.json, then repository defaults
$repoParamsPath = Join-Path $PSScriptRoot "..\infrastructure\parameters.json"
$repoDefaults = @{
    webAppName = 'my-agency-asset-api'
    storageAccountName = 'myagencyassetstore'
    keyVaultName = 'my-agency-asset-kv'
    apiKey = $null
}

if (Test-Path $repoParamsPath) {
    try {
        $paramsJson = Get-Content $repoParamsPath -Raw | ConvertFrom-Json
        if ($paramsJson.parameters.webAppName.value) { $repoDefaults.webAppName = $paramsJson.parameters.webAppName.value }
        if ($paramsJson.parameters.storageAccountName.value) { $repoDefaults.storageAccountName = $paramsJson.parameters.storageAccountName.value }
        if ($paramsJson.parameters.keyVaultName.value) { $repoDefaults.keyVaultName = $paramsJson.parameters.keyVaultName.value }
        if ($paramsJson.parameters.apiKey.value) { $repoDefaults.apiKey = $paramsJson.parameters.apiKey.value }
    } catch {
        Write-Warning "Could not parse infrastructure/parameters.json; using embedded defaults. Error: $_"
    }
} else {
    Write-Verbose "infrastructure/parameters.json not found at $repoParamsPath — using embedded defaults."
}

# Effective values (priority: explicit param > env var > parameters.json/default)
if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    if ($env:AGENCY_API_URL) {
        $BaseUrl = $env:AGENCY_API_URL
        Write-Host "Using AGENCY_API_URL environment variable for BaseUrl." -ForegroundColor Cyan
    } else {
        # Check whether user appears to be logged in to Azure (Az PowerShell or az CLI)
        $loggedIn = $false
        if (Get-Command Get-AzContext -ErrorAction SilentlyContinue) {
            try {
                $ctx = Get-AzContext -ErrorAction Stop
                if ($ctx -and $ctx.Account) { $loggedIn = $true }
            } catch {
                # ignore
            }
        }

        if (-not $loggedIn -and (Get-Command az -ErrorAction SilentlyContinue)) {
            try {
                $acctId = az account show --query id -o tsv 2>$null
                if ($acctId) { $loggedIn = $true }
            } catch {
                # ignore
            }
        }

        if (-not $loggedIn) {
            Write-Warning "You do not appear to be logged into Azure (Connect-AzAccount or 'az login'). App discovery may fail. Either log in or set AGENCY_API_URL environment variable to the API base URL."
        }

        # Try to discover the app's default host name via Az PowerShell first (Get-AzWebApp)
        $discoveredHost = $null

        if (Get-Command Get-AzWebApp -ErrorAction SilentlyContinue) {
            try {
                $webapp = Get-AzWebApp -Name $repoDefaults.webAppName -ErrorAction Stop
                if ($webapp.DefaultHostName) { $discoveredHost = $webapp.DefaultHostName }
            } catch {
                Write-Verbose "Get-AzWebApp failed to locate web app '$($repoDefaults.webAppName)': $_"
            }
        }

        # Fallback: try Azure CLI if available
        if (-not $discoveredHost -and (Get-Command az -ErrorAction SilentlyContinue)) {
            try {
                $azHost = az webapp show --name $repoDefaults.webAppName --query defaultHostName -o tsv 2>$null
                if ($azHost) { $discoveredHost = $azHost.Trim() }
            } catch {
                Write-Verbose "az webapp show failed to locate web app '$($repoDefaults.webAppName)': $_"
            }
        }

        if ($discoveredHost) {
            $BaseUrl = "https://$discoveredHost"
            Write-Host "Discovered App Service host for '$($repoDefaults.webAppName)': $BaseUrl" -ForegroundColor Cyan

            # Cache discovered BaseUrl in environment for subsequent runs (current session + persist to User scope)
            try {
                $env:AGENCY_API_URL = $BaseUrl
                [Environment]::SetEnvironmentVariable('AGENCY_API_URL', $BaseUrl, 'User')
                Write-Host "Cached AGENCY_API_URL in current session and user environment." -ForegroundColor Cyan
            } catch {
                Write-Verbose "Failed to persist AGENCY_API_URL to user environment: $_"
            }
        } else {
            Write-Error "Could not discover App Service host for '$($repoDefaults.webAppName)'. Please ensure you are logged in (Connect-AzAccount or 'az login') and that the web app name is correct, or set the AGENCY_API_URL environment variable to the base URL of your API."
            exit 1
        }
    }
} else {
    Write-Host "Using explicit parameter for BaseUrl: $BaseUrl" -ForegroundColor Cyan
}

if ([string]::IsNullOrWhiteSpace($StorageAccountName)) {
    if ($env:AGENCY_STORAGE_ACCOUNT) {
        $StorageAccountName = $env:AGENCY_STORAGE_ACCOUNT
        Write-Host "Using AGENCY_STORAGE_ACCOUNT environment variable for StorageAccountName." -ForegroundColor Cyan
    } else {
        $StorageAccountName = $repoDefaults.storageAccountName
        Write-Host "No StorageAccountName provided; using fallback from parameters.json: $StorageAccountName" -ForegroundColor Yellow
    }
} else {
    Write-Host "Using explicit parameter for StorageAccountName: $StorageAccountName" -ForegroundColor Cyan
}

if ([string]::IsNullOrWhiteSpace($KeyVaultName)) {
    if ($env:AGENCY_KV_NAME) {
        $KeyVaultName = $env:AGENCY_KV_NAME
        Write-Host "Using AGENCY_KV_NAME environment variable for KeyVaultName." -ForegroundColor Cyan
    } else {
        $KeyVaultName = $repoDefaults.keyVaultName
        Write-Host "No KeyVaultName provided; using fallback from parameters.json: $KeyVaultName" -ForegroundColor Yellow
    }
} else {
    Write-Host "Using explicit parameter for KeyVaultName: $KeyVaultName" -ForegroundColor Cyan
}

# ========================================
# Section 1: Resolve API key (Key Vault first, then parameters.json)
# ========================================
# Preferred: Key Vault secret "ApiKey" (same path as before).
# Fallback: apiKey from infrastructure/parameters.json when Key Vault is unavailable
# (e.g. after a free trial ends). The Web App uses Authorization__ApiKeyFallback separately.

Write-Host "Fetching API key from Azure Key Vault..." -ForegroundColor Cyan

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI is required but not installed."
    exit 1
}

$ApiKey = $null
try {
    $ApiKey = az keyvault secret show --vault-name $KeyVaultName --name "ApiKey" --query "value" -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw "Retrieved API Key is empty." }
    Write-Host "Retrieved API key from Key Vault ($KeyVaultName)." -ForegroundColor Cyan
} catch {
    if (-not [string]::IsNullOrWhiteSpace($repoDefaults.apiKey)) {
        $ApiKey = $repoDefaults.apiKey
        Write-Warning "Key Vault unavailable ($KeyVaultName); using apiKey from parameters.json. Error: $_"
    } else {
        Write-Error "Failed to retrieve API Key from Key Vault ($KeyVaultName). Ensure you have run 'az login', have Key Vault Secrets User access, and that the Key Vault name matches your deployment (or set AGENCY_KV_NAME). Alternatively set apiKey in infrastructure/parameters.json. Error: $_"
        exit 1
    }
}

# Generate timestamp for audit log filename (useful for trending/archival)
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $PSScriptRoot "audit-log-$timestamp.csv"

# Prepare HTTP headers with API key (required by the REST API)
Write-Host "Connecting to Agency Asset API Compliance Engine..." -ForegroundColor Cyan
$headers = @{ "X-Api-Key" = $ApiKey }

# ========================================
# Section 2: Fetch Non-Compliant Assets
# ========================================
# Calls the /api/assets/non-audited endpoint to retrieve assets violating compliance policy.
# Used for reporting and to identify remediation targets.

try {
    $nonCompliant = Invoke-RestMethod -Uri "$BaseUrl/api/assets/non-audited" -Headers $headers -Method Get
} catch {
    Write-Error "Failed to connect to API platform: $_"
    exit 1
}

# ========================================
# Section 3: Process Compliance Status
# ========================================
# Branch logic:
#   - If fully compliant: log success, no remediation needed
#   - If non-compliant: generate report and attempt remediation

if ($nonCompliant.Count -eq 0 -or $null -eq $nonCompliant) {
    # Happy path: system is fully compliant
    Write-Host "🎉 System fully compliant. Zero outstanding audits found." -ForegroundColor Green
    [PSCustomObject]@{ Timestamp = (Get-Date); Status = "Fully Compliant"; ActionTaken = "None" } | Export-Csv -Path $logPath -NoTypeInformation
} else {
    # Non-compliant assets found: generate detailed report
    Write-Host "⚠️ Found $($nonCompliant.Count) assets violating compliance guidelines. Exporting ledger..." -ForegroundColor Yellow

    # Transform API response into a CSV-ready format
    $reportData = foreach ($asset in $nonCompliant) {
        [PSCustomObject]@{
            AssetId            = $asset.assetId
            SerialNumber       = $asset.serialNumber
            AssetName          = $asset.assetName
            AssignedDepartment = $asset.assignedDepartment
            LastAuditDate      = $asset.lastAuditDate
            DaysOverdue = if ($asset.lastAuditDate) {
                (New-TimeSpan -Start (Get-Date $asset.lastAuditDate) -End (Get-Date)).Days
            } else {
                "Never audited"
            }
        }
    }

    # Export compliance report to local CSV file
    $reportData | Export-Csv -Path $logPath -NoTypeInformation

    # ========================================
    # Section 4: Automated Remediation (Simulation)
    # ========================================
    # For demo purposes, randomly select one asset and mark it as audited today.

    $targetAsset = $nonCompliant | Get-Random
    Write-Host "Automated Mitigation: Scheduling compliance update for Asset ID $($targetAsset.assetId) ($($targetAsset.assetName))..." -ForegroundColor Cyan

    try {
        # Call the PUT /api/assets/{id}/audit endpoint
        $updateUri = "$BaseUrl/api/assets/$($targetAsset.assetId)/audit"
        $response = Invoke-RestMethod -Uri $updateUri -Headers $headers -Method Put -ContentType "application/json"
        Write-Host "✅ Migration Complete: $($response.message)" -ForegroundColor Green
    } catch {
        Write-Warning "Could not submit target remediation update: $_"
    }
}

# ========================================
# Section 5: Archive Audit Report to Cloud Storage
# ========================================
# Uploads the CSV report to Azure Blob Storage (audit-history container).
# Creates an immutable, time-indexed compliance archive for audits

if (Get-Command az -ErrorAction SilentlyContinue) {
    Write-Host "Uploading snapshot ledger to cloud storage vault..." -ForegroundColor Cyan

    # Use Azure CLI to upload blob
    # --auth-mode login: Uses current user's Azure credentials (Managed Identity in CI/CD)
    az storage blob upload `
        --account-name $StorageAccountName `
        --container-name "audit-history" `
        --name "audit-log-$timestamp.csv" `
        --file $logPath `
        --auth-mode login `
        --output none 2>$null

    Write-Host "Snapshot archived in Azure Blob Storage" -ForegroundColor Green

    if ($LASTEXITCODE -ne 0) { 
        Write-Warning "Upload may have failed. Verify storage account permissions." 
    }
}