// ═══════════════════════════════════════════════════════════════════════════
// Platform module: api-management.bicep
// Location: azure-platform-iac/modules/integration/api-management.bicep
//
// Generic API Management service. Callers configure APIs, products,
// policies, and named values separately.
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (e.g., contoso-apim-dev)')
param name string

@description('Azure region')
param location string

@description('SKU: Consumption | Developer | Basic | Standard | Premium')
@allowed(['Consumption', 'Developer', 'Basic', 'Standard', 'Premium'])
param sku string = 'Developer'

@description('Publisher email (required by APIM)')
param publisherEmail string = 'admin@contoso.com'

@description('Publisher name')
param publisherName string = 'Contoso'

@description('Whether to enable VNet internal mode (Premium only)')
param enableVnetInternal bool = false

@description('Subnet resource ID for VNet internal mode (Premium only)')
param vnetSubnetId string = ''

@description('Whether to disable public network access (Internal mode auto-disables)')
param disablePublicAccess bool = false

@description('Environment tag')
param environment string

@description('Additional tags')
param tags object = {}

resource apim 'Microsoft.ApiManagement/service@2023-12-01' = {
  name: name
  location: location
  sku: {
    name: sku
    capacity: (sku == 'Consumption' ? 0 : 1)
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: enableVnetInternal ? 'Internal' : 'None'
    virtualNetworkConfiguration: enableVnetInternal ? {
      subnetResourceId: vnetSubnetId
    } : null
    publicNetworkAccess: (enableVnetInternal || disablePublicAccess) ? 'Disabled' : 'Enabled'
  }
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

output id string = apim.id
output name string = apim.name
output gatewayUrl string = apim.properties.gatewayUrl
output portalUrl string = apim.properties.portalUrl
