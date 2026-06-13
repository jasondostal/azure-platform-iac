// ═══════════════════════════════════════════════════════════════════════════
// Platform module: entra-app-registration.bicep
// Location: azure-platform-iac/modules/identity/entra-app-registration.bicep
//
// Entra ID Application Registration — CONFIGURATION CONTRACT module.
//
// Truth: Bicep cannot create Entra app registrations directly (no
// Microsoft.Graph provider support in Bicep). App registrations are
// created via Azure CLI, Portal, or Terraform's azuread provider.
//
// This module models the output contract that APIM and App Service
// modules consume: audience URI, tenant ID, scopes, app roles.
// Callers either:
//   (a) Create the app reg externally, pass the client ID as a param
//   (b) Use az cli in an ADO pipeline step to create the app reg,
//       then pass the resulting client ID to the Bicep deployment
//
// Outputs are the standard set of values needed by APIM validate-jwt
// policies and App Service EasyAuth configuration.
// ═══════════════════════════════════════════════════════════════════════════

@description('Entra tenant ID (GUID)')
param tenantId string

@description('Application (client) ID — from the app registration created externally')
param clientId string

@description('Display name of the app registration (for documentation / tagging)')
param displayName string

@description('Whether this app exposes an API (scopes) or is a client')
param exposeApi bool = true

@description('Identifier URI (e.g., api://contoso-api-dev). Default: api://{clientId}')
param identifierUri string = ''

@description('List of scopes exposed (documentation only — managed in Entra)')
param scopes array = []

@description('List of app roles (documentation only — managed in Entra)')
param appRoles array = []

@description('Client secret (if generated). DO NOT hardcode — inject from Key Vault.')
@secure()
param clientSecret string = ''

@description('Environment tag')
param environment string

// OpenID Connect metadata URL — used by APIM validate-jwt
var openIdConfigUrl = 'https://login.microsoftonline.com/${tenantId}/v2.0/.well-known/openid-configuration'

// Issuer — also needed by validate-jwt
var issuer = 'https://login.microsoftonline.com/${tenantId}/v2.0'

// Effective identifier URI
var effectiveIdentifierUri = !empty(identifierUri) ? identifierUri : 'api://${clientId}'

// ── Outputs (consumed by APIM modules, App Service auth config) ────────────

output applicationId string = clientId
output displayName string = displayName
output tenantId string = tenantId
output openIdConfigUrl string = openIdConfigUrl
output issuer string = issuer
output identifierUris array = [effectiveIdentifierUri]
output audience string = clientId        // primary audience for validate-jwt
output apiAudience string = effectiveIdentifierUri  // api:// form for validate-jwt
