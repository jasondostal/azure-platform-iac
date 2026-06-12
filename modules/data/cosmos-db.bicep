// ═══════════════════════════════════════════════════════════════════════════
// Platform module: cosmos-db.bicep
// Location: azure-platform-iac/modules/data/cosmos-db.bicep
//
// Generic Cosmos DB account. Callers add databases + containers separately.
// Serverless by default — flip to provisioned for steady-state production.
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (e.g., contoso-cosmos-dev — must be globally unique)')
param name string

@description('Azure region')
param location string

@description('Whether to enable serverless (pay-per-request). Disable for provisioned throughput.')
param serverless bool = true

@description('Default consistency level: Strong | BoundedStaleness | Session | ConsistentPrefix | Eventual')
@allowed(['Strong', 'BoundedStaleness', 'Session', 'ConsistentPrefix', 'Eventual'])
param consistencyLevel string = 'Session'

@description('Whether to restrict public network access (private endpoints only)')
param disablePublicAccess bool = false

@description('Whether to enable free tier (one per subscription, dev only)')
param enableFreeTier bool = false

@description('Continuous backup for prod (30 days) vs periodic for dev')
param continuousBackup bool = false

@description('Whether to enable multi-region writes')
param enableMultiRegionWrite bool = false

@description('Environment tag')
param environment string

@description('Additional tags')
param tags object = {}

resource account 'Microsoft.DocumentDB/databaseAccounts@2023-04-15' = {
  name: name
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    capabilities: serverless ? [{ name: 'EnableServerless' }] : null
    publicNetworkAccess: disablePublicAccess ? 'Disabled' : 'Enabled'
    enableFreeTier: enableFreeTier
    enableAutomaticFailover: enableMultiRegionWrite
    locations: [{ locationName: location, failoverPriority: 0, isZoneRedundant: false }]
    consistencyPolicy: { defaultConsistencyLevel: consistencyLevel }
    backupPolicy: continuousBackup ? {
      type: 'Continuous'
      continuousModeProperties: { tier: 'Continuous30Days' }
    } : {
      type: 'Periodic'
      periodicModeProperties: { backupIntervalInMinutes: 240, backupRetentionIntervalInHours: 8 }
    }
    databaseAccountOfferType: serverless ? null : 'Standard'
  }
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

output id string = account.id
output name string = account.name
output endpoint string = account.properties.documentEndpoint
output primaryKey string = account.listKeys().primaryMasterKey
