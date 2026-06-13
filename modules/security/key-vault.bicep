// ═══════════════════════════════════════════════════════════════════════════
// Platform module: key-vault.bicep
// Location: azure-platform-iac/modules/security/key-vault.bicep
//
// Generic Key Vault with RBAC authorization (no legacy access policies).
// Callers add role assignments for the principals that need access.
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (globally unique, e.g., contoso-kv-dev)')
param name string

@description('Azure region')
param location string

@description('Tenant ID (Entra ID directory)')
param tenantId string

@description('SKU: standard | premium (premium for HSM-backed keys)')
@allowed(['standard', 'premium'])
param sku string = 'standard'

@description('Whether to enable purge protection (prod — cannot be reverted once enabled)')
param enablePurgeProtection bool = false

@description('Whether to enable RBAC authorization (recommended). False = legacy access policies.')
param enableRbacAuthorization bool = true

@description('Whether to restrict public network access')
param disablePublicAccess bool = false

@description('Environment tag')
param environment string

@description('Additional tags')
param tags object = {}

resource vault 'Microsoft.KeyVault/vaults@2024-04-01-preview' = {
  name: name
  location: location
  properties: {
    tenantId: tenantId
    sku: { family: 'A', name: sku }
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    enableSoftDelete: true
    // Azure only accepts `true` or null here — explicitly setting `false` is
    // rejected ("cannot be set to false"). Omit the property to leave it off.
    enablePurgeProtection: enablePurgeProtection ? true : null
    enableRbacAuthorization: enableRbacAuthorization
    networkAcls: {
      defaultAction: disablePublicAccess ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
    }
  }
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

output id string = vault.id
output name string = vault.name
output uri string = vault.properties.vaultUri
