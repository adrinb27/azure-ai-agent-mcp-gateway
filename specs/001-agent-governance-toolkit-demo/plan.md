# Implementation Plan: Agent Governance Toolkit Demo

**Branch**: `001-agent-governance-toolkit-demo` (spec directory; actual git branch in use is `add-spec-kit`) | **Date**: 2026-07-21 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/001-agent-governance-toolkit-demo/spec.md`

## Summary

Add a light-footprint demonstration of the Microsoft **Agent Governance Toolkit (AGT)** to this repo. AGT's `agentmesh.governance.govern()` wrapper will front two representative Azure MCP tool call shapes — a safe/read action (list resource groups) and a destructive action (delete resource group) — evaluated against a small YAML policy. Two demo surfaces are delivered:

1. A **standalone script** (`demo_governance.py`) that requires no Azure deployment and prints an ALLOW and a DENY decision with audit output.
2. An **opt-in governance mode** in the existing `test_agent_mcp.py`, gated by a `--governed` CLI flag (also honoring a `GOVERNANCE_ENABLED` env var for consistency with the rest of the `.env`-driven config), that wraps the MCP tool-call path with the same policy before requests are ever sent to APIM.

Documentation lives in a new `docs/governance-demo.md`, with a short pointer section added to the top-level `README.md`.

## Technical Context

**Language/Version**: Python 3.10+ (matches repo's existing `test_agent_mcp.py` and AGT's minimum supported version)

**Primary Dependencies**: `agent-governance-toolkit[full]` (PyPI, public preview) — provides `agentmesh.governance.govern()` and the `agt` CLI (`agt doctor`, `agt lint-policy`, `agt verify`). No other new dependency required; reuses existing `requests`, `azure-identity`, `azure-ai-agents` already in the repo's Python environment.

**Storage**: N/A — policy is a static YAML file checked into the repo; decision/audit records are printed to stdout for demo purposes (AGT's default local audit sink is sufficient; no external audit store needed for a demo).

**Testing**: Manual/scripted validation via the `quickstart.md` run-through (this is a demo artifact, not production code — no new automated test suite is required per the spec's "as light as possible" goal). Existing repo has no test framework configured (`test_agent_mcp.py` is itself a manual E2E script, not a pytest suite), so we follow that precedent.

**Target Platform**: Linux/WSL developer machine (matches existing repo usage — `deploy.sh`, `setup-obo-auth.sh` are bash scripts run from WSL/Linux shells); AGT demo has no platform-specific dependency beyond Python 3.10+.

**Project Type**: Single small demo addition to an existing infra/POC repo (not a standalone project) — two new Python scripts/docs at repo root + `docs/` and `policies/` directories.

**Performance Goals**: N/A (demo, not a production service). Success is defined qualitatively in the spec (SC-001: decisions visible within 60s; SC-002: demo runs in <5 min end-to-end).

**Constraints**: Must not modify existing Bicep infra or require redeployment (FR-004). Must not change default (ungoverned) behavior of `test_agent_mcp.py` (FR-009/SC-005). Combined new application code (excluding policy YAML/docs) should stay under ~50 lines per SC-004 — this bounds the demo script and the governance wrapper added to `test_agent_mcp.py` to small, focused helpers rather than a general framework.

**Scale/Scope**: Two demo call shapes (allow + deny), one policy file, one standalone script, one opt-in code path in an existing script, one new doc page + short README section. No multi-user, no persistence, no deployment changes.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` in this repo is still the unfilled template (no project-specific principles have been ratified yet — all placeholder tokens like `[PRINCIPLE_1_NAME]` remain). There are no ratified gates to check against. This plan proceeds under the repo's de facto conventions observed in existing code (small bash/Python scripts, `.env`-driven config, no test framework, minimal abstraction) rather than a formal constitution. No violations to justify — **Constitution Check: PASS (no gates defined)**.

## Project Structure

### Documentation (this feature)

```text
specs/001-agent-governance-toolkit-demo/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md         # Phase 1 output (/speckit.plan command)
├── quickstart.md         # Phase 1 output (/speckit.plan command)
├── contracts/            # Phase 1 output (/speckit.plan command)
│   └── governance-policy.schema.md
└── tasks.md              # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
policies/
└── governance-policy.yaml       # AGT policy: allow-by-default, deny destructive Azure MCP actions

demo_governance.py                # Standalone AGT demo: governed allow + governed deny, no Azure deps

test_agent_mcp.py                 # EXISTING file, modified: adds optional governance wrapper
                                   #   - new --governed CLI flag / GOVERNANCE_ENABLED env var
                                   #   - new helper(s) wrapping MCP tool-call dispatch with govern()
                                   #   - default (flag/env unset) behavior unchanged

docs/
└── governance-demo.md            # New: what AGT is, why included, how to run both demo surfaces

README.md                         # EXISTING file, modified: short new section linking to
                                   #   docs/governance-demo.md
```

**Structure Decision**: Single-project structure (Option 1, trimmed to just what's needed). This is not a standalone app needing `src/`/`tests/` scaffolding — it's a thin addition to an existing infra-POC repo, so new files land at the repo root (`demo_governance.py`, `policies/`) and `docs/`, following the existing flat layout (`deploy.sh`, `test_agent_mcp.py` already live at root). No `src/` or `tests/` directories are introduced, consistent with the repo's current structure and the "as light as possible" requirement.

## Complexity Tracking

*No constitution gates are defined (see Constitution Check above), so no violations require justification. This section is intentionally empty.*
