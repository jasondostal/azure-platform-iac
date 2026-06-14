// ═══════════════════════════════════════════════════════════════════════════
// Platform module: container-app.bicep
// Location: azure-platform-iac/modules/compute/container-app.bicep
//
// Container App — a single containerised workload in a managed environment.
// Supports: scale-to-zero, passwordless ACR pull (user-assigned identity),
// SystemAssigned managed identity for downstream resource access, and
// internal (VNet-only) or external ingress.
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (e.g., contoso-app-dev)')
param name string

@description('Azure region')
param location string

@description('Container Apps managed environment resource ID')
param environmentId string

@description('Full container image reference, e.g. <acr>.azurecr.io/app:tag or mcr.microsoft.com/azuredocs/containerapps-helloworld:latest')
param image string

@description('ACR login server hostname (e.g., contosoacr.azurecr.io). When provided together with acrIdentityId, enables passwordless ACR pull via user-assigned managed identity.')
param acrLoginServer string = ''

@description('User-assigned managed identity resource ID that holds AcrPull on the ACR. Required when acrLoginServer is set.')
param acrIdentityId string = ''

@description('Container port that the app listens on')
param targetPort int = 8080

@description('Whether ingress is external (internet-facing) or internal (VNet-only). Set false when deploying behind APIM or inside a private environment.')
param external bool = true

@description('vCPU allocation per replica — must be paired with a supported memory value (0.5 CPU → 1Gi, 1 CPU → 2Gi, 2 CPU → 4Gi)')
param cpu string = '0.5'

@description('Memory allocation per replica (e.g., 1Gi, 2Gi). Must be consistent with the cpu value.')
param memory string = '1Gi'

@description('Minimum replica count. 0 enables scale-to-zero (no cost when idle).')
param minReplicas int = 0

@description('Maximum replica count')
param maxReplicas int = 3

@description('Whether to enable SystemAssigned managed identity for downstream resource access (Key Vault, Service Bus, SQL, etc.)')
param enableManagedIdentity bool = true

@description('Environment variables to inject into the container (key → value object). For secrets, prefer Key Vault references.')
param envVars object = {}

@description('Environment tag')
param environment string

@description('Additional tags')
param tags object = {}

// Build the container env array from the flat envVars object
var envVarsArray = [for entry in items(envVars): {
  name: entry.key
  value: entry.value
}]

// Passwordless ACR registry config — only wired when both server and identity are provided
var registries = (!empty(acrLoginServer) && !empty(acrIdentityId)) ? [
  {
    server: acrLoginServer
    identity: acrIdentityId
  }
] : []

// User-assigned identities block — needed for ACR pull identity
var userAssignedIdentities = !empty(acrIdentityId) ? {
  '${acrIdentityId}': {}
} : {}

// Compose the identity block based on enableManagedIdentity and whether a user-assigned identity is present
var identityBlock = enableManagedIdentity ? ((!empty(acrIdentityId)) ? {
  type: 'SystemAssigned,UserAssigned'
  userAssignedIdentities: userAssignedIdentities
} : {
  type: 'SystemAssigned'
}) : ((!empty(acrIdentityId)) ? {
  type: 'UserAssigned'
  userAssignedIdentities: userAssignedIdentities
} : null)

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  identity: identityBlock
  properties: {
    environmentId: environmentId
    configuration: {
      ingress: {
        external: external
        targetPort: targetPort
        transport: 'auto'
      }
      registries: !empty(registries) ? registries : null
    }
    template: {
      containers: [
        {
          name: name
          image: image
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          env: envVarsArray
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
      }
    }
  }
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

output id string = containerApp.id
output name string = containerApp.name
output fqdn string = containerApp.properties.configuration.ingress.fqdn
output managedIdentityPrincipalId string = enableManagedIdentity ? containerApp.identity.principalId : ''
