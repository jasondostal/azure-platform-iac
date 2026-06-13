// ═══════════════════════════════════════════════════════════════════════════
// Platform module: apim-api.bicep
// Location: azure-platform-iac/modules/integration/apim-api.bicep
//
// Reusable API definition for Azure API Management. Creates the API
// resource + products + configurable authentication policies.
//
// Supports three auth modes, any or all simultaneously:
//   1. Internal Entra ID (employees — validate-jwt against corporate tenant)
//   2. External B2C (partner end-users — validate-jwt against B2C tenant)
//   3. Client credentials (machine-to-machine — validate-jwt with separate aud)
//
// Also creates standard APIM Products (Internal, Partner, Public) and
// applies a global API policy that chains auth validation.
//
// NOTE: This module creates API-level resources, not the APIM instance itself.
//       Use api-management.bicep for the service, then this module for APIs.
//
// NOTE: Bicep multi-line strings ('''...''') are RAW — they do NOT interpolate
//       ${...}. The policy + auth fragments below therefore use __TOKEN__
//       placeholders and replace() to splice in values. Interpolating directly
//       inside ''' emitted literal "${x}" text into the policy XML, so the
//       validate-jwt blocks never actually applied.
// ═══════════════════════════════════════════════════════════════════════════

// ── APIM instance reference ────────────────────────────────────────────────

@description('APIM service name (must already exist — used to build resource references)')
param apimServiceName string

// ── API definition ──────────────────────────────────────────────────────────

@description('API resource name (e.g., contoso-members-api)')
param apiName string

@description('API display name')
param displayName string

@description('URL path prefix (e.g., members)')
param path string

@description('Backend service URL (e.g., App Service URL)')
param serviceUrl string = ''

@description('API version (e.g., v1). Set to empty string for unversioned.')
param apiVersion string = 'v1'

@description('Whether subscription key is required')
param subscriptionRequired bool = true

@description('OpenAPI spec URL to import operations from. Empty = manual.')
param openApiSpecUrl string = ''

@description('Environment tag')
param environment string

// ── Auth configuration ──────────────────────────────────────────────────────

@description('Enable internal Entra ID auth (employees)')
param enableEntraAuth bool = true

@description('Entra tenant ID for internal employee auth')
param entraTenantId string = ''

@description('Entra App Registration client ID (audience claim to validate)')
param entraAudience string = ''

@description('Enable external B2C auth (partner end-users)')
param enableB2CAuth bool = false

@description('B2C tenant name (e.g., contosob2c)')
param b2cTenantName string = ''

@description('B2C sign-in policy name (e.g., B2C_1_signin)')
param b2cSignInPolicy string = ''

@description('B2C App Registration client ID (audience for B2C tokens)')
param b2cAudience string = ''

@description('Enable client credential auth (M2M / partner systems)')
param enableClientCredentialAuth bool = false

@description('Client credential Entra tenant ID')
param clientCredentialTenantId string = ''

@description('Client credential audience (app registration client ID)')
param clientCredentialAudience string = ''

@description('Additional allowed issuers (e.g., federal Entra tenants)')
param additionalIssuers array = []

// ── Products ───────────────────────────────────────────────────────────────

@description('Whether to create the standard product suite')
param createProducts bool = true

// ── Inbound CORS ───────────────────────────────────────────────────────────

@description('Allowed CORS origins (array of URLs)')
param corsOrigins array = ['*']

// ── Rate limiting ──────────────────────────────────────────────────────────

@description('Rate limit: max calls per renewal period')
param rateLimitCalls int = 100

@description('Rate limit: renewal period in seconds')
param rateLimitPeriod int = 60

// ── API ────────────────────────────────────────────────────────────────────

var apiResourceName = apiName

// Determine API type: openapi-link for URL imports, http for manual
var apiTypeValue = empty(openApiSpecUrl) ? 'http' : 'openapi-link'

// Reference the APIM service (existing — created by api-management.bicep)
resource apimService 'Microsoft.ApiManagement/service@2023-12-01' existing = {
  name: apimServiceName
}

resource apiDef 'Microsoft.ApiManagement/service/apis@2023-12-01' = {
  parent: apimService
  name: apiResourceName
  properties: {
    displayName: displayName
    path: path
    serviceUrl: serviceUrl
    protocols: ['https']
    subscriptionRequired: subscriptionRequired
    apiType: apiTypeValue
    apiVersion: !empty(apiVersion) ? apiVersion : null
    apiVersionSetId: null
    format: !empty(openApiSpecUrl) ? 'openapi-link' : null
    value: !empty(openApiSpecUrl) ? openApiSpecUrl : null
  }
}

// ── Auth: build JWT validation fragments (token templates + replace) ─────────

var additionalIssuerLines = [for issuer in additionalIssuers: '        <issuer>${issuer}</issuer>']

// Internal Entra — validate employee tokens
var entraJwtRaw = '''
    <!-- Internal employee auth (Entra ID) -->
    <validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized - valid Entra ID token required">
      <openid-config url="https://login.microsoftonline.com/__ENTRA_TENANT__/v2.0/.well-known/openid-configuration" />
      <audiences>
        <audience>__ENTRA_AUD__</audience>
        <audience>api://__ENTRA_AUD__</audience>
      </audiences>
      <issuers>
        <issuer>https://login.microsoftonline.com/__ENTRA_TENANT__/v2.0</issuer>
        <issuer>https://sts.windows.net/__ENTRA_TENANT__/</issuer>
__ENTRA_EXTRA_ISSUERS__
      </issuers>
      <required-claims>
        <claim name="appid" match="any">
          <value>__ENTRA_AUD__</value>
        </claim>
      </required-claims>
    </validate-jwt>
'''
var entraJwtFragment = enableEntraAuth && !empty(entraTenantId) && !empty(entraAudience)
  ? replace(replace(replace(entraJwtRaw, '__ENTRA_TENANT__', entraTenantId), '__ENTRA_AUD__', entraAudience), '__ENTRA_EXTRA_ISSUERS__', join(additionalIssuerLines, '\n'))
  : ''

// B2C — validate external user tokens
var b2cJwtRaw = '''
    <!-- External partner/customer auth (Azure AD B2C) -->
    <validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized - valid B2C token required">
      <openid-config url="https://__B2C_TENANT__.b2clogin.com/__B2C_TENANT__.onmicrosoft.com/__B2C_POLICY__/v2.0/.well-known/openid-configuration" />
      <audiences>
        <audience>__B2C_AUD__</audience>
      </audiences>
      <issuers>
        <issuer>https://__B2C_TENANT__.b2clogin.com/__B2C_TENANT__.onmicrosoft.com/v2.0/</issuer>
      </issuers>
    </validate-jwt>
'''
var b2cJwtFragment = enableB2CAuth && !empty(b2cTenantName) && !empty(b2cSignInPolicy) && !empty(b2cAudience)
  ? replace(replace(replace(b2cJwtRaw, '__B2C_TENANT__', b2cTenantName), '__B2C_POLICY__', b2cSignInPolicy), '__B2C_AUD__', b2cAudience)
  : ''

// Client credentials — validate M2M tokens
var ccJwtRaw = '''
    <!-- Machine-to-machine auth (client credentials) -->
    <validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized - valid client credential token required">
      <openid-config url="https://login.microsoftonline.com/__CC_TENANT__/v2.0/.well-known/openid-configuration" />
      <audiences>
        <audience>__CC_AUD__</audience>
        <audience>api://__CC_AUD__</audience>
      </audiences>
      <issuers>
        <issuer>https://login.microsoftonline.com/__CC_TENANT__/v2.0</issuer>
        <issuer>https://sts.windows.net/__CC_TENANT__/</issuer>
      </issuers>
    </validate-jwt>
'''
var clientCredentialJwtFragment = enableClientCredentialAuth && !empty(clientCredentialTenantId) && !empty(clientCredentialAudience)
  ? replace(replace(ccJwtRaw, '__CC_TENANT__', clientCredentialTenantId), '__CC_AUD__', clientCredentialAudience)
  : ''

// ── Policy (global, all operations inherited) ───────────────────────────────

var corsOriginLines = [for origin in corsOrigins: '        <origin>${origin}</origin>']
var corsOriginsXml = join(corsOriginLines, '\n')

var policyRaw = '''
<policies>
  <inbound>
    <base />
    <set-header name="X-Environment" exists-action="override">
      <value>__ENVIRONMENT__</value>
    </set-header>
    <set-header name="X-Api-Gateway" exists-action="override">
      <value>__APIM__</value>
    </set-header>
    <cors allow-credentials="true">
      <allowed-origins>
__CORS_ORIGINS__
      </allowed-origins>
      <allowed-methods>
        <method>GET</method>
        <method>POST</method>
        <method>PUT</method>
        <method>PATCH</method>
        <method>DELETE</method>
      </allowed-methods>
      <allowed-headers>
        <header>*</header>
      </allowed-headers>
    </cors>
    <rate-limit calls="__RATE_CALLS__" renewal-period="__RATE_PERIOD__" />
__ENTRA_JWT__
__B2C_JWT__
__CC_JWT__
    <choose>
      <when condition="@(context.Request.Headers.GetValueOrDefault(&quot;Authorization&quot;,&quot;&quot;).Contains(&quot;Bearer&quot;))">
        <!-- Token present - one of the validate-jwt blocks above already checked it -->
      </when>
      <otherwise>
        <return-response>
          <set-status code="401" reason="Unauthorized" />
          <set-body>@{
            return new JObject(
              new JProperty("error", "unauthorized"),
              new JProperty("message", "Bearer token required. See https://__APIM__.developer.azure-api.net/ for authentication instructions.")
            ).ToString();
          }</set-body>
        </return-response>
      </otherwise>
    </choose>
  </inbound>
  <backend>
    <base />
    <!-- Forward user identity to backend -->
    <set-header name="X-Authenticated-User-Id" exists-action="override">
      <value>@(context.User?.Id ?? "anonymous")</value>
    </set-header>
  </backend>
  <outbound>
    <base />
    <set-header name="X-Powered-By" exists-action="delete" />
    <set-header name="X-Environment" exists-action="override">
      <value>__ENVIRONMENT__</value>
    </set-header>
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
'''

var policyXml = replace(replace(replace(replace(replace(replace(replace(replace(policyRaw, '__ENVIRONMENT__', environment), '__APIM__', apimServiceName), '__CORS_ORIGINS__', corsOriginsXml), '__RATE_CALLS__', string(rateLimitCalls)), '__RATE_PERIOD__', string(rateLimitPeriod)), '__ENTRA_JWT__', entraJwtFragment), '__B2C_JWT__', b2cJwtFragment), '__CC_JWT__', clientCredentialJwtFragment)

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-12-01' = {
  parent: apiDef
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: policyXml
  }
}

// ── Products (subscription tiers) ───────────────────────────────────────────

resource internalProduct 'Microsoft.ApiManagement/service/products@2023-12-01' = if (createProducts) {
  parent: apimService
  name: '${apiName}-internal'
  properties: {
    displayName: 'Internal (${displayName})'
    description: 'Internal employees — no subscription approval required'
    subscriptionRequired: subscriptionRequired
    approvalRequired: false
    state: 'published'
  }
}

resource partnerProduct 'Microsoft.ApiManagement/service/products@2023-12-01' = if (createProducts) {
  parent: apimService
  name: '${apiName}-partner'
  properties: {
    displayName: 'Partner (${displayName})'
    description: 'External partners — subscription approval required'
    subscriptionRequired: subscriptionRequired
    approvalRequired: true
    state: 'published'
  }
}

resource publicProduct 'Microsoft.ApiManagement/service/products@2023-12-01' = if (createProducts) {
  parent: apimService
  name: '${apiName}-public'
  properties: {
    displayName: 'Public (${displayName})'
    description: 'Public consumers — require subscription but auto-approve'
    subscriptionRequired: subscriptionRequired
    approvalRequired: false
    state: 'published'
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

output apiId string = apiDef.id
output apiName string = apiDef.name
output apiPath string = path
