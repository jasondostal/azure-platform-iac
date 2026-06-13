// ═══════════════════════════════════════════════════════════════════════════
// Platform module: ai/foundry-project.bicep
// Location: azure-platform-iac/modules/ai/foundry-project.bicep
//
// Azure AI Foundry Project — the scope where agents, vector stores, and
// connections live. A Hub can have many projects; each project is a logical
// workspace for a team or app.
//
// The project endpoint is what the SDK connects to:
//   PROJECT_ENDPOINT = https://<hub>.services.ai.azure.com/api/projects/<project-name>
// ═══════════════════════════════════════════════════════════════════════════

@description('Project name (e.g., contoso-members-agent-dev)')
param name string

@description('Azure region')
param location string

@description('Parent Hub resource ID')
param hubId string

@description('AI Services account resource ID (for billing + quota)')
param aiServicesId string

@description('Storage account resource ID for project data')
param storageAccountId string = ''

@description('AI Search service resource ID for vector search (RAG at scale)')
param aiSearchServiceId string = ''

@description('Whether to enable public network access')
param publicNetworkAccess bool = true

@description('Environment tag')
param environment string

@description('Additional tags')
param tags object = {}

resource project 'Microsoft.MachineLearningServices/workspaces@2024-10-01' = {
  name: name
  location: location
  kind: 'project'
  properties: {
    friendlyName: name
    // Parent Hub reference
    hubResourceId: hubId
    // Workspace-level connections to services the project uses
    workspaceHubConfig: {
      additionalWorkspaceStorageAccounts: !empty(storageAccountId) ? [storageAccountId] : []
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

// ── Outputs ────────────────────────────────────────────────────────────────

output projectName string = project.name
output projectId string = project.id
output projectEndpoint string = 'https://${project.name}.services.ai.azure.com'
output hubResourceId string = hubId
