# ── Self-hosted Azure DevOps agent image ─────────────────────────────────────
# Based on the .NET 10 SDK so the agent can BUILD .NET apps out of the box.
# Adds az CLI (for AzureCLI@2 / WIF deploys) and the agent bootstrap.
# Build (no local Docker needed):
#   az acr build -r <acr> -t ado-agent:latest modules/devops/agent-image
# ─────────────────────────────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/sdk:10.0

ENV AGENT_ALLOW_RUNASROOT=1 \
    DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl jq git ca-certificates libicu-dev zip unzip \
 && curl -sL https://aka.ms/InstallAzureCLIDeb | bash \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /azp
COPY start.sh /azp/start.sh
RUN chmod +x /azp/start.sh

ENTRYPOINT ["/azp/start.sh"]
