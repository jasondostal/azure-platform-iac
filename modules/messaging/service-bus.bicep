// ═══════════════════════════════════════════════════════════════════════════
// Platform module: service-bus.bicep
// Location: azure-platform-iac/modules/messaging/service-bus.bicep
//
// Generic Service Bus namespace. Callers add queues/topics/subscriptions
// via separate deployments or post-deploy configuration.
// Outputs the namespace endpoint + auth rule connection strings.
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (globally unique — consider suffix)')
param name string

@description('Azure region')
param location string

@description('SKU: Basic | Standard | Premium')
@allowed(['Basic', 'Standard', 'Premium'])
param sku string = 'Standard'

@description('Whether to restrict public network access (private endpoints only)')
param disablePublicAccess bool = false

@description('Minimum TLS version')
param minTlsVersion string = '1.2'

@description('Whether to disable local auth (access keys) — Entra-only by default. Set false if a consumer needs SAS connection strings.')
param disableLocalAuth bool = true

@description('Environment tag')
param environment string

@description('Additional tags')
param tags object = {}

resource ns 'Microsoft.ServiceBus/namespaces@2024-01-01' = {
  name: name
  location: location
  sku: { name: sku, tier: sku }
  properties: {
    publicNetworkAccess: disablePublicAccess ? 'Disabled' : 'Enabled'
    minimumTlsVersion: minTlsVersion
    disableLocalAuth: disableLocalAuth
  }
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

output id string = ns.id
output name string = ns.name
output endpoint string = ns.properties.serviceBusEndpoint
