// ═══════════════════════════════════════════════════════════════════════════
// Platform module: ai/foundry-agent-setup.bicep
// Location: azure-platform-iac/modules/ai/foundry-agent-setup.bicep
//
// Deploys a deploymentScripts resource that runs the Foundry agent setup:
//   - Creates Foundry agents (Agents API v1 + v2 named agents)
//   - Builds vector stores from knowledge-base documents
//   - Configures VoiceLive sessions for unified text+voice agents
//   - Writes agent IDs and config back to Azure App Configuration
//
// This bridges the gap between ARM-managed infrastructure (Foundry Hub,
// AI Services, Search) and the API-only Foundry resources (agents, vector
// stores, voice configuration) that Bicep cannot create directly.
//
// The setup script writes agent IDs to App Configuration, where the app
// reads them at startup — replacing the manual `npm run setup-agents` flow
// with an IAC-managed one.
//
// SCRIPT SOURCE: The agent-setup.sh script lives in the app repo at
//   scripts/foundry/agent-setup.sh
// It's parameterized via environment variables and uses the Foundry SDKs
// (Python azure-ai-projects for v2 agents, Node @azure/ai-agents for v1).
// ═══════════════════════════════════════════════════════════════════════════

@description('Deployment name suffix (e.g., setup)')
param deploymentName string = 'setup'

@description('Foundry project endpoint (e.g., https://contoso.services.ai.azure.com)')
param foundryEndpoint string

@description('AI Services key (for the setup script to authenticate)')
@secure()
param aiServicesKey string

@description('Model deployment name (e.g., gpt-5-mini)')
param modelDeployment string = 'gpt-5-mini'

@description('Vector store ID to reuse (empty to create new)')
param vectorStoreId string = ''

@description('Knowledge base file path (directory of .md files, e.g., /workspace/kb/)')
param kbSourcePath string = '/workspace/kb/'

@description('Storage account name for setup artifacts')
param storageAccountName string

@description('App Configuration endpoint (Key=Vault URI or config store name)')
param appConfigEndpoint string = ''

@description('Managed identity client ID for the setup script to use')
param managedIdentityClientId string = ''

@description('Script URI (BLOB SAS URL or inline)')
param scriptUri string = ''

@description('Location')
param location string

@description('Environment tag')
param environment string

resource deploymentScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${deploymentName}-foundry-agents-${environment}'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityClientId}': {}    // MI with AI Developer role on Foundry
    }
  }
  properties: {
    azCliVersion: '2.63.0'
    timeout: 'PT30M'
    retentionInterval: 'PT1H'
    environmentVariables: [
      { name: 'FOUNDRY_ENDPOINT', value: foundryEndpoint }
      { name: 'AI_SERVICES_KEY', secureValue: aiServicesKey }
      { name: 'MODEL_DEPLOYMENT', value: modelDeployment }
      { name: 'VECTOR_STORE_ID', value: vectorStoreId }
      { name: 'KB_SOURCE_PATH', value: kbSourcePath }
      { name: 'APP_CONFIG_ENDPOINT', value: appConfigEndpoint }
      { name: 'ENVIRONMENT', value: environment }
    ]
    // Script is either provided via URI (BLOB storage) or inline
    scriptContent: !empty(scriptUri) ? null : '''
      #!/bin/bash
      set -euo pipefail
      echo "→ Installing Python dependencies for Foundry agent setup..."
      pip install azure-ai-projects azure-identity azure-appconfiguration --quiet
      echo "→ Running agent setup..."
      python /workspace/scripts/foundry/agent-setup.py \
        --endpoint "$FOUNDRY_ENDPOINT" \
        --model "$MODEL_DEPLOYMENT" \
        --kb-path "$KB_SOURCE_PATH" \
        --config-endpoint "$APP_CONFIG_ENDPOINT" \
        --environment "$ENVIRONMENT"
      echo "✓ Agent setup complete"
    '''
    primaryScriptUri: !empty(scriptUri) ? scriptUri : null
    supportingScriptUris: []
  }
}

output deploymentScriptName string = deploymentScript.name
output outputs object = deploymentScript.properties.outputs
