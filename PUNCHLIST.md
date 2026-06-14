# Platform Punchlist

Running list of corrections and follow-ups, mostly surfaced by dogfooding the
platform to build the `playground` app (a real SvelteKit `node-agent` service
deployed through ADO on a self-hosted agent). Status as of 2026-06-14.

Legend: ✅ done & pushed · ⚠️ fixed in playground only (needs backport) · 📋 open

---

## ✅ Fixed & pushed (azure-platform-iac)

| Item | Where |
|------|-------|
| `app-service.bicep`: add `disablePublicAccess` (private-by-default) | `modules/compute/app-service.bicep` |
| `onboard-subscription.sh`: register resource providers on fresh subs (Compute/Web/Sql/…) — avoids "0 quota / SkuNotAvailable" | `bootstrap/onboard-subscription.sh` |
| `deploy-environment.yml`: add `pool` param so deploys can run on a self-hosted agent (templates hardcoded MS-hosted, contradicting the private-endpoint posture) | `pipelines/templates/deploy-environment.yml` |
| `build-node.yml`: preserve the `build/` directory in the artifact (adapter-node `server.js` imports `./build/handler.js`; flattening broke it) | `pipelines/templates/build-node.yml` |
| `azure-project-starter`: prune stray `src/pyproject.toml` for non-python archetypes | `hooks/post_gen_project.py` |

## 🔴 Critical — in progress

| Item | Detail |
|------|--------|
| **gitleaks download URL is wrong** | `security-gates.yml` builds `gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz` with `GITLEAKS_VERSION=v8.21.2`, but the release **asset** filename has no `v` (`gitleaks_8.21.2_...`). The tag has the `v`, the filename doesn't. → 404 → no binary → the **HARD gate fails on every run**. Fix: strip the `v` for the filename. Affects **every consumer**. |
| **Imported ADO platform repo is a snapshot, not a mirror** | The pipeline consumes templates from an *ADO* repo `azure-platform-iac` (created via `az repos import` from GitHub). Imports don't auto-sync — platform fixes pushed to GitHub do NOT reach pipelines until the ADO copy is updated. Need a sync strategy (scheduled mirror pipeline, or make ADO the platform home, or a GitHub service-connection repo resource). |

## ⚠️ Fixed in playground only — backport to azure-project-starter

The `node-agent` archetype was essentially non-functional out of the box; every
one of these was a blocker for a generated repo:

| # | Bug (node-agent unless noted) | Fix |
|---|------|-----|
| 1 | `infra/params/*.bicepparam` say `using 'main.bicep'` but sit in `infra/params/` → deploy fails. **Cross-archetype.** | `using '../main.bicep'` |
| 2 | ships **no SvelteKit source** (`app.html`, `src/routes/+page.svelte`) → nothing to build | ship a minimal skeleton (mark `_copy_without_render` to avoid Jinja/Svelte brace clashes) |
| 3 | `@sveltejs/adapter-node` **missing** from `package.json` (config imports it) | add to devDeps |
| 4 | `@sveltejs/vite-plugin-svelte ^4` incompatible with `vite ^6` → npm ERESOLVE | bump to `^5` |
| 5 | no `package-lock.json` (and `.gitignore` ignores it) → `npm ci` fails in CI | commit the lock; post-gen `npm install` to generate it; stop ignoring it |
| 6 | service connection referenced via **runtime var** `$(devServiceConnection)` → ADO can't authorize a service connection at compile time | generate **literal** SC names (`sc-{{project}}-{{env}}`) |
| 7 | generated pipeline Build job pool hardcoded `vmImage: ubuntu-latest` → can't run self-hosted | make pool configurable (cookiecutter var, default MS-hosted) |

## 📋 Open

| # | Item |
|---|------|
| 8 | **Test the other archetypes end-to-end** — only `node-agent` has been run through generation → pipeline → deploy. Validate `dotnet-api`, `dotnet-web`, `python-function`, `go-web`, `go-desktop` the same way (each almost certainly has analogous gaps). |
| 9 | `app-service.bicep` doesn't set the **startup command** (`node server.js`) — set manually via `az` for the playground. Add an `appCommandLine` param so it's IaC. |
| 10 | **Self-hosted agent onboarding** — add an optional "provision a self-hosted agent for this region/env?" prompt/flag to `onboard-subscription.sh`, since private-endpoint deploys require one. |
| 11 | **Container Apps module** (`modules/compute/container-app.bicep`) — quota-free alternative to App Service; nice-to-have. |
| 12 | `build-node.yml` end-to-end verification — confirm the deployed artifact actually runs on App Service (closes the loop once the playground deploy is green). |
| 13 | Consider whether `gitleaks` should pin/verify the binary (checksum) rather than curl-pipe-to-tar. |
| 14 | **App name consistency**: the var-group `devAppName` (set by `onboard --app-name`) MUST equal the App Service the infra creates (`<appName>-app-<env>`). The onboard default aligns; an `--app-name` override that doesn't match the infra convention fails the deploy with "Resource doesn't exist." Document, and/or have onboard derive it from the same convention rather than accept a free-form override. |
