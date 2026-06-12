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

@description('Runtime version (e.g., 9.0 for dotnet-isolated, 20 for node, 3.12 for python)')
param runtimeVersion string = '9.0'

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

var defaultSettings = {
  AzureWebJobsStorage: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};EndpointSuffix=core.windows.net;AccountKey=${listKeys(resourceId('Microsoft.Storage/storageAccounts', storageAccountName), '2023-04-01').keys[0].value}'
  FUNCTIONS_EXTENSION_VERSION: '~4'
  FUNCTIONS_WORKER_RUNTIME: runtimeStack
  WEBSITE_RUN_FROM_PACKAGE: '1'
}

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
      appSettings: concat(
        [for entry in items(defaultSettings): { name: entry.key, value: entry.value }],
        [for entry in items(appSettings): { name: entry.key, value: entry.value }]
      )
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
