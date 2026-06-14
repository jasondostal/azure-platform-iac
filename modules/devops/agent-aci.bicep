// ═══════════════════════════════════════════════════════════════════════════
// Platform module: devops/agent-aci.bicep
// Location: azure-platform-iac/modules/devops/agent-aci.bicep
//
// Self-hosted Azure DevOps build/deploy agent(s) running on Azure Container
// Instances, VNet-INJECTED so they can reach private-endpoint-locked resources
// (private App Service, private SQL, private Key Vault).
//
// WHY THIS EXISTS — it's not optional in the private-endpoint world:
//   When `enablePrivateEndpoints=true`, app resources have NO public endpoint —
//   reachable only from inside the VNet. Microsoft-HOSTED ADO agents live on
//   Microsoft's network, outside your tenant, so they physically cannot route
//   to those resources; deploys hang and time out. A VNet-integrated SELF-hosted
//   agent is the only thing that can deploy into a private-by-default estate.
//   The regulatory "private-by-default" posture therefore REQUIRES this module.
//
// Each container group = one persistent agent (restartPolicy Always). Set
// `agentCount` for a fixed pool size; scale by redeploying with a higher count.
//
// Image pull is passwordless: a user-assigned identity with AcrPull on the
// registry (created + assigned here). The ADO registration PAT is the one secret
// (agent registration has no WIF path) — pass it from Key Vault as `azpToken`.
// ═══════════════════════════════════════════════════════════════════════════

@description('Base name for the agent container group(s)')
param name string

@description('Azure region')
param location string

@description('Subnet resource ID the agent is injected into — must be delegated to Microsoft.ContainerInstance/containerGroups and have line-of-sight to the private endpoints it deploys to')
param subnetId string

@description('Agent container image, e.g. <acr>.azurecr.io/ado-agent:latest')
param image string

@description('ACR resource ID (for the AcrPull role assignment) — the registry hosting the agent image')
param acrId string

@description('ACR login server, e.g. <acr>.azurecr.io')
param acrLoginServer string

@description('Azure DevOps organization URL, e.g. https://dev.azure.com/your-org')
param azpUrl string

@description('Azure DevOps agent pool name the agent registers into')
param azpPool string

@description('PAT with Agent Pools (Read & Manage) scope. Source from Key Vault — agent registration has no Workload Identity Federation path.')
@secure()
param azpToken string

@description('Number of agent container groups (each = one persistent agent)')
@minValue(1)
param agentCount int = 1

@description('vCPU per agent')
param cpu int = 1

@description('Memory (GiB) per agent')
param memoryInGb int = 2

@description('Environment tag')
param environment string

@description('Additional tags')
param tags object = {}

var commonTags = union(tags, {
  environment: environment
  managedBy: 'azure-platform-iac'
})

// The ACR may live in a DIFFERENT resource group / subscription than the agent
// (e.g. platform-shared registry vs the app's RG). Parse its id so the AcrPull
// grant targets the registry in its own RG via a scoped nested module.
var acrSubId = split(acrId, '/')[2]
var acrRgName = split(acrId, '/')[4]
var acrName = last(split(acrId, '/'))

// ── Pull identity (passwordless ACR pull) ───────────────────────────────────
resource pullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${name}-pull'
  location: location
  tags: commonTags
}

module acrPull 'acr-pull-role.bicep' = {
  name: 'acrpull-${name}'
  scope: resourceGroup(acrSubId, acrRgName)
  params: {
    acrName: acrName
    principalId: pullIdentity.properties.principalId
  }
}

// ── Agent container group(s) ────────────────────────────────────────────────
resource agent 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = [for i in range(0, agentCount): {
  name: '${name}-${i}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${pullIdentity.id}': {}
    }
  }
  properties: {
    sku: 'Standard'
    osType: 'Linux'
    restartPolicy: 'Always'
    subnetIds: [
      { id: subnetId }
    ]
    imageRegistryCredentials: [
      {
        server: acrLoginServer
        identity: pullIdentity.id
      }
    ]
    containers: [
      {
        name: 'agent'
        properties: {
          image: image
          resources: {
            requests: {
              cpu: cpu
              memoryInGB: memoryInGb
            }
          }
          environmentVariables: [
            { name: 'AZP_URL', value: azpUrl }
            { name: 'AZP_POOL', value: azpPool }
            { name: 'AZP_AGENT_NAME', value: '${name}-${i}' }
            { name: 'AZP_TOKEN', secureValue: azpToken }
          ]
        }
      }
    ]
  }
  tags: commonTags
  dependsOn: [
    acrPull
  ]
}]

output pullIdentityPrincipalId string = pullIdentity.properties.principalId
output agentNames array = [for i in range(0, agentCount): '${name}-${i}']
