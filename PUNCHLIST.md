# Platform Punchlist

Corrections and follow-ups surfaced by dogfooding the platform — generating real
apps from the starter and deploying them through ADO pipelines on a self-hosted
agent. Status as of 2026-06-14.

## Status: all 6 archetypes proven end-to-end

Every archetype was generated from `azure-project-starter` and run through its ADO
pipeline (build on the VNet self-hosted ACI agent → deploy via WIF), live-verified:

| Archetype | Result |
|-----------|--------|
| node-agent (SvelteKit) | live — `playground-app-dev` |
| dotnet-api | live — `/Home` returns JSON |
| dotnet-web | live — Razor page renders |
| go-web | live — `/health` returns JSON |
| python-function | live — `/api/health` returns JSON |
| go-desktop | build-only (no Azure target) — cross-compiled binary artifact |

Getting there fixed **~20 platform/starter bugs** (the starter `node-agent` and
several others were non-functional out of the box).

---

## ✅ Done & pushed

**azure-platform-iac**
- `app-service.bicep`: `disablePublicAccess` + `appCommandLine` params
- `onboard-subscription.sh`: registers resource providers; WIF; explicit `--organization` (no global default writes)
- `deploy-environment.yml`: `pool` param (run on self-hosted agents) + `location` param
- `build-node.yml`: preserve `build/` dir for adapter-node
- `build-go.yml`: `CGO_ENABLED=0` static binary for web; create static dir
- `build-python.yml`: apt fallback + venv (self-hosted agent + PEP 668)
- `security-gates.yml`: gitleaks download URL (asset filename has no `v`)
- pipelines: single-branch build-once-deploy-many (approval-gated, no branch gating); infra `what-if`

**azure-project-starter** (node-agent + cross-archetype)
- bicepparam `using '../main.bicep'`; `staging.bicepparam` env `stage`
- node-agent: ship SvelteKit source; add `@sveltejs/adapter-node`; bump vite-plugin-svelte `^5`; post-gen `npm install` for lockfile
- dotnet: fix nested Api/Web prune; `.slnx` conditional (web vs api); `2>NUL`→`2>/dev/null`; `_ViewImports.cshtml`; missing dotnet-web files; `TreatWarningsAsErrors=false` (analyzers as warnings so scaffolds build)
- python-function: v4 decorator `function_app.py` model (drop v1 `function.json`)
- go: prune empty `src/`; `go.mod` chi only for go-web; post-gen `go mod tidy` for go.sum
- pipeline: literal service-connection names (ADO authorizes SCs at compile time); configurable `agent_pool`
- post-gen: prune `src/lib`, `src/app.html`, `src/routes`, `src/pyproject.toml`, `src/function_app.py` per archetype

---

## 📋 Remaining

| # | Item | Notes |
|---|------|-------|
| R1 | **ADO platform-repo sync** | The pipeline reads templates from an *imported* ADO copy of `azure-platform-iac`; imports don't auto-sync, so platform fixes on GitHub must be pushed to the ADO copy too. Decide: scheduled mirror pipeline, GitHub service-connection repo resource, or make ADO the platform home. (Was managed manually this session.) |
| R2 | **onboard self-hosted agent option** | Add an opt-in flag to `onboard-subscription.sh` to provision the `agent-aci` self-hosted agent for a region/env (private-endpoint deploys require it). Also have onboard set `allPipelines` authorization on the SC/env/var-groups it creates (had to do it manually). |
| R3 | **Container Apps module** | `modules/compute/container-app.bicep` — quota-free alternative to App Service (this sub caps at 3 App Service Plans/region). Nice-to-have. |
| R4 | **App Service Plan quota** | The personal sub allows only **3** App Service Plans per region (B1/S1 etc. shared). Fine for the platform; relevant for test sprawl. Container Apps (R3) sidesteps it. |
| R5 | **onboard `--app-name` consistency** | Var-group `devAppName` must equal the App Service the infra creates (`<app>-app-<env>`); default aligns, an override that doesn't match fails the deploy. Document or derive it. |
| R6 | **gitleaks binary integrity** | Consider checksum-pinning the gitleaks download instead of curl-pipe-to-tar. Low priority. |
