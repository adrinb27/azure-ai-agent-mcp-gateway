"""
Standalone demo: Agent Governance Toolkit (AGT) governing Azure MCP tool calls.

Requires no Azure deployment. Shows one governed ALLOW decision (a real Azure
MCP "list resource groups" call through the existing APIM gateway) and one
governed DENY decision (a safe local stub representing a destructive action),
both evaluated against policies/governance-policy.yaml.

See docs/governance-demo.md for the full walkthrough.

Usage:
    pip install -r requirements-governance.txt
    python demo_governance.py
"""

import json
import os
import sys

from agentmesh.governance import govern, GovernanceDenied

# Reuse this repo's existing .env-driven config pattern (see test_agent_mcp.py).
_env_path = os.path.join(os.path.dirname(__file__), ".env")
if os.path.isfile(_env_path):
    with open(_env_path) as _f:
        for _line in _f:
            _line = _line.strip()
            if _line and not _line.startswith("#") and "=" in _line:
                _k, _v = _line.split("=", 1)
                os.environ.setdefault(_k.strip(), _v.strip())

POLICY_FILE = os.path.join(os.path.dirname(__file__), "policies", "governance-policy.yaml")


def list_resource_groups(action: str = "list_resource_groups") -> dict:
    """
    ALLOW example: a real Azure MCP tool call (list resource groups) through
    the deployed APIM gateway, using the same JSON-RPC pattern as
    test_agent_mcp.py's phase1_test_apim_mcp. Requires APIM_GATEWAY_URL,
    AZURE_TENANT_ID, and APIM_GATEWAY_APP_ID to be set in .env; if they are
    not set, this call is skipped with a clear message so the rest of the
    demo (the DENY path) still runs standalone.
    """
    apim_url = os.environ.get("APIM_GATEWAY_URL", "")
    apim_app_id = os.environ.get("APIM_GATEWAY_APP_ID", "")
    tenant_id = os.environ.get("AZURE_TENANT_ID", "")
    if not (apim_url and apim_app_id and tenant_id):
        return {
            "skipped": True,
            "reason": "APIM_GATEWAY_URL / APIM_GATEWAY_APP_ID / AZURE_TENANT_ID not set in .env "
                      "— skipping the real Azure MCP call; the deny path below still works standalone.",
        }

    # Imported lazily so the demo still runs (and gracefully skips, above) even
    # if requests/azure-identity aren't installed and .env isn't configured yet.
    import requests
    from azure.identity import AzureCliCredential

    credential = AzureCliCredential(tenant_id=tenant_id)
    token = credential.get_token(f"api://{apim_app_id}/.default", tenant_id=tenant_id).token
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    payload = {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
    resp = requests.post(f"{apim_url}/mcp", json=payload, headers=headers, timeout=15)
    return {"status_code": resp.status_code, "body": resp.text[:500]}


def delete_resource_group(action: str, name: str) -> dict:
    """
    DENY example: a safe local stub representing a destructive Azure action.
    Deliberately makes NO network/Azure call — the standard Azure MCP server
    surface does not expose a generic destructive "delete resource group"
    tool, so this stub proves AGT's enforcement mechanics without any risk.

    ``action`` is required so govern() can evaluate it against the policy's
    `action.type` condition (AGT derives the policy context from the
    call's `action=` kwarg, not the function name).
    """
    return {"would_delete": name}


def main() -> int:
    safe_list = govern(list_resource_groups, policy=POLICY_FILE)
    safe_delete = govern(delete_resource_group, policy=POLICY_FILE)

    print("=" * 60)
    print("Agent Governance Toolkit demo — Azure MCP tool calls")
    print("=" * 60)

    print("\n[ALLOW] Calling governed list_resource_groups()...")
    result = safe_list(action="list_resource_groups")
    print(f"  \u2705 Allowed. Result: {json.dumps(result, indent=2)}")

    print("\n[DENY] Calling governed delete_resource_group('rg-demo')...")
    try:
        safe_delete(action="delete_resource_group", name="rg-demo")
        print("  \u274c Unexpected: call was NOT denied (check policy file).")
        return 1
    except GovernanceDenied as exc:
        print(f"  \u2705 Denied as expected: {exc}")

    print("\nDone. See docs/governance-demo.md for what this demonstrates.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
