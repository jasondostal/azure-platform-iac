// ── AcrPull grant (deployed at the ACR's own resource group scope) ──────────
// Companion to agent-aci.bicep: lets the agent's pull identity pull images from
// a registry that may live in a different RG/subscription than the agent.
param acrName string
param principalId string

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: acrName
}

// AcrPull = 7f951dda-4ed3-4680-a7ca-43fe172d538d
resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, principalId, 'AcrPull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
