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

@description('Entra (Azure AD) tenant ID — required for the Entra admin')
param tenantId string = tenant().tenantId

@description('Entra admin display name/login (e.g., a group name or the provisioning identity name). Empty = no Entra admin.')
param entraAdminLogin string = ''

@description('Entra admin object (SID): the objectId of the group / user / managed identity that administers this server')
param entraAdminSid string = ''

@description('Entra-only authentication — when true the server is created with the Entra admin only and NO SQL admin login (passwordless). Reversible by the Entra admin.')
param entraOnlyAuth bool = true

@description('Entra admin principal type: Application (managed identity / SP, default), Group (recommended for human admins), or User')
@allowed(['Application', 'Group', 'User'])
param entraAdminPrincipalType string = 'Application'

@description('Environment tag')
param environment string

@description('Additional tags')
param tags object = {}

var hasEntraAdmin = !empty(entraAdminSid)

// Born Entra-only: when an Entra admin is set AND entraOnlyAuth, the server is
// created with the Entra admin inline and azureADOnlyAuthentication=true, and we
// OMIT the SQL admin login/password entirely. That avoids the AadOnly conflict
// you hit if you ever re-PUT the server carrying SQL credentials.
var bornEntraOnly = hasEntraAdmin && entraOnlyAuth

// SQL-auth admin credentials — included only when NOT going born-Entra-only.
var sqlAuthProps = bornEntraOnly ? {} : {
  administratorLogin: adminLogin
  administratorLoginPassword: adminPassword
}

// Inline Entra admin (set at creation — works for born-Entra-only and dual-auth).
var entraAdminProps = hasEntraAdmin ? {
  administrators: {
    administratorType: 'ActiveDirectory'
    principalType: entraAdminPrincipalType
    login: entraAdminLogin
    sid: entraAdminSid
    tenantId: tenantId
    azureADOnlyAuthentication: entraOnlyAuth
  }
} : {}

resource server 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: name
  location: location
  // System-assigned identity — needed for the server to validate Entra (managed
  // identity / service principal) logins. Grant this identity the Directory
  // Readers Entra role (out-of-band, one-time) to enable passwordless SQL.
  identity: {
    type: 'SystemAssigned'
  }
  properties: union({
    publicNetworkAccess: disablePublicAccess ? 'Disabled' : 'Enabled'
    minimalTlsVersion: minTlsVersion
  }, sqlAuthProps, entraAdminProps)
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
output principalId string = server.identity.principalId
