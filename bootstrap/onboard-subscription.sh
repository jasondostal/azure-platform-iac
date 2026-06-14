#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# onboard-subscription.sh — stand up a fresh Azure subscription for the platform,
# end to end, in ONE command. Idempotent: safe to re-run.
#
# It wires all THREE planes that a new subscription needs (Bicep only does the
# first; the other two are why this script exists):
#
#   1. RESOURCE plane  → bootstrap/main.bicep (RG, ACR, Log Analytics, Key Vault)
#   2. IDENTITY plane  → an Entra app + Workload Identity Federation (NO secret),
#                        with Contributor + User Access Administrator on the sub
#   3. ADO plane       → service connection (WIF), variable groups, environment
#
# Why WIF and not `az ad sp create-for-rbac --years 2`? There is NO secret to
# store, rotate, or leak. The ADO service connection federates to the app reg
# via OIDC. For a regulated shop, "zero standing secrets for deploy identities"
# is the audit story you want.
#
# ONE RUN = ONE SUBSCRIPTION = ONE ENVIRONMENT. Run it once per env you stand up
# (each env is typically its own subscription). The shared variable group is
# created on first run and updated on later ones.
#
# ── Prerequisites ─────────────────────────────────────────────────────────────
#   az login                       (a user/identity that can: create RGs +
#                                    role assignments on the sub, and create
#                                    Entra app registrations)
#   az extension add --name azure-devops
#   az devops login                (or export AZURE_DEVOPS_EXT_PAT=<pat>)
#   jq installed
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#   ./onboard-subscription.sh \
#       --env dev \
#       --subscription <subscription-id> \
#       --ado-org https://dev.azure.com/<org> \
#       --ado-project <project> \
#       --project contoso \
#       [--location eastus] \
#       [--app-name contoso-app-dev] \
#       [--dry-run]
#
#   --project   logical platform/app name → names everything (vg-<project>-*,
#               sc-<project>-<env>, the app reg, the ADO environment).
#   --app-name  the App Service name this env deploys to (stored in the env's
#               variable group as <env>AppName). Defaults to <project>-app-<env>.
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
LOCATION="eastus"
DRY_RUN=false
APP_NAME=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)          ENVIRONMENT="$2"; shift 2 ;;
    --subscription) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --ado-org)      ADO_ORG="$2"; shift 2 ;;
    --ado-project)  ADO_PROJECT="$2"; shift 2 ;;
    --project)      PROJECT="$2"; shift 2 ;;
    --location)     LOCATION="$2"; shift 2 ;;
    --app-name)     APP_NAME="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    *) echo "✗ unknown arg: $1" >&2; exit 1 ;;
  esac
done

: "${ENVIRONMENT:?--env is required (dev|qa|stage|prod)}"
: "${SUBSCRIPTION_ID:?--subscription is required}"
: "${ADO_ORG:?--ado-org is required (https://dev.azure.com/<org>)}"
: "${ADO_PROJECT:?--ado-project is required}"
: "${PROJECT:?--project is required}"
APP_NAME="${APP_NAME:-${PROJECT}-app-${ENVIRONMENT}}"

APP_REG_NAME="${PROJECT}-ado-${ENVIRONMENT}"
SERVICE_CONNECTION="sc-${PROJECT}-${ENVIRONMENT}"
VG_SHARED="vg-${PROJECT}-shared"
VG_ENV="vg-${PROJECT}-${ENVIRONMENT}"
ADO_ENVIRONMENT="${PROJECT}-${ENVIRONMENT}"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m⚠\033[0m %s\n' "$*" >&2; }
run()  { if $DRY_RUN; then printf '  [dry-run] %s\n' "$*"; else eval "$*"; fi; }

need() { command -v "$1" >/dev/null || { echo "✗ missing dependency: $1" >&2; exit 1; }; }
need az; need jq

az extension show --name azure-devops >/dev/null 2>&1 || {
  echo "✗ az devops extension not installed: az extension add --name azure-devops" >&2; exit 1; }

# NOTE: we deliberately do NOT run `az devops configure --defaults`. That writes
# a GLOBAL org/project into ~/.azure/azuredevops/config and leaves it behind
# after the script exits — a footgun (especially if the org isn't yours). Every
# az devops / az pipelines call below passes --organization/--project explicitly
# instead, so this script never mutates your machine's persistent CLI defaults.
ADO_ARGS=(--organization "$ADO_ORG")
ADOP_ARGS=(--organization "$ADO_ORG" --project "$ADO_PROJECT")

cat <<BANNER
══════════════════════════════════════════════════════════════════════════════
 Onboarding subscription
   env            : ${ENVIRONMENT}
   subscription   : ${SUBSCRIPTION_ID}
   location       : ${LOCATION}
   project        : ${PROJECT}
   ADO org/project: ${ADO_ORG} / ${ADO_PROJECT}
   app reg        : ${APP_REG_NAME}   (WIF — no secret)
   service conn   : ${SERVICE_CONNECTION}
   variable groups: ${VG_SHARED}, ${VG_ENV}
   ADO env        : ${ADO_ENVIRONMENT}
   dry-run        : ${DRY_RUN}
══════════════════════════════════════════════════════════════════════════════
BANNER

az account set --subscription "$SUBSCRIPTION_ID"
TENANT_ID="$(az account show --query tenantId -o tsv)"

# ══════════════════════════════════════════════════════════════════════════════
# PLANE 1 — RESOURCE: register providers, then deploy the Bicep bootstrap
# ══════════════════════════════════════════════════════════════════════════════
log "Plane 1/3 — Resource: registering providers + deploying bootstrap/main.bicep"

# Fresh subscriptions often have resource providers UNregistered. That surfaces
# later as confusing failures — e.g. App Service workers need Microsoft.Compute
# registered, and without it quota reads as 0 ("SubscriptionIsOverQuotaForSku,
# Total VMs: 0"). Register the whole platform surface up front. Registration is
# async + idempotent; we kick it off and continue (it finishes in the background
# well before any app deploys).
PROVIDERS=(Microsoft.Compute Microsoft.Web Microsoft.Network Microsoft.KeyVault
  Microsoft.Storage Microsoft.ContainerInstance Microsoft.ContainerRegistry
  Microsoft.OperationalInsights Microsoft.Insights Microsoft.ManagedIdentity
  Microsoft.Sql Microsoft.ServiceBus Microsoft.EventGrid Microsoft.DocumentDB
  Microsoft.CognitiveServices Microsoft.Search Microsoft.ApiManagement)
for ns in "${PROVIDERS[@]}"; do
  if $DRY_RUN; then
    run "az provider register --namespace $ns"
  else
    state="$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || echo Unknown)"
    if [[ "$state" != "Registered" ]]; then
      az provider register --namespace "$ns" >/dev/null 2>&1 && ok "registering $ns" || warn "could not register $ns"
    fi
  fi
done

DEPLOY_NAME="bootstrap-${ENVIRONMENT}-$(date +%Y%m%d%H%M%S)"
if $DRY_RUN; then
  run "az deployment sub what-if --name '$DEPLOY_NAME' --location '$LOCATION' \
        --template-file '$SCRIPT_DIR/main.bicep' \
        --parameters environment='$ENVIRONMENT' location='$LOCATION' tenantId='$TENANT_ID' platformName='$PROJECT'"
  KV_NAME="<dry-run-kv>"; ACR_LOGIN="<dry-run-acr>"
else
  OUTPUTS="$(az deployment sub create --name "$DEPLOY_NAME" --location "$LOCATION" \
    --template-file "$SCRIPT_DIR/main.bicep" \
    --parameters environment="$ENVIRONMENT" location="$LOCATION" tenantId="$TENANT_ID" platformName="$PROJECT" \
    --query properties.outputs -o json)"
  KV_NAME="$(echo "$OUTPUTS"   | jq -r '.keyVaultName.value')"
  ACR_LOGIN="$(echo "$OUTPUTS" | jq -r '.acrLoginServer.value')"
  ok "resource plane deployed (KeyVault=$KV_NAME, ACR=$ACR_LOGIN)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PLANE 2 — IDENTITY: app registration + WIF (no secret) + RBAC
# ══════════════════════════════════════════════════════════════════════════════
log "Plane 2/3 — Identity: app registration + Workload Identity Federation"

APP_ID="$(az ad app list --display-name "$APP_REG_NAME" --query '[0].appId' -o tsv 2>/dev/null || true)"
if [[ -z "$APP_ID" ]]; then
  if $DRY_RUN; then APP_ID="<dry-run-appid>"; run "az ad app create --display-name '$APP_REG_NAME' --sign-in-audience AzureADMyOrg"
  else APP_ID="$(az ad app create --display-name "$APP_REG_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)"; fi
  ok "created app registration ($APP_ID)"
else
  ok "app registration exists ($APP_ID)"
fi

# Service principal for the app (idempotent).
SP_OID="$(az ad sp list --filter "appId eq '$APP_ID'" --query '[0].id' -o tsv 2>/dev/null || true)"
if [[ -z "$SP_OID" && "$APP_ID" != "<dry-run-appid>" ]]; then
  SP_OID="$(az ad sp create --id "$APP_ID" --query id -o tsv)"
  ok "created service principal ($SP_OID)"
else
  ok "service principal present"
fi

# RBAC: Contributor (deploy resources) + User Access Administrator (so app
# deployments can create their own role assignments — Foundry/Cosmos data-plane
# RBAC, etc.). Both scoped to THIS subscription only. Idempotent.
SUB_SCOPE="/subscriptions/${SUBSCRIPTION_ID}"
for ROLE in "Contributor" "User Access Administrator"; do
  if $DRY_RUN; then
    run "az role assignment create --assignee '$APP_ID' --role '$ROLE' --scope '$SUB_SCOPE'"
  else
    az role assignment create --assignee "$APP_ID" --role "$ROLE" --scope "$SUB_SCOPE" \
      --only-show-errors >/dev/null 2>&1 || true
    ok "role ensured: $ROLE @ subscription"
  fi
done

# ══════════════════════════════════════════════════════════════════════════════
# PLANE 3 — ADO: service connection (WIF), federated credential, var groups, env
# ══════════════════════════════════════════════════════════════════════════════
log "Plane 3/3 — Azure DevOps: service connection + variable groups + environment"

ADO_PROJECT_ID="$(az devops project show "${ADO_ARGS[@]}" --project "$ADO_PROJECT" --query id -o tsv)"

# ── 3a. Service connection (Workload Identity Federation, manual) ─────────────
EP_ID="$(az devops service-endpoint list "${ADOP_ARGS[@]}" --query "[?name=='$SERVICE_CONNECTION'].id | [0]" -o tsv 2>/dev/null || true)"
if [[ -z "$EP_ID" ]]; then
  EP_CONFIG="$(mktemp)"
  cat > "$EP_CONFIG" <<JSON
{
  "name": "${SERVICE_CONNECTION}",
  "type": "azurerm",
  "url": "https://management.azure.com/",
  "authorization": {
    "scheme": "WorkloadIdentityFederation",
    "parameters": { "tenantid": "${TENANT_ID}", "serviceprincipalid": "${APP_ID}" }
  },
  "data": {
    "subscriptionId": "${SUBSCRIPTION_ID}",
    "subscriptionName": "${ENVIRONMENT}",
    "environment": "AzureCloud",
    "scopeLevel": "Subscription",
    "creationMode": "Manual"
  },
  "serviceEndpointProjectReferences": [
    { "projectReference": { "id": "${ADO_PROJECT_ID}", "name": "${ADO_PROJECT}" },
      "name": "${SERVICE_CONNECTION}" }
  ]
}
JSON
  if $DRY_RUN; then
    run "az devops service-endpoint create --organization '$ADO_ORG' --project '$ADO_PROJECT' --service-endpoint-configuration '$EP_CONFIG'"
    EP_ID="<dry-run-ep>"
  else
    EP_ID="$(az devops service-endpoint create "${ADOP_ARGS[@]}" --service-endpoint-configuration "$EP_CONFIG" --query id -o tsv)"
    ok "created service connection ($EP_ID)"
  fi
  rm -f "$EP_CONFIG"
else
  ok "service connection exists ($EP_ID)"
fi

# ── 3b. Federated credential — bind the app reg to the ADO service connection ─
# ADO reports the exact issuer + subject for the endpoint; use those verbatim.
if ! $DRY_RUN && [[ "$EP_ID" != "<dry-run-ep>" ]]; then
  EP_JSON="$(az devops service-endpoint show "${ADOP_ARGS[@]}" --id "$EP_ID" -o json)"
  ISSUER="$(echo "$EP_JSON"  | jq -r '.authorization.parameters.workloadIdentityFederationIssuer // empty')"
  SUBJECT="$(echo "$EP_JSON" | jq -r '.authorization.parameters.workloadIdentityFederationSubject // empty')"
  # Fallback to the deterministic ADO form if the API didn't echo them back.
  ORG_SHORT="$(basename "$ADO_ORG")"
  SUBJECT="${SUBJECT:-sc://${ORG_SHORT}/${ADO_PROJECT}/${SERVICE_CONNECTION}}"
  if [[ -z "$ISSUER" ]]; then
    ORG_ID="$(az devops invoke "${ADO_ARGS[@]}" --area core --resource connectionData \
      --route-parameters "" --query 'instanceId' -o tsv 2>/dev/null || true)"
    [[ -n "$ORG_ID" ]] && ISSUER="https://vstoken.dev.azure.com/${ORG_ID}"
  fi
  if [[ -n "$ISSUER" && -n "$SUBJECT" ]]; then
    APP_OBJ_ID="$(az ad app show --id "$APP_ID" --query id -o tsv)"
    FC_NAME="ado-${SERVICE_CONNECTION}"
    EXISTS="$(az ad app federated-credential list --id "$APP_OBJ_ID" \
      --query "[?name=='$FC_NAME'].name | [0]" -o tsv 2>/dev/null || true)"
    if [[ -z "$EXISTS" ]]; then
      az ad app federated-credential create --id "$APP_OBJ_ID" --parameters "$(cat <<JSON
{ "name": "${FC_NAME}", "issuer": "${ISSUER}", "subject": "${SUBJECT}",
  "audiences": ["api://AzureADTokenExchange"] }
JSON
)" >/dev/null
      ok "created federated credential ($FC_NAME)"
    else
      ok "federated credential exists ($FC_NAME)"
    fi
  else
    warn "could not resolve WIF issuer/subject — finish the service connection in the ADO UI (Verify)."
  fi
else
  ok "[dry-run] would create federated credential binding $APP_REG_NAME ↔ $SERVICE_CONNECTION"
fi

# ── 3c. Variable groups ──────────────────────────────────────────────────────
upsert_varset() {  # upsert_varset <group-name> KEY=VAL [KEY=VAL ...]
  local group="$1"; shift
  local gid
  gid="$(az pipelines variable-group list "${ADOP_ARGS[@]}" --query "[?name=='$group'].id | [0]" -o tsv 2>/dev/null || true)"
  if [[ -z "$gid" ]]; then
    if $DRY_RUN; then run "az pipelines variable-group create --organization '$ADO_ORG' --project '$ADO_PROJECT' --name '$group' --variables $*"; return; fi
    gid="$(az pipelines variable-group create "${ADOP_ARGS[@]}" --name "$group" --variables "$@" --query id -o tsv)"
    ok "created variable group $group ($gid)"
  else
    for kv in "$@"; do
      local k="${kv%%=*}" v="${kv#*=}"
      if $DRY_RUN; then run "az pipelines variable-group variable update --organization '$ADO_ORG' --project '$ADO_PROJECT' --group-id '$gid' --name '$k' --value '$v'"; continue; fi
      az pipelines variable-group variable update "${ADOP_ARGS[@]}" --group-id "$gid" --name "$k" --value "$v" >/dev/null 2>&1 \
        || az pipelines variable-group variable create "${ADOP_ARGS[@]}" --group-id "$gid" --name "$k" --value "$v" >/dev/null
    done
    ok "updated variable group $group ($gid)"
  fi
}

upsert_varset "$VG_SHARED" "tenantId=$TENANT_ID"
upsert_varset "$VG_ENV" \
  "${ENVIRONMENT}ServiceConnection=$SERVICE_CONNECTION" \
  "${ENVIRONMENT}AppName=$APP_NAME" \
  "keyVaultName=$KV_NAME" \
  "acrLoginServer=$ACR_LOGIN"

# ── 3d. ADO Environment (approval checks are configured in the UI) ────────────
ENV_EXISTS="$(az devops invoke "${ADO_ARGS[@]}" --area distributedtask --resource environments \
  --route-parameters project="$ADO_PROJECT" --api-version 7.1-preview \
  --query "value[?name=='$ADO_ENVIRONMENT'].name | [0]" -o tsv 2>/dev/null || true)"
if [[ -z "$ENV_EXISTS" ]]; then
  if $DRY_RUN; then
    ok "[dry-run] would create ADO environment $ADO_ENVIRONMENT"
  else
    ENV_BODY="$(mktemp)"; echo "{\"name\":\"$ADO_ENVIRONMENT\",\"description\":\"$PROJECT $ENVIRONMENT\"}" > "$ENV_BODY"
    az devops invoke "${ADO_ARGS[@]}" --area distributedtask --resource environments \
      --route-parameters project="$ADO_PROJECT" --http-method POST \
      --in-file "$ENV_BODY" --api-version 7.1-preview >/dev/null 2>&1 \
      && ok "created ADO environment $ADO_ENVIRONMENT" \
      || warn "could not create ADO environment $ADO_ENVIRONMENT (create it in the UI)"
    rm -f "$ENV_BODY"
  fi
else
  ok "ADO environment exists ($ADO_ENVIRONMENT)"
fi

cat <<DONE

══════════════════════════════════════════════════════════════════════════════
 ✓ ${PROJECT} / ${ENVIRONMENT} onboarded.

 Still MANUAL (by design — these are human-approval controls, not plumbing):
   • Add approval checks on ADO environment '${ADO_ENVIRONMENT}'
     (qa = QA lead, stage = tech lead, prod = VP + business-hours).
   • Link KeyVault-backed secrets (sqlAdminPassword, etc.) into '${VG_ENV}'
     if this app uses them, or leave passwordless (Entra-only SQL) and skip.

 The deploy identity uses Workload Identity Federation — there is NO secret to
 rotate. Re-run this script any time; it is idempotent.
══════════════════════════════════════════════════════════════════════════════
DONE
