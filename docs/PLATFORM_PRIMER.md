# The Azure Platform — a narrative primer

This document describes how four repositories cooperate to take a service from
initial idea to running in production — privately, with an audit trail. Read it
once for the model; the `README` in each repo is the day-to-day reference. A
companion diagram is at [`docs/platform-flow.svg`](platform-flow.svg).

---

## 1. The mental model: a cascade

The platform is **four repos**, each with one responsibility, arranged so a
change flows downhill to everything that depends on it:

```
azure-platform-iac      ← the source of truth (modules, pipeline templates, bootstrap)
   │
   ├── azure-iac-patterns      ← a standalone library of à-la-carte modules
   │
   ├── azure-ref-webapp-sql    ← example: a real private-by-default app that CONSUMES the platform
   │
   ├── azure-playground        ← example: a cheap sandbox for fast experiments
   │
   └── azure-project-starter   ← a cookiecutter template that GENERATES new app repos
            │
            └── <your-new-service>   ← what a developer gets
```

The split keeps each pattern in one place. A security scanner added to the
platform's pipeline template reaches every app repo on its next build — no
copy-paste across repos. The reference app exists to verify the modules compose.
The starter exists so the wiring isn't hand-written for each new service.

In short: platform = library; starter = a project generator for a whole service;
reference = the worked example.

---

## 2. The platform repo

`azure-platform-iac` holds three kinds of asset, mapping to the three things
every service needs: *infrastructure*, *a pipeline*, and *a place to run*.

### Modules (`modules/`)

Single-purpose Bicep files — `compute/app-service.bicep`, `data/sql-server.bicep`,
`security/key-vault.bicep`, `networking/vnet.bicep`, `devops/agent-aci.bicep`, and
~20 more. Each one:

- has a `@description` on every parameter,
- ships private-by-default values (`minTlsVersion 1.2`, managed identity over
  connection strings, `disablePublicAccess` available),
- outputs `id`/`name`/endpoints so modules chain — one module's output feeds the
  next module's input.

A module contains no app-specific logic. It is a generic shape; the caller decides
how to wire shapes together.

### Pipeline templates (`pipelines/templates/`)

Reusable Azure DevOps YAML: `build-dotnet.yml`, `build-python.yml`,
`build-go.yml`, `build-node.yml`, `security-gates.yml`, and
`deploy-environment.yml`. An app pipeline references these rather than writing its
own build or scan. A change to `security-gates.yml` here reaches every consumer on
its next run.

### Bootstrap (`bootstrap/`)

One-time-per-subscription onboarding: `bootstrap/main.bicep` (resource plane) plus
`bootstrap/onboard-subscription.sh` (the orchestrator). See §5.

### How app repos consume modules

Three options, increasingly decoupled:

1. **Relative path** (local dev + CI today): the app's `infra/main.bicep` declares
   `module app '../../azure-platform-iac/modules/compute/app-service.bicep'`.
2. **ADO repo resource** (pipeline): the pipeline checks out the platform repo
   alongside the app repo via `resources.repositories`.
3. **Bicep module registry** (future): `br:contosoacr.azurecr.io/bicep/modules/
   app-service:v1.2.0` — versioned, pinned, published artifacts.

Each option is only a difference in how the app *finds* the module; the module is
identical.

---

## 3. The reference app

`azure-ref-webapp-sql` is a working .NET web app whose `infra/main.bicep` is an
orchestrator: it imports the platform modules and wires them into one
private-by-default app — VNet, private endpoints, App Service, SQL (passwordless,
Entra-only), and a self-hosted ADO agent — across four environments. It serves
two purposes: a single real consumer to run `what-if` against before merging a
platform-module change, and a one-file example of how the pieces fit. For cheap,
throwaway experiments with individual services, use `azure-playground` instead.

---

## 4. The starter: cookiecutter + cruft

`azure-project-starter` is a **cookiecutter** template. One command, a few prompts,
and the result is a complete, wired-up service repo.

### Cookiecutter

A cookiecutter template is a directory whose name is a variable —
`{{cookiecutter.project_slug}}/` — containing files with `{{ cookiecutter.* }}`
placeholders. The variables and defaults live in `cookiecutter.json`:

```json
{
  "project_name": "member-portal",
  "project_slug": "MemberPortal",
  "project_type": "dotnet-api",
  "include_sql": true, "include_apim": true, "include_foundry": true,
  "__project_type_choices": ["dotnet-api","dotnet-web","python-function",
                             "go-web","go-desktop","node-agent"]
}
```

`cookiecutter azure-project-starter` clones that directory, substitutes every
`{{ ... }}` (in file contents and file names), and writes the result to a new
folder. Six **archetypes** are supported; each renders the matching source
skeleton, the matching platform build template, and the matching Azure target.

### The post-generation hook

Cookiecutter substitutes text but does not make decisions. That is
`hooks/post_gen_project.py`, which runs once after rendering and does what Jinja
cannot:

1. **Prunes** the archetypes not selected (a `dotnet-api` project does not keep
   the Go and Python skeletons).
2. **Writes `.cruft.json`** — the link back to the template (below).
3. **`git init`** + first commit.

It does not fabricate Azure identifiers: Entra app registration client IDs are
assigned by Azure at creation time, so the starter ships
`scripts/setup-app-registrations.sh` to create them and write the real IDs to a
gitignored `.azure-guids.env`.

### Cruft

A plain cookiecutter run is a one-time copy: the generated repo and the template
diverge after generation. **cruft** addresses this. The `.cruft.json` the hook
wrote records the template URL and the commit it was generated from. When the
starter is later updated, a developer in the generated repo runs:

```
cruft update
```

cruft computes the diff between the template's old commit and its new commit and
applies that diff to the repo as a patch — effectively rebasing the project onto
the latest template. cookiecutter performs the initial generation; cruft applies
later template updates.

---

## 5. Onboarding a subscription: three planes, one script

Standing up a new subscription touches three control planes, each needing a
different tool. Onboarding is therefore a script that *calls* Bicep rather than
Bicep alone:

| Plane | What it creates | Tool | Why not Bicep |
|-------|-----------------|------|---------------|
| **Resource** | RG, ACR, Log Analytics, Key Vault | `bootstrap/main.bicep` | (Bicep fits here) |
| **Identity** | the ADO deploy app registration + RBAC | `az` CLI | Bicep can't create Entra app registrations |
| **ADO** | service connection, variable groups, environment | `az devops` CLI | Not an ARM resource type |

`bootstrap/onboard-subscription.sh` orchestrates all three, idempotently:

```
onboard-subscription.sh --env dev --subscription <id> \
  --ado-org https://dev.azure.com/<org> --ado-project <proj> --project contoso
```

The identity plane uses **Workload Identity Federation (WIF)**: the ADO service
connection federates to the app registration over OIDC, so there is no service-
principal password to store, rotate, or leak. (The earlier approach of minting the
SP inside Bicep was removed — a fresh deploymentScript identity cannot hold the
rights to create a subscription-Contributor SP, so it did not work. The script
does it out of band.)

Run it once per environment/subscription; re-running is safe.

---

## 6. Shipping code: build once, deploy many, one branch

The CI/CD model uses one branch, `main`. A merge triggers one pipeline run that
builds a single immutable artifact and promotes that same artifact through a
linear chain:

```
Build → Scan → dev (auto) → qa (✋) → stage (✋) → prod (✋)
```

Two properties define the model:

- **Build once.** The artifact that passes `dev` is byte-for-byte what reaches
  `prod`; a rebuild per environment can introduce drift, and this design removes
  that possibility.
- **Promotion is gated by approvals, not branches.** Each stage `dependsOn` the
  previous and targets an **ADO Environment** whose checks/approvals are
  configured in the ADO UI (qa lead → tech lead → VP). Promotion history is
  recorded in ADO, which gives two independent audit surfaces: who merged (git)
  and who approved each promotion (ADO).

The reusable `deploy-environment.yml` template emits one approval-gated stage; the
app pipeline chains four of them. Infrastructure promotes the same way, with
`az deployment sub what-if` as the validation step (the real resource diff, not
just a schema check).

---

## 7. Private by default, and self-hosted agents

Setting `enablePrivateEndpoints=true` removes the public endpoints from App
Service, SQL, and Key Vault — they become reachable only from inside the VNet.
This has a direct consequence for deployment:

> Microsoft-hosted pipeline agents run on Microsoft's network, outside your
> tenant. They cannot route to a private endpoint, so deploys to private-endpoint
> resources hang and time out.

A private-by-default estate therefore needs a **self-hosted agent inside the
VNet**. That is `modules/devops/agent-aci.bicep`: the Azure DevOps agent running
on VNet-injected Azure Container Instances. It pulls its image passwordlessly
(user-assigned identity + AcrPull), takes its registration PAT from Key Vault
(agent registration has no WIF path), and sits in the VNet with line-of-sight to
the private endpoints it deploys to. Pipelines point `pool:` at it.

The self-hosted agent is a required component of the private-endpoint posture, not
an optional add-on. It has been verified end to end: a pipeline running on the
in-VNet agent deployed a private container and reached it from inside the VNet,
which a Microsoft-hosted agent could not do.

---

## 8. The full flow

The life of a new service:

1. **Onboard the subscription** (once): `onboard-subscription.sh` lays down the
   resource plane (Bicep), the WIF deploy identity, and the ADO plumbing.
2. **Generate the repo**: `cookiecutter azure-project-starter` → choose an
   archetype → the post-gen hook prunes, writes `.cruft.json`, inits git. The
   result is source + `infra/` (consuming platform modules) + two pipelines.
3. **Push to `main`** and create the pipelines from the YAML.
4. **The pipeline runs once**: it builds the artifact, runs the shared security
   gates, then promotes that one artifact dev → qa → stage → prod, each gated by
   an ADO Environment approval. Infrastructure promotes the same way with
   `what-if`.
5. **Deploys run on the in-VNet self-hosted agent**, so private-endpoint resources
   are reachable.
6. **Later**, `cruft update` pulls template changes into a generated repo, and a
   platform-module change reaches every app on its next run.

The result: one source of truth, generated repos that stay current, repeatable
subscription onboarding with no standing secrets, build-once promotion with an
audit trail, and deploys that work in a locked-down network.
