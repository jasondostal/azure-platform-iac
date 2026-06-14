#!/bin/bash
# ── ADO self-hosted agent bootstrap (unattended) ─────────────────────────────
# Downloads the agent matching the org, configures it against AZP_POOL using a
# PAT, runs it, and de-registers cleanly on container stop. Env contract:
#   AZP_URL    (required)  https://dev.azure.com/<org>
#   AZP_TOKEN  (required)  PAT with Agent Pools (Read & Manage)
#   AZP_POOL   (default: Default)
#   AZP_AGENT_NAME (default: hostname)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

[ -n "${AZP_URL:-}" ]   || { echo 1>&2 "error: missing AZP_URL";   exit 1; }
[ -n "${AZP_TOKEN:-}" ] || { echo 1>&2 "error: missing AZP_TOKEN"; exit 1; }

AZP_POOL="${AZP_POOL:-Default}"
AZP_AGENT_NAME="${AZP_AGENT_NAME:-$(hostname)}"
AZP_WORK="${AZP_WORK:-_work}"

mkdir -p /azp/agent && cd /azp/agent

echo "Fetching agent package for this organization..."
PKG_URL=$(curl -LsS -u "user:${AZP_TOKEN}" \
  -H 'Accept:application/json;api-version=3.0-preview' \
  "${AZP_URL}/_apis/distributedtask/packages/agent?platform=linux-x64&top=1" \
  | jq -r '.value[0].downloadUrl')
[ -n "$PKG_URL" ] && [ "$PKG_URL" != "null" ] || { echo 1>&2 "error: could not resolve agent package URL (check AZP_URL/AZP_TOKEN)"; exit 1; }

curl -LsS "$PKG_URL" | tar -xz

cleanup() {
  echo "De-registering agent..."
  ./config.sh remove --unattended --auth pat --token "${AZP_TOKEN}" || true
}
trap 'cleanup; exit 0' EXIT SIGINT SIGTERM

echo "Configuring agent '${AZP_AGENT_NAME}' into pool '${AZP_POOL}'..."
./config.sh --unattended \
  --agent "${AZP_AGENT_NAME}" \
  --url "${AZP_URL}" \
  --auth pat \
  --token "${AZP_TOKEN}" \
  --pool "${AZP_POOL}" \
  --work "${AZP_WORK}" \
  --replace \
  --acceptTeeEula

echo "Agent online. Running..."
./run.sh
