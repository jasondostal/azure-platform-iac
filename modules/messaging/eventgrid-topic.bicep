// ═══════════════════════════════════════════════════════════════════════════
// Platform module: eventgrid-topic.bicep
// Location: azure-platform-iac/modules/messaging/eventgrid-topic.bicep
//
// Generic Event Grid Custom Topic. Callers add event subscriptions
// (webhook, Service Bus, Storage Queue, Event Hub) separately.
// ═══════════════════════════════════════════════════════════════════════════

@description('Resource name (e.g., contoso-eg-dev)')
param name string

@description('Azure region')
param location string

@description('Input schema: CloudEventSchemaV1_0 (recommended) | EventGridSchema | CustomInputSchema')
@allowed(['CloudEventSchemaV1_0', 'EventGridSchema', 'CustomInputSchema'])
param inputSchema string = 'CloudEventSchemaV1_0'

@description('Whether to enable public network access')
param enablePublicAccess bool = true

@description('Environment tag')
param environment string

@description('Additional tags')
param tags object = {}

resource topic 'Microsoft.EventGrid/topics@2024-06-01-preview' = {
  name: name
  location: location
  properties: {
    inputSchema: inputSchema
    publicNetworkAccess: enablePublicAccess ? 'Enabled' : 'Disabled'
    minimumTlsVersionAllowed: '1.2'
  }
  tags: union(tags, {
    environment: environment
    managedBy: 'azure-platform-iac'
  })
}

output id string = topic.id
output name string = topic.name
output endpoint string = topic.properties.endpoint
