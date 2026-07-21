# Agent Governance Toolkit Demo

This repo includes a light-footprint demo of Microsoft's open-source
[**Agent Governance Toolkit (AGT)**](https://github.com/microsoft/agent-governance-toolkit),
showing how to add deterministic, auditable policy enforcement in front of
Azure MCP tool calls — without changing the existing Bicep infrastructure or
requiring a redeploy.

## Why AGT?

Prompt-level safety ("please follow the rules") is not a control surface —
it's a polite request to a stochastic system. AGT intercepts tool calls in
deterministic application code *before* the model's intent reaches the wire,
evaluates them against a YAML policy, and produces a tamper-evident decision
record. Actions the policy denies are not "unlikely" — they are **structurally
impossible**.

In this repo's architecture (**AI Foundry Agent → APIM gateway → Azure MCP
Server**), the MCP server itself is a prebuilt Microsoft container image
(`mcr.microsoft.com/azure-sdk/azure-mcp:latest`) we don't own the internals
of — so governance is applied at the layer we *do* control: the client-side
code that issues MCP tool calls.

## What's included

| File | Purpose |
|---|---|
| `policies/governance-policy.yaml` | Single shared policy: allow-by-default, deny destructive actions (`delete`, `drop`, `truncate`, `delete_resource_group`) |
| `demo_governance.py` | Standalone demo — no Azure deployment required |
| `test_agent_mcp.py --governed` | Opt-in governance mode wired into the real Foundry Agent → APIM → MCP flow |
| `requirements-governance.txt` | `agent-governance-toolkit[full]` — the only new dependency |

## 1. Standalone demo (no Azure deployment required)

This is the fastest way to see AGT in action — it always works, even if the
Azure resources in this repo aren't deployed.

```bash
pip install -r requirements-governance.txt
python demo_governance.py
```

**What you'll see**:
1. An **ALLOW** decision — a real Azure MCP `tools/list` call (through the
   deployed APIM gateway, if `.env` is configured) proceeds normally.
   If `.env` isn't configured yet, this step is skipped with a clear message
   so the rest of the demo still runs.
2. A **DENY** decision — a safe, local stub representing a destructive
   action (`delete_resource_group`) is blocked by AGT *before* anything
   executes, with the matched policy rule name and description printed.

No real destructive Azure call is ever made — the standard Azure MCP server
surface is deliberately read/list-oriented and doesn't expose a generic
"delete resource group" tool, so the deny path uses a safe stub. This proves
the enforcement mechanics (rule match → `GovernanceDenied` → audit output)
identically to how it would work against a real destructive tool.

## 2. Governed end-to-end flow (`test_agent_mcp.py --governed`)

To see governance applied to the *real* deployed architecture (the same flow
described in the main [README](../README.md)):

```bash
# Default — unchanged behavior, no governance
python test_agent_mcp.py --phase 1

# Governed — same call, now evaluated against policies/governance-policy.yaml
python test_agent_mcp.py --phase 1 --governed
```

You can also set `GOVERNANCE_ENABLED=true` in `.env` instead of passing
`--governed` every time.

With governance enabled, the `tools/list` call is wrapped with
`agentmesh.governance.govern()` before the HTTP request is sent to APIM. The
call is a safe/read action, so it is allowed exactly as before — governance
adds a visible "evaluating call against policy" log line but changes nothing
about the request or response. Denied calls (per the same shared policy)
would be stopped locally, before any request reaches APIM.

## 3. Validate the policy with the AGT CLI

AGT ships a CLI (`agt`) for auditing governance coverage independent of any
single demo run:

```bash
agt doctor                              # confirm the AGT install is healthy
agt lint-policy policies/                # validate governance-policy.yaml
agt verify                              # OWASP-style compliance/coverage report
```

All three should complete with no errors against
`policies/governance-policy.yaml`. This is a good "trust but verify" moment
in a live demo — it shows governance isn't just a runtime side-effect, it's
something you can audit and prove independently.

## Editing the policy

`policies/governance-policy.yaml` is a single, self-contained file used by
*both* demo surfaces above — edit it once and both pick up the change:

```yaml
apiVersion: governance.toolkit/v1
name: azure-mcp-demo-policy
default_action: allow
rules:
  - name: block-destructive-azure-actions
    condition: "action.type in ['delete_resource_group', 'drop', 'delete', 'truncate']"
    action: deny
    description: "Destructive Azure operations are blocked in this demo"
    priority: 100
```

Try adding a `require_approval` rule, or changing `default_action` to see how
the demo's behavior changes — that's the point of showing this live.

## What's next (out of scope for this demo)

AGT's full stack includes an MCP Security Gateway (tool poisoning/drift
detection), a real-time Governance Dashboard, Shadow AI Discovery, and
framework adapters for LangChain/AutoGen/CrewAI/etc. None of these are wired
up here — this demo intentionally stays as light as possible to prove the
core value (`govern()` + a YAML policy) first. See the
[Agent Governance Toolkit README](https://github.com/microsoft/agent-governance-toolkit)
for the full capability set.
