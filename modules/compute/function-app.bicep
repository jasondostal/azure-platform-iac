// ═══════════════════════════════════════════════════════════════════════════
// Platform module: function-app.bicep
// Location: azure-platform-iac/modules/compute/function-app.bicep
//
// Generic Azure Function App (serverless or dedicated plan).
// Supports: .NET isolated, Node, Python, Java, PowerShell, custom handlers.
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (e.g., contoso-func-dev)')
param name string

@description('Azure region')
param location string

@description('App Service Plan resource ID')
param appServicePlanId string

@description('Storage account name for Functions runtime (AzureWebJobsStorage)')
param storageAccountName string

@description('Runtime stack: dotnet-isolated, node, python, java, powershell, custom')
@allowed(['dotnet-isolated', 'node', 'python', 'java', 'powershell', 'custom'])
param runtimeStack string = 'dotnet-isolated'

@description('Runtime version (e.g., 10.0 for dotnet-isolated, 20 for node, 3.12 for python)')
param runtimeVersion string = '10.0'

@description('Whether to enable always-on (prod). Not billable on consumption.')
param alwaysOn bool = false

@description('Environment tag')
param environment string

@description('App settings (key-value pairs)')
param appSettings object = {}

@description('Whether to enable VNet integration')
param enableVnetIntegration bool = false

@description('Subnet resource ID for VNet integration')
param vnetSubnetId string = ''

@description('Use managed identity for the Functions host storage (AzureWebJobsStorage) instead of an account key — passwordless. Grants the function MI Storage Blob/Queue Data roles on the storage account.')
param identityBasedStorage bool = true

@description('Additional tags')
param tags object = {}

var linuxFxVersion = {
  'dotnet-isolated': 'DOTNET-ISOLATED|${runtimeVersion}'
  node: 'NODE|${runtimeVersion}'
  python: 'PYTHON|${runtimeVersion}'
  java: 'JAVA|${runtimeVersion}'
  powershell: 'POWERSHELL|${runtimeVersion}'
  custom: 'DOCKER|app'
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}

// AzureWebJobsStorage: identity-based (account name + the host's managed identity,
// no secret) or the legacy account-key connection string.
var hostStorageSettings = identityBasedStorage ? [
  { name: 'AzureWebJobsStorage__accountName', value: storageAccountName }
] : [
  { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};EndpointSuffix=core.windows.net;AccountKey=${storageAccount.listKeys().keys[0].value}' }
]

// Built as arrays of {name,value} (not an object) so the user appSettings
// for-expression can be a variable and concat'd directly — a for-expression
// nested inside concat() is illegal (BCP138), and enumerating an object that
// holds a listKeys() value can't be done at deployment start (BCP178).
var defaultSettings = concat(hostStorageSettings, [
  { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
  { name: 'FUNCTIONS_WORKER_RUNTIME', value: runtimeStack }
  { name: 'WEBSITE_RUN_FROM_PACKAGE', value: '1' }
])

var extraSettings = [for entry in items(appSettings): { name: entry.key, value: entry.value }]

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: name
  location: location
  kind: 'functionapp,linux'
  properties: {
    serverFarmId: appServicePlanId
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: linuxFxVersion[runtimeStack]
      alwaysOn: alwaysOn
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      vnetRouteAllEnabled: enableVnetIntegration
      appSettings: concat(defaultSettings, extraSettings)
    }
  }
  identity: {
    type: 'SystemAssigned'
  }
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

// Passwordless host storage: grant the function's managed identity data access.
// Blob Data Owner + Queue Data Contributor cover the runtime's blob/queue needs.
var blobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var queueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'

resource blobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (identityBasedStorage) {
  scope: storageAccount
  name: guid(storageAccount.id, functionApp.id, blobDataOwnerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataOwnerRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource queueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (identityBasedStorage) {
  scope: storageAccount
  name: guid(storageAccount.id, functionApp.id, queueDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', queueDataContributorRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource vnetIntegration 'Microsoft.Web/sites/networkConfig@2024-04-01' = if (enableVnetIntegration && !empty(vnetSubnetId)) {
  parent: functionApp
  name: 'virtualNetwork'
  properties: {
    subnetResourceId: vnetSubnetId
    swiftSupported: true
  }
}

output id string = functionApp.id
output name string = functionApp.name
output defaultHostName string = functionApp.properties.defaultHostName
output managedIdentityPrincipalId string = functionApp.identity.principalId
