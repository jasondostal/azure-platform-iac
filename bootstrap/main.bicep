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

// ── Shared platform plumbing (env-INVARIANT names) ──────────────────────────
// These are the genuinely sub-wide resources: ONE ACR, ONE Log Analytics, ONE
// platform Key Vault per subscription, shared by every environment. Names omit
// ${environment} so re-running the bootstrap per env is idempotent against the
// SAME resources (no per-env duplicates). In a single-subscription / RG-per-env
// org (Fox), this is what you want; in a sub-per-env org each sub gets its own
// set anyway. The `environment` param now only drives tags.

// ── Log Analytics Workspace (nested module — RG-scoped) ─────────────────────

module logAnalytics 'log-analytics.bicep' = {
  name: 'deploy-log-analytics'
  scope: resourceGroup
  params: {
    name: '${platformName}-log'
    location: location
    retentionDays: 90
  }
}

// ── Azure Container Registry (nested module — RG-scoped) ────────────────────

module acr 'acr.bicep' = {
  name: 'deploy-acr'
  scope: resourceGroup
  params: {
    name: replace('${platformName}acr${uniq}', '-', '')
    location: location
    sku: 'Standard'
  }
}

// ── Key Vault (shared platform secrets) ─────────────────────────────────────
// Purge protection OFF by default so test/demo subs can be torn down cleanly.
// Turn it on for a real prod platform subscription.

module keyVault '../modules/security/key-vault.bicep' = {
  name: '${platformName}-kv'
  scope: resourceGroup
  params: {
    name: '${platformName}-kv-${uniq}'
    location: location
    tenantId: tenantId
    enablePurgeProtection: false
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
