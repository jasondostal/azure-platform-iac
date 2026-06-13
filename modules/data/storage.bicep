// ═══════════════════════════════════════════════════════════════════════════
// Platform module: storage.bicep
// Location: azure-platform-iac/modules/data/storage.bicep
//
// Generic Storage Account v2. Callers add containers/shares/queues/tables
// via separate bicep or post-deploy configuration.
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (3-24 lowercase alphanumeric, globally unique)')
param name string

@description('Azure region')
param location string

@description('SKU: Standard_LRS | Standard_GRS | Standard_RAGRS | Standard_ZRS | Premium_LRS')
@allowed(['Standard_LRS', 'Standard_GRS', 'Standard_RAGRS', 'Standard_ZRS', 'Premium_LRS'])
param sku string = 'Standard_LRS'

@description('Whether to enable hierarchical namespace (Data Lake Gen2)')
param enableHierarchicalNamespace bool = false

@description('Whether to restrict public network access (private endpoints only)')
param disablePublicAccess bool = false

@description('Whether to allow blob public access (should almost always be false)')
param allowBlobPublicAccess bool = false

@description('Blob soft-delete retention in days (min 1)')
param blobDeleteRetentionDays int = 7

@description('Container soft-delete retention in days')
param containerDeleteRetentionDays int = 7

@description('Whether to enable blob versioning')
param enableVersioning bool = true

@description('Whether to enable infrastructure encryption (double encryption)')
param infrastructureEncryption bool = false

@description('Environment tag')
param environment string

@description('Additional tags')
param tags object = {}

resource st 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: name
  location: location
  kind: 'StorageV2'
  sku: { name: sku }
  properties: {
    publicNetworkAccess: disablePublicAccess ? 'Disabled' : 'Enabled'
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: allowBlobPublicAccess
    isHnsEnabled: enableHierarchicalNamespace
    networkAcls: {
      defaultAction: disablePublicAccess ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
    }
    supportsHttpsTrafficOnly: true
  }
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

// Blob service properties (soft-delete + versioning)
resource blob 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: st
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: blobDeleteRetentionDays }
    containerDeleteRetentionPolicy: { enabled: true, days: containerDeleteRetentionDays }
    isVersioningEnabled: enableVersioning
  }
}

// Required parents for other services
resource file 'Microsoft.Storage/storageAccounts/fileServices@2024-01-01' = {
  parent: st
  name: 'default'
}

resource table 'Microsoft.Storage/storageAccounts/tableServices@2024-01-01' = {
  parent: st
  name: 'default'
}

resource queue 'Microsoft.Storage/storageAccounts/queueServices@2024-01-01' = {
  parent: st
  name: 'default'
}

output id string = st.id
output name string = st.name
output blobEndpoint string = st.properties.primaryEndpoints.blob
output tableEndpoint string = st.properties.primaryEndpoints.table
output queueEndpoint string = st.properties.primaryEndpoints.queue
