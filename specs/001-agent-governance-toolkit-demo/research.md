# Phase 0 Research: Agent Governance Toolkit Demo

## 1. Which AGT distribution/API to use

**Decision**: Install `agent-governance-toolkit[full]` from PyPI and use the `agentmesh.governance.govern()` quick-start wrapper as the primary integration point for both demo surfaces. Use the CLI (`agt doctor`, `agt lint-policy`, `agt verify`) for User Story 3.

**Rationale**:
- Python is AGT's primary/most complete implementation (per `docs/PACKAGE-FEATURE-MATRIX.md`) and the only language already used in this repo (`test_agent_mcp.py`, `azure-identity`, `azure-ai-agents`).
- `govern()` is a 2-line wrapper (`safe_tool = govern(my_tool, policy="policy.yaml")`) — the lightest possible integration surface, matching the "as light as possible" requirement (FR-001, SC-004), versus the more verbose `PolicyEvaluator`/`PolicyDocument` construction API which requires building Python objects instead of just pointing at a YAML file.
- The `[full]` extra bundles the consolidated `agent-governance-toolkit-core` distribution (current, non-deprecated) plus the `agt` CLI (part of `agent-compliance`), so a single `pip install agent-governance-toolkit[full]` covers every capability the spec needs.
- The `agent_os.policies.PolicyEvaluator` path is flagged by AGT's own docs as "legacy compatibility" (emits `DeprecationWarning` on import). We avoid it to keep the demo forward-compatible with AGT's stated direction ("prefer the AGT 5 `agt-policies`/ACS APIs for new policy-engine host code").

**Alternatives considered**:
- `PolicyEvaluator` API (`agent_os.policies`): rejected as primary path — more code, deprecated import path, no material benefit for a 2-call demo. Can be mentioned as a "going further" callout in docs for teams wanting programmatic policy construction.
- TypeScript/.NET/Rust/Go SDKs: rejected — no existing runtime for these languages in this repo; would add net-new toolchain dependencies purely for the demo.
- LangChain/AutoGen/CrewAI framework adapters: rejected — this repo's agent code talks to Azure AI Foundry's `AgentsClient` + raw MCP JSON-RPC directly, not through one of AGT's supported framework adapters. The generic `govern()` wrapper works with any Python callable, so no adapter is needed.

## 2. What "governed tool calls" represent, given the real MCP server is a prebuilt image

**Decision**: The demo governs two **local Python callables** that stand in for Azure MCP tool actions, rather than trying to intercept traffic inside the `mcr.microsoft.com/azure-sdk/azure-mcp:latest` container image:
- An **ALLOW** example: a thin function that performs the real, already-working "list resource groups" MCP call (reusing the existing `phase1`-style JSON-RPC `tools/list`/`tools/call` pattern from `test_agent_mcp.py`) — this is a genuine Azure MCP tool invocation.
- A **DENY** example: a locally-defined stub function named to represent a destructive action (e.g. `delete_resource_group(name: str)`), governed by the same policy. It is intentionally **not** wired to a real Azure MCP "delete" tool call, because the standard Azure MCP server surface is deliberately read/list-oriented and does not expose a generic destructive "delete resource group" tool by default. Governing a stub keeps the DENY path 100% safe to demo (never risks a real destructive Azure call) while still proving AGT's enforcement mechanics (rule match, `GovernanceDenied`, audit record) identically to how it would work against a real destructive tool if one existed.

**Rationale**: This satisfies FR-001/FR-003/FR-008 and SC-003 ("100% of destructive/denied tool call attempts ... blocked before any real Azure/MCP/APIM call is attempted") in the safest, lightest way — governance is proven functionally without depending on undocumented or risky live Azure operations. It also sidesteps needing to discover/confirm exact live tool names for a destructive action that may not exist in the deployed MCP server's tool catalog.

**Alternatives considered**:
- Governing a real destructive Azure MCP tool call: rejected — no such tool is confirmed to exist in the standard Azure MCP server catalog (which is read/list-heavy for safety), and even if one did, exercising it live in a demo would be operationally risky and require production Azure resources the demo should not depend on (FR-004 — no infra changes/redeploy required).
- Mocking both allow and deny calls (no real Azure call at all): rejected — using one real MCP call (list resource groups) for the ALLOW path makes the demo more credible and directly ties to the existing architecture, satisfying User Story 2's intent, while keeping the DENY path safe.

## 3. Where the governed call path plugs into `test_agent_mcp.py`

**Decision**: Add a small `_governed_mcp_call(...)` helper (or wrap the existing tool-dispatch call site) that:
1. Loads the shared `policies/governance-policy.yaml`.
2. Wraps the specific function that issues the MCP `tools/call` HTTP request to APIM (the function already used in Phase 1's `tools/list`/`tools/call` flow) with `govern(..., policy=...)`.
3. Is only active when `--governed` is passed on the CLI or `GOVERNANCE_ENABLED=true` is set in `.env` — mirroring the existing `.env`-driven config pattern already used for `AZURE_TENANT_ID`, `APIM_GATEWAY_URL`, etc.
4. When a call is denied, catches `GovernanceDenied`, prints the rule name/description, and exits that phase gracefully (no unhandled stack trace), rather than sending anything to APIM.

**Rationale**: Keeps default behavior of `test_agent_mcp.py` completely unchanged (FR-009/SC-005) since the wrapper is purely additive and opt-in. Follows the file's existing conventions (env-driven config, `_require()`-style helpers, phase-based prints) instead of introducing a new pattern.

**Alternatives considered**:
- A separate copy of `test_agent_mcp.py` (e.g. `test_agent_mcp_governed.py`): rejected — duplicates ~430 lines of existing code, harder to keep in sync, and contradicts "as light as possible."
- Governing at the APIM policy layer (XML policy) instead of client-side Python: rejected — AGT is a Python (or SDK-language) library, not something expressible as an APIM inbound policy; this would require reimplementing policy evaluation in XML, which is neither light nor faithful to what AGT actually provides.

## 4. Policy file shape

**Decision**: A single `policies/governance-policy.yaml` at repo root (not nested under `.specify/` or `demo/`), following AGT's documented schema exactly:

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

**Rationale**: Matches the exact schema shown in AGT's own README/quickstart (`apiVersion`, `name`, `default_action`, `rules[].{name,condition,action,description,priority}`), so it is trivially recognizable to anyone who has seen AGT's docs — reinforcing the demo's credibility. A single shared policy file is reused by both demo surfaces (standalone script and governed `test_agent_mcp.py` mode) to avoid duplication.

**Alternatives considered**: Two separate policy files (one per demo surface) — rejected, adds duplication with no benefit; a single shared policy is easier to reason about in a live demo ("one policy governs everything").

## 5. Documentation placement (resolves prior [NEEDS CLARIFICATION])

**Decision**: `docs/governance-demo.md` (new directory `docs/` at repo root) is the full walkthrough; `README.md` gets a new short section (below existing sections, ~5–8 lines) linking to it. Confirmed directly with the user during `/speckit.specify` clarification.

## Summary of resolved unknowns

| Unknown | Resolution |
|---|---|
| AGT distribution/API | `agent-governance-toolkit[full]` + `agentmesh.governance.govern()` |
| Real vs. simulated destructive call | ALLOW = real MCP list call; DENY = safe local stub, same enforcement guarantees |
| Integration point in `test_agent_mcp.py` | New opt-in helper wrapping the existing MCP `tools/call` site, gated by `--governed`/`GOVERNANCE_ENABLED` |
| Policy file location/shape | `policies/governance-policy.yaml`, matches AGT's documented schema verbatim |
| Docs placement | `docs/governance-demo.md` + short `README.md` pointer section (user-confirmed) |
