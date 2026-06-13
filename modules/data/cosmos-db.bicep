// ═══════════════════════════════════════════════════════════════════════════
// Platform module: cosmos-db.bicep
// Location: azure-platform-iac/modules/data/cosmos-db.bicep
//
// Cosmos DB account, passwordless by default (key auth disabled — Entra /
// managed-identity only). Grant the consuming app's managed identity the
// built-in Data Contributor role via dataContributorPrincipalIds; it can then
// read/write documents with no key. Consume from app code as:
//   new CosmosClient(endpoint, new DefaultAzureCredential())
//
// Callers add databases + containers separately (your containers are your
// schema). Serverless by default — flip to provisioned for steady-state prod.
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

@description('Disable key-based (local) auth — passwordless, Entra/managed-identity only. Recommended.')
param disableLocalAuth bool = true

@description('Object IDs (principalIds) granted the Cosmos DB Built-in Data Contributor role (read+write, data plane)')
param dataContributorPrincipalIds array = []

@description('Optional: create a single SQL (Core) API database with this name. Empty = none (caller adds its own).')
param databaseName string = ''

@description('Optional: create a single container in that database. Empty = none.')
param containerName string = ''

@description('Partition key path for the optional container')
param partitionKeyPath string = '/id'

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

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: name
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    capabilities: serverless ? [{ name: 'EnableServerless' }] : null
    publicNetworkAccess: disablePublicAccess ? 'Disabled' : 'Enabled'
    disableLocalAuth: disableLocalAuth
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
    databaseAccountOfferType: 'Standard'
  }
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

// Data-plane RBAC — built-in "Cosmos DB Built-in Data Contributor" (read+write).
// Control-plane assignment in Bicep: no Directory Readers, no contained users.
var dataContributorRoleId = '00000000-0000-0000-0000-000000000002'

resource dataRoles 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = [for pid in dataContributorPrincipalIds: {
  parent: account
  name: guid(account.id, pid, dataContributorRoleId)
  properties: {
    roleDefinitionId: '${account.id}/sqlRoleDefinitions/${dataContributorRoleId}'
    principalId: pid
    scope: account.id
  }
}]

// Optional single database + container (the common app case). For multiple
// databases/containers, omit these and have the caller add its own.
resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = if (!empty(databaseName)) {
  parent: account
  name: databaseName
  properties: {
    resource: { id: databaseName }
  }
}

resource container 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = if (!empty(databaseName) && !empty(containerName)) {
  parent: database
  name: containerName
  properties: {
    resource: {
      id: containerName
      partitionKey: { paths: [ partitionKeyPath ], kind: 'Hash' }
    }
  }
}

output id string = account.id
output name string = account.name
output endpoint string = account.properties.documentEndpoint
