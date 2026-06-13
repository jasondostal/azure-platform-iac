// ═══════════════════════════════════════════════════════════════════════════
// Platform module: private-dns-zones.bicep
// Location: azure-platform-iac/modules/networking/private-dns-zones.bicep
//
// Deploys private DNS zones for Azure PaaS services and links them to a VNet.
// Required for private endpoints to resolve via private IPs.
// ═══════════════════════════════════════════════════════════════════════════

@description('VNet resource ID to link DNS zones to')
param vnetId string

@description('Environment tag')
param environment string

@description('Which DNS zones to deploy. Default: all common PaaS services. Pass a subset to scope down.')
param zones array = [
  'privatelink.database.windows.net'     // SQL Server
  'privatelink.azurewebsites.net'        // App Service
  'privatelink.blob.core.windows.net'    // Blob Storage
  'privatelink.table.core.windows.net'   // Table Storage
  'privatelink.queue.core.windows.net'   // Queue Storage
  'privatelink.file.core.windows.net'    // File Storage
  'privatelink.servicebus.windows.net'   // Service Bus
  'privatelink.documents.azure.com'      // Cosmos DB
  'privatelink.azure-api.net'            // API Management
  'privatelink.eventgrid.azure.net'      // Event Grid
]

resource zonesResource 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zone in zones: {
  name: zone
  location: 'global'
  properties: {}
  tags: { environment: environment, managedBy: 'azure-platform-iac' }
}]

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zone, i) in zones: {
  parent: zonesResource[i]
  name: '${uniqueString(vnetId)}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}]

// Output zone IDs as array of {name, id}. Consumers index by name.
output zoneIds array = [for (zone, i) in zones: {
  name: zone
  id: zonesResource[i].id
}]
