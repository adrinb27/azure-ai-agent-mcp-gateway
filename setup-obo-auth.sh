#!/usr/bin/env bash
# setup-obo-auth.sh — Configure Entra ID and APIM for OBO-based MCP gateway auth
#
# Run this AFTER every deployment. It is idempotent — safe to re-run.
#
# What this does:
#   0a. Configures the APIM Gateway Entra app registration:
#       - Adds identifierUris (required for api://<appId> audience to work)
#       - Sets requestedAccessTokenVersion = 2 (required for v2 tokens)
#       - Adds APIM.Access app role (required for Foundry Project MI CC grant)
#   0b. Configures the MCP CA Entra app registration (if MCP_APP_ID is set):
#       - Adds identifierUris (required for api://<appId> audience to work)
#       - Sets requestedAccessTokenVersion = 2
#   1.  Assigns Mcp.Tools.ReadWrite.All to the APIM Gateway App SP on the MCP CA
#       (needed for the client_credentials path when app-only tokens arrive at APIM)
#   1b. Assigns APIM.Access + Mcp.Tools.ReadWrite.All to the Foundry Project MI
#       (required for the Foundry agent to get tokens for both APIM and MCP)
#   2.  Ensures obo-client-id / obo-client-secret named values exist in APIM
#   3.  Applies the infra/apim-obo-policy.xml to configured APIM instances
#       (substitutes APIM_TENANT_ID / APIM_GATEWAY_APP_ID / MCP_CA_APP_ID)
#
# Prerequisites:
#   - az login with Application Administrator + APIM Contributor on the RG.
#   - .env file filled in (see .env.example).  All variables described below.
#
# Usage:
#   ./setup-obo-auth.sh [obo-client-secret]

set -euo pipefail

# ── Load .env ─────────────────────────────────────────────────────────────────
if [[ -f ".env" ]]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' .env | xargs)
fi

# ── Required variables ────────────────────────────────────────────────────────
: "${AZURE_SUBSCRIPTION_ID:?'AZURE_SUBSCRIPTION_ID not set in .env'}"
: "${AZURE_TENANT_ID:?'AZURE_TENANT_ID not set in .env'}"
: "${APIM_GATEWAY_APP_ID:?'APIM_GATEWAY_APP_ID not set in .env'}"
: "${APIM_GATEWAY_SP_OBJECT_ID:?'APIM_GATEWAY_SP_OBJECT_ID not set in .env'}"
: "${MCP_APP_ID:?'MCP_APP_ID not set in .env'}"
: "${MCP_APP_SP_OBJECT_ID:?'MCP_APP_SP_OBJECT_ID not set in .env'}"
: "${MCP_APP_ROLE_ID:?'MCP_APP_ROLE_ID not set in .env'}"

RESOURCE_GROUP="${RESOURCE_GROUP_NAME:-${RESOURCE_GROUP:-rg-${ENVIRONMENT_NAME:-agenttest}}}"
APIM_STANDARD="${APIM_STANDARD_NAME:-}"

POLICY_FILE="infra/apim-obo-policy.xml"

# ── Load secret ───────────────────────────────────────────────────────────────
if [[ -n "${1:-}" ]]; then
  OBO_CLIENT_SECRET="$1"
else
  OBO_CLIENT_SECRET="${APIM_GATEWAY_CLIENT_SECRET:-}"
fi

if [[ -z "${OBO_CLIENT_SECRET:-}" ]]; then
  echo "❌  APIM Gateway client secret not found."
  echo "    Pass it as \$1 or set APIM_GATEWAY_CLIENT_SECRET in .env"
  echo "    To create a new secret: az ad app credential reset --id $APIM_GATEWAY_APP_ID --display-name apim-obo-secret --years 2"
  exit 1
fi

az account set --subscription "$AZURE_SUBSCRIPTION_ID"
echo "✅  Subscription set to $AZURE_SUBSCRIPTION_ID"

# ─────────────────────────────────────────────────────────────────────────────
# 0a. Configure APIM Gateway app registration.
#
# REQUIRED — without these settings Entra rejects token requests:
#   • identifierUris: api://<appId> — callers must reference the app by audience
#   • requestedAccessTokenVersion: 2 — ensures v2 JWT (with oid/sub/roles claims)
#   • APIM.Access app role — Foundry Project MI (and any M2M caller) needs this
#     role granted in order to receive a CC token for the APIM gateway resource
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── Step 0a: Configure APIM Gateway app registration ──────────────────────"

python3 - <<PYEOF
import json, subprocess, uuid, sys

app_id = "$APIM_GATEWAY_APP_ID"

app_raw = subprocess.check_output(
    ["az", "ad", "app", "show", "--id", app_id, "-o", "json"],
    stderr=subprocess.DEVNULL
)
app = json.loads(app_raw)
obj_id = app["id"]

changes = {}

# 1. identifierUris
expected_uri = f"api://{app_id}"
current_uris = app.get("identifierUris", [])
if expected_uri not in current_uris:
    print(f"   ➕  Adding identifierUri {expected_uri} ...")
    changes["identifierUris"] = list(set(current_uris + [expected_uri]))
else:
    print(f"   ✅  identifierUri already set")

# 2. requestedAccessTokenVersion = 2
current_ver = (app.get("api") or {}).get("requestedAccessTokenVersion")
if current_ver != 2:
    print(f"   ➕  Setting requestedAccessTokenVersion = 2 ...")
    changes.setdefault("api", {}).update({"requestedAccessTokenVersion": 2})
else:
    print(f"   ✅  requestedAccessTokenVersion already = 2")

# 3. APIM.Access app role
roles = app.get("appRoles", [])
role_val = "APIM.Access"
existing_role = next((r for r in roles if r.get("value") == role_val), None)
if not existing_role:
    print(f"   ➕  Adding app role {role_val} ...")
    new_role = {
        "allowedMemberTypes": ["Application"],
        "description": "Allows applications to call the APIM MCP gateway",
        "displayName": "APIM MCP Access",
        "id": str(uuid.uuid4()),
        "isEnabled": True,
        "value": role_val,
    }
    updated_roles = roles + [new_role]
    changes["appRoles"] = updated_roles
    # Write the role ID to stdout so bash can capture it
    print(f"   APIM_ACCESS_ROLE_ID={new_role['id']}", file=sys.stderr)
else:
    print(f"   ✅  App role {role_val} already exists (id={existing_role['id']})")
    print(f"   APIM_ACCESS_ROLE_ID={existing_role['id']}", file=sys.stderr)

if changes:
    patch_body = json.dumps(changes)
    subprocess.check_call([
        "az", "rest", "--method", "PATCH",
        "--uri", f"https://graph.microsoft.com/v1.0/applications/{obj_id}",
        "--headers", "Content-Type=application/json",
        "--body", patch_body,
    ])
    print("   ✅  APIM Gateway app updated.")
else:
    print("   ✅  APIM Gateway app already fully configured.")
PYEOF

# Capture APIM.Access role ID for use in grants below
APIM_ACCESS_ROLE_ID=$(python3 - <<PYEOF 2>/dev/null
import json, subprocess
app = json.loads(subprocess.check_output(
    ["az", "ad", "app", "show", "--id", "$APIM_GATEWAY_APP_ID", "-o", "json"],
    stderr=subprocess.DEVNULL
))
r = next((r["id"] for r in app.get("appRoles", []) if r.get("value") == "APIM.Access"), "")
print(r)
PYEOF
)
echo "   APIM.Access role ID: ${APIM_ACCESS_ROLE_ID:-<not found>}"

# ─────────────────────────────────────────────────────────────────────────────
# 0b. Configure MCP CA app registration (set after deployment).
#
# REQUIRED — same as above: identifierUris + v2 tokens are required for the
# OBO/CC backend token exchange to produce a token the MCP CA will accept.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── Step 0b: Configure MCP CA app registration ─────────────────────────────"

python3 - <<PYEOF
import json, subprocess

app_id = "$MCP_APP_ID"

app_raw = subprocess.check_output(
    ["az", "ad", "app", "show", "--id", app_id, "-o", "json"],
    stderr=subprocess.DEVNULL
)
app = json.loads(app_raw)
obj_id = app["id"]

changes = {}

expected_uri = f"api://{app_id}"
current_uris = app.get("identifierUris", [])
if expected_uri not in current_uris:
    print(f"   ➕  Adding identifierUri {expected_uri} ...")
    changes["identifierUris"] = list(set(current_uris + [expected_uri]))
else:
    print(f"   ✅  identifierUri already set")

current_ver = (app.get("api") or {}).get("requestedAccessTokenVersion")
if current_ver != 2:
    print(f"   ➕  Setting requestedAccessTokenVersion = 2 ...")
    changes.setdefault("api", {}).update({"requestedAccessTokenVersion": 2})
else:
    print(f"   ✅  requestedAccessTokenVersion already = 2")

if changes:
    subprocess.check_call([
        "az", "rest", "--method", "PATCH",
        "--uri", f"https://graph.microsoft.com/v1.0/applications/{obj_id}",
        "--headers", "Content-Type=application/json",
        "--body", json.dumps(changes),
    ])
    print("   ✅  MCP CA app updated.")
else:
    print("   ✅  MCP CA app already fully configured.")
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# 1. Assign Mcp.Tools.ReadWrite.All to the APIM Gateway App SP on the MCP CA SP.
#    Needed for the client_credentials path (app-only / M2M tokens at APIM).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── Step 1: Assign Mcp.Tools.ReadWrite.All to APIM Gateway App SP ──────────"

EXISTING=$(az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${APIM_GATEWAY_SP_OBJECT_ID}/appRoleAssignments" \
  --query "value[?appRoleId=='${MCP_APP_ROLE_ID}' && resourceId=='${MCP_APP_SP_OBJECT_ID}'].id" \
  -o tsv 2>/dev/null || echo "")

if [[ -n "$EXISTING" ]]; then
  echo "   ✅  Mcp.Tools.ReadWrite.All already assigned to APIM Gateway App SP — skipping."
else
  echo "   ➕  Assigning Mcp.Tools.ReadWrite.All to APIM Gateway App SP…"
  az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${APIM_GATEWAY_SP_OBJECT_ID}/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{
      \"principalId\": \"${APIM_GATEWAY_SP_OBJECT_ID}\",
      \"resourceId\":  \"${MCP_APP_SP_OBJECT_ID}\",
      \"appRoleId\":   \"${MCP_APP_ROLE_ID}\"
    }" --output none
  echo "   ✅  Role assigned."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1b. Grant roles to Foundry Project Managed Identity.
#
# Two grants are required for the Foundry agent to call MCP through APIM:
#   • APIM.Access on APIM Gateway App SP  — lets the MI get a CC token for APIM
#   • Mcp.Tools.ReadWrite.All on MCP CA SP — lets the OBO backend token pass
#
# Set FOUNDRY_PROJECT_MI_OBJECT_ID (and optionally OLD_FOUNDRY_PROJECT_MI_OBJECT_ID)
# in .env to enable this step.
# ─────────────────────────────────────────────────────────────────────────────
grant_foundry_mi_roles() {
  local mi_oid="$1" label="$2"
  echo ""
  echo "── Step 1b: Grant roles to ${label} (${mi_oid}) ──"

  # Resolve the APIM Gateway App SP object ID from Graph
  APIM_SP_OID=$(az ad sp show --id "$APIM_GATEWAY_APP_ID" --query id -o tsv 2>/dev/null || echo "$APIM_GATEWAY_SP_OBJECT_ID")

  # Grant APIM.Access on APIM Gateway app (if role ID is known)
  if [[ -n "${APIM_ACCESS_ROLE_ID:-}" ]]; then
    EXISTING_APIM=$(az rest --method GET \
      --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${mi_oid}/appRoleAssignments" \
      --query "value[?appRoleId=='${APIM_ACCESS_ROLE_ID}' && resourceId=='${APIM_SP_OID}'].id" \
      -o tsv 2>/dev/null || echo "")
    if [[ -n "$EXISTING_APIM" ]]; then
      echo "   ✅  APIM.Access already granted to ${label} — skipping."
    else
      echo "   ➕  Granting APIM.Access to ${label}…"
      az rest --method POST \
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${mi_oid}/appRoleAssignments" \
        --headers "Content-Type=application/json" \
        --body "{
          \"principalId\": \"${mi_oid}\",
          \"resourceId\":  \"${APIM_SP_OID}\",
          \"appRoleId\":   \"${APIM_ACCESS_ROLE_ID}\"
        }" --output none
      echo "   ✅  APIM.Access granted."
    fi
  else
    echo "   ⚠️   APIM_ACCESS_ROLE_ID not found — skipping APIM.Access grant."
  fi

  # Grant Mcp.Tools.ReadWrite.All on MCP CA
  EXISTING_MCP=$(az rest --method GET \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${mi_oid}/appRoleAssignments" \
    --query "value[?appRoleId=='${MCP_APP_ROLE_ID}' && resourceId=='${MCP_APP_SP_OBJECT_ID}'].id" \
    -o tsv 2>/dev/null || echo "")
  if [[ -n "$EXISTING_MCP" ]]; then
    echo "   ✅  Mcp.Tools.ReadWrite.All already granted to ${label} — skipping."
  else
    echo "   ➕  Granting Mcp.Tools.ReadWrite.All to ${label}…"
    az rest --method POST \
      --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${mi_oid}/appRoleAssignments" \
      --headers "Content-Type=application/json" \
      --body "{
        \"principalId\": \"${mi_oid}\",
        \"resourceId\":  \"${MCP_APP_SP_OBJECT_ID}\",
        \"appRoleId\":   \"${MCP_APP_ROLE_ID}\"
      }" --output none
    echo "   ✅  Mcp.Tools.ReadWrite.All granted."
  fi
}

FOUNDRY_MI="${FOUNDRY_PROJECT_MI_OBJECT_ID:-}"
OLD_FOUNDRY_MI="${OLD_FOUNDRY_PROJECT_MI_OBJECT_ID:-}"

if [[ -n "$FOUNDRY_MI" ]]; then
  grant_foundry_mi_roles "$FOUNDRY_MI" "Foundry Project MI"
else
  echo ""
  echo "── Step 1b: Skipping — FOUNDRY_PROJECT_MI_OBJECT_ID not set in .env ──────"
  echo "   Set it after deployment and re-run to grant agent access."
fi

if [[ -n "$OLD_FOUNDRY_MI" ]]; then
  grant_foundry_mi_roles "$OLD_FOUNDRY_MI" "Old Foundry Project MI"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Ensure APIM instances have the obo-client-id and obo-client-secret NVs.
# ─────────────────────────────────────────────────────────────────────────────
upsert_nv() {
  local apim="$1" nv_id="$2" display="$3" value="$4" secret="$5"
  EXISTS=$(az apim nv show -g "$RESOURCE_GROUP" -n "$apim" --named-value-id "$nv_id" \
           --query "name" -o tsv 2>/dev/null || echo "")
  if [[ -n "$EXISTS" ]]; then
    echo "   ✅  $display already exists in $apim — skipping."
  else
    echo "   ➕  Creating $display in $apim…"
    az apim nv create -g "$RESOURCE_GROUP" -n "$apim" \
      --named-value-id "$nv_id" \
      --display-name   "$display" \
      --value          "$value" \
      $( [[ "$secret" == "true" ]] && echo "--secret true" || echo "" ) \
      --output none
    echo "   ✅  Created."
  fi
}

if [[ -n "$APIM_STANDARD" ]]; then
  echo ""
  echo "── Step 2: Sync named values to $APIM_STANDARD ───────────────────────────"
  upsert_nv "$APIM_STANDARD" "obo-client-id"     "obo-client-id"     "$APIM_GATEWAY_APP_ID" "false"
  upsert_nv "$APIM_STANDARD" "obo-client-secret" "obo-client-secret" "$OBO_CLIENT_SECRET"   "true"
else
  echo ""
  echo "── Step 2: Skipping named values — APIM_STANDARD_NAME not set in .env ────"
  echo "   Set it after deployment (APIM_STANDARD_NAME=apim-{token}) and re-run."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Apply the updated policy to configured APIM instances.
#
# Uses rawxml format (required — the policy contains C# expressions with & chars
# that must not be double-decoded). Substitutes placeholders before uploading.
# ─────────────────────────────────────────────────────────────────────────────
apply_policy() {
  local apim="$1"
  echo "   Applying policy to $apim…"

  API_ID=$(az apim api list -g "$RESOURCE_GROUP" -n "$apim" \
    --query "[?contains(path,'mcp')].name" -o tsv 2>/dev/null | head -1)

  if [[ -z "$API_ID" ]]; then
    echo "   ⚠️   No API with path containing 'mcp' found in $apim — skipping."
    return
  fi

  echo "      API id: $API_ID"

  POLICY_URI="https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${apim}/apis/${API_ID}/policies/policy?api-version=2024-05-01"

  TEMP_JSON=".apim-policy-${apim}.json"
  # Substitute tenant/app ID placeholders and use rawxml format.
  # rawxml is required because the policy uses C# with &amp; entities
  # that APIM decodes at compile time — using xml would double-decode them.
  python3 - <<PYEOF > "$TEMP_JSON"
import json
with open("$POLICY_FILE") as f:
    xml = f.read()
xml = xml.replace("APIM_TENANT_ID",      "$AZURE_TENANT_ID")
xml = xml.replace("APIM_GATEWAY_APP_ID", "$APIM_GATEWAY_APP_ID")
xml = xml.replace("MCP_CA_APP_ID",       "$MCP_APP_ID")
print(json.dumps({"properties": {"value": xml, "format": "rawxml"}}))
PYEOF

  az rest --method PUT \
    --uri "$POLICY_URI" \
    --body "@${TEMP_JSON}" \
    --output none

  rm -f "$TEMP_JSON"
  echo "   ✅  Policy applied to $apim ($API_ID)."
}

if [[ -n "$APIM_STANDARD" ]]; then
  echo ""
  echo "── Step 3: Apply policy to APIM instances ─────────────────────────────────"
  apply_policy "$APIM_STANDARD"
else
  echo ""
  echo "── Step 3: Skipping policy apply — APIM_STANDARD_NAME not set in .env ─────"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════════════════"
echo "✅  OBO auth setup complete."
echo ""
echo "   Auth chain:"
echo "   ┌─ MCP Client (CC or OBO token for api://$APIM_GATEWAY_APP_ID)"
echo "   │    sub == oid (app-only) → APIM client_credentials → MCP CA token"
echo "   │    sub != oid (user)     → APIM OBO               → MCP CA token"
echo "   └─ MCP CA validates v2 token, checks Mcp.Tools.ReadWrite.All role"
echo ""
echo "   Role requirements:"
echo "   • Foundry Project MI: must have APIM.Access on APIM Gateway app"
echo "     AND Mcp.Tools.ReadWrite.All on MCP CA app."
echo "   • APIM Gateway App SP: must have Mcp.Tools.ReadWrite.All on MCP CA."
echo ""
if [[ -n "${APIM_STANDARD:-}" ]]; then
  APIM_URL=$(az apim show -g "$RESOURCE_GROUP" -n "$APIM_STANDARD" --query properties.gatewayUrl -o tsv 2>/dev/null || echo "https://apim-<token>.azure-api.net")
  echo "   AI Foundry MCP tool configuration:"
  echo "   ┌─ Server URL : ${APIM_URL}/mcp"
  echo "   └─ Auth scope : api://${APIM_GATEWAY_APP_ID}/.default"
fi
echo "══════════════════════════════════════════════════════════════════════════"
