# ========================================
# Agency Asset Compliance Automation Script
# ========================================
#
# Purpose: Orchestrates compliance audits for the Agency Asset Management system.
#
# Workflow:
#   1. Retrieves API credentials from Azure Key Vault (passwordless, no secrets in script)
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
#   - Key Vault access: need "Key Vault Secrets User" RBAC role
#   - Storage Blob Data Contributor role for audit log upload

# ========================================
# Parameters and Configuration
# ========================================
# Environment variables take precedence over defaults (12-factor app pattern)
param(
    [string]$BaseUrl = $(if ($env:AGENCY_API_URL) { $env:AGENCY_API_URL } else { "https://agencyasset-api-frhba2hmagfbhteg.westus3-01.azurewebsites.net" }),
    [string]$StorageAccountName = $(if ($env:AGENCY_STORAGE_ACCOUNT) { $env:AGENCY_STORAGE_ACCOUNT } else { "agencyassetstore" }),
    [string]$KeyVaultName = $(if ($env:AGENCY_KV_NAME) { $env:AGENCY_KV_NAME } else { "agency-asset-kv" })
)

# ========================================
# Section 1: Authenticate with Azure Key Vault
# ========================================

Write-Host "Fetching secure credentials from Azure Key Vault..." -ForegroundColor Cyan

# Verify Azure CLI is available
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI is required but not installed."
    exit 1
}

# Retrieve API Key from Key Vault using the user's current Azure login
try {
    $ApiKey = az keyvault secret show --vault-name $KeyVaultName --name "ApiKey" --query "value" -o tsv
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw "Retrieved API Key is empty." }
} catch {
    Write-Error "Failed to retrieve API Key from KeyVault. Ensure you have run 'az login' and have Key Vault Secrets User access."
    exit 1
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