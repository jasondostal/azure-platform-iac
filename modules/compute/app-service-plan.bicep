// ═══════════════════════════════════════════════════════════════════════════
// Platform module: app-service-plan.bicep
// Location: azure-platform-iac/modules/compute/app-service-plan.bicep
//
// Generic App Service Plan for any compute workload.
// Works with: app-service, functions, logic-apps-standard
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (e.g., contoso-asp-dev)')
param name string

@description('Azure region')
param location string

@description('SKU name: F1 (free), D1 (shared), B1/B2/B3 (basic), S1/S2/S3 (standard), P1v2/P2v2/P3v2 (premium), P1v3/P2v3/P3v3 (premium v3), WS1/WS2/WS3 (elastic premium)')
param skuName string = 'B1'

@description('SKU tier matching the SKU name')
param skuTier string = 'Basic'

@description('Number of workers (scale-out)')
param capacity int = 1

@description('OS: linux | windows. Linux required for .NET/Node/Python on Linux, consumed plans')
@allowed(['linux', 'windows'])
param osKind string = 'linux'

@description('Whether to reserve instances (required for Linux)')
param reserved bool = osKind == 'linux'

@description('Whether to enable zone redundancy (Standard SKU+, not all regions)')
param zoneRedundant bool = false

@description('Environment tag')
param environment string

@description('Additional tags')
param tags object = {}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: name
  location: location
  kind: (osKind == 'linux' ? 'linux' : 'windows')
  sku: {
    name: skuName
    tier: skuTier
    capacity: capacity
  }
  properties: {
    reserved: reserved
    zoneRedundant: zoneRedundant
  }
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

output id string = plan.id
output name string = plan.name
output kind string = plan.kind
