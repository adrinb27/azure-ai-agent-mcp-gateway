# Feature Specification: Agent Governance Toolkit Demo

**Feature Branch**: `001-agent-governance-toolkit-demo`

**Created**: 2026-07-21

**Status**: Draft

**Input**: User description: "I want to add the governance tool kit to this architecture: https://github.com/microsoft/agent-governance-toolkit. This is for me to use as a demo, so I want the implementation to be as light as possible, with clear examples that I can show the value using this opensource tool."

## Context

This repo (`azure-ai-agent-mcp-gateway`) is a POC wiring: **AI Foundry Agent → APIM gateway (OBO/CC token exchange) → Azure MCP Server (Container App, prebuilt Microsoft image `mcr.microsoft.com/azure-sdk/azure-mcp:latest`)**. The MCP server's internals are not owned by this repo — only the deployment (Bicep), gateway auth policy, and the `test_agent_mcp.py` end-to-end test script are.

The **Agent Governance Toolkit (AGT)** (`microsoft/agent-governance-toolkit`) adds a policy-enforcement layer (`govern()` / `PolicyEvaluator`) that intercepts tool calls in application code *before* they execute, evaluates a YAML policy (allow / deny / require-approval), and writes a tamper-evident audit/decision record. Because the actual MCP server binary is a prebuilt image we don't control, AGT cannot be injected inside it — it must sit at a layer we do own.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Demonstrate governed tool calls locally (Priority: P1)

As the repo owner running a live demo, I want a small standalone Python script that wraps representative Azure MCP tool calls (e.g., "list resource groups" vs. a destructive "delete resource group") with AGT's `govern()`, so I can show an audience a real ALLOW and a real DENY decision, plus the resulting audit record, in under a minute — without needing to touch or redeploy the existing Azure infrastructure.

**Why this priority**: This is the fastest path to a working, repeatable demo of AGT's core value (deterministic policy enforcement + audit trail) and requires no infra changes, so it can be built and shown first.

**Independent Test**: Run the demo script locally with no Azure deployment required (or against the already-deployed MCP server via the existing APIM test flow); observe one call ALLOWED and one call DENIED by policy, each producing a printed/logged decision record.

**Acceptance Scenarios**:

1. **Given** the AGT policy file allows "read" style Azure MCP tools (e.g., listing resource groups) and denies destructive ones (e.g., delete operations), **When** the demo script invokes a governed "list resource groups" call, **Then** the call executes normally and an ALLOW decision is logged.
2. **Given** the same policy, **When** the demo script invokes a governed destructive call (e.g., "delete resource group"), **Then** the call is blocked with a `GovernanceDenied` error before reaching Azure, and a DENY decision with the matched rule name is logged.

---

### User Story 2 - Wire governance into the real MCP call path via APIM/agent test script (Priority: P2)

As the repo owner, I want the existing `test_agent_mcp.py` end-to-end flow to optionally route its MCP tool calls through the AGT policy layer (client-side, before the request reaches APIM), so I can show governance enforcement in the context of the actual Foundry Agent → APIM → MCP Server chain, not just an isolated script.

**Why this priority**: Builds credibility of the demo by connecting AGT to the real deployed architecture, but is not required for the initial value demonstration and depends on User Story 1 being in place.

**Independent Test**: Run `test_agent_mcp.py` (or a thin wrapper around it) with governance enabled; confirm a benign MCP tool call proceeds through APIM as before, and a simulated/denied tool category is stopped locally (never sent to APIM) with a clear message.

**Acceptance Scenarios**:

1. **Given** governance is enabled for the test script, **When** an allowed MCP tool call is made through the Foundry Agent, **Then** the call reaches APIM/MCP exactly as it does today (no behavior change for allowed actions).
2. **Given** governance is enabled, **When** a denied tool/category is requested, **Then** the request is stopped before any network call to APIM and the denial + reason is printed.

---

### User Story 3 - One-command compliance/audit check for the demo (Priority: P3)

As the repo owner, I want to run AGT's built-in CLI checks (`agt doctor`, `agt verify`, `agt lint-policy`) against the demo's policy file, so I can show the audience that governance can be validated/audited independent of any single run.

**Why this priority**: Nice-to-have polish that reinforces the "prove what happened" pillar of AGT; not required for the core demo narrative.

**Independent Test**: Run `agt lint-policy policies/` and `agt verify` against the demo policy and confirm they pass and print a readable report.

**Acceptance Scenarios**:

1. **Given** a valid AGT policy YAML file in the repo, **When** `agt lint-policy` is run, **Then** it reports the policy as valid with no errors.

---

### Edge Cases

- What happens when the AGT package is not installed / `pip install` fails during the live demo (network issue)? → Demo instructions must include a pre-flight `agt doctor` check to run *before* presenting.
- How does the system handle a policy file with a syntax error? → `agt lint-policy` must be run as a pre-demo sanity check; the demo script should fail fast with a clear message rather than a stack trace.
- What happens if the real Azure MCP server / APIM deployment is not up at demo time? → User Story 1 (local-only) must work with zero dependency on the deployed Azure resources, so the demo has a fallback that always works.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The repo MUST provide a standalone, runnable demo script (Python) that governs at least two representative Azure MCP tool call shapes using AGT's `govern()`/`PolicyEvaluator`: one that is allowed and one that is denied.
- **FR-002**: The demo MUST include a policy file (YAML) checked into the repo, readable and self-explanatory (comments describing each rule) for an audience unfamiliar with AGT.
- **FR-003**: Denied calls MUST raise/surface AGT's `GovernanceDenied` (or equivalent) with the matched rule name and description, and this MUST be visibly printed by the demo script.
- **FR-004**: The demo MUST run without requiring any changes to existing Bicep infrastructure or a redeploy of the Container App / APIM.
- **FR-005**: The demo MUST be runnable with a single documented command (e.g., `python demo_governance.py`) after a one-line dependency install (`pip install agent-governance-toolkit[full]`).
- **FR-006**: A new standalone doc, `docs/governance-demo.md`, MUST document what AGT is, why it's included, and how to run both the standalone demo (User Story 1) and the governed end-to-end flow (User Story 2). The top-level `README.md` MUST gain a short section (a few lines, in keeping with its existing style) introducing the governance demo and linking to `docs/governance-demo.md` for full details.
- **FR-007**: User Story 2 (wiring governance into the real `test_agent_mcp.py` → APIM → MCP flow) IS in scope for this feature. The existing `test_agent_mcp.py` MUST gain an opt-in governance mode (e.g., a `--governed` flag or environment variable) that wraps its MCP tool-call path with AGT's `govern()` before requests reach APIM, without changing default (ungoverned) behavior when the flag/variable is not set.
- **FR-008**: The governance policy demonstrated MUST distinguish at minimum between a safe/read-style Azure MCP action (e.g., listing resource groups) and a destructive/dangerous action (e.g., delete), matching the categories the underlying Azure MCP server exposes.
- **FR-009**: When governance mode is enabled in `test_agent_mcp.py`, a denied tool call MUST be blocked locally (raising/reporting `GovernanceDenied`) before any HTTP request is made to APIM, and an allowed tool call MUST proceed through APIM exactly as it does today (no behavior change for allowed actions).

### Key Entities

- **Policy Document**: YAML file defining `default_action` and a list of `rules` (condition → action: allow/deny/require_approval); owned by this repo, versioned alongside code.
- **Governed Tool Call**: A representative Azure MCP tool invocation (e.g., list resource groups, delete resource group) wrapped by AGT's `govern()` so every call is checked against the Policy Document before executing.
- **Decision Record**: The result of a governance evaluation (allowed/denied, matched rule, timestamp) surfaced to the console/log for demo purposes.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A first-time viewer can see one ALLOW and one DENY governance decision within 60 seconds of the standalone demo script starting, with no Azure deployment required.
- **SC-002**: The standalone demo (install + run) completes in under 5 minutes on a clean environment, following only `docs/governance-demo.md` instructions.
- **SC-003**: 100% of destructive/denied tool call attempts in both the standalone demo and the governed `test_agent_mcp.py` mode are blocked before any real Azure/MCP/APIM call is attempted (zero false-allows in the fixed demo scenarios).
- **SC-004**: The policy file and demo script require no more than ~50 lines of new application code combined (excluding the policy YAML and docs), keeping the footprint "as light as possible" per the ask.
- **SC-005**: Enabling governance mode on `test_agent_mcp.py` produces zero behavior change for allowed tool calls compared to running it today without governance (same requests reach APIM, same responses returned).

## Assumptions

- Target audience for the demo is technical (developers/architects) but not necessarily familiar with AGT beforehand — the demo should be self-explanatory.
- Python is the implementation language for the demo, since this repo already uses Python (`test_agent_mcp.py`) and AGT's Python distribution is the "full stack" option (`agent-governance-toolkit[full]`).
- The demo targets AGT's `agentmesh.governance.govern()` quick-start API (or the `agent_os.policies.PolicyEvaluator` API) rather than the TypeScript/.NET/Rust/Go SDKs, since no other language runtime is present in this repo today.
- The demo does not require deploying AGT's MCP Security Gateway, Governance Dashboard, or Shadow AI Discovery components — those are out of scope for a "light" first demo and can be called out as "what's next" talking points.
- No production security guarantees are required; this is explicitly a demo/POC to show the value of the tool, not a hardened production governance rollout.
