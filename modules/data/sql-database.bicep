// ═══════════════════════════════════════════════════════════════════════════
// Platform module: sql-database.bicep
// Location: azure-platform-iac/modules/data/sql-database.bicep
//
// Generic Azure SQL Database.
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (e.g., contoso-db-dev)')
param name string

@description('Azure region')
param location string

@description('Parent SQL server name')
param sqlServerName string

@description('SKU name: Basic, S0-S12, P1-P15, GP_Gen5_2 etc., or HS_Gen5_2 for hyperscale')
param skuName string = 'Basic'

@description('SKU tier: Basic, Standard, Premium, GeneralPurpose, Hyperscale')
param skuTier string = 'Basic'

@description('Max size in bytes (2GB = 2147483648)')
param maxSizeBytes int = 2147483648

@description('Environment tag')
param environment string

@description('Additional tags')
param tags object = {}

resource db 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  name: '${sqlServerName}/${name}'
  location: location
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    maxSizeBytes: maxSizeBytes
  }
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

output id string = db.id
output name string = db.name
