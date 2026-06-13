// ── Log Analytics Workspace ─────────────────────────────────────────────────
param name string
param location string
param retentionDays int = 30

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: name
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionDays
  }
}

output id string = logAnalytics.id
output name string = logAnalytics.name
