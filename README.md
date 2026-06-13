# Azure Platform IAC

Shared Bicep platform modules — the single source of truth for Azure infrastructure patterns. This is the **platform repo**: app repos consume these modules; a change here propagates to all consumers on their next deployment.

## Related Repos

| Repo | Purpose |
|------|---------|
| **azure-platform-iac** (this repo) | Platform modules — generic, reusable Bicep templates |
| [azure-iac-reference](../azure-iac-reference) | Reference app — .NET web app consuming platform modules |
| [azure-iac-patterns](../azure-iac-patterns) | Patterns catalog — standalone service templates (Service Bus, Cosmos, etc.) |
| [azure-project-starter](../azure-project-starter) | Cookiecutter template — one command generates a new project repo with pipeline, IaC, and .NET starter |

## Architecture

```
azure-platform-iac/              ← PLATFORM REPO (this one)
├── modules/
│   ├── compute/                 ← app-service, app-service-plan, function-app
│   ├── data/                    ← sql-server, sql-database, cosmos-db, storage
│   ├── messaging/               ← service-bus, eventgrid-topic
│   ├── networking/              ← vnet, private-dns-zones, private-endpoint
│   ├── security/                ← key-vault
│   ├── integration/             ← api-management, apim-api
│   ├── identity/                ← entra-app-registration, entra-b2c
│   └── ai/                      ← foundry-hub, foundry-project, ai-search
│
├── bootstrap/                   ← subscription onboarding (ACR, Log Analytics, SP)
│
├── pipelines/templates/         ← shared ADO pipeline templates
│   ├── build-dotnet.yml         → .NET build + test + publish
│   ├── build-python.yml         → Python build + test + package
│   ├── build-go.yml             → Go build + cross-compile (web or desktop)
│   ├── build-node.yml           → Node/TS build + test + package
│   ├── security-gates.yml       → gitleaks, trivy, semgrep, NuGet scan
│   └── deploy-environment.yml   → deploy app + infra to one environment
│
azure-iac-reference/             ← APP REPO (web app)
│   infra/main.bicep              → consumes platform modules
│
azure-iac-patterns/              ← PATTERNS CATALOG
│   identity/main.bicep           → standalone multi-auth + APIM pattern
│   foundry/main.bicep            → standalone Foundry AI agent stack
│   networking/main.bicep         → standalone VNet + private DNS
│
azure-project-starter/           ← COOKIECUTTER TEMPLATE
│   cookiecutter.json             → one command = new project repo
```

## Module Catalog

| Module | Category | What it provisions |
|--------|----------|-------------------|
| `compute/app-service-plan` | Compute | App Service Plan (Linux/Windows, all SKUs) |
| `compute/app-service` | Compute | App Service (any runtime, managed identity, VNet integration) |
| `compute/function-app` | Compute | Function App (.NET/Node/Python/Java, serverless or dedicated) |
| `data/sql-server` | Data | SQL Server (logical server, firewall, private endpoints) |
| `data/sql-database` | Data | SQL Database (any SKU, free to hyperscale) |
| `data/cosmos-db` | Data | Cosmos DB account (serverless or provisioned, all consistency levels) |
| `data/storage` | Data | Storage Account v2 (blob/file/table/queue services, soft-delete) |
| `messaging/service-bus` | Messaging | Service Bus namespace (Basic/Standard/Premium) |
| `messaging/eventgrid-topic` | Messaging | Event Grid Custom Topic (CloudEvents or EventGrid schema) |
| `networking/vnet` | Networking | Virtual Network with parameterized subnets |
| `networking/private-dns-zones` | Networking | Private DNS zones + VNet links (all 10 PaaS zones) |
| `networking/private-endpoint` | Networking | Private Endpoint for any PaaS service + optional DNS zone group |
| `security/key-vault` | Security | Key Vault (RBAC authorization, no legacy access policies) |
| `integration/api-management` | Integration | API Management (all tiers, VNet internal mode) |
| `integration/apim-api` | Integration | APIM API definition with multi-auth policies |
| `identity/entra-app-registration` | Identity | Entra ID app registration config contract |
| `identity/entra-b2c` | Identity | Azure AD B2C tenant config contract |
| `ai/foundry-hub` | AI | Foundry Hub + AI Services + model deployments |
| `ai/foundry-project` | AI | Foundry Project (agent scope) |
| `ai/ai-search` | AI | Azure AI Search (RAG vector stores) |
| `ai/foundry-agent-setup` | AI | deploymentScripts for API-only agent creation |

### Bootstrap

`bootstrap/main.bicep` — one-time subscription onboarding. Deploys ACR, Log Analytics, ADO Service Principal, and Key Vault. Makes a fresh subscription platform-ready in one deployment.

### Pipeline Templates

| Template | Purpose |
|----------|--------|
| `pipelines/templates/build-dotnet.yml` | .NET build, test, publish |
| `pipelines/templates/build-python.yml` | Python build, test, package |
| `pipelines/templates/build-go.yml` | Go build with cross-compile (web or desktop) |
| `pipelines/templates/build-node.yml` | Node.js / TypeScript build, test, package |
| `pipelines/templates/security-gates.yml` | Shared scanners — gitleaks, trivy, semgrep, NuGet vuln |
| `pipelines/templates/deploy-environment.yml` | Deploy app + Bicep infra to one environment |

**Add a scanner here → every team gets it on next build.** No repo-by-repo patching.

## Design Rules

1. **Every parameter has `@description`** — self-documenting. No guessing.
2. **Sensible defaults** — `osKind='linux'`, `sku='Standard'`, `minTlsVersion='1.2'`.
3. **`environment` tag on everything** — consistent tagging.
4. **Managed identity over connection strings** — `app-service` and `function-app` default to `SystemAssigned`.
5. **`disablePublicAccess` over `enablePublicEndpoints`** — private-by-default mindset.
6. **Single responsibility** — `storage.bicep` creates the account + service parents. Containers/queues are added by the caller.
7. **Outputs are chainable** — every module outputs `id`, most output `name`, `endpoint`, or `managedIdentityPrincipalId`.

## How App Repos Consume

### Relative path (local dev + CI)
```bicep
module appService '../../azure-platform-iac/modules/compute/app-service.bicep' = {
  name: 'contoso-app-dev'
  params: ...
}
```

### ADO template reference (pipeline)
```yaml
resources:
  repositories:
    - repository: platform
      type: git
      name: azure-platform-iac
      ref: main

stages:
  - stage: Deploy
    jobs:
      - job: DeployInfra
        steps:
          - checkout: self
          - checkout: platform
          # app repo's main.bicep references platform modules via relative path
```

### Module Registry (future)
```bicep
module appService 'br:contosoacr.azurecr.io/bicep/modules/app-service:v1.2.0' = {
  name: 'contoso-app-dev'
  params: ...
}
```

## Versioning

SemVer. Breaking changes = major version bump. App repos pin to a specific git tag. The `ref: main` pattern can be changed to `ref: v1.2.0` for pinning.

## Governance

- **PR required** for every platform module change.
- **Validate all consumers** — run `what-if` against at least one app repo before merge.
- **Backward compatibility** — add params, don't remove. Deprecate with `@description('DEPRECATED: use X instead')`.
- **No app-specific logic** — platform modules are generic templates.
