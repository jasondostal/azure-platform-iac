# Platform Setup Runbook

Standing up this Secure Coding Platform in a subscription, **from zero** — start
to finish.

This runbook **assumes nothing exists** (no resource groups, no VNet, no Azure
DevOps org) and is written to double as an **audit checklist**: in an existing
environment, some of these will already be in place, so each step is phrased as
**Check** what's there, then **Create** only what's missing.

Two roles run through it: **🔑 infra** (has subscription/Entra/ADO admin) and
**👩‍💻 devs** (write code and pipelines, no Azure access).

Legend: `□` checklist item · **Check:** audit command · **Create:** run if missing
· ⚠️ a spot where an existing enterprise environment usually differs from greenfield.

---

## Phase 0 — Workstation + accounts

### Tooling (🔑 infra machine)
- □ `az version` — Azure CLI ≥ 2.6x
- □ `az extension add --name azure-devops`
- □ `az bicep version` (`az bicep install` if missing)
- □ `jq`, `git`, `python3`
- □ `pipx install cookiecutter` (devs need this to generate apps)
- □ **Docker NOT required** — the agent image builds with `az acr build` (cloud build)

### Permissions (confirm before running anything)
| Who | Needs | For |
|-----|-------|-----|
| 🔑 infra | Subscription **Owner** OR (**Contributor + User Access Administrator**) | create RGs + role assignments |
| 🔑 infra | Entra **Application Administrator** (or App Developer) | WIF deploy app reg, federated creds, user-auth app regs |
| 🔑 infra | ADO **Project Administrator** (and **Org Owner** to create the org) | repo import, agent pools, service connections, environments |
| 👩‍💻 devs | ADO **Contributor** on the project | push code, create/run pipelines — no Azure access |

Check your own roles: `az role assignment list --assignee <you@domain> --all -o table`

### Decisions to lock in up front
- □ **Naming convention** — this platform uses `rg-<app>-<env>`, `<app>-<resource>-<env>`, `sc-<app>-<env>`, `vg-<app>-<shared|env>`.
- □ **Region(s)** — e.g. `eastus`. Mind compute quota.
- □ **Environments** — dev / qa / stage / prod. Ideally one subscription per environment; minimum is per-env resource groups in one subscription.
- □ **Network model** — greenfield (this runbook creates a VNet) vs. ⚠️ existing hub-spoke (reference an existing VNet + central DNS). Decide before Phase 1.

---

## Phase 1 — Azure foundation

### 1a. Subscription
- **Check:** `az account list -o table` → `az account set --subscription <id>` → `az account show`

### 1b. Resource providers
- **Check:** `az provider list --query "[?registrationState=='NotRegistered'].namespace" -o tsv`
- **Create:**
  ```bash
  for p in Microsoft.Web Microsoft.KeyVault Microsoft.ContainerInstance \
           Microsoft.ContainerRegistry Microsoft.Network Microsoft.ManagedIdentity \
           Microsoft.OperationalInsights Microsoft.Sql; do
    az provider register --namespace "$p"
  done
  ```
- ⚠️ A regulated tenant may restrict provider self-registration — confirm infra can register, or have them pre-registered.

### 1c. Resource groups
- **Check:** `az group list -o table`
- **Create:**
  ```bash
  LOC=eastus; APP=<appname>
  az group create -n rg-${APP}-shared -l $LOC     # ACR, Log Analytics, shared Key Vault
  az group create -n rg-${APP}-dev    -l $LOC     # per-env app resources
  # add rg-${APP}-qa / -stage / -prod as you onboard those environments
  ```

### 1d. Virtual network + subnets
> Needed only for **private endpoints / a self-hosted agent**. For a public app,
> skip the VNet entirely.

- **Check:** `az network vnet list -o table`
- **Create (greenfield):**
  ```bash
  az network vnet create -g rg-${APP}-dev -n ${APP}-vnet-dev \
    --address-prefix 10.30.0.0/16 -l $LOC
  # agent subnet — delegated to ACI, holds nothing else
  az network vnet subnet create -g rg-${APP}-dev --vnet-name ${APP}-vnet-dev \
    -n aci-agents --address-prefixes 10.30.1.0/24 \
    --delegations Microsoft.ContainerInstance/containerGroups
  # private-endpoint subnet — separate, non-delegated, PE network policies off
  az network vnet subnet create -g rg-${APP}-dev --vnet-name ${APP}-vnet-dev \
    -n private-endpoints --address-prefixes 10.30.2.0/24 \
    --disable-private-endpoint-network-policies true
  ```
- ⚠️ In an existing hub-spoke a VNet already exists — **reference it** (pass subnet IDs into the bicep as `existing`), don't create a new one. Request the delegated `aci-agents` subnet + a PE subnet from the network team.

### 1e. Private DNS (only with private endpoints)
- **Check:** `az network private-dns zone list -o table`
- **Create:** one zone **per service type** (`privatelink.azurewebsites.net`, `privatelink.database.windows.net`, `privatelink.vaultcore.azure.net`, …), each **linked to the VNet**. The platform `private-dns-zones` module does this.
- ⚠️ If central private DNS + Azure Policy already auto-registers private endpoints, do **not** also deploy the per-app DNS module (collision). Coordinate with the hub owner.

### 1f. Passwordless SQL prereq (only if using SQL)
- ⚠️ An Entra admin must create a group holding **Directory Readers** and add each SQL server's managed identity to it (Bicep can't assign Entra directory roles). Without it, `CREATE USER ... FROM EXTERNAL PROVIDER` fails.

---

## Phase 2 — Azure DevOps foundation

### 2a. Organization
- **Check:** `az devops project list --organization https://dev.azure.com/<org>` (errors without org/access)
- **Create:** orgs are created in the web UI (`https://dev.azure.com/` → New organization).
- ⚠️ New orgs start with **zero** Microsoft-hosted parallel jobs until a grant request clears (2–3 business days). A self-hosted agent (Phase 4) brings its own free parallel job and unblocks you immediately.

### 2b. Project
- **Check:** `az devops project list --organization https://dev.azure.com/<org> -o table`
- **Create:** `az devops project create --organization https://dev.azure.com/<org> --name <project>`

### 2c. Bring the platform repo into ADO
> Pipelines consume shared templates via `resources.repositories`, so the platform
> repo must live in ADO, not just GitHub.

- **Check:** `az repos list --organization https://dev.azure.com/<org> --project <project> -o table`
- **Create:**
  ```bash
  az devops login   # or: export AZURE_DEVOPS_EXT_PAT=<pat>
  cd azure-platform-iac
  ./bootstrap/sync-platform-to-ado.sh \
    --ado-org https://dev.azure.com/<org> --ado-project <project>
  ```
- Re-sync on platform updates with `--force` (imports are snapshots, not live mirrors).

---

## Phase 3 — Onboard subscription/environment (WIF)

> One command wires all three planes — resource (Bicep), identity (Workload Identity
> Federation, no stored secret), ADO — and auto-authorizes the service connection,
> variable groups, environment, and agent-pool queue for pipelines.

- **Create:**
  ```bash
  ./bootstrap/onboard-subscription.sh \
    --env dev \
    --subscription <sub-id> \
    --ado-org https://dev.azure.com/<org> \
    --ado-project <project> \
    --project <appname> \
    --location <region>          # add --dry-run first to preview
  ```
- **Verify:** `sc-<app>-dev` → `isReady: true`; var groups `vg-<app>-shared` / `vg-<app>-dev` exist; environment `<app>-dev` exists.
- Run once **per environment**.

---

## Phase 4 — Self-hosted agent (per VNet)

> Required only when deploying to private endpoints — a Microsoft-hosted agent runs
> outside your network and cannot reach a private endpoint. A public app deploys
> fine on hosted agents (`vmImage: ubuntu-latest`); skip this whole phase.

- □ **Mint a PAT** scoped **Agent Pools (Read & Manage)**, short expiry — the one
  unavoidable secret (the API can't mint one non-interactively). Store it in Key Vault.
- **Build the agent image into your ACR (cloud build — no Docker):**
  ```bash
  az acr build -r <acr-name> -t ado-agent:latest modules/devops/agent-image
  ```
- **Verify the agent subnet is delegated to ACI:**
  ```bash
  az network vnet subnet show -g <net-rg> --vnet-name <vnet> -n aci-agents \
    --query "delegations[].serviceName" -o tsv   # → Microsoft.ContainerInstance/containerGroups
  ```
- **Deploy the agent:**
  ```bash
  az deployment group create -g <rg> --template-file modules/devops/agent-aci.bicep \
    --parameters name=<app>-agent location=<region> \
      subnetId=<aci-agents subnet resource id> \
      image=<acr>.azurecr.io/ado-agent:latest \
      acrId=<acr resource id> acrLoginServer=<acr>.azurecr.io \
      azpUrl=https://dev.azure.com/<org> azpPool=<pool> \
      azpToken=<PAT> environment=dev
  ```
- **Verify online:** `az pipelines agent list --organization https://dev.azure.com/<org> --pool-id <id>` → online
- Offline? Check the agent's **outbound network** (must reach `dev.azure.com`, `*.visualstudio.com`, the ACR login server, and package feeds) and the **PAT scope** first. ⚠️ On a locked-down subnet, outbound needs a NAT gateway or firewall allowlist.

---

## Phase 5 — Generate an app (no Azure keys)

- **Create:**
  ```bash
  cookiecutter https://github.com/jasondostal/azure-project-starter \
    project_type=dotnet-api project_name=<app> project_slug=<app> \
    ado_org=<org> ado_project=<project> agent_pool=<pool>   # omit agent_pool ⇒ hosted agents
  az repos create --name <app> --org https://dev.azure.com/<org> --project <project>
  cd <app>
  git remote add origin https://dev.azure.com/<org>/<project>/_git/<app>
  git push -u origin main
  ```
- Archetypes: `dotnet-api`, `dotnet-web`, `python-function`, `go-web`, `go-desktop`, `node-agent`.
- □ (APIM apps) `bash scripts/setup-app-registrations.sh` — needs Entra create rights.
- □ (EasyAuth web sign-in) `bash scripts/setup-easyauth.sh`, then set `authClientId` in the env bicepparam.

---

## Phase 6 — Deploy via pipeline

- **Deploy per-env app infra:**
  ```bash
  az deployment sub create --location <region> \
    --template-file infra/main.bicep --parameters infra/params/dev.bicepparam
  ```
- **Create + run the app pipeline:**
  ```bash
  az pipelines create --org https://dev.azure.com/<org> --project <project> --name <app>-ci \
    --repository <app> --repository-type tfsgit --branch main \
    --yml-path pipelines/azure-pipelines.yml
  ```
- □ Build runs on the chosen pool → deploys dev (service connection / environment / queue / variable groups already authorized in Phase 3).
- □ Promote the **same artifact** dev → qa → stage → prod, gated by approvals.

---

## Phase 7 — Governance

- □ **Environment approval checks** per stage (e.g. qa lead → tech lead → prod sign-off).
- □ **Branch policy** on `main`: required reviewers, linked work items, build validation.

---

## Concepts worth internalizing

- Azure PaaS is **public-by-default** — each resource keeps a public endpoint unless you explicitly disable it. Private is a posture you build (private endpoint + private DNS), not the default.
- A private endpoint is useless without its **private DNS zone**, one per service type, linked to the VNet.
- To deploy to private endpoints, the agent must be **inside the VNet** (VNet-injected self-hosted). Microsoft-hosted agents are external and can't reach them. So "private-by-default" and "self-hosted agent" are two halves of one decision.
- Everything authenticates via **Workload Identity Federation** (no stored secrets) except agent registration, which needs a **PAT**.
- Service-connection names in pipeline YAML must be **literal** (e.g. `sc-app-dev`), never `$(var)` — ADO authorizes service connections at compile time.
- A self-hosted agent does not have Microsoft-hosted tooling preinstalled — install runtimes explicitly, and build static binaries where the runtime host differs from the build host.

---

## Diagnostics (when the ADO UI/API is unhelpful)

```bash
# pipeline failure detail — use --api-version 7.1 (NOT -preview); find the failed task's log.id from Timeline
az devops invoke --organization <org> --area build --resource Timeline \
  --route-parameters project=<proj> buildId=<id> --api-version 7.1
az devops invoke --organization <org> --area build --resource logs \
  --route-parameters project=<proj> buildId=<id> logId=<n> --api-version 7.1

# when server logs are unavailable, read the self-hosted agent's own diag logs:
az container exec -g <rg> -n <agent-container> --exec-command "cat /azp/agent/_diag/Worker_<...>.log"
```
