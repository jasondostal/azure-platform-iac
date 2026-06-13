targetScope = 'subscription'

// ═══════════════════════════════════════════════════════════════════════════
// azure-platform-iac — bootstrap/main.bicep
//
// One-time bootstrap for a new Azure subscription — provisions the
// minimum infrastructure to make a subscription "platform-ready":
//
//   1. Resource Group for platform-shared resources (ACR, Log Analytics)
//   2. Azure Container Registry (private, admin disabled)
//   3. Log Analytics Workspace (centralized logging)
//   4. Service Principal for ADO service connections
//   5. RBAC assignments (Contributor on subscription for the ADO SP)
//   6. Key Vault for platform secrets
//
// After this runs, the subscription can consume platform modules from
// azure-platform-iac — `az deployment sub create` with any module works.
//
// Usage:
//   az deployment sub create \
//     --location eastus \
//     --template-file bootstrap/main.bicep \
//     --parameters bootstrap/params/dev.bicepparam
// ═══════════════════════════════════════════════════════════════════════════

@description('Short name for this subscription (e.g., dev, nonprod, prod)')
param environment string

@description('Azure region for platform-shared resources')
param location string = 'eastus'

@description('Tenant ID (Entra ID directory)')
param tenantId string

@description('Base name for platform resources')
param platformName string = 'platform'

@description('Whether to create an ADO service principal for deployments')
param createServicePrincipal bool = true

@description('Service principal name (defaults to {platformName}-ado-sp-{environment})')
param servicePrincipalName string = ''

// ── Resource Group ──────────────────────────────────────────────────────────

var rgName = 'rg-${platformName}-shared'

// Deterministic per-subscription suffix so globally-unique names (ACR, Key
// Vault) don't collide with resources claimed elsewhere in Azure. Stable across
// reruns in the same subscription, so deployments stay idempotent.
var uniq = substring(uniqueString(subscription().subscriptionId), 0, 6)

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
  tags: {
    environment: environment
    managedBy: 'azure-platform-iac'
    purpose: 'platform-shared'
  }
}

// ── Log Analytics Workspace (nested module — RG-scoped) ─────────────────────

module logAnalytics 'log-analytics.bicep' = {
  name: 'deploy-log-analytics'
  scope: resourceGroup
  params: {
    name: '${platformName}-log-${environment}'
    location: location
    retentionDays: (environment == 'prod' ? 90 : 30)
  }
}

// ── Azure Container Registry (nested module — RG-scoped) ────────────────────

module acr 'acr.bicep' = {
  name: 'deploy-acr'
  scope: resourceGroup
  params: {
    name: replace('${platformName}acr${environment}${uniq}', '-', '')
    location: location
    sku: (environment == 'prod' ? 'Standard' : 'Basic')
  }
}

// ── Key Vault ───────────────────────────────────────────────────────────────

module keyVault '../modules/security/key-vault.bicep' = {
  name: '${platformName}-kv-${environment}'
  scope: resourceGroup
  params: {
    name: '${platformName}-kv-${environment}-${uniq}'
    location: location
    tenantId: tenantId
    enablePurgeProtection: (environment == 'prod')
    environment: environment
  }
}

// ── Service Principal for ADO (nested module — RG-scoped deploymentScript) ──

var spName = !empty(servicePrincipalName) ? servicePrincipalName : '${platformName}-ado-sp-${environment}'

module sp 'create-sp.bicep' = if (createServicePrincipal) {
  name: 'deploy-sp'
  scope: resourceGroup
  params: {
    spName: spName
    keyVaultName: keyVault.outputs.name
    environment: environment
    location: location
  }
}

// ── RBAC: grant deployment script MI access to Key Vault ────────────────────
// (Runs as a nested deployment at RG scope to avoid cross-scope issues.)

module kvAccess 'kv-access.bicep' = if (createServicePrincipal) {
  name: 'grant-kv-access'
  scope: resourceGroup
  params: {
    keyVaultName: keyVault.outputs.name
    principalId: sp.outputs.identityPrincipalId
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────

output resourceGroupName string = resourceGroup.name
output logAnalyticsWorkspaceId string = logAnalytics.outputs.id
output acrName string = acr.outputs.name
output acrLoginServer string = acr.outputs.loginServer
output keyVaultName string = keyVault.outputs.name
output keyVaultUri string = keyVault.outputs.uri
output servicePrincipalName string = spName
