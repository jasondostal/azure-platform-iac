// ═══════════════════════════════════════════════════════════════════════════
// Platform module: container-app-environment.bicep
// Location: azure-platform-iac/modules/compute/container-app-environment.bicep
//
// Container Apps Managed Environment — quota-free alternative to App Service
// Plans (which are capped at 3/region per subscription).
// Supports: VNet integration (internal / private), Log Analytics log routing.
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (e.g., contoso-cae-dev)')
param name string

@description('Azure region')
param location string

@description('Environment tag')
param environment string

@description('Log Analytics workspace customer ID (from Log Analytics resource). When provided, app logs are streamed to the workspace.')
param logAnalyticsCustomerId string = ''

@description('Log Analytics workspace shared key (primary). Required when logAnalyticsCustomerId is set. Treat as a secret — pass from Key Vault reference.')
@secure()
param logAnalyticsSharedKey string = ''

@description('Subnet resource ID for VNet integration. When provided, the environment is deployed in internal (private) mode — the static IP is a private IP only reachable inside the VNet. Leave empty for public environments.')
param infrastructureSubnetId string = ''

@description('Additional tags')
param tags object = {}

// Wire log analytics when both customer id and key are provided
var logAnalyticsConfig = (!empty(logAnalyticsCustomerId) && !empty(logAnalyticsSharedKey)) ? {
  customerId: logAnalyticsCustomerId
  sharedKey: logAnalyticsSharedKey
} : null

// VNet config: internal = true when a subnet is specified (private-by-default posture)
var vnetConfig = !empty(infrastructureSubnetId) ? {
  infrastructureSubnetId: infrastructureSubnetId
  internal: true
} : null

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: name
  location: location
  properties: {
    appLogsConfiguration: logAnalyticsConfig != null ? {
      destination: 'log-analytics'
      logAnalyticsConfiguration: logAnalyticsConfig
    } : null
    vnetConfiguration: vnetConfig
  }
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

output id string = managedEnvironment.id
output name string = managedEnvironment.name
output defaultDomain string = managedEnvironment.properties.defaultDomain
output staticIp string = managedEnvironment.properties.staticIp
