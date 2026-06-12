// ═══════════════════════════════════════════════════════════════════════════
// Platform module: sql-server.bicep
// Location: azure-platform-iac/modules/data/sql-server.bicep
//
// Generic Azure SQL Server (logical server).
// Works with: sql-database, sql-elastic-pool
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (e.g., contoso-sql-dev — must be globally unique prefixes)')
param name string

@description('Azure region')
param location string

@description('SQL admin login')
@secure()
param adminLogin string

@description('SQL admin password')
@secure()
param adminPassword string

@description('Whether to restrict public network access (private endpoints only)')
param disablePublicAccess bool = true

@description('Minimum TLS version')
param minTlsVersion string = '1.2'

@description('Whether to allow Azure services through firewall (only when public access enabled)')
param allowAzureServices bool = false

@description('Environment tag')
param environment string

@description('Additional tags')
param tags object = {}

resource server 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: name
  location: location
  properties: {
    administratorLogin: adminLogin
    administratorLoginPassword: adminPassword
    publicNetworkAccess: disablePublicAccess ? 'Disabled' : 'Enabled'
    minimalTlsVersion: minTlsVersion
  }
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

resource allowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = if (!disablePublicAccess && allowAzureServices) {
  parent: server
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

output id string = server.id
output name string = server.name
output fqdn string = server.properties.fullyQualifiedDomainName
