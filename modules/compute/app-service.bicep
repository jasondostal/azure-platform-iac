// ═══════════════════════════════════════════════════════════════════════════
// Platform module: app-service.bicep
// Location: azure-platform-iac/modules/compute/app-service.bicep
//
// Generic App Service (Web App) for any runtime stack.
// Supports: .NET, Node, Python, Java, Go, PHP, Ruby, custom containers.
// Authenticates via managed identity — no connection strings exposed.
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (e.g., contoso-app-dev)')
param name string

@description('Azure region')
param location string

@description('App Service Plan resource ID')
param appServicePlanId string

@description('Runtime stack: DOTNETCORE|8.0, DOTNETCORE|9.0, NODE|20-lts, PYTHON|3.12, JAVA|17-java17, GO|1.21')
param runtimeStack string = 'DOTNETCORE|9.0'

@description('Whether to force HTTPS only')
param httpsOnly bool = true

@description('Whether to enable always-on (prod). Costs more, required for slot-warming.')
param alwaysOn bool = false

@description('Minimum TLS version: 1.2 recommended, 1.0/1.1 deprecated')
param minTlsVersion string = '1.2'

@description('Disable FTP/FTPS deployment')
param ftpsDisabled bool = true

@description('Environment tag')
param environment string

@description('App settings (key-value pairs)')
param appSettings object = {}

@description('Connection strings (key-value pairs injected as app settings with ConnectionStrings__ prefix)')
param connectionStrings object = {}

@description('Disable public network access — the app is then reachable ONLY via private endpoint (requires a VNet-integrated/self-hosted deploy agent; Microsoft-hosted agents cannot reach it)')
param disablePublicAccess bool = false

@description('Whether to enable VNet integration (outbound traffic through VNet)')
param enableVnetIntegration bool = false

@description('Subnet resource ID for VNet integration (required if enableVnetIntegration=true)')
param vnetSubnetId string = ''

@description('Whether to enable managed identity (SystemAssigned)')
param enableManagedIdentity bool = true

@description('Optional startup command, e.g. "node server.js". Empty = App Service default/auto-detect')
param appCommandLine string = ''

@description('Additional tags')
param tags object = {}

var defaultSettings = {
  ASPNETCORE_ENVIRONMENT: (environment == 'prod' ? 'Production' : 'Development')
  WEBSITE_RUN_FROM_PACKAGE: '1'
}

// Augment connection strings with ASPNETCORE prefix for .NET
var connectionStringSettings = [for entry in items(connectionStrings): {
  name: 'ConnectionStrings__${entry.key}'
  value: entry.value
}]

var defaultSettingsArray = [for entry in items(defaultSettings): {
  name: entry.key
  value: entry.value
}]

var userSettingsArray = [for entry in items(appSettings): {
  name: entry.key
  value: entry.value
}]

// Merge defaults + user-provided + connection strings (pre-compute to avoid for-expression in property)
var allSettingsArray = concat(defaultSettingsArray, userSettingsArray, connectionStringSettings)

resource app 'Microsoft.Web/sites@2024-04-01' = {
  name: name
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: appServicePlanId
    httpsOnly: httpsOnly
    publicNetworkAccess: disablePublicAccess ? 'Disabled' : 'Enabled'
    siteConfig: {
      linuxFxVersion: runtimeStack
      alwaysOn: alwaysOn
      ftpsState: ftpsDisabled ? 'Disabled' : 'AllAllowed'
      minTlsVersion: minTlsVersion
      appCommandLine: appCommandLine
      vnetRouteAllEnabled: enableVnetIntegration
      appSettings: allSettingsArray
    }
  }
  identity: enableManagedIdentity ? {
    type: 'SystemAssigned'
  } : null
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

// VNet integration (outbound)
resource vnetIntegration 'Microsoft.Web/sites/networkConfig@2024-04-01' = if (enableVnetIntegration && !empty(vnetSubnetId)) {
  parent: app
  name: 'virtualNetwork'
  properties: {
    subnetResourceId: vnetSubnetId
    swiftSupported: true
  }
}

output id string = app.id
output name string = app.name
output defaultHostName string = app.properties.defaultHostName
output managedIdentityPrincipalId string = enableManagedIdentity ? app.identity.principalId : ''
output managedIdentityTenantId string = enableManagedIdentity ? app.identity.tenantId : ''
