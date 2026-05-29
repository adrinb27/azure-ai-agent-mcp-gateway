#!/usr/bin/env bash
# deploy.sh — Interactive deployment for the Azure AI Agent POC infrastructure
#
# Usage (interactive):
#   ./deploy.sh
#
# Usage (CI / non-interactive — reads everything from .env):
#   ./deploy.sh --ci
#
# What this does:
#   1. Prompts for deployment settings (or reads from .env in CI mode)
#   2. Creates or verifies the APIM Gateway Entra app registration
#   3. Deploys the Bicep infrastructure (creates/reuses the resource group)
#   4. Saves deployment outputs back to .env for post-deployment scripts

set -euo pipefail

CI_MODE=false
[[ "${1:-}" == "--ci" ]] && CI_MODE=true

# ── Load .env ─────────────────────────────────────────────────────────────────
if [[ -f ".env" ]]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' .env | xargs)
else
  if $CI_MODE; then
    echo "❌  .env file not found. In CI mode all variables must be in .env."
    exit 1
  fi
  echo "⚠️   No .env file found — creating one from .env.example"
  cp .env.example .env
fi

# ── Required variables (always must be set) ────────────────────────────────────
: "${AZURE_TENANT_ID:?'AZURE_TENANT_ID not set in .env'}"
: "${AZURE_SUBSCRIPTION_ID:?'AZURE_SUBSCRIPTION_ID not set in .env'}"

# ── Interactive prompts (skipped in CI mode) ───────────────────────────────────
prompt_with_default() {
  local var_name="$1" prompt_text="$2" default_val="$3"
  if $CI_MODE; then
    # In CI, use existing value or default
    printf -v "$var_name" '%s' "${!var_name:-$default_val}"
    return
  fi
  local current_val="${!var_name:-$default_val}"
  read -rp "$(echo -e "\033[1;36m$prompt_text\033[0m [$current_val]: ")" input
  printf -v "$var_name" '%s' "${input:-$current_val}"
}

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║       Azure AI Agent POC — Deployment Setup                     ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# 1. Deployment / environment name
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-agenttest}"
prompt_with_default ENVIRONMENT_NAME \
  "📦 Deployment name (used for tagging and default RG name)" \
  "$ENVIRONMENT_NAME"

# 2. Resource group name
DEFAULT_RG="rg-${ENVIRONMENT_NAME}"
RESOURCE_GROUP_NAME="${RESOURCE_GROUP_NAME:-$DEFAULT_RG}"
prompt_with_default RESOURCE_GROUP_NAME \
  "📁 Resource group name (will be created if it does not exist)" \
  "${RESOURCE_GROUP_NAME:-$DEFAULT_RG}"

# 3. Region
AZURE_LOCATION="${AZURE_LOCATION:-swedencentral}"
prompt_with_default AZURE_LOCATION \
  "🌍 Azure region" \
  "$AZURE_LOCATION"

# 4. Publisher email
APIM_PUBLISHER_EMAIL="${APIM_PUBLISHER_EMAIL:-admin@contoso.com}"
prompt_with_default APIM_PUBLISHER_EMAIL \
  "📧 APIM publisher email" \
  "$APIM_PUBLISHER_EMAIL"

echo ""
echo "────────────────────────────────────────────────────────────────────"
echo "  Environment : $ENVIRONMENT_NAME"
echo "  Resource RG : $RESOURCE_GROUP_NAME"
echo "  Region      : $AZURE_LOCATION"
echo "────────────────────────────────────────────────────────────────────"

if ! $CI_MODE; then
  read -rp "$(echo -e "\033[1;33mProceed with deployment? [Y/n]: \033[0m")" confirm
  [[ "${confirm:-Y}" =~ ^[Nn] ]] && { echo "Aborted."; exit 0; }
fi

az account set --subscription "$AZURE_SUBSCRIPTION_ID"
echo ""
echo "✅  Subscription set to $AZURE_SUBSCRIPTION_ID"

# ─────────────────────────────────────────────────────────────────────────────
# Create or verify the APIM Gateway Entra app registration.
#
# The APIM Gateway app must exist BEFORE deploying Bicep (its App ID and client
# secret are Bicep parameters). If APIM_GATEWAY_APP_ID is not yet set, we create
# the app here with all required settings baked in from the start.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── Entra: APIM Gateway app registration ─────────────────────────────────"

if [[ -z "${APIM_GATEWAY_APP_ID:-}" ]]; then
  echo "   APIM_GATEWAY_APP_ID not set — creating a new app registration…"

  APIM_APP_DISPLAY_NAME="APIM-Gateway-${ENVIRONMENT_NAME}"
  APIM_GATEWAY_APP_ID=$(az ad app create \
    --display-name "$APIM_APP_DISPLAY_NAME" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)

  echo "   ✅  Created app: $APIM_APP_DISPLAY_NAME (App ID: $APIM_GATEWAY_APP_ID)"

  # Create a client secret
  SECRET_JSON=$(az ad app credential reset \
    --id "$APIM_GATEWAY_APP_ID" \
    --display-name "apim-obo-secret" \
    --years 2 \
    --output json)
  APIM_GATEWAY_CLIENT_SECRET=$(echo "$SECRET_JSON" | jq -r '.password')
  echo "   ✅  Client secret created."

  # Apply required settings via Graph
  echo "   ➕  Configuring identifierUris, token version, and APIM.Access role…"
  APP_OBJ_ID=$(az ad app show --id "$APIM_GATEWAY_APP_ID" --query id -o tsv)
  python3 - <<PYEOF
import json, subprocess, uuid

obj_id = "$APP_OBJ_ID"
app_id = "$APIM_GATEWAY_APP_ID"

apim_access_role_id = str(uuid.uuid4())
patch = {
    "identifierUris": [f"api://{app_id}"],
    "api": {
        "requestedAccessTokenVersion": 2,
        "oauth2PermissionScopes": [{
            "adminConsentDescription": "Access the APIM MCP Gateway",
            "adminConsentDisplayName": "Access APIM",
            "id": str(uuid.uuid4()),
            "isEnabled": True,
            "type": "Admin",
            "userConsentDescription": None,
            "userConsentDisplayName": None,
            "value": "user_impersonation",
        }],
    },
    "appRoles": [{
        "allowedMemberTypes": ["Application"],
        "description": "Allows applications to call the APIM MCP gateway",
        "displayName": "APIM MCP Access",
        "id": apim_access_role_id,
        "isEnabled": True,
        "value": "APIM.Access",
    }],
}
subprocess.check_call([
    "az", "rest", "--method", "PATCH",
    "--uri", f"https://graph.microsoft.com/v1.0/applications/{obj_id}",
    "--headers", "Content-Type=application/json",
    "--body", json.dumps(patch),
])
print(f"   ✅  App configured (APIM.Access role id: {apim_access_role_id})")
PYEOF

  # Get the SP object ID (created automatically by Entra, may take a moment)
  echo "   Waiting for service principal to be created…"
  for i in {1..10}; do
    APIM_GATEWAY_SP_OBJECT_ID=$(az ad sp show --id "$APIM_GATEWAY_APP_ID" --query id -o tsv 2>/dev/null || echo "")
    [[ -n "$APIM_GATEWAY_SP_OBJECT_ID" ]] && break
    sleep 3
  done
  [[ -z "${APIM_GATEWAY_SP_OBJECT_ID:-}" ]] && {
    echo "   ⚠️   SP not found yet — run: az ad sp create --id $APIM_GATEWAY_APP_ID"
    APIM_GATEWAY_SP_OBJECT_ID="<run: az ad sp create --id $APIM_GATEWAY_APP_ID>"
  }
  echo "   SP Object ID: $APIM_GATEWAY_SP_OBJECT_ID"

else
  echo "   ✅  Using existing APIM Gateway app: $APIM_GATEWAY_APP_ID"
  : "${APIM_GATEWAY_CLIENT_SECRET:?'APIM_GATEWAY_CLIENT_SECRET not set in .env'}"
  APIM_GATEWAY_SP_OBJECT_ID="${APIM_GATEWAY_SP_OBJECT_ID:-$(az ad sp show --id "$APIM_GATEWAY_APP_ID" --query id -o tsv 2>/dev/null || echo '')}"
fi

: "${APIM_GATEWAY_CLIENT_SECRET:?'APIM_GATEWAY_CLIENT_SECRET not set — set it in .env or re-run to create a new app'}"
: "${MCP_APP_ID:?'MCP_APP_ID not set — this is created by Container Apps Easy Auth on first deploy. Set it after the first deploy and re-run setup-obo-auth.sh'}"

# ─────────────────────────────────────────────────────────────────────────────
# Deploy Bicep
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── Deploying Bicep infrastructure ───────────────────────────────────────"
echo "   Resource group : $RESOURCE_GROUP_NAME"
echo "   Token source   : uniqueString(sub, '$RESOURCE_GROUP_NAME', '$AZURE_LOCATION')"
echo ""

DEPLOY_OUTPUT=$(az deployment sub create \
  --name "deploy-${ENVIRONMENT_NAME}-$(date +%Y%m%d%H%M%S)" \
  --location "$AZURE_LOCATION" \
  --template-file "infra/main.bicep" \
  --parameters "infra/main.parameters.json" \
  --parameters environmentName="$ENVIRONMENT_NAME" \
  --parameters resourceGroupName="$RESOURCE_GROUP_NAME" \
  --parameters location="$AZURE_LOCATION" \
  --parameters azureTenantId="$AZURE_TENANT_ID" \
  --parameters azureSubscriptionId="$AZURE_SUBSCRIPTION_ID" \
  --parameters azureAdClientId="$MCP_APP_ID" \
  --parameters apimGatewayAppId="$APIM_GATEWAY_APP_ID" \
  --parameters apimGatewayClientSecret="$APIM_GATEWAY_CLIENT_SECRET" \
  --parameters apimPublisherEmail="$APIM_PUBLISHER_EMAIL" \
  --output json)

echo ""
echo "✅  Deployment complete!"
echo ""
echo "📋  Key outputs:"
echo "$DEPLOY_OUTPUT" | jq -r '
  .properties.outputs |
  to_entries[] |
  "  \(.key): \(.value.value)"
'

# ─────────────────────────────────────────────────────────────────────────────
# Save deployment outputs back to .env
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── Saving deployment outputs to .env ────────────────────────────────────"

save_env() {
  local key="$1" val="$2"
  [[ -z "$val" || "$val" == "null" ]] && return
  if grep -q "^${key}=" .env 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
  echo "   ${key}=${val}"
}

APIM_NAME=$(echo "$DEPLOY_OUTPUT"    | jq -r '.properties.outputs.apimGatewayUrl.value // ""' | sed 's|https://||' | sed 's|\.azure.*||')
APIM_URL=$(echo "$DEPLOY_OUTPUT"     | jq -r '.properties.outputs.apimGatewayUrl.value // ""')
NEW_PROJ_NAME=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.outputs.newFoundryProjectName.value // ""')
NEW_PROJ_MI=$(echo "$DEPLOY_OUTPUT"   | jq -r '.properties.outputs.newFoundryProjectPrincipalId.value // ""')
NEW_PROJ_EP=$(echo "$DEPLOY_OUTPUT"   | jq -r '.properties.outputs.newFoundryProjectEndpoint.value // ""')

save_env "ENVIRONMENT_NAME"                "$ENVIRONMENT_NAME"
save_env "RESOURCE_GROUP_NAME"             "$RESOURCE_GROUP_NAME"
save_env "AZURE_LOCATION"                  "$AZURE_LOCATION"
save_env "APIM_PUBLISHER_EMAIL"            "$APIM_PUBLISHER_EMAIL"
save_env "APIM_GATEWAY_APP_ID"             "$APIM_GATEWAY_APP_ID"
save_env "APIM_GATEWAY_SP_OBJECT_ID"       "${APIM_GATEWAY_SP_OBJECT_ID:-}"
save_env "APIM_GATEWAY_CLIENT_SECRET"      "$APIM_GATEWAY_CLIENT_SECRET"
save_env "APIM_STANDARD_NAME"              "${APIM_NAME:-}"
save_env "APIM_GATEWAY_URL"                "$APIM_URL"
save_env "NEW_FOUNDRY_PROJECT_NAME"        "${NEW_PROJ_NAME:-}"
save_env "FOUNDRY_PROJECT_MI_OBJECT_ID"    "${NEW_PROJ_MI:-}"
save_env "NEW_FOUNDRY_PROJECT_ENDPOINT"    "${NEW_PROJ_EP:-}"

echo "   ✅  .env updated"

# ─────────────────────────────────────────────────────────────────────────────
# Next steps
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════════════════"
echo "✅  Infrastructure deployed!"
echo ""
echo "   ⚠️   IMPORTANT POST-DEPLOYMENT STEPS:"
echo ""
echo "   1. Get the MCP CA app registration ID (created by Container Apps Easy Auth):"
echo "      az ad app list --display-name ca-mcp --query '[0].appId' -o tsv"
echo "      → Set MCP_APP_ID=<result> in .env"
echo "      → Also get the SP object ID and role ID from the MCP CA app."
echo "        (See README.md → Post-Deployment for full commands)"
echo ""
echo "   2. Run setup-obo-auth.sh to configure Entra roles and apply the APIM policy:"
echo "      ./setup-obo-auth.sh"
echo ""
echo "   3. Configure your AI Foundry agent with the MCP tool:"
echo "      Server URL : ${APIM_URL:-https://apim-<token>.azure-api.net}/mcp"
echo "      Auth scope : api://${APIM_GATEWAY_APP_ID:-<apim-gateway-app-id>}/.default"
echo "══════════════════════════════════════════════════════════════════════════"
