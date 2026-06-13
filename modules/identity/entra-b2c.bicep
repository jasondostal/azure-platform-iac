// ═══════════════════════════════════════════════════════════════════════════
// Platform module: entra-b2c.bicep
// Location: azure-platform-iac/modules/identity/entra-b2c.bicep
//
// Azure AD B2C tenant + user flow configuration for external (non-employee)
// identity. Exposes a config summary usable by APIM validate-jwt policies.
//
// NOTE: B2C tenant creation via Bicep is limited — the Microsoft.Graph
// provider cannot create B2C tenants directly (they require the "Create
// tenant" API which is ARM-only and doesn't support full B2C config).
//
// In practice, B2C tenants are created manually or via Terraform's azuread
// provider, and Bicep consumes the outputs (tenant name, policy names)
// as parameters. This module models that pattern: it takes the existing
// B2C tenant details and produces the standardized output contract that
// APIM modules and app repos consume.
//
// For a fully IAC-managed B2C, use Terraform for the tenant + user flows,
// then feed the outputs as params here.
// ═══════════════════════════════════════════════════════════════════════════

@description('B2C tenant name (e.g., contosob2c). Do not include .onmicrosoft.com.')
param tenantName string

@description('B2C tenant ID (GUID)')
param tenantId string

@description('List of user flow / custom policy names to reference. Each: {name, displayName}')
param userFlows array = []

@description('B2C App Registration client ID (for APIM token validation audience)')
param apiClientId string

@description('Environment tag')
param environment string

// B2C OpenID Connect metadata endpoint — used by APIM validate-jwt
// For user flows:   https://{tenantName}.b2clogin.com/{tenantName}.onmicrosoft.com/{policy}/v2.0/.well-known/openid-configuration
// For custom policies: same but with B2C_1A_ prefix
var b2cDomain = '${tenantName}.b2clogin.com'
var b2cIssuer = '${tenantName}.onmicrosoft.com'

// Build per-policy metadata URLs
var policyMetadata = [for flow in userFlows: {
  policyName: flow.name
  displayName: flow.displayName
  openIdConfigUrl: 'https://${b2cDomain}/${b2cIssuer}/${flow.name}/v2.0/.well-known/openid-configuration'
  issuer: 'https://${b2cDomain}/${b2cIssuer}/v2.0/'
}]

// Output contract — everything an APIM module or app needs
output tenantName string = tenantName
output tenantId string = tenantId
output b2cDomain string = b2cDomain
output b2cIssuer string = b2cIssuer
output apiClientId string = apiClientId
output policyMetadata array = policyMetadata
output defaultSignInPolicy string = !empty(userFlows) ? userFlows[0].name : ''
