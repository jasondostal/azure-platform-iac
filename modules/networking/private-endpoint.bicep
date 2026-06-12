// ═══════════════════════════════════════════════════════════════════════════
// Platform module: private-endpoint.bicep
// Location: azure-platform-iac/modules/networking/private-endpoint.bicep
//
// Generic Private Endpoint for any Azure PaaS service.
// Callers pass the target resource ID, group ID, and subnet.
// Optionally links to a private DNS zone for auto-resolution.
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (e.g., contoso-pe-sql-dev)')
param name string

@description('Azure region')
param location string

@description('Subnet resource ID for the private endpoint')
param subnetId string

@description('Target resource ID to connect to')
param targetResourceId string

@description('Private Link group ID (e.g., sqlServer, sites, blob, vault)')
param groupId string

@description('Optional: private DNS zone ID for auto-registration')
param privateDnsZoneId string = ''

@description('Environment tag')
param environment string

resource pe 'Microsoft.Network/privateEndpoints@2024-03-01' = {
  name: name
  location: location
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [{
      name: name
      properties: {
        privateLinkServiceId: targetResourceId
        groupIds: [groupId]
      }
    }]
  }
  tags: { environment: environment }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-03-01' = if (!empty(privateDnsZoneId)) {
  parent: pe
  name: '${name}-dns'
  properties: {
    privateDnsZoneConfigs: [{
      name: 'default'
      properties: { privateDnsZoneId: privateDnsZoneId }
    }]
  }
}

output id string = pe.id
