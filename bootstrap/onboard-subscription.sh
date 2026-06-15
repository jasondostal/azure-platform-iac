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
# ONE RUN = ONE ENVIRONMENT. Run it once per env you stand up. Two org shapes:
#   • Sub-per-env  → pass a different --subscription each run (--rbac-scope sub).
#   • One sub, RG-per-env (e.g. Fox) → pass the SAME --subscription each run with
#     --rbac-scope rg. Each run pre-creates rg-<project>-<env> and scopes that
#     env's deploy identity + service connection to it — so the dev pipeline
#     can't reach another env. The shared plumbing (ACR, Log Analytics, platform
#     Key Vault) is env-invariant, so it's created once and reused on later runs.
# The shared variable group is created on first run and updated on later ones.
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
#       [--rbac-scope sub|rg] \
#       [--app-resource-group rg-contoso-dev] \
#       [--dry-run]
#
#   --project    logical platform/app name → names everything (vg-<project>-*,
#                sc-<project>-<env>, the app reg, the ADO environment).
#   --app-name   the App Service name this env deploys to (stored in the env's
#                variable group as <env>AppName). Defaults to <project>-app-<env>.
#   --rbac-scope sub (default) = identity + service connection span the whole
#                subscription. rg = least privilege: pre-create the env's RG and
#                scope identity + service connection to it (single-sub orgs).
#   --app-resource-group  rg mode only: the env's RG. Default rg-<project>-<env>;
#                must match what the app's infra deploys into.
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
LOCATION="eastus"
DRY_RUN=false
APP_NAME=""
RBAC_SCOPE="sub"          # sub | rg  — see --rbac-scope
APP_RESOURCE_GROUP=""     # rg mode: the env's app RG (default rg-<project>-<env>)
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
    --app-name)     APP_NAME="$2"; APP_NAME_EXPLICIT=true; shift 2 ;;
    --rbac-scope)   RBAC_SCOPE="$2"; shift 2 ;;
    --app-resource-group) APP_RESOURCE_GROUP="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    *) echo "✗ unknown arg: $1" >&2; exit 1 ;;
  esac
done

: "${ENVIRONMENT:?--env is required (dev|qa|stage|prod)}"
: "${SUBSCRIPTION_ID:?--subscription is required}"
: "${ADO_ORG:?--ado-org is required (https://dev.azure.com/<org>)}"
: "${ADO_PROJECT:?--ado-project is required}"
: "${PROJECT:?--project is required}"
# Convention: App Service names follow <project>-app-<env> — must match infra.
APP_NAME="${APP_NAME:-${PROJECT}-app-${ENVIRONMENT}}"

# RBAC scope: how far the deploy identity + service connection can reach.
#   sub — Contributor/UAA on the whole subscription, service connection
#         scopeLevel=Subscription. The "move fast" default; in a single-sub org
#         every env's identity can deploy ANYWHERE in the sub (no isolation).
#   rg  — Contributor/UAA on ONLY this env's resource group, service connection
#         scopeLevel=ResourceGroup. Least privilege per env in one subscription:
#         the dev pipeline can't reach another env. Infra pre-creates the RG here
#         (an RG-scoped identity cannot create its own RG — a sub-level write).
case "$RBAC_SCOPE" in
  sub|rg) ;;
  *) echo "✗ --rbac-scope must be 'sub' or 'rg' (got '$RBAC_SCOPE')" >&2; exit 1 ;;
esac
# The env's app RG — must match what the app's infra deploys into (rg-<project>-<env>).
APP_RESOURCE_GROUP="${APP_RESOURCE_GROUP:-rg-${PROJECT}-${ENVIRONMENT}}"

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

# R2 — grant "all pipelines" authorization for an ADO resource so app pipelines
# don't stall on a manual authorization checkpoint on first run. Best-effort.
# Usage: authorize_pipeline_resource <resourceType> <resourceId>
# Note: api-version must be 7.1-preview (no trailing .N — az devops invoke rejects it).
authorize_pipeline_resource() {
  local rtype="$1" rid="$2"
  if $DRY_RUN; then
    run "az devops invoke ... --area pipelinePermissions --resource pipelinePermissions --route-parameters project='$ADO_PROJECT' resourceType=$rtype resourceId=$rid --http-method PATCH --api-version 7.1-preview"
    return
  fi
  local auth_body
  auth_body="$(mktemp)"
  printf '{"allPipelines":{"authorized":true}}' > "$auth_body"
  az devops invoke "${ADO_ARGS[@]}" \
    --area pipelinePermissions --resource pipelinePermissions \
    --route-parameters project="$ADO_PROJECT" resourceType="$rtype" resourceId="$rid" \
    --http-method PATCH --in-file "$auth_body" \
    --api-version 7.1-preview >/dev/null 2>&1 \
    && ok "authorized $rtype for all pipelines" \
    || warn "could not authorize $rtype ($rid) for all pipelines — do it in ADO UI (Pipelines → Settings → Resources)"
  rm -f "$auth_body"
}

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

# R5 — app-name consistency guard: explicit --app-name must match <project>-app-<env>.
if [[ "${APP_NAME_EXPLICIT:-false}" == "true" && "$APP_NAME" != "${PROJECT}-app-${ENVIRONMENT}" ]]; then
  warn "--app-name '$APP_NAME' does not match the infra convention '${PROJECT}-app-${ENVIRONMENT}' — the deploy will fail with 'Resource doesn't exist' if these differ. Proceeding anyway."
fi

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
   rbac scope     : ${RBAC_SCOPE}$( [[ "$RBAC_SCOPE" == "rg" ]] && echo "  → ${APP_RESOURCE_GROUP} (least privilege)" || echo "  → whole subscription" )
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

# In rg mode, infra pre-creates the env's app RG: an RG-scoped deploy identity
# cannot create its own resource group (that's a subscription-level write). The
# app's infra then deploys INTO this RG (targetScope='resourceGroup'), rather
# than creating it. Idempotent.
if [[ "$RBAC_SCOPE" == "rg" ]]; then
  if $DRY_RUN; then
    run "az group create --name '$APP_RESOURCE_GROUP' --location '$LOCATION'"
    RBAC_SCOPE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${APP_RESOURCE_GROUP}"
  else
    az group create --name "$APP_RESOURCE_GROUP" --location "$LOCATION" \
      --tags managedBy=azure-platform-iac environment="$ENVIRONMENT" project="$PROJECT" \
      --only-show-errors >/dev/null && ok "pre-created app RG $APP_RESOURCE_GROUP"
    RBAC_SCOPE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${APP_RESOURCE_GROUP}"
  fi
else
  RBAC_SCOPE_ID="/subscriptions/${SUBSCRIPTION_ID}"
fi

# RBAC: Contributor (deploy resources) + User Access Administrator (so app
# deployments can create their own role assignments WITHIN scope — Cosmos/SQL
# MI data-plane RBAC, etc.). Scoped per --rbac-scope: the whole sub, or just the
# env's RG (least privilege — the dev pipeline can't touch another env). Idempotent.
for ROLE in "Contributor" "User Access Administrator"; do
  if $DRY_RUN; then
    run "az role assignment create --assignee '$APP_ID' --role '$ROLE' --scope '$RBAC_SCOPE_ID'"
  else
    az role assignment create --assignee "$APP_ID" --role "$ROLE" --scope "$RBAC_SCOPE_ID" \
      --only-show-errors >/dev/null 2>&1 || true
    ok "role ensured: $ROLE @ ${RBAC_SCOPE} scope"
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
  # Scope the service connection to match the RBAC grant: a ResourceGroup-scoped
  # connection can only target $APP_RESOURCE_GROUP, so a pipeline using it
  # physically cannot deploy into another env's RG.
  if [[ "$RBAC_SCOPE" == "rg" ]]; then
    EP_SCOPE_LEVEL="ResourceGroup"
    EP_RG_LINE="\"resourceGroupName\": \"${APP_RESOURCE_GROUP}\","
  else
    EP_SCOPE_LEVEL="Subscription"
    EP_RG_LINE=""
  fi
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
    ${EP_RG_LINE}
    "scopeLevel": "${EP_SCOPE_LEVEL}",
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
authorize_pipeline_resource endpoint "$EP_ID"

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
LAST_VARGROUP_ID=""  # R2: set by upsert_varset so caller can authorize the group.
upsert_varset() {  # upsert_varset <group-name> KEY=VAL [KEY=VAL ...]
  local group="$1"; shift
  local gid
  gid="$(az pipelines variable-group list "${ADOP_ARGS[@]}" --query "[?name=='$group'].id | [0]" -o tsv 2>/dev/null || true)"
  if [[ -z "$gid" ]]; then
    if $DRY_RUN; then run "az pipelines variable-group create --organization '$ADO_ORG' --project '$ADO_PROJECT' --name '$group' --variables $*"; LAST_VARGROUP_ID="<dry-run-vgid>"; return; fi
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
  LAST_VARGROUP_ID="$gid"
}

# ── 3f (#6). Sub-scoped INFRA service connection (rg mode only) ───────────────
# The two-layer infra-pipeline deploys the infra layer (RG + VNet + agent +
# cross-RG ACR grant) on a SUBSCRIPTION-scoped connection — work the RG-scoped
# app identity can't do. This provisions ONE infra identity per subscription
# (shared across envs), written to vg-<project>-shared as infraServiceConnection.
# Idempotent; mirrors the per-env identity flow above.
provision_infra_service_connection() {
  local areg="${PROJECT}-ado-infra" sc="sc-${PROJECT}-infra"
  log "Plane 3f — Infra identity: subscription-scoped service connection ($sc)"

  local app_id
  app_id="$(az ad app list --display-name "$areg" --query '[0].appId' -o tsv 2>/dev/null || true)"
  if [[ -z "$app_id" ]]; then
    if $DRY_RUN; then app_id="<dry-run-infra-appid>"; run "az ad app create --display-name '$areg' --sign-in-audience AzureADMyOrg"
    else app_id="$(az ad app create --display-name "$areg" --sign-in-audience AzureADMyOrg --query appId -o tsv)"; fi
    ok "created infra app registration ($app_id)"
  else ok "infra app registration exists ($app_id)"; fi
  if ! $DRY_RUN; then
    az ad sp list --filter "appId eq '$app_id'" --query '[0].id' -o tsv 2>/dev/null | grep -q . \
      || az ad sp create --id "$app_id" >/dev/null 2>&1 || true
  fi

  # Sub-scoped Contributor + UAA (infra needs to create RGs, networking, grants).
  local role
  for role in "Contributor" "User Access Administrator"; do
    if $DRY_RUN; then run "az role assignment create --assignee '$app_id' --role '$role' --scope '/subscriptions/${SUBSCRIPTION_ID}'"
    else az role assignment create --assignee "$app_id" --role "$role" --scope "/subscriptions/${SUBSCRIPTION_ID}" --only-show-errors >/dev/null 2>&1 || true; ok "infra role ensured: $role @ subscription"; fi
  done

  # Service connection (scopeLevel Subscription).
  local ep_id
  ep_id="$(az devops service-endpoint list "${ADOP_ARGS[@]}" --query "[?name=='$sc'].id | [0]" -o tsv 2>/dev/null || true)"
  if [[ -z "$ep_id" ]]; then
    local cfg; cfg="$(mktemp)"
    cat > "$cfg" <<JSON
{ "name": "${sc}", "type": "azurerm", "url": "https://management.azure.com/",
  "authorization": { "scheme": "WorkloadIdentityFederation", "parameters": { "tenantid": "${TENANT_ID}", "serviceprincipalid": "${app_id}" } },
  "data": { "subscriptionId": "${SUBSCRIPTION_ID}", "subscriptionName": "infra", "environment": "AzureCloud", "scopeLevel": "Subscription", "creationMode": "Manual" },
  "serviceEndpointProjectReferences": [ { "projectReference": { "id": "${ADO_PROJECT_ID}", "name": "${ADO_PROJECT}" }, "name": "${sc}" } ] }
JSON
    if $DRY_RUN; then run "az devops service-endpoint create (infra: $sc)"; ep_id="<dry-run-infra-ep>"
    else ep_id="$(az devops service-endpoint create "${ADOP_ARGS[@]}" --service-endpoint-configuration "$cfg" --query id -o tsv)"; ok "created infra service connection ($ep_id)"; fi
    rm -f "$cfg"
  else ok "infra service connection exists ($ep_id)"; fi
  authorize_pipeline_resource endpoint "$ep_id"

  # Federated credential binding the infra app reg ↔ infra service connection.
  if ! $DRY_RUN && [[ "$ep_id" != "<dry-run-infra-ep>" ]]; then
    local ep_json issuer subject org_short app_obj fc
    ep_json="$(az devops service-endpoint show "${ADOP_ARGS[@]}" --id "$ep_id" -o json)"
    issuer="$(echo "$ep_json"  | jq -r '.authorization.parameters.workloadIdentityFederationIssuer // empty')"
    subject="$(echo "$ep_json" | jq -r '.authorization.parameters.workloadIdentityFederationSubject // empty')"
    org_short="$(basename "$ADO_ORG")"
    subject="${subject:-sc://${org_short}/${ADO_PROJECT}/${sc}}"
    if [[ -z "$issuer" ]]; then
      local org_id; org_id="$(az devops invoke "${ADO_ARGS[@]}" --area core --resource connectionData --route-parameters "" --query 'instanceId' -o tsv 2>/dev/null || true)"
      [[ -n "$org_id" ]] && issuer="https://vstoken.dev.azure.com/${org_id}"
    fi
    if [[ -n "$issuer" && -n "$subject" ]]; then
      app_obj="$(az ad app show --id "$app_id" --query id -o tsv)"
      fc="ado-${sc}"
      az ad app federated-credential list --id "$app_obj" --query "[?name=='$fc'].name | [0]" -o tsv 2>/dev/null | grep -q . \
        || az ad app federated-credential create --id "$app_obj" --parameters "{\"name\":\"${fc}\",\"issuer\":\"${issuer}\",\"subject\":\"${subject}\",\"audiences\":[\"api://AzureADTokenExchange\"]}" >/dev/null
      ok "infra federated credential ensured ($fc)"
    else warn "could not resolve infra WIF issuer/subject — finish $sc in the ADO UI (Verify)."; fi
  fi

  upsert_varset "$VG_SHARED" "infraServiceConnection=$sc"
  authorize_pipeline_resource variablegroup "$LAST_VARGROUP_ID"
}

upsert_varset "$VG_SHARED" "tenantId=$TENANT_ID"
authorize_pipeline_resource variablegroup "$LAST_VARGROUP_ID"
upsert_varset "$VG_ENV" \
  "${ENVIRONMENT}ServiceConnection=$SERVICE_CONNECTION" \
  "${ENVIRONMENT}AppName=$APP_NAME" \
  "keyVaultName=$KV_NAME" \
  "acrLoginServer=$ACR_LOGIN"
authorize_pipeline_resource variablegroup "$LAST_VARGROUP_ID"

# ── 3d. ADO Environment (approval checks are configured in the UI) ────────────
ADO_ENV_ID=""
ENV_EXISTS="$(az devops invoke "${ADO_ARGS[@]}" --area distributedtask --resource environments \
  --route-parameters project="$ADO_PROJECT" --api-version 7.1-preview \
  --query "value[?name=='$ADO_ENVIRONMENT'].id | [0]" -o tsv 2>/dev/null || true)"
if [[ -z "$ENV_EXISTS" ]]; then
  if $DRY_RUN; then
    ok "[dry-run] would create ADO environment $ADO_ENVIRONMENT"
    ADO_ENV_ID="<dry-run-envid>"
  else
    ENV_BODY="$(mktemp)"; echo "{\"name\":\"$ADO_ENVIRONMENT\",\"description\":\"$PROJECT $ENVIRONMENT\"}" > "$ENV_BODY"
    ADO_ENV_ID="$(az devops invoke "${ADO_ARGS[@]}" --area distributedtask --resource environments \
      --route-parameters project="$ADO_PROJECT" --http-method POST \
      --in-file "$ENV_BODY" --api-version 7.1-preview \
      --query id -o tsv 2>/dev/null || true)"
    if [[ -n "$ADO_ENV_ID" ]]; then
      ok "created ADO environment $ADO_ENVIRONMENT ($ADO_ENV_ID)"
    else
      warn "could not create ADO environment $ADO_ENVIRONMENT (create it in the UI)"
    fi
    rm -f "$ENV_BODY"
  fi
else
  ADO_ENV_ID="$ENV_EXISTS"
  ok "ADO environment exists ($ADO_ENVIRONMENT, id=$ADO_ENV_ID)"
fi
[[ -n "$ADO_ENV_ID" ]] && authorize_pipeline_resource environment "$ADO_ENV_ID"

# ── 3e. Authorize the Default agent pool queue for all pipelines ──────────────
if $DRY_RUN; then
  run "az devops invoke ... --area distributedtask --resource queues --route-parameters project='$ADO_PROJECT' (query Default queue id)"
  authorize_pipeline_resource queue "<dry-run-queueid>"
else
  DEFAULT_QUEUE_ID="$(az devops invoke "${ADO_ARGS[@]}" --area distributedtask --resource queues \
    --route-parameters project="$ADO_PROJECT" --api-version 7.1-preview \
    --query "value[?name=='Default'].id | [0]" -o tsv 2>/dev/null || true)"
  if [[ -n "$DEFAULT_QUEUE_ID" ]]; then
    authorize_pipeline_resource queue "$DEFAULT_QUEUE_ID"
  else
    warn "Default agent pool queue not found — skipping queue authorization (add it in ADO)"
  fi
fi

# #6 — the two-layer model (rg mode) needs the sub-scoped infra connection.
if [[ "$RBAC_SCOPE" == "rg" ]]; then
  provision_infra_service_connection
fi

RG_MODE_NOTE=""
if [[ "$RBAC_SCOPE" == "rg" ]]; then
  RG_MODE_NOTE="
   • rg-scope: the deploy identity is Contributor + UAA on ${APP_RESOURCE_GROUP}
     ONLY. If this app uses the self-hosted ACI agent, its AcrPull on the SHARED
     ACR is a cross-RG grant the RG-scoped identity can't make — infra grants it
     (or pre-creates the agent pull identity). See azure-ref-webapp-sql."
fi

cat <<DONE

══════════════════════════════════════════════════════════════════════════════
 ✓ ${PROJECT} / ${ENVIRONMENT} onboarded  (rbac-scope: ${RBAC_SCOPE}).

 Still MANUAL (by design — these are human-approval controls, not plumbing):
   • Add approval checks on ADO environment '${ADO_ENVIRONMENT}'
     (qa = QA lead, stage = tech lead, prod = VP + business-hours).
   • Link KeyVault-backed secrets (sqlAdminPassword, etc.) into '${VG_ENV}'
     if this app uses them, or leave passwordless (Entra-only SQL) and skip.${RG_MODE_NOTE}

 The deploy identity uses Workload Identity Federation — there is NO secret to
 rotate. Re-run this script any time; it is idempotent.
══════════════════════════════════════════════════════════════════════════════
DONE
