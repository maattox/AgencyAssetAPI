@description('The name prefix for all resources')
param appName string = 'agency-asset'

@description('The location for all resources')
param location string = resourceGroup().location

@description('Web App name — must match App Service name for Managed Identity SQL access')
param webAppName string = 'agencyasset-api'

@description('Key Vault name (globally unique)')
param keyVaultName string = 'agency-asset-kv'

@description('SQL administrator login')
param sqlAdminLogin string

@description('SQL administrator password')
@secure()
param sqlAdminPassword string

@description('The API key for the application')
@secure()
param apiKey string

var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

// =============================================
// Azure Key Vault
// =============================================
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

resource apiKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'ApiKey'
  properties: {
    value: apiKey
  }
}

// =============================================
// Azure SQL Server
// =============================================
resource sqlServer 'Microsoft.Sql/servers@2023-05-01-preview' = {
  name: '${appName}-sql'
  location: location
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
  }
}

resource sqlFirewallAzure 'Microsoft.Sql/servers/firewallRules@2023-05-01-preview' = {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-05-01-preview' = {
  parent: sqlServer
  name: 'AgencyAssetDB'
  location: location
  sku: {
    name: 'GP_S_Gen5_1'
    tier: 'GeneralPurpose'
  }
  properties: {
    autoPauseDelay: 60
    minCapacity: '0.5'
  }
}

// =============================================
// App Service Plan (F1 Free)
// =============================================
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${appName}-plan'
  location: location
  sku: {
    name: 'F1'
    tier: 'Free'
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

// =============================================
// App Service
// =============================================
resource appService 'Microsoft.Web/sites@2023-01-01' = {
  name: webAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|10.0'
      appSettings: [
        {
          name: 'Authorization__ApiKey'
          value: '@Microsoft.KeyVault(SecretUri=${apiKeySecret.properties.secretUri})'
        }
        {
          name: 'SpecialValues__MaxDaysSinceLastAudit'
          value: '90'
        }
      ]
      connectionStrings: [
        {
          name: 'DefaultConnection'
          connectionString: 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Initial Catalog=AgencyAssetDB;Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'
          type: 'SQLServer'
        }
      ]
    }
  }
}

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
// Outputs
// =============================================
output appServiceUrl string = 'https://${appService.properties.defaultHostName}'
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output keyVaultUri string = keyVault.properties.vaultUri
output appServicePrincipalId string = appService.identity.principalId
output managedIdentitySqlSetupNote string = 'After deployment, run sql/setup-managed-identity.sql as Entra admin. Use webAppName (${webAppName}) as the database user name.'
