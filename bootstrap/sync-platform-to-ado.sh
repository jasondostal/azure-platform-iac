#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# sync-platform-to-ado.sh — mirror the azure-platform-iac GitHub repo into an
# Azure DevOps project so app pipelines can reference shared templates via
# `resources.repositories`.
#
# WHY THIS EXISTS (punchlist R1):
#   App pipelines in ADO extend shared pipeline templates that live in this
#   repo (azure-platform-iac). ADO's `resources.repositories` can reference a
#   GitHub repo directly IF a GitHub service connection exists, but many shops
#   prefer to keep all pipeline source inside ADO so RBAC, auditing, and
#   branch policies are uniform. This script imports the GitHub repo into ADO.
#
#   IMPORTANT LIMITATION: `az repos import create` is a ONE-SHOT SNAPSHOT. It
#   does NOT keep the ADO repo in sync with GitHub going forward. For a live
#   mirror you have two real options:
#     (a) a scheduled task (CI job, cron, Azure Automation) that runs
#         `git push --mirror` from GitHub → ADO on a recurring basis, OR
#     (b) point `resources.repositories` at GitHub directly using a GitHub
#         service connection (avoids the copy entirely).
#   This script covers the initial import; the real long-term fix is option (a)
#   or (b). See the banner at the end for details.
#
# ── Prerequisites ─────────────────────────────────────────────────────────────
#   az login
#   az extension add --name azure-devops
#   az devops login  (or export AZURE_DEVOPS_EXT_PAT=<pat>)
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#   ./sync-platform-to-ado.sh \
#       --ado-org  https://dev.azure.com/<org> \
#       --ado-project <project> \
#       [--repo-name azure-platform-iac] \
#       [--git-url  https://github.com/jasondostal/azure-platform-iac.git] \
#       [--force]   # delete + reimport if the ADO repo already exists
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO_NAME="azure-platform-iac"
GIT_URL="https://github.com/jasondostal/azure-platform-iac.git"
FORCE=false

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ado-org)     ADO_ORG="$2";     shift 2 ;;
    --ado-project) ADO_PROJECT="$2"; shift 2 ;;
    --repo-name)   REPO_NAME="$2";   shift 2 ;;
    --git-url)     GIT_URL="$2";     shift 2 ;;
    --force)       FORCE=true;       shift ;;
    *) echo "✗ unknown arg: $1" >&2; exit 1 ;;
  esac
done

: "${ADO_ORG:?--ado-org is required (https://dev.azure.com/<org>)}"
: "${ADO_PROJECT:?--ado-project is required}"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m⚠\033[0m %s\n' "$*" >&2; }

need() { command -v "$1" >/dev/null || { echo "✗ missing dependency: $1" >&2; exit 1; }; }
need az

az extension show --name azure-devops >/dev/null 2>&1 || {
  echo "✗ az devops extension not installed: az extension add --name azure-devops" >&2; exit 1; }

# NOTE: every az devops / az repos call passes --organization/--project
# explicitly — we deliberately avoid `az devops configure --defaults` because
# it writes a persistent global config and is a footgun in shared environments.
ADO_ARGS=(--organization "$ADO_ORG")
ADOP_ARGS=(--organization "$ADO_ORG" --project "$ADO_PROJECT")

cat <<BANNER
══════════════════════════════════════════════════════════════════════════════
 Syncing platform repo → ADO
   ADO org/project : ${ADO_ORG} / ${ADO_PROJECT}
   ADO repo name   : ${REPO_NAME}
   source URL      : ${GIT_URL}
   force reimport  : ${FORCE}

 NOTE: this creates a one-time snapshot — not a live mirror. See script
 header for long-term sync options.
══════════════════════════════════════════════════════════════════════════════
BANNER

# ── Check if the ADO repo already exists ──────────────────────────────────────
log "Checking whether '$REPO_NAME' already exists in ADO project '$ADO_PROJECT'"

EXISTING_REPO_ID="$(az repos show "${ADOP_ARGS[@]}" --repository "$REPO_NAME" \
  --query id -o tsv 2>/dev/null || true)"

if [[ -n "$EXISTING_REPO_ID" ]]; then
  if [[ "$FORCE" == "true" ]]; then
    warn "Repo '$REPO_NAME' already exists (id=$EXISTING_REPO_ID). --force specified — deleting and reimporting."
    warn "This is DESTRUCTIVE: all ADO-side commits, branch policies, and PRs in '$REPO_NAME' will be lost."
    az repos delete "${ADOP_ARGS[@]}" --id "$EXISTING_REPO_ID" --yes
    ok "deleted existing repo ($EXISTING_REPO_ID)"
    EXISTING_REPO_ID=""
  else
    warn "Repo '$REPO_NAME' already exists in ADO (id=$EXISTING_REPO_ID)."
    warn ""
    warn "Re-syncing an existing repo is NOT supported by 'az repos import create' —"
    warn "the import API only works on empty repos. Your options:"
    warn ""
    warn "  (a) Re-run with --force to delete the ADO repo and reimport from GitHub."
    warn "      WARNING: this is destructive — any ADO-side history/PRs/policies are lost."
    warn ""
    warn "  (b) Set up a scheduled mirror so GitHub stays the source of truth:"
    warn "      e.g. a GitHub Action or Azure Pipeline that runs:"
    warn "        git clone --mirror <github-url>"
    warn "        git push --mirror <ado-remote-url>"
    warn "      on a cron schedule (daily is usually sufficient for shared templates)."
    warn ""
    warn "  (c) Skip the ADO copy entirely and reference the GitHub repo directly"
    warn "      via a GitHub service connection in your app pipeline's"
    warn "      'resources.repositories' block."
    warn ""
    warn "No changes made. Exiting."
    exit 0
  fi
fi

# ── Create the ADO repo ────────────────────────────────────────────────────────
log "Creating ADO repo '$REPO_NAME'"
REPO_ID="$(az repos create "${ADOP_ARGS[@]}" --name "$REPO_NAME" \
  --query id -o tsv)"
ok "created repo '$REPO_NAME' ($REPO_ID)"

# ── Import from GitHub ────────────────────────────────────────────────────────
log "Importing from $GIT_URL (this may take a minute)"
az repos import create "${ADOP_ARGS[@]}" \
  --repository "$REPO_NAME" \
  --git-source-url "$GIT_URL" \
  --requires-authorization false >/dev/null
ok "import queued — ADO is pulling from GitHub"

# Poll for import completion (ADO import is async).
log "Waiting for import to complete"
SECONDS_WAITED=0
while true; do
  STATUS="$(az repos import show "${ADOP_ARGS[@]}" \
    --repository "$REPO_NAME" \
    --query "importRequestId" -o tsv 2>/dev/null || echo "unknown")"
  # az repos import show exits 0 with content once done; absence of error = done.
  IMPORT_STATUS="$(az repos show "${ADOP_ARGS[@]}" \
    --repository "$REPO_NAME" \
    --query "size" -o tsv 2>/dev/null || echo "0")"
  if [[ "$IMPORT_STATUS" -gt 0 ]]; then
    ok "import complete (repo size: ${IMPORT_STATUS} bytes)"
    break
  fi
  if [[ $SECONDS_WAITED -ge 120 ]]; then
    warn "Import is taking longer than expected. Check ADO UI → Repos → '$REPO_NAME' for status."
    break
  fi
  sleep 5
  SECONDS_WAITED=$((SECONDS_WAITED + 5))
done

cat <<DONE

══════════════════════════════════════════════════════════════════════════════
 ✓ '$REPO_NAME' is now available in ${ADO_ORG}/${ADO_PROJECT}.

 Reference it in app pipelines with:

   resources:
     repositories:
       - repository: platform
         type: git
         name: ${ADO_PROJECT}/${REPO_NAME}
         ref: refs/heads/main

 then use shared templates with:   template: templates/foo.yml@platform

 REMINDER — this is a snapshot, not a live mirror. To keep it current:
   • Scheduled mirror job (recommended):
       git clone --mirror ${GIT_URL}
       git push --mirror <ado-repo-url>
   • OR re-run this script with --force after platform changes land.
   • OR switch to a GitHub service connection + type: github in resources.
══════════════════════════════════════════════════════════════════════════════
DONE
