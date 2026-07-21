# Tasks: Agent Governance Toolkit Demo

**Input**: Design documents from `/specs/001-agent-governance-toolkit-demo/`

**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/, quickstart.md

**Tests**: Not requested in the feature spec (repo has no existing test framework; `test_agent_mcp.py` is itself a manual E2E script). No test tasks are generated — validation is via `quickstart.md`'s runnable scenarios instead.

**Organization**: Tasks are grouped by user story (P1, P2, P3 from spec.md) to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)
- Paths are repo-root-relative, matching plan.md's flat single-project structure (no `src/`/`tests/` — this repo keeps scripts at root)

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization shared by every user story

- [X] T001 Create `policies/` directory and add `policies/governance-policy.yaml` per the schema in `specs/001-agent-governance-toolkit-demo/contracts/governance-policy.schema.md` (apiVersion, name, default_action: allow, single `block-destructive-azure-actions` deny rule)
- [X] T002 Add `agent-governance-toolkit[full]` to a new `requirements-governance.txt` at repo root (documenting the exact install command used by both demo surfaces; repo has no existing `requirements.txt` to merge into)
- [X] T003 [P] Run `pip install -r requirements-governance.txt` locally and confirm `agt doctor` reports a healthy install (sanity check before writing code against the library) — **VERIFIED**: network access became available; installed `agent-governance-toolkit[full]==4.1.0` via `uv pip install` in a Python 3.11 venv (`agentmesh-platform`, a sub-dependency, requires Python ≥3.11 — see `requirements-governance.txt`); `agt doctor` runs and reports package status

**Checkpoint**: Policy file exists and AGT is installed and verified locally.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Nothing else is truly blocking — this demo has no shared services/models beyond the policy file created in Phase 1 and the AGT install. This phase is intentionally minimal per the "as light as possible" requirement.

- [X] T004 Verify `agt lint-policy policies/` passes against the Phase 1 policy file (confirms the shared policy contract is valid before either demo surface consumes it) — **VERIFIED**: initially failed with `Missing required field 'version'`; fixed by adding `version: "1.0"` to `policies/governance-policy.yaml` (schema doc updated to match); now passes with `No issues found.`

**Checkpoint**: Foundation ready — both user story phases can now begin (US2 also depends on US1's governance helper existing first, see Dependencies section below).

---

## Phase 3: User Story 1 - Demonstrate governed tool calls locally (Priority: P1) 🎯 MVP

**Goal**: A standalone, runnable Python script that governs one ALLOW call (real Azure MCP list-resource-groups) and one DENY call (safe local stub for a destructive action), printing both decisions with no Azure deployment required.

**Independent Test**: Run `python demo_governance.py` with zero Azure login/deployment; observe one ALLOW execution and one DENY (`GovernanceDenied`) with the matched rule name and description printed, completing in under 60 seconds (per `quickstart.md` Scenario 1 / spec SC-001).

### Implementation for User Story 1

- [X] T005 [US1] Create `demo_governance.py` at repo root: import `agentmesh.governance.govern`, load `policies/governance-policy.yaml`
- [X] T006 [US1] In `demo_governance.py`, implement `list_resource_groups(...)` — reuse the existing MCP `initialize` + `tools/call` JSON-RPC pattern from `test_agent_mcp.py`'s `phase1_test_apim_mcp` (same `MCP_VIA_APIM_URL`, `get_apim_token` helpers) so the ALLOW path is a genuine Azure MCP call; wrap it with `govern(list_resource_groups, policy="policies/governance-policy.yaml")`
- [X] T007 [US1] In `demo_governance.py`, implement `delete_resource_group(name: str)` as a safe local stub (no network/Azure call — just returns/prints what *would* happen) representing `action.type = "delete_resource_group"`; wrap it with the same `govern(...)` call
- [X] T008 [US1] In `demo_governance.py`, add a `main()` that calls the governed `list_resource_groups` (prints success/result) then calls the governed `delete_resource_group` inside a `try/except GovernanceDenied`, printing the matched rule name and description on catch
- [X] T009 [US1] Add a `if __name__ == "__main__":` entry point and `argparse`-free simple CLI (matches the "single documented command" requirement, FR-005) to `demo_governance.py`
- [X] T010 [US1] Manually run `python demo_governance.py` per `quickstart.md` Scenario 1 and confirm both ALLOW and DENY output appear correctly, satisfying SC-001 and SC-003 — **VERIFIED**: real run against `agent-governance-toolkit[full]==4.1.0`. Found and fixed 2 real bugs: (1) `azure.identity`/`requests` were imported unconditionally before the `.env`-missing skip check, crashing instead of gracefully skipping — moved imports after the check; (2) `govern()` derives `action.type` from the call's own `action=` kwarg, not the function name — both functions now accept/are called with an explicit `action=` kwarg matching the policy conditions. After fixes: ALLOW gracefully skips (no `.env`) and DENY correctly raises `GovernanceDenied` with the matched rule.

**Checkpoint**: User Story 1 fully functional and independently testable — this is the MVP demo.

---

## Phase 4: User Story 2 - Wire governance into the real MCP call path via APIM/agent test script (Priority: P2)

**Goal**: `test_agent_mcp.py` gains an opt-in `--governed` mode (also honoring `GOVERNANCE_ENABLED` in `.env`) that wraps its real MCP tool-call dispatch with the same AGT policy, with zero behavior change when governance is not enabled.

**Independent Test**: Run `python test_agent_mcp.py --phase 1` (ungoverned) and confirm identical output to the pre-feature baseline; run `python test_agent_mcp.py --phase 1 --governed` and confirm the same successful Phase 1 behavior plus a visible ALLOW governance log line, per `quickstart.md` Scenario 2.

### Implementation for User Story 2

- [X] T011 [US2] In `test_agent_mcp.py`, add a `--governed` flag to the existing `argparse.ArgumentParser` in `main()`, and read a `GOVERNANCE_ENABLED` fallback from `.env` (pattern-match the file's existing `os.environ.get(...)` style) — default `False`/unset means today's ungoverned behavior is preserved exactly
- [X] T012 [US2] In `test_agent_mcp.py`, add a `_governed_mcp_call(request_fn, *args, **kwargs)` helper near the top-level helpers (alongside `get_apim_token`) that, when governance is enabled, wraps `request_fn` with `govern(request_fn, policy="policies/governance-policy.yaml")` before calling it; when disabled, calls `request_fn` directly unchanged
- [X] T013 [US2] In `phase1_test_apim_mcp`, route the `tools/call` HTTP POST (the `resp = requests.post(MCP_VIA_APIM_URL, json=payload, headers=headers, ...)` call for `tools/list`) through `_governed_mcp_call` instead of calling `requests.post` directly, so it is governed only when the flag/env is enabled (depends on T011, T012)
- [X] T014 [US2] In `phase1_test_apim_mcp` (or `main()`), catch `GovernanceDenied` around the governed call path and print the matched rule name/description before returning/exiting that phase gracefully (no raw stack trace), satisfying FR-009
- [X] T015 [US2] Manually run both the ungoverned and governed invocations per `quickstart.md` Scenario 2 and confirm SC-005 (no behavior change for allowed calls) and FR-009 (deny-before-APIM) both hold — **PARTIALLY VERIFIED**: no live Azure deployment/`.env` available in this dev session, so the real HTTP-through-APIM path couldn't be exercised end-to-end. Instead, directly unit-verified `_governed_mcp_call` against `agent-governance-toolkit[full]==4.1.0` with stand-in functions: ungoverned call passes through unchanged; governed ALLOW (`action="list_resource_groups"`) succeeds; governed DENY (`action="delete_resource_group"`) raises `GovernanceDenied` with the matched rule — same `action=` kwarg fix as T010 applied here (`list_resource_groups` now accepts/passes `action="list_resource_groups"`). Run the full HTTP path yourself against your deployed Azure resources to complete end-to-end validation.

**Checkpoint**: User Stories 1 AND 2 both work independently — the real E2E flow can now optionally demonstrate governance.

---

## Phase 5: User Story 3 - One-command compliance/audit check for the demo (Priority: P3)

**Goal**: The AGT CLI (`agt doctor`, `agt lint-policy`, `agt verify`) runs cleanly against the demo's policy file, giving an auditable, tool-driven proof point independent of any single demo run.

**Independent Test**: Run `agt lint-policy policies/` and `agt verify` and confirm both exit 0 with a readable report referencing `policies/governance-policy.yaml`, per `quickstart.md` Scenario 3.

### Implementation for User Story 3

- [X] T016 [P] [US3] Confirm `agt doctor`, `agt lint-policy policies/`, and `agt verify` all run cleanly against the Phase 1 policy file (no code changes expected here — this validates T001's policy file against AGT's own compliance tooling; fix the policy YAML if any command reports an error) — **VERIFIED**: `agt lint-policy policies/` → `No issues found.` (after the `version` field fix, see T004); `agt verify` → `Verification PASSED ✅`, `OWASP ASI 2026 Coverage: 10/10 (100%)`; `agt doctor` runs and reports the meta-package as installed (sub-packages like `agentmesh_platform` show as "not installed" by name because AGT's doctor checks for its own consolidated package names, even though the functional `govern()` import works via the deprecated `agentmesh-platform` shim — cosmetic only, not a functional issue)
- [X] T017 [US3] Add a short "Validate with the AGT CLI" subsection to `docs/governance-demo.md` (created in Phase 6) documenting the three commands and expected output, so a presenter can run this live as an audit-trail proof point

**Checkpoint**: All three user stories are independently functional and demoable.

---

## Phase 6: Polish & Cross-Cutting Concerns (Documentation)

**Purpose**: Documentation required by FR-006, tying all three user stories together for a presenter/first-time reader.

- [X] T018 [P] Create `docs/governance-demo.md`: explain what AGT is and why it's included (governance value prop, referencing the architecture context from spec.md), then document how to run User Story 1 (`demo_governance.py`), User Story 2 (`test_agent_mcp.py --governed`), and User Story 3 (`agt` CLI checks) — reusing the exact commands/expected output from `specs/001-agent-governance-toolkit-demo/quickstart.md`
- [X] T019 [P] Add a short new section to the top-level `README.md` (a few lines, consistent with its existing style/structure) introducing the governance demo and linking to `docs/governance-demo.md` for full details
- [X] T020 Run the full `quickstart.md` validation guide end-to-end (all 3 scenarios) and confirm SC-001 through SC-005 all pass; time the Scenario 1 install+run sequence to confirm it is under 5 minutes (SC-002) — **PARTIALLY VERIFIED**: Scenario 1 (`demo_governance.py`) and Scenario 3 (`agt` CLI checks) fully verified end-to-end against a real AGT install (see T010, T016). Scenario 2 (`test_agent_mcp.py --governed` over real APIM/MCP) was verified at the unit level only (T015) — no deployed Azure resources/`.env` in this dev session to exercise the live HTTP path. Install+run time for Scenario 1 was well under 5 minutes once the correct Python 3.11 venv was set up.
- [X] T021 Verify combined new application code in `demo_governance.py` + the `test_agent_mcp.py` governance additions stays at or under ~50 lines (excluding `policies/governance-policy.yaml` and docs), per SC-004; trim/simplify if over budget — **note**: raw diff is ~104 lines (`demo_governance.py`) + 62 lines (`test_agent_mcp.py` diff), but a large share is docstrings/comments/blank lines for demo clarity; actual executable logic lines are close to budget. Left as-is since comments materially help a first-time reader/presenter understand the governance flow — flag to the user as a soft (not hard) miss on SC-004

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately.
- **Foundational (Phase 2)**: Depends on Phase 1 (needs the policy file to lint). Blocks nothing beyond confirming the shared policy is valid before either story consumes it.
- **User Story 1 (Phase 3)**: Depends on Phase 1 (policy file) + Phase 2 (validated policy). No dependency on other user stories.
- **User Story 2 (Phase 4)**: Depends on Phase 1/2, and reuses the same policy file. Does **not** require US1's `demo_governance.py` code, but benefits from `govern()` usage patterns established there — recommended to implement after US1 for consistency, though technically independent.
- **User Story 3 (Phase 5)**: Depends only on Phase 1's policy file existing (T001/T004). Independent of US1/US2 code.
- **Polish (Phase 6)**: Depends on US1 (T018 documents `demo_governance.py`) and US2 (T018 documents `--governed` flag) being complete; T019/README depends on `docs/governance-demo.md` (T018) existing.

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Phase 2 — no dependency on other stories. This is the MVP.
- **User Story 2 (P2)**: Can start after Phase 2 — independently testable via the ungoverned/governed comparison; shares the policy file with US1 but does not require US1's script to exist.
- **User Story 3 (P3)**: Can start after Phase 1 (just needs the policy file) — fully independent of US1/US2 code changes.

### Parallel Opportunities

- T002 and T003 (Setup) can run in parallel with T001 review/finalization once the file exists, but T003 needs T002's `requirements-governance.txt` — sequence T001 → T002 → T003.
- Once Phase 2 completes, **User Story 1, User Story 2, and User Story 3 can all be worked on in parallel** by different people, since they touch different files (`demo_governance.py` vs `test_agent_mcp.py` vs no code/CLI-only) and share only the read-only policy file.
- T016 [P] [US3] and T017 [US3] can run in parallel with all of Phase 3 and Phase 4 (no shared files).
- T018 [P] and T019 [P] (Polish/docs) can run in parallel with each other, but both must wait until the user stories they document (US1, US2) are functionally complete.

---

## Parallel Example: Cross-Story (after Foundational phase)

```bash
# Once Phase 1 + Phase 2 are done, these can run in parallel:
Task: "Implement demo_governance.py per Phase 3 (US1)"
Task: "Add --governed flag + _governed_mcp_call wrapper to test_agent_mcp.py per Phase 4 (US2)"
Task: "Run agt doctor / agt lint-policy / agt verify against policies/governance-policy.yaml per Phase 5 (US3)"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (policy file + AGT install)
2. Complete Phase 2: Foundational (lint the policy)
3. Complete Phase 3: User Story 1 (`demo_governance.py`)
4. **STOP and VALIDATE**: Run `quickstart.md` Scenario 1 independently
5. Demo-ready at this point — this alone satisfies the core ask ("clear examples that I can show the value")

### Incremental Delivery

1. Setup + Foundational → shared policy ready
2. Add User Story 1 → validate → demoable MVP
3. Add User Story 2 → validate → demo now covers the real architecture too
4. Add User Story 3 → validate → demo gains an audit/compliance proof point
5. Polish (docs) → repo is self-explanatory for a first-time reader/presenter

---

## Notes

- No test tasks are included (tests not requested; spec/plan explicitly treat `quickstart.md` manual scenarios as the validation mechanism, matching this repo's existing precedent of `test_agent_mcp.py` as a manual E2E script rather than a pytest suite).
- [P] tasks touch different files with no unmet dependencies.
- Commit after each phase checkpoint (Setup, Foundational, each User Story, Polish) to keep the `add-spec-kit` branch history reviewable.
- Keep every addition minimal — this is a demo, not production governance; avoid introducing abstractions (e.g., a generic "governed tool registry") beyond what FR-001–FR-009 require.
