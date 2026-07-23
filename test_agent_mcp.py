"""
End-to-end test: AI Foundry Agent → APIM (APIMAIgatewayAzure) → Azure MCP Server

Flow:
  1. [Phase 1] Direct APIM→MCP test — verify the gateway works standalone
  2. [Phase 2] Create/reuse a Foundry agent with MCP tool pointed at APIM
  3. [Phase 3] Run a thread and trace tool calls through the full chain

Auth chain:
  - Inbound (caller → APIM): Bearer token for api://<APIM_GATEWAY_APP_ID>
  - Outbound (APIM → MCP):  Token obtained by APIM via send-request to /oauth2/v2.0/token:
      • delegated token (idtyp≠app): OBO grant — caller identity flows to MCP CA
      • app-only token  (idtyp=app):  client_credentials — APIM app SP identity used

Usage:
  python test_agent_mcp.py              # full run (all 3 phases)
  python test_agent_mcp.py --phase 1   # APIM→MCP only
  python test_agent_mcp.py --phase 2   # create/show agent config only
  python test_agent_mcp.py --phase 3   # run conversation thread only

Config: all values are read from environment variables. Copy .env.example → .env and fill in.
"""

import argparse
import json
import os
import sys
import time

# Load .env if present (no external dependency — simple manual parse)
_env_path = os.path.join(os.path.dirname(__file__), ".env")
if os.path.isfile(_env_path):
    with open(_env_path) as _f:
        for _line in _f:
            _line = _line.strip()
            if _line and not _line.startswith("#") and "=" in _line:
                _k, _v = _line.split("=", 1)
                os.environ.setdefault(_k.strip(), _v.strip())

import requests
from azure.identity import AzureCliCredential, DefaultAzureCredential
from azure.ai.agents import AgentsClient
from azure.ai.agents.models import (
    McpTool,
    MCPToolDefinition,
    MessageRole,
    RunStatus,
    RequiredMcpToolCall,
    RunStepMcpToolCall,
    ToolApproval,
)

# Agent Governance Toolkit (AGT) — optional, opt-in governance layer.
# Only imported when actually needed (--governed / GOVERNANCE_ENABLED) so the
# default (ungoverned) path has zero new dependency requirements.
try:
    from agentmesh.governance import govern, GovernanceDenied
except ImportError:
    govern = None
    GovernanceDenied = Exception  # placeholder so `except GovernanceDenied` still parses


def _require(var: str) -> str:
    val = os.environ.get(var, "")
    if not val:
        print(f"❌  {var} is not set. Add it to your .env file (see .env.example).")
        sys.exit(1)
    return val


# ── Config ─────────────────────────────────────────────────────────────────────
TENANT_ID        = _require("AZURE_TENANT_ID")
SUBSCRIPTION_ID  = _require("AZURE_SUBSCRIPTION_ID")
RESOURCE_GROUP   = os.environ.get("RESOURCE_GROUP", "rg-agenttest")
PROJECT_NAME     = os.environ.get("FOUNDRY_PROJECT_NAME", "")

# APIM gateway that fronts the MCP server
APIM_GATEWAY_URL = os.environ.get("APIM_GATEWAY_URL", "")
MCP_VIA_APIM_URL = f"{APIM_GATEWAY_URL}/mcp" if APIM_GATEWAY_URL else ""

# App registration that APIM validates tokens against (inbound auth)
APIM_APP_ID      = _require("APIM_GATEWAY_APP_ID")
APIM_TOKEN_SCOPE = f"api://{APIM_APP_ID}/.default"

# AI Foundry project endpoint
AI_SERVICES_NAME = os.environ.get("AI_SERVICES_NAME", "")
AI_PROJECT_NAME  = os.environ.get("AI_PROJECT_NAME", "")
FOUNDRY_ENDPOINT = (
    f"https://{AI_SERVICES_NAME}.services.ai.azure.com/api/projects/{AI_PROJECT_NAME}"
    if AI_SERVICES_NAME and AI_PROJECT_NAME else ""
)

# Agent config
AGENT_NAME        = os.environ.get("AGENT_NAME", "azure-assitant")
AGENT_MODEL       = os.environ.get("AGENT_MODEL", "gpt-4.1")
AGENT_INSTRUCTIONS = (
    "You are a helpful Azure assistant. "
    "You have access to an Azure MCP server which can list and inspect Azure resources. "
    "Use MCP tools when the user asks about Azure resources, subscriptions, or services."
)
TEST_MESSAGE = "Using the MCP tools available to you, list the resource groups in the Azure subscription under the tenant:  bf9dbca7-0b29-484e-b213-891ff18de01f and subscription: 276feb32-98b6-4602-90b0-4f5b72e60b35 ."

# Governance (Agent Governance Toolkit demo — see docs/governance-demo.md).
# Opt-in via --governed CLI flag (set in main()) or GOVERNANCE_ENABLED in .env.
GOVERNANCE_ENABLED = os.environ.get("GOVERNANCE_ENABLED", "").strip().lower() in ("1", "true", "yes")
GOVERNANCE_POLICY_FILE = os.path.join(os.path.dirname(__file__), "policies", "governance-policy.yaml")
# ──────────────────────────────────────────────────────────────────────────────


def get_apim_token(credential) -> str:
    """Acquire a bearer token for the APIM gateway app (inbound auth)."""
    print(f"  Acquiring token for scope: {APIM_TOKEN_SCOPE}")
    token = credential.get_token(APIM_TOKEN_SCOPE, tenant_id=TENANT_ID)
    print(f"  ✅ Token acquired (expires: {token.expires_on})")
    return token.token


def _governed_mcp_call(request_fn, *args, **kwargs):
    """
    Optionally wrap an MCP request function with AGT governance.

    When governance is disabled (default), calls request_fn unchanged — zero
    behavior change from the pre-governance code path. When enabled, evaluates
    the call against policies/governance-policy.yaml before it runs; a denied
    call raises GovernanceDenied *before* any HTTP request is made.
    """
    if not GOVERNANCE_ENABLED:
        return request_fn(*args, **kwargs)

    if govern is None:
        print("  ⚠️  GOVERNANCE_ENABLED is set but agent-governance-toolkit is not installed.")
        print("     Run: pip install -r requirements-governance.txt")
        raise SystemExit(1)

    governed_fn = govern(request_fn, policy=GOVERNANCE_POLICY_FILE)
    return governed_fn(*args, **kwargs)


def phase1_test_apim_mcp(credential):
    """
    Phase 1: Direct HTTP test of APIM → MCP gateway.
    Calls the MCP initialize + tools/list to confirm the full chain works.
    """
    print("\n" + "="*60)
    print("PHASE 1: Direct APIM → MCP test")
    print("="*60)

    token = get_apim_token(credential)
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }

    # 1a. Check PRM discovery (no auth needed)
    print(f"\n[1a] GET {MCP_VIA_APIM_URL}/.well-known/oauth-protected-resource")
    resp = requests.get(
        f"{MCP_VIA_APIM_URL}/.well-known/oauth-protected-resource",
        timeout=10
    )
    print(f"     Status: {resp.status_code}")
    if resp.ok:
        print(f"     PRM: {json.dumps(resp.json(), indent=6)}")

    # 1b. MCP initialize handshake
    print(f"\n[1b] POST {MCP_VIA_APIM_URL} — initialize")
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "test-client", "version": "1.0"}
        }
    }
    resp = requests.post(MCP_VIA_APIM_URL, json=payload, headers=headers, timeout=15)
    print(f"     Status: {resp.status_code}")
    if resp.status_code == 401:
        print("     ❌ 401 Unauthorized — check token audience / app role assignment")
        return False
    if resp.status_code == 502:
        try:
            err = resp.json()
            print(f"     ❌ 502 Bad Gateway — APIM token exchange failed:")
            print(f"        {err.get('message', resp.text[:300])}")
            print(f"        Checklist:")
            print(f"          • obo-client-id/obo-client-secret named values set in both APIM instances?")
            print(f"          • APIM Gateway App SP has Mcp.Tools.ReadWrite on MCP CA?")
            print(f"          • Run ./setup-obo-auth.sh to configure prerequisites.")
        except Exception:
            print(f"     ❌ 502: {resp.text[:300]}")
        return False
    if not resp.ok:
        print(f"     ❌ Unexpected: {resp.text[:300]}")
        return False

    # Handle streamed or direct JSON response
    session_id = None
    body_text = resp.text
    for line in body_text.splitlines():
        if line.startswith("data:"):
            try:
                data = json.loads(line[5:].strip())
                if data.get("id") == 1 and "result" in data:
                    print(f"     ✅ MCP server: {data['result'].get('serverInfo', {})}")
                    # Extract session ID from response headers if present
                    session_id = resp.headers.get("mcp-session-id")
                    print(f"     Session-ID: {session_id}")
            except json.JSONDecodeError:
                pass
        elif line.strip().startswith("{"):
            try:
                data = json.loads(line.strip())
                if "result" in data:
                    print(f"     ✅ MCP server: {data['result'].get('serverInfo', {})}")
                    session_id = resp.headers.get("mcp-session-id")
            except json.JSONDecodeError:
                pass

    # 1c. List available tools
    print(f"\n[1c] POST {MCP_VIA_APIM_URL} — tools/list")
    if session_id:
        headers["mcp-session-id"] = session_id

    payload = {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}

    def list_resource_groups(action="list_resource_groups"):
        # Named to match the "safe/read" side of policies/governance-policy.yaml
        # (never matches the destructive-action deny rule, so it is always
        # allowed — this is the real MCP call the --governed flag demonstrates).
        # `action` is passed through so govern() can evaluate action.type
        # (AGT derives policy context from the call's `action=` kwarg).
        return requests.post(MCP_VIA_APIM_URL, json=payload, headers=headers, timeout=15)

    if GOVERNANCE_ENABLED:
        print("     🛡️  Governance enabled — evaluating call against policy before sending...")
        try:
            resp = _governed_mcp_call(list_resource_groups, action="list_resource_groups")
        except GovernanceDenied as exc:
            print(f"     ⛔ Governance denied this call before it reached APIM: {exc}")
            return False
    else:
        resp = list_resource_groups()
    print(f"     Status: {resp.status_code}")

    tools = []
    body_text = resp.text
    for line in body_text.splitlines():
        chunk = line[5:].strip() if line.startswith("data:") else line.strip()
        if not chunk:
            continue
        try:
            data = json.loads(chunk)
            if "result" in data and "tools" in data["result"]:
                tools = data["result"]["tools"]
                print(f"     ✅ {len(tools)} tools available:")
                for t in tools[:10]:
                    print(f"        • {t['name']}: {t.get('description','')[:70]}")
                if len(tools) > 10:
                    print(f"        ... and {len(tools)-10} more")
        except json.JSONDecodeError:
            pass

    return True


def _build_mcp_tool_with_auth(token: str):
    """
    Build McpTool with the APIM Bearer token injected into tool_resources headers.
    The 'headers' field lives in tool_resources.mcp[n], not in the tool definition,
    so the API accepts it without complaining about unknown parameters.
    """
    mcp_tool = McpTool(
        server_label="azure_mcp_via_apim",
        server_url=MCP_VIA_APIM_URL,
        allowed_tools=[],
    )
    # Inject Authorization header into the MCP resource entry
    for resource_entry in mcp_tool.resources.get("mcp", []):
        resource_entry["headers"] = {"Authorization": f"Bearer {token}"}
    return mcp_tool


def phase2_create_or_get_agent(agents_client: AgentsClient, token: str) -> str:
    """
    Phase 2: Create (or replace) the azure-agent-helper agent configured with
    MCP tool pointing to APIM, with a fresh Bearer token injected as a header.
    The agent is deleted and recreated on each run to keep the token fresh.
    Returns the agent ID.
    """
    print("\n" + "="*60)
    print("PHASE 2: Create / reuse Foundry agent with APIM MCP tool")
    print("="*60)

    # Delete existing agent so we can recreate with a fresh token in the header.
    # NOTE: collect matches first, then delete — deleting while the paged
    # `list_agents()` iterator is still active corrupts its continuation
    # token and raises a spurious ResourceNotFoundError on the next page.
    print(f"\n  Looking for existing agent '{AGENT_NAME}'...")
    stale_agent_ids = [agent.id for agent in agents_client.list_agents() if agent.name == AGENT_NAME]
    for stale_id in stale_agent_ids:
        print(f"  🗑  Deleting stale agent {stale_id} (token refresh)")
        agents_client.delete_agent(stale_id)

    # Create the agent with MCP tool pointed at APIM, token in headers
    print(f"  Creating agent '{AGENT_NAME}' with fresh APIM Bearer token...")
    mcp_tool = _build_mcp_tool_with_auth(token)

    agent = agents_client.create_agent(
        model=AGENT_MODEL,
        name=AGENT_NAME,
        instructions=AGENT_INSTRUCTIONS,
        tools=mcp_tool.definitions,
        tool_resources=mcp_tool.resources,
    )

    print(f"  ✅ Agent created: {agent.id}")
    print(f"     Name:  {agent.name}")
    print(f"     Model: {agent.model}")
    print(f"     MCP:   {MCP_VIA_APIM_URL}")
    return agent.id


def phase3_run_conversation(agents_client: AgentsClient, agent_id: str, credential):
    """
    Phase 3: Run a conversation thread and trace MCP tool calls.
    """
    print("\n" + "="*60)
    print("PHASE 3: Run agent conversation → trace MCP tool calls")
    print("="*60)

    # Acquire APIM token to pass as header for MCP calls during the run
    token = get_apim_token(credential)

    print(f"\n  Creating thread and sending message:")
    print(f"  > {TEST_MESSAGE}")

    # Create thread
    thread = agents_client.threads.create()
    print(f"  Thread ID: {thread.id}")

    # Add user message
    agents_client.messages.create(
        thread_id=thread.id,
        role=MessageRole.USER,
        content=TEST_MESSAGE,
    )

    # Pass the APIM Bearer token in tool_resources at run level.
    # The Foundry backend uses these headers when calling the MCP server
    # for tool discovery and execution.  Headers in the agent definition are
    # silently dropped by the API, so run-level tool_resources is the correct place.
    mcp_tool_resources = {
        "mcp": [
            {
                "server_label": "azure_mcp_via_apim",
                "headers": {"Authorization": f"Bearer {token}"},
            }
        ]
    }
    run = agents_client.runs.create(
        thread_id=thread.id,
        agent_id=agent_id,
        tool_resources=mcp_tool_resources,
    )
    print(f"  Run ID: {run.id}  (status: {run.status})")

    # Poll until terminal state
    print("\n  Polling run status...")
    while run.status in (RunStatus.QUEUED, RunStatus.IN_PROGRESS, RunStatus.REQUIRES_ACTION):

        if run.status == RunStatus.REQUIRES_ACTION:
            # Handle MCP tool approval if required
            required_actions = run.required_action.submit_tool_approval.tool_calls
            tool_approvals = []
            for tool_call in required_actions:
                if isinstance(tool_call, RequiredMcpToolCall):
                    print(f"  ⚙️  MCP approval needed: {tool_call.name}")
                    # Auto-approve for testing
                    tool_approvals.append(
                        ToolApproval(
                            tool_call_id=tool_call.id,
                            approve=True,
                            headers={"Authorization": f"Bearer {token}"},
                        )
                    )
            if tool_approvals:
                run = agents_client.runs.submit_tool_outputs(
                    thread_id=thread.id,
                    run_id=run.id,
                    tool_approvals=tool_approvals,
                )

        time.sleep(2)
        run = agents_client.runs.get(thread_id=thread.id, run_id=run.id)
        print(f"  → {run.status}", end="", flush=True)

    print(f"\n  Final status: {run.status}")

    if run.status == RunStatus.FAILED:
        print(f"  ❌ Run failed: {run.last_error}")
        return

    # Show run steps — highlight MCP tool calls
    print("\n  Run steps:")
    steps = agents_client.run_steps.list(thread_id=thread.id, run_id=run.id)
    for step in steps:
        print(f"    [{step.type}] {step.status}")
        if step.step_details and hasattr(step.step_details, 'tool_calls'):
            for tc in step.step_details.tool_calls:
                if isinstance(tc, RunStepMcpToolCall):
                    print(f"      🔧 MCP Tool: {tc.name}")
                    print(f"         Input:  {json.dumps(tc.arguments, indent=10)[:200]}")
                    output_preview = str(tc.output or '')[:200]
                    print(f"         Output: {output_preview}")

    # Show final assistant message
    print("\n  Assistant response:")
    messages = agents_client.messages.list(thread_id=thread.id)
    for msg in messages:
        if msg.role == MessageRole.AGENT:
            for content in msg.content:
                if hasattr(content, 'text'):
                    print(f"\n  {content.text.value}")
            break


def main():
    global GOVERNANCE_ENABLED

    parser = argparse.ArgumentParser(description="Test Agent → APIM → MCP flow")
    parser.add_argument("--phase", type=int, choices=[1, 2, 3], default=0,
                        help="Run a specific phase only (default: all)")
    parser.add_argument("--governed", action="store_true",
                        help="Wrap MCP tool calls with Agent Governance Toolkit "
                             "(policies/governance-policy.yaml) before they reach APIM. "
                             "Same effect as setting GOVERNANCE_ENABLED=true in .env. "
                             "See docs/governance-demo.md.")
    args = parser.parse_args()

    if args.governed:
        GOVERNANCE_ENABLED = True

    print("Azure Agent → APIM → MCP end-to-end test")
    print(f"  APIM MCP URL : {MCP_VIA_APIM_URL or '(not set — add APIM_GATEWAY_URL to .env)'}")
    print(f"  Foundry proj : {PROJECT_NAME or '(not set)'}")
    print(f"  Agent name   : {AGENT_NAME}")
    print(f"  Model        : {AGENT_MODEL}")
    print(f"  Governance   : {'enabled ✅' if GOVERNANCE_ENABLED else 'disabled (default)'}")

    if not MCP_VIA_APIM_URL:
        print("❌  APIM_GATEWAY_URL is not set in .env — required for all phases.")
        sys.exit(1)

    # Use AzureCliCredential for local testing (falls back to DefaultAzureCredential)
    try:
        credential = AzureCliCredential(tenant_id=TENANT_ID)
        # Quick smoke-test
        credential.get_token("https://management.azure.com/.default", tenant_id=TENANT_ID)
        print("\n  Auth: AzureCliCredential ✅")
    except Exception:
        credential = DefaultAzureCredential()
        print("\n  Auth: DefaultAzureCredential")

    run_all = args.phase == 0

    # Phase 1: Direct APIM → MCP test
    if run_all or args.phase == 1:
        ok = phase1_test_apim_mcp(credential)
        if not ok and run_all:
            print("\n⛔ Phase 1 failed — fix APIM/MCP connectivity before proceeding.")
            sys.exit(1)

    # Phase 2 & 3 need the Foundry agents client
    if run_all or args.phase in (2, 3):
        if not FOUNDRY_ENDPOINT:
            print("❌  AI_SERVICES_NAME and AI_PROJECT_NAME must be set in .env for phases 2 and 3.")
            sys.exit(1)
        agents_client = AgentsClient(
            endpoint=FOUNDRY_ENDPOINT,
            credential=credential,
        )

        # Always acquire a fresh APIM token for the agent header
        apim_token = get_apim_token(credential)

        if run_all or args.phase == 2:
            agent_id = phase2_create_or_get_agent(agents_client, apim_token)
        else:
            # Phase 3 only — recreate agent with fresh token
            agent_id = phase2_create_or_get_agent(agents_client, apim_token)

        if run_all or args.phase == 3:
            phase3_run_conversation(agents_client, agent_id, credential)

    print("\n✅ Test complete.")


if __name__ == "__main__":
    main()
