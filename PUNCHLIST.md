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

## ✅ Tail — resolved

| # | Item | Resolution |
|---|------|-----------|
| R1 | ADO platform-repo sync | Added `bootstrap/sync-platform-to-ado.sh` (create+import, `--force` reimport). Long-term options (scheduled mirror / GitHub service-connection repo resource) documented in the script header. |
| R2 | onboard auto-authorization | `onboard-subscription.sh` now grants `allPipelines` authorization to the SC, variable groups, environment, and Default queue it creates — no manual checkpoint on first run. |
| R3 | Container Apps module | `modules/compute/container-app{,-environment}.bicep` added + cataloged (scale-to-zero, passwordless ACR pull, internal/external ingress, optional private VNet). |
| R4 | App Service Plan quota | Documented finding (sub caps at 3 plans/region). No code action; Container Apps (R3) is the quota-free alternative. |
| R5 | onboard `--app-name` consistency | Default already follows `<project>-app-<env>`; onboard now `warn`s if an explicit `--app-name` override breaks the convention. |

## ⏸ Deferred (low priority — reasoned)

- **onboard self-hosted-agent provisioning** — an opt-in `--with-agent` flag to deploy `agent-aci` from onboard. The module exists and is proven; folding it into onboard (subnet/PAT/image plumbing) is its own task. Provision via the module directly for now.
- **R6 gitleaks checksum-pinning** — accepted as-is (curl-pipe-to-tar from the pinned `v8.21.2` GitHub release). Checksum verification is a hardening nice-to-have, not a correctness issue.
