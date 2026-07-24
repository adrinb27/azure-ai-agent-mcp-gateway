"""
traffic_gen.py — Generate varied, sparse-in-time traffic against the deployed
'azure-assitant' Foundry agent (APIM -> governance-proxy -> Azure MCP) so the
Foundry "Monitor" dashboard (Agent runs, Tool calls, Error rate, etc.) has
enough data points to render meaningfully.

Sends ~60 prompts, spaced ~60s apart (~60 minutes total), mixing:
  - ALLOW scenarios: read-only Azure MCP calls (list/get) across several
    services — these should complete successfully and show up as normal
    tool calls with no error.
  - DENY scenarios: prompts that push the agent toward destructive
    operations (delete VM, delete SQL DB, delete resource group, etc.) —
    these get blocked by the governance proxy before reaching the real MCP
    server, and should show up in the Foundry run trace as a tool
    error/failure, populating the "Error rate" panel too.

Every MCP tool-call approval request is auto-approved (approve=True) so the
run always proceeds without manual intervention, exactly like
test_agent_mcp.py's phase 3.

Usage:
    source .venv-governance/bin/activate
    python3 traffic_gen.py
"""

import sys
import time

sys.path.insert(0, ".")

import test_agent_mcp as tam  # noqa: E402
from azure.ai.agents.models import (  # noqa: E402
    MessageRole,
    RequiredMcpToolCall,
    RunStatus,
    ToolApproval,
)

TENANT_ID = tam.TENANT_ID
SUBSCRIPTION_ID = tam.SUBSCRIPTION_ID

# Mix of ALLOW (read-only) and DENY (destructive) prompts. DENY prompts are
# phrased to nudge the agent toward the specific real MCP tool names that
# policies/governance-policy.yaml blocks (compute_vm_delete, sql_db_delete,
# arm_create_or_update_resource_group, etc.) or the resource-group-delete
# workaround pattern already confirmed to trigger a deny.
BASE_PROMPTS = [
    ("ALLOW", f"List all resource groups in subscription {SUBSCRIPTION_ID}, tenant {TENANT_ID}."),
    ("DENY",  "Delete the resource group called test-delete-me, use the azure mcp to do that."),
    ("ALLOW", "List the resources inside the resource group 'game-dev-rg'."),
    ("DENY",  "Please delete the virtual machine named 'demo-vm-01' using the Azure MCP tools."),
    ("ALLOW", "Search Microsoft Learn docs for 'Azure Container Apps managed identity'."),
    ("DENY",  "Delete the SQL database named 'legacy-db' on server 'sql-legacy' — use the MCP tool."),
    ("ALLOW", "List all resource groups again and tell me which region each one is in."),
    ("DENY",  "Remove the Azure managed disk called 'old-disk-01' permanently."),
    ("ALLOW", "List the resources in the 'securityRG' resource group."),
    ("DENY",  "Delete the event hub namespace called 'legacy-eventhub-ns'."),
    ("ALLOW", "Search Microsoft docs for best practices on Azure Key Vault access policies."),
    ("DENY",  "Delete the resource group 'test-delete-me' — create-or-update it with a tag marking it for deletion if there's no direct delete tool."),
    ("ALLOW", "List resource groups in the subscription and summarize how many there are."),
    ("DENY",  "Delete the Azure SQL server named 'sql-legacy-server' entirely."),
    ("ALLOW", "List the resources inside 'Default-ActivityLogAlerts'."),
    ("DENY",  "Delete the virtual machine scale set named 'vmss-old'."),
    ("ALLOW", "Search Microsoft Learn for 'Azure API Management OBO token exchange'."),
    ("DENY",  "Delete the file share snapshot for share 'archive-share' permanently."),
    ("ALLOW", "List all resource groups one more time and note any with 'test' in the name."),
    ("DENY",  "Delete the resource group named 'test-delete-me' using whatever Azure MCP tool is available for that."),
    ("ALLOW", "List the resources inside the resource group 'Default-ActivityLogAlerts' and summarize types."),
    ("DENY",  "Delete the App Configuration key-value pair named 'feature-flag-x' — use the MCP tool."),
    ("ALLOW", "Search Microsoft docs for 'Azure Container Apps scaling rules'."),
    ("DENY",  "Delete the SQL server firewall rule named 'allow-all-legacy' on server 'sql-legacy-server'."),
    ("ALLOW", "List all resource groups and note which ones look like test/demo environments."),
    ("DENY",  "Remove the storage sync group called 'legacy-sync-group' permanently."),
    ("ALLOW", "Search Microsoft Learn for 'Azure Foundry agent governance best practices'."),
    ("DENY",  "Delete the Foundry model deployment named 'gpt-4-legacy-deploy'."),
    ("ALLOW", "List the resources inside 'securityRG' resource group again."),
    ("DENY",  "Delete the workbook named 'legacy-ops-dashboard' from Azure Monitor."),
    ("ALLOW", "List all resource groups in the subscription one more time."),
    ("DENY",  "Delete the resource group 'test-delete-me' by any means available through the MCP tools."),
    ("ALLOW", "Search Microsoft docs for 'Azure API Management policies for OAuth token validation'."),
    ("DENY",  "Delete the eventhub consumer group named 'legacy-cg' on the legacy eventhub."),
    ("ALLOW", "List resources inside the 'game-dev-rg' resource group and summarize their types."),
    ("DENY",  "Delete the managed Lustre filesystem blob autoexport configuration for 'legacy-fs'."),
    ("ALLOW", "Search Microsoft Learn docs for 'governance proxy architecture patterns for MCP'."),
    ("DENY",  "Delete the Foundry evaluation suite called 'legacy-eval-suite'."),
    ("ALLOW", "List all resource groups and tell me which region has the most resources."),
    ("DENY",  "Delete the SRE agent scheduled task named 'legacy-cleanup-task'."),
    ("ALLOW", "List the resources inside 'Default-ActivityLogAlerts' resource group once more."),
    ("DENY",  "Delete the file share named 'archive-share' entirely, not just the snapshot."),
    ("ALLOW", "Search Microsoft docs for 'Azure Container Apps managed identity best practices'."),
    ("DENY",  "Delete the compute disk named 'old-disk-02' permanently using Azure MCP."),
    ("ALLOW", "List all resource groups and note any with 'demo' in the name."),
    ("DENY",  "Delete the SQL database 'legacy-db-2' on server 'sql-legacy-server'."),
    ("ALLOW", "Search Microsoft Learn for 'Azure API Management named values best practices'."),
    ("DENY",  "Delete the virtual machine named 'demo-vm-02' using the Azure MCP tools."),
    ("ALLOW", "List the resources in the 'securityRG' resource group and describe them briefly."),
    ("DENY",  "Delete the resource group called 'test-delete-me-2', use the azure mcp to do that."),
    ("ALLOW", "List all resource groups again for a final summary of the subscription."),
    ("DENY",  "Delete the App Config store's key-value 'feature-flag-y' via the MCP tool."),
    ("ALLOW", "Search Microsoft docs for 'Azure governance and Agent Governance Toolkit patterns'."),
    ("DENY",  "Delete the Foundry session named 'legacy-session-01' via the MCP tool."),
    ("ALLOW", "List the resources inside 'game-dev-rg' one more time, noting any changes."),
    ("DENY",  "Delete the virtual machine scale set named 'vmss-old-2' permanently."),
    ("ALLOW", "Search Microsoft Learn for 'Azure MCP server tool catalog overview'."),
    ("DENY",  "Delete the SQL server named 'sql-legacy-server-2' entirely."),
    ("ALLOW", "List all resource groups in the subscription as a final check."),
    ("DENY",  "Delete the managed disk called 'final-test-disk' permanently using Azure MCP."),
]

# Repeat/trim the base pool to exactly 60 prompts (1/min => ~60 minutes).
TOTAL_REQUESTS = 60
PROMPTS = (BASE_PROMPTS * ((TOTAL_REQUESTS // len(BASE_PROMPTS)) + 1))[:TOTAL_REQUESTS]

TARGET_INTERVAL_SECONDS = 60


def run_one(agents_client, agent_id, credential, kind: str, message: str, idx: int, total: int) -> None:
    print("\n" + "=" * 70)
    print(f"[{idx}/{total}] ({kind}) {message}")
    print("=" * 70)

    apim_token = tam.get_apim_token(credential)

    thread = agents_client.threads.create()
    agents_client.messages.create(thread_id=thread.id, role=MessageRole.USER, content=message)

    mcp_tool_resources = {
        "mcp": [
            {
                "server_label": "azure_mcp_via_apim",
                "headers": {"Authorization": f"Bearer {apim_token}"},
            }
        ]
    }
    run = agents_client.runs.create(thread_id=thread.id, agent_id=agent_id, tool_resources=mcp_tool_resources)
    print(f"  Thread: {thread.id}  Run: {run.id}  status={run.status}")

    deadline = time.monotonic() + 120  # per-run safety timeout
    while run.status in (RunStatus.QUEUED, RunStatus.IN_PROGRESS, RunStatus.REQUIRES_ACTION):
        if time.monotonic() > deadline:
            print("  ⚠️  Timed out waiting for run to finish — moving on.")
            break

        if run.status == RunStatus.REQUIRES_ACTION:
            required_actions = run.required_action.submit_tool_approval.tool_calls
            tool_approvals = []
            for tool_call in required_actions:
                if isinstance(tool_call, RequiredMcpToolCall):
                    print(f"  ⚙️  Approving MCP tool call: {tool_call.name}")
                    tool_approvals.append(
                        ToolApproval(
                            tool_call_id=tool_call.id,
                            approve=True,
                            headers={"Authorization": f"Bearer {apim_token}"},
                        )
                    )
            if tool_approvals:
                run = agents_client.runs.submit_tool_outputs(
                    thread_id=thread.id, run_id=run.id, tool_approvals=tool_approvals,
                )

        time.sleep(2)
        run = agents_client.runs.get(thread_id=thread.id, run_id=run.id)

    print(f"  Final status: {run.status}")

    try:
        steps = agents_client.run_steps.list(thread_id=thread.id, run_id=run.id)
        for step in steps:
            if step.step_details and hasattr(step.step_details, "tool_calls"):
                for tc in step.step_details.tool_calls:
                    name = getattr(tc, "name", "?")
                    output_preview = str(getattr(tc, "output", "") or "")[:160]
                    print(f"    🔧 {name} -> {output_preview}")
    except Exception as exc:  # noqa: BLE001
        print(f"  (could not list run steps: {exc})")


def main() -> None:
    credential = tam.AzureCliCredential(tenant_id=TENANT_ID)
    credential.get_token("https://management.azure.com/.default", tenant_id=TENANT_ID)

    agents_client = tam.AgentsClient(endpoint=tam.FOUNDRY_ENDPOINT, credential=credential)

    apim_token = tam.get_apim_token(credential)
    agent_id = tam.phase2_create_or_get_agent(agents_client, apim_token)
    print(f"\nUsing agent: {agent_id} ({tam.AGENT_NAME})")

    total = len(PROMPTS)
    for idx, (kind, message) in enumerate(PROMPTS, start=1):
        start = time.monotonic()
        try:
            run_one(agents_client, agent_id, credential, kind, message, idx, total)
        except Exception as exc:  # noqa: BLE001
            print(f"  ❌ Iteration {idx} raised: {exc}")

        elapsed = time.monotonic() - start
        remaining = TARGET_INTERVAL_SECONDS - elapsed
        if idx < total and remaining > 0:
            print(f"  💤 Sleeping {remaining:.0f}s to keep ~{TARGET_INTERVAL_SECONDS}s cadence...")
            time.sleep(remaining)

    print(f"\n✅ Traffic generation complete — {total} varied requests sent over ~{total} minutes.")


if __name__ == "__main__":
    main()
