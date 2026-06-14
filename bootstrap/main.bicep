targetScope = 'subscription'

// ═══════════════════════════════════════════════════════════════════════════
// azure-platform-iac — bootstrap/main.bicep
//
// One-time bootstrap for a new Azure subscription — provisions the RESOURCE
// PLANE that makes a subscription "platform-ready":
//
//   1. Resource Group for platform-shared resources
//   2. Azure Container Registry (private, admin disabled)
//   3. Log Analytics Workspace (centralized logging)
//   4. Key Vault for platform secrets (RBAC-authorized)
//
// IDENTITY PLANE (the ADO deploy identity + its RBAC) is intentionally NOT
// here. Bicep cannot create Entra app registrations, and a deploymentScript's
// own managed identity does not (and should not) hold the Application + role-
// assignment rights needed to mint a subscription-Contributor service
// principal. That work lives in `bootstrap/onboard-subscription.sh`, which uses
// Workload Identity Federation (no stored secret) and az CLI. Run the script;
// it calls this template as step 1, then wires identity + the ADO plane.
//
// Usage (resource plane only — normally invoked by onboard-subscription.sh):
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

// ── Outputs ─────────────────────────────────────────────────────────────────
// onboard-subscription.sh reads these to wire the identity + ADO planes.

output resourceGroupName string = resourceGroup.name
output logAnalyticsWorkspaceId string = logAnalytics.outputs.id
output acrName string = acr.outputs.name
output acrLoginServer string = acr.outputs.loginServer
output keyVaultName string = keyVault.outputs.name
output keyVaultUri string = keyVault.outputs.uri
