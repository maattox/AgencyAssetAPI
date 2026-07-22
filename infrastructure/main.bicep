// ========================================
// Agency Asset Management API - Infrastructure as Code
// ========================================
// This Bicep template defines a complete Azure infrastructure for a .NET 10 REST API
// demonstrating Managed Identity, serverless SQL, and free-tier-friendly configuration.
//
// Deployment command:
//   az deployment group create \
//     --resource-group <rg-name> \
//     --template-file main.bicep \
//     --parameters parameters.json
//
// Key design principles:
//   - Passwordless authentication: Managed Identity for all Azure service connections
//   - No secrets in application source: API key in Key Vault (primary) + App Setting fallback
//   - Cost-optimized: Free tier App Service, Serverless SQL (auto-pause), Storage Cool tier
//   - HTTPS-only and TLS 1.2+ enforcement
//
// Note on secrets: Key Vault is preferred. Because Key Vault has no always-free tier,
// Authorization__ApiKeyFallback is also set as a plain App Service setting so the API
// can keep running if Key Vault becomes unavailable after a free trial ends.

@description('The name prefix for all resources')
param appName string = 'agency-asset'

@description('The location for all resources')
param location string = resourceGroup().location

@description('Web App name — must match App Service name for Managed Identity SQL access')
param webAppName string = 'agencyasset-api'

@description('Key Vault name (must be globally unique)')
param keyVaultName string = 'agency-asset-kv'

@description('Storage Account name (must be globally unique, 3-24 lowercase letters/numbers)')
param storageAccountName string = 'agencyassetstore'

@description('SQL Server administrator login')
param sqlAdminLogin string

@description('SQL Server administrator password')
@secure()
param sqlAdminPassword string

@description('The Object ID of the user deploying the template (for local script access)')
param deployerObjectId string

@description('The API key for the application (stored in Key Vault and as an App Service fallback setting)')
@secure()
param apiKey string

@description('Public IP address of the machine running deploy.ps1, temporarily allow-listed so setup.sql can run')
param clientIpAddress string = ''

@description('Azure AD user principal name (UPN) of the deployer, used for the SQL AAD admin assignment')
param deployerLoginName string

// Azure RBAC Role IDs (used for Managed Identity assignments)
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

// =============================================
// Azure Key Vault - Secrets Management (primary)
// =============================================
// Stores the API key and enables secret injection via RBAC + App Service Key Vault references.
// - enableRbacAuthorization: Uses role-based access control instead of access policies
// - enableSoftDelete: Prevents accidental deletion (90-day recovery window)
// - The Web App retrieves the API key at runtime using Managed Identity
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
  }
}

// Store the API key as a secret (retrieved by the Web App via Key Vault reference)
resource apiKeySecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'ApiKey'
  properties: { value: apiKey }
}

// =============================================
// Azure SQL Server + Database (Serverless)
// =============================================
// - GP_S tier: Serverless General Purpose (auto-pause enabled, scales down to 0.5 vCores)
// - minCapacity: 0.5 vCore minimum when paused (reduces cost to near $0)
// - autoPauseDelay: 60 minutes of inactivity before auto-pause
// - TLS 1.2+: Enforced at the server level
// 
// Security:
// - administratorLogin: Used only for local deployment; disabled for Managed Identity access
// - Managed Identity grant: Applied via setup.sql (EXTERNAL PROVIDER)
resource sqlServer 'Microsoft.Sql/servers@2024-11-01-preview' = {
  name: '${appName}-sql'
  location: location
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

// Designates the deploying user as the SQL Server's Azure AD admin.
// Required because only an Azure AD-authenticated connection can run
// CREATE USER ... FROM EXTERNAL PROVIDER (setup.sql uses this to grant the
// Web App's Managed Identity database access). SQL auth alone cannot do this.
resource sqlAadAdmin 'Microsoft.Sql/servers/administrators@2024-11-01-preview' = {
  parent: sqlServer
  name: 'ActiveDirectory'
  properties: {
    administratorType: 'ActiveDirectory'
    login: deployerLoginName
    sid: deployerObjectId
    tenantId: subscription().tenantId
  }
}

// Firewall rule: Allow Azure services to connect (0.0.0.0/0 is Azure internal only)
resource sqlFirewall 'Microsoft.Sql/servers/firewallRules@2024-11-01-preview' = {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// Firewall rule: Allow the machine running deploy.ps1 to reach the server directly
// so setup.sql can execute. Only created if an IP was actually detected/passed in.
resource sqlFirewallClientIp 'Microsoft.Sql/servers/firewallRules@2024-11-01-preview' = if (!empty(clientIpAddress)) {
  parent: sqlServer
  name: 'AllowDeployerClientIP'
  properties: {
    startIpAddress: clientIpAddress
    endIpAddress: clientIpAddress
  }
}

// Serverless database: auto-pauses after 60 min of inactivity, scales from 0.5–2 vCores
resource sqlDatabase 'Microsoft.Sql/servers/databases@2024-11-01-preview' = {
  parent: sqlServer
  name: 'AgencyAssetDB'
  location: location
  sku: {
    name: 'GP_S_Gen5_2'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2
  }
  properties: {
    autoPauseDelay: 60
    minCapacity: json('0.5')
    collation: 'SQL_Latin1_General_CP1_CI_AS'
  }
}

// =============================================
// App Service Plan - F1 Free Tier
// =============================================
// - F1 tier: Free, with limitations (shared infrastructure, no auto-scale, no always-on)
// - Linux runtime: Cost-effective and supports .NET natively
// - alwaysOn: false (database wake-up latency on first request expected, as documented in README)
// 
// Performance note: Cold starts expected (~30–60 sec) due to:
//   - F1 free tier shared infrastructure
//   - Azure SQL serverless auto-pause
resource appServicePlan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: '${appName}-plan'
  location: location
  sku: { name: 'F1', tier: 'Free', size: 'F1', family: 'F', capacity: 1 }
  kind: 'linux'
  properties: { reserved: true }
}

// =============================================
// App Service (Web App)
// =============================================
// - identity: SystemAssigned: Creates a Managed Identity for passwordless auth
// - httpsOnly: Redirects all HTTP traffic to HTTPS
// - minTlsVersion: 1.2: Enforces modern TLS (disables SSL 3.0, TLS 1.0, 1.1)
// - ftpsState: 'FtpsOnly': Disables insecure FTP
//
// Configuration:
//   - linuxFxVersion: .NET 10 runtime on Linux
//   - Authorization__ApiKey: Key Vault reference (preferred)
//   - Authorization__ApiKeyFallback: plain app setting if Key Vault is unavailable
//   - DefaultConnection: Connection string WITHOUT credentials (Managed Identity token used instead)
resource appService 'Microsoft.Web/sites@2024-11-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|10.0'
      alwaysOn: false
      minTlsVersion: '1.2'
      ftpsState: 'FtpsOnly'
      appSettings: [
        { 
          name: 'Authorization__ApiKey' 
          value: '@Microsoft.KeyVault(SecretUri=${apiKeySecret.properties.secretUri})' 
        }
        {
          // Free-tier fallback when Key Vault cannot be resolved (no always-free Key Vault tier).
          name: 'Authorization__ApiKeyFallback'
          value: apiKey
        }
        { 
          name: 'SpecialValues__MaxDaysSinceLastAudit' 
          value: '90' 
        }
        {
          name: 'SpecialValues__StorageAccountName'
          value: storageAccountName
        }
      ]
      connectionStrings: [
        {
          name: 'DefaultConnection'
          connectionString: 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Initial Catalog=AgencyAssetDB;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'
          type: 'SQLServer'
        }
      ]
    }
  }
}

// =============================================
// Azure Storage Account (Audit Ledger Archive)
// =============================================
// Stores compliance audit reports generated by Run-AgencyAudit.ps1.
// - Standard_LRS: Locally redundant (cost-effective for non-critical logs)
// - Cool tier: Optimized for infrequent access (lower storage cost)
// - allowBlobPublicAccess: false: Prevents accidental public exposure
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Cool'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
  }
}

// Blob service: default configuration
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

// audit-history container: stores CSV audit logs from the automation script
resource auditHistoryContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'audit-history'
  properties: {
    publicAccess: 'None'
  }
}

// =============================================
// RBAC: Grant Web App Access to Blob Storage
// =============================================
// Enables the Web App's Managed Identity to read audit history files.
// Role: "Storage Blob Data Contributor" — allows read/write on blobs
var storageBlobDataContributorRole = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource webAppStorageAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, appService.id, storageBlobDataContributorRole)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRole)
    principalId: appService.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================
// RBAC: Grant Local Deployer Access to Blob Storage
// =============================================
// Allows the person running deploy.ps1 to upload audit reports to the archive.
resource deployerStorageAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, deployerObjectId, storageBlobDataContributorRole)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRole)
    principalId: deployerObjectId
    principalType: 'User'
  }
}

// =============================================
// RBAC: Grant Web App Access to Key Vault
// =============================================
// Enables the Web App's Managed Identity to retrieve the API key from Key Vault.
// Role: "Key Vault Secrets User" — read-only access to secrets
resource keyVaultSecretsUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, appService.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: appService.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================
// RBAC: Grant Local Deployer Access to Key Vault
// =============================================
// Allows Run-AgencyAudit.ps1 to read the ApiKey secret via Azure CLI.
resource deployerKeyVaultAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, deployerObjectId, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: deployerObjectId
    principalType: 'User'
  }
}

// =============================================
// Deployment Outputs
// =============================================
output appServiceUrl string = 'https://${appService.properties.defaultHostName}'
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output webAppManagedIdentityName string = webAppName
output webAppName string = webAppName
output resourceGroupName string = resourceGroup().name
output keyVaultName string = keyVault.name
