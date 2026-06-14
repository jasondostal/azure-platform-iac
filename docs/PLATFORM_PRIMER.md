# The Azure Platform — a narrative primer

This is the story of how four repositories cooperate to take a developer from
*"I have an idea for a service"* to *"it's running in production, privately, with
an audit trail"* — with as little ceremony as possible. Read it top to bottom
once; after that the `README`s in each repo are the reference.

There's a companion picture: [`docs/platform-flow.svg`](platform-flow.svg). The
words here; the shapes there.

---

## 1. The mental model: a cascade, not a monolith

The platform is **four repos**, each with one job, arranged so a change flows
*downhill* to everything that depends on it:

```
azure-platform-iac      ← the source of truth (modules, pipeline templates, bootstrap)
   │
   ├── azure-iac-reference     ← a real app that CONSUMES the platform (the proof)
   │
   └── azure-project-starter   ← a cookiecutter template that GENERATES new app repos
            │
            └── <your-new-service>   ← what a developer actually gets
```

The reason it's split this way is the whole point: **the platform repo is the
single place a pattern lives.** Add a security scanner to the platform's pipeline
template, and every app repo picks it up on its next build — no copy-paste, no
"go update 40 repos." The reference app exists to *prove* the modules compose.
The starter exists so nobody hand-writes that wiring ever again.

Think of it as: **platform = library, starter = `npm init` for a whole service,
reference = the worked example in the docs.**

---

## 2. The platform repo — where patterns live

`azure-platform-iac` has three kinds of asset, and they map to the three things
every service needs: *infrastructure*, *a pipeline*, and *a place to run*.

### Modules (`modules/`)

Small, single-purpose Bicep files — `compute/app-service.bicep`,
`data/sql-server.bicep`, `security/key-vault.bicep`, `networking/vnet.bicep`,
`devops/agent-aci.bicep`, and ~20 more. Each one:

- has a `@description` on **every** parameter (self-documenting, no guessing),
- ships sensible private-by-default defaults (`minTlsVersion 1.2`, managed
  identity over connection strings, `disablePublicAccess` available),
- outputs `id`/`name`/endpoints so modules **chain** — one module's output is the
  next one's input.

A module never contains app-specific logic. It's a generic shape; the *caller*
decides how to wire shapes together.

### Pipeline templates (`pipelines/templates/`)

Reusable Azure DevOps YAML: `build-dotnet.yml`, `build-python.yml`,
`build-go.yml`, `build-node.yml`, `security-gates.yml`, and
`deploy-environment.yml`. An app pipeline doesn't *write* a build or a scan — it
**references** these. Change `security-gates.yml` here → every consumer gets the
new scanner on its next run. That sentence is the entire business case for the
platform.

### Bootstrap (`bootstrap/`)

The one-time-per-subscription onboarding: `bootstrap/main.bicep` (resource plane)
plus `bootstrap/onboard-subscription.sh` (the orchestrator). More on this in §5.

### How app repos consume modules

Three options, increasingly decoupled:

1. **Relative path** (local dev + CI today): the app's `infra/main.bicep` says
   `module app '../../azure-platform-iac/modules/compute/app-service.bicep'`.
2. **ADO repo resource** (pipeline): the pipeline checks out the platform repo
   alongside the app repo via a `resources.repositories` reference.
3. **Bicep module registry** (future): `br:contosoacr.azurecr.io/bicep/modules/
   app-service:v1.2.0` — versioned, pinned, published artifacts.

All three are just "how does the app *find* the module." The module is identical.

---

## 3. The reference app — proof the modules compose

`azure-iac-reference` is a working .NET web app whose `infra/main.bicep` is an
*orchestrator*: it imports a dozen platform modules and wires them into one
opinionated app — VNet, private endpoints, App Service, SQL (passwordless, Entra-
only), Key Vault, APIM with multi-auth, Foundry AI. It exists so that:

- when you change a platform module, you have **one real consumer** to run
  `what-if` against before you merge, and
- a new engineer can read *one file* and see how the pieces fit.

It is the canary and the worked example, in one.

---

## 4. The starter — generating a new repo with cookiecutter + cruft

This is where "lazy enterprise dev" gets its payoff. `azure-project-starter` is a
**cookiecutter** template. You run one command, answer a few prompts, and get a
complete, wired-up service repo.

### Cookiecutter, concretely

A cookiecutter template is a directory whose name is a variable —
`{{cookiecutter.project_slug}}/` — full of files containing `{{ cookiecutter.* }}`
placeholders. The variables and their defaults live in `cookiecutter.json`:

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

Running `cookiecutter azure-project-starter` clones that directory, substitutes
every `{{ ... }}` (in file *contents* and file *names*), and drops the result in
a new folder. Six **archetypes** are supported; each renders the right source
skeleton, the right platform build template (`build-dotnet`/`python`/`go`/`node`),
and the right Azure target.

### The post-generation hook

Cookiecutter can substitute text but can't make *decisions*. That's
`hooks/post_gen_project.py`, which runs once after rendering and does the things
Jinja can't:

1. **Prunes** the archetypes you didn't pick (a `dotnet-api` project doesn't keep
   the Go and Python skeletons).
2. **Writes `.cruft.json`** — the link back to the template (see below).
3. **`git init`** + first commit, so the new repo has clean history from line one.

It also can't (and deliberately doesn't) fabricate Azure identifiers: Entra app
registration client IDs are assigned *by Azure at creation time*, so the starter
ships `scripts/setup-app-registrations.sh` to create them for real and write the
true IDs to a gitignored `.azure-guids.env` — never a made-up GUID in source.

### Cruft — keeping generated repos in sync with the template

Here's the part most "generate a repo" setups miss. A plain cookiecutter run is a
*one-time copy* — the moment you generate, the new repo and the template diverge
forever. **cruft** fixes that. The `.cruft.json` the hook wrote records the
template URL and the exact commit it was generated from. Later, when the platform
team improves the starter (new gate, better defaults), a developer in their
generated repo runs:

```
cruft update
```

and cruft computes the diff between the template's old commit and its new commit,
and applies *that diff* to their repo as a patch — like a rebase of your project
onto the latest template. So the starter isn't just a birth event; it's a living
upstream the whole fleet can pull from. **cookiecutter creates; cruft keeps
current.**

---

## 5. Onboarding a subscription — three planes, one script

Standing up a *new subscription* (you'll do this repeatedly) touches three
different control planes, and they need three different tools. That mismatch is
exactly why onboarding is a script that *calls* Bicep rather than Bicep alone:

| Plane | What it creates | Tool | Why not Bicep |
|-------|-----------------|------|---------------|
| **Resource** | RG, ACR, Log Analytics, Key Vault | `bootstrap/main.bicep` | (Bicep is perfect here) |
| **Identity** | the ADO deploy app registration + RBAC | `az` CLI | Bicep can't create Entra app registrations |
| **ADO** | service connection, variable groups, environment | `az devops` CLI | Not an ARM resource type at all |

`bootstrap/onboard-subscription.sh` orchestrates all three, idempotently:

```
onboard-subscription.sh --env dev --subscription <id> \
  --ado-org https://dev.azure.com/<org> --ado-project <proj> --project contoso
```

The identity plane uses **Workload Identity Federation (WIF)**, not a stored
secret: the ADO service connection federates to the app registration over OIDC.
There is no SP password to rotate, store, or leak — for a regulated shop, "zero
standing secrets for deploy identities" is the audit story you want. (The old
attempt to mint the SP *inside* Bicep was removed — a fresh deploymentScript
identity can't hold the rights to create a subscription-Contributor SP, so it
never worked. The script does it correctly, out of band.)

Run it once per environment/subscription. Re-running is safe.

---

## 6. Shipping code — build once, deploy many, one branch

The CI/CD model is deliberately **not** branch-per-environment. There is one
branch, `main`. A merge triggers **one** pipeline run that builds a **single
immutable artifact** and promotes *that exact artifact* through a linear chain:

```
Build → Scan → dev (auto) → qa (✋) → stage (✋) → prod (✋)
```

Two ideas do the heavy lifting:

- **Build once.** The zip/image that passes `dev` is byte-for-byte what reaches
  `prod`. A rebuild-per-environment can silently introduce drift; this design
  makes that impossible.
- **Promotion is gated by approvals, not branches.** Each stage `dependsOn` the
  previous and targets an **ADO Environment** whose checks/approvals live in the
  ADO UI (qa lead → tech lead → VP). Promotion history ("who approved prod, when")
  becomes a first-class audit record, and you get *two* independent audit
  surfaces: who merged (git) and who approved each promotion (ADO).

The reusable `deploy-environment.yml` template emits one approval-gated stage; the
app pipeline strings four of them together. Infra promotes the same way, but its
"validate" step is `az deployment sub what-if` — the real resource diff, not just
a schema check.

---

## 7. Private by default → self-hosted agents (the part everyone forgets)

When you set `enablePrivateEndpoints=true`, your App Service, SQL, and Key Vault
lose their public endpoints — reachable **only** from inside the VNet. This is the
posture a credit union wants. But it has a consequence that bites people in week
three:

> **Microsoft-hosted pipeline agents run on Microsoft's network, outside your
> tenant. They physically cannot route to a private endpoint. Deploys hang and
> time out.**

So a private-by-default estate *requires* a **self-hosted agent that lives inside
the VNet**. That's `modules/devops/agent-aci.bicep`: the Azure DevOps agent
running on VNet-injected Azure Container Instances. It pulls its image
passwordlessly (user-assigned identity + AcrPull), takes its registration PAT from
Key Vault (agent registration is the one thing with no WIF path), and sits in the
VNet with line-of-sight to the private endpoints it deploys to. Pipelines just
point `pool:` at it.

This isn't an add-on; it's the other half of the private-endpoint story. The
platform shipping private endpoints *without* an agent story was a gap — now
closed, and proven end to end (a pipeline on the in-VNet agent deploying a private
container and curling it, which a hosted agent could never reach).

---

## 8. The whole flow, as one walk

Putting it together, here's the life of a new service:

1. **Onboard the subscription** (once): `onboard-subscription.sh` lays down the
   resource plane (Bicep), the WIF deploy identity, and the ADO plumbing.
2. **Generate the repo**: `cookiecutter azure-project-starter` → pick an
   archetype → the post-gen hook prunes, writes `.cruft.json`, inits git. You now
   have source + `infra/` (consuming platform modules) + two pipelines.
3. **Push to `main`** and create the pipelines from the YAML.
4. **The pipeline runs once**: builds the artifact, runs the shared security
   gates, then promotes that one artifact dev → qa → stage → prod, each gated by
   an ADO Environment approval. Infra promotes the same way with `what-if`.
5. **Deploys land via the in-VNet self-hosted agent**, so private-endpoint
   resources are reachable.
6. **Later**, when the platform improves, `cruft update` pulls template changes
   into the repo, and a platform-module change reaches every app on its next run.

One source of truth, generated repos that stay current, repeatable subscription
onboarding with no standing secrets, build-once promotion with a real audit
trail, and deploys that work in a locked-down network. That's the platform.
