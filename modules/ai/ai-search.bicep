// ═══════════════════════════════════════════════════════════════════════════
// Platform module: ai/ai-search.bicep
// Location: azure-platform-iac/modules/ai/ai-search.bicep
//
// Azure AI Search service — used by Foundry for RAG (vector search + hybrid
// retrieval) and by apps directly for semantic search over large document
// collections.
//
// SKU guide:
//   Free (F)     — dev only, 50MB, 3 indexes
//   Basic (B)    — small prod, 2GB, 15 indexes
//   Standard S1  — typical prod, 25GB/partition, 50 indexes, up to 36 units
//   Standard S2+ — high volume / high perf
//
// Semantic ranker (free tier: up to 1,000 queries/month on Basic+) enables
// re-ranking with deep learning models — key for RAG quality.
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (e.g., contoso-search-dev). Lowercase, no special chars.')
param name string

@description('Azure region')
param location string

@description('SKU: free | basic | standard | standard2 | standard3 | storage_optimized_l1 | storage_optimized_l2')
@allowed(['free', 'basic', 'standard', 'standard2', 'standard3', 'storage_optimized_l1', 'storage_optimized_l2'])
param sku string = (environment == 'prod' ? 'standard' : 'basic')

@description('Whether to enable semantic ranker (requires Basic+ SKU)')
param enableSemanticSearch bool = (environment == 'prod')

@description('Replica count (1-N, Default: 1 for Basic, 3 for Standard)')
param replicaCount int = (environment == 'prod' ? 3 : 1)

@description('Partition count (1-N, Default: 1)')
param partitionCount int = 1

@description('Whether to enable public network access')
param publicNetworkAccess bool = true

@description('Whether to enable managed identity')
param enableManagedIdentity bool = true

@description('Environment tag')
param environment string

@description('Additional tags')
param tags object = {}

resource searchService 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: name
  location: location
  sku: {
    name: sku
  }
  properties: {
    replicaCount: replicaCount
    partitionCount: partitionCount
    publicNetworkAccess: publicNetworkAccess ? 'enabled' : 'disabled'
    semanticSearch: enableSemanticSearch ? 'free' : 'disabled'
    hostingMode: 'default'
  }
  identity: enableManagedIdentity ? {
    type: 'SystemAssigned'
  } : null
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

// ── Outputs ────────────────────────────────────────────────────────────────

output searchServiceName string = searchService.name
output searchServiceId string = searchService.id
output searchEndpoint string = 'https://${name}.search.windows.net'
output adminKey string = searchService.listAdminKeys().primaryKey
output managedIdentityPrincipalId string = enableManagedIdentity ? searchService.identity.principalId : ''
