// ═══════════════════════════════════════════════════════════════════════════
// Platform module: vnet.bicep
// Location: azure-platform-iac/modules/networking/vnet.bicep
//
// Generic Virtual Network with configurable subnets.
// All subnets have privateEndpointNetworkPolicies disabled for PE support.
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (e.g., contoso-vnet-dev)')
param name string

@description('Azure region')
param location string

@description('VNet address space (CIDR)')
param addressPrefix string = '10.0.0.0/16'

@description('Subnet definitions. Each: { name, prefix, delegationService? }. "AzureBastionSubnet" is reserved.')
param subnets array = []

@description('Environment tag')
param environment string

@description('Additional tags')
param tags object = {}

var defaultSubnets = [
  { name: 'private-endpoints', prefix: '10.0.2.0/24' }
]

var allSubnets = empty(subnets) ? defaultSubnets : subnets

resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: name
  location: location
  properties: {
    addressSpace: { addressPrefixes: [addressPrefix] }
    subnets: [for subnet in allSubnets: {
      name: subnet.name
      properties: {
        addressPrefix: subnet.prefix
        delegations: contains(subnet, 'delegationService') ? [{
          name: '${subnet.name}-delegation'
          properties: { serviceName: subnet.delegationService }
        }] : []
        privateEndpointNetworkPolicies: 'Disabled'
      }
    }]
  }
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

output id string = vnet.id
output name string = vnet.name

// Output subnet IDs as an array of {name, id}. Consumers index by name.
output subnetIds array = [for subnet in allSubnets: {
  name: subnet.name
  id: '${vnet.id}/subnets/${subnet.name}'
}]
