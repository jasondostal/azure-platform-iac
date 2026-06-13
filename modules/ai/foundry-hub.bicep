// ═══════════════════════════════════════════════════════════════════════════
// Platform module: ai/foundry-hub.bicep
// Location: azure-platform-iac/modules/ai/foundry-hub.bicep
//
// Azure AI Foundry Hub + AI Services account (Cognitive Services) + model
// deployments. The Hub is the top-level resource that owns projects.
// The AI Services account is the shared billing + quota container.
//
// This deploys the infrastructure that the Foundry SDKs connect to:
//   - Hub:    PROJECT_ENDPOINT (e.g. https://<name>.services.ai.azure.com)
//   - AI Services: the OpenAI and model-hosting account
//   - Model deployments: GPT-5-mini, text-embedding-3-small, etc.
//
// NOTE: Foundry is a rapidly-evolving surface. The resource types are in flux
//       and some features (agent vector stores, VoiceLive configuration) are
//       API-only — deployed via SDK scripts, not Bicep. This module covers
//       the ARM-manageable infrastructure; setup scripts handle the rest.
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (e.g., contoso-foundry-dev)')
param name string

@description('Azure region')
param location string

@description('AI Services account name. Defaults to {name}-aisvc.')
param aiServicesName string = ''

@description('Whether to enable public network access')
param publicNetworkAccess bool = true

@description('Whether to enable managed identity on the AI Services account')
param enableManagedIdentity bool = true

@description('Model deployments to create. Each: {name, modelFormat, modelName, modelVersion?, skuName?, skuCapacity?}')
param modelDeployments array = []

@description('Environment tag')
param environment string

@description('Additional tags')
param tags object = {}

var aisvcName = !empty(aiServicesName) ? aiServicesName : '${name}-aisvc'

// ── AI Services account (Cognitive Services) ────────────────────────────────

resource aiServices 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: aisvcName
  location: location
  kind: 'AIServices'
  sku: { name: 'S0' }
  properties: {
    publicNetworkAccess: publicNetworkAccess ? 'Enabled' : 'Disabled'
    customSubDomainName: aisvcName
    apiProperties: {
      statisticsEnabled: false
    }
  }
  identity: enableManagedIdentity ? {
    type: 'SystemAssigned'
  } : null
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

// ── Foundry Hub (Machine Learning workspace configured as Hub) ──────────────

resource hub 'Microsoft.MachineLearningServices/workspaces@2024-10-01' = {
  name: name
  location: location
  kind: 'hub'
  properties: {
    friendlyName: name
    // Link the AI Services account to the Hub
    // This is the key integration point — Foundry Hubs use this for billing + quota
    workspaceHubConfig: {
      additionalWorkspaceStorageAccounts: []
    }
    publicNetworkAccess: publicNetworkAccess ? 'Enabled' : 'Disabled'
  }
  identity: {
    type: 'SystemAssigned'
  }
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

// ── Model Deployments (on the AI Services account) ──────────────────────────

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = [for model in modelDeployments: {
  parent: aiServices
  name: model.name
  sku: {
    name: contains(model, 'skuName') ? model.skuName : 'GlobalStandard'
    capacity: contains(model, 'skuCapacity') ? model.skuCapacity : 10
  }
  properties: {
    model: {
      format: model.modelFormat
      name: model.modelName
      version: contains(model, 'modelVersion') ? model.modelVersion : '1'
    }
  }
}]

// ── Outputs ────────────────────────────────────────────────────────────────

output hubName string = hub.name
output hubId string = hub.id
output aiServicesName string = aiServices.name
output aiServicesId string = aiServices.id
output aiServicesEndpoint string = aiServices.properties.endpoint
output aiServicesKey string = aiServices.listKeys().key1
output managedIdentityPrincipalId string = enableManagedIdentity ? aiServices.identity.principalId : ''
