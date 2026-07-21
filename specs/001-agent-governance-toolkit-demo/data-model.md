# Data Model: Agent Governance Toolkit Demo

This feature has no persistent storage or database entities. The "data model" here
describes the small set of structured artifacts and in-memory objects the demo
manipulates, derived from the feature spec's Key Entities section.

## Policy Document

Represents the governance rules loaded from `policies/governance-policy.yaml`.

| Field | Type | Description | Validation |
|---|---|---|---|
| `apiVersion` | string | Schema version, fixed value | Must equal `governance.toolkit/v1` |
| `name` | string | Human-readable policy name | Non-empty |
| `default_action` | enum(`allow`, `deny`) | Fallback decision when no rule matches | Must be `allow` for this demo (default-allow, deny-by-exception) |
| `rules` | list of Rule | Ordered list of policy rules | At least 1 rule (the destructive-action deny rule) |

### Rule (nested in Policy Document)

| Field | Type | Description | Validation |
|---|---|---|---|
| `name` | string | Rule identifier, surfaced in `GovernanceDenied` messages | Non-empty, unique within the policy |
| `condition` | string | Expression evaluated against the call's `action` context | Must reference `action.type` per AGT's condition grammar |
| `action` | enum(`allow`, `deny`, `require_approval`) | Effect when condition matches | This demo only uses `deny` (destructive actions) |
| `description` | string | Human-readable explanation, printed on denial | Non-empty (drives demo narration) |
| `priority` | integer | Evaluation order when multiple rules could match | 100 for the single rule in this demo (no ordering conflicts expected) |

**Relationships**: A Policy Document has many Rules (1:N, embedded, not a separate file).

**State transitions**: None — the policy file is static for the demo; no runtime mutation.

## Governed Tool Call

Represents one invocation wrapped by `agentmesh.governance.govern()`.

| Field | Type | Description |
|---|---|---|
| `action.type` | string | Logical action name matched by policy `condition`s. Two values used in this demo: `list_resource_groups` (real MCP call) and `delete_resource_group` (local stub). |
| `inputs` | dict | Parameters passed to the underlying callable (e.g., subscription ID for list; a fake resource group name for the stub) |
| `underlying_callable` | Python function | The wrapped function `govern()` executes (or blocks) |

**Relationships**: Each Governed Tool Call is evaluated against exactly one Policy Document at call time; it produces exactly one Decision Record.

**Validation rules**: `action.type` must be a value the policy's rule `condition`s can distinguish (i.e., new action types added later must also be reflected in the policy or they silently fall through to `default_action: allow`).

## Decision Record

Represents the outcome AGT returns/raises for a single Governed Tool Call — this is what the demo prints to prove enforcement occurred.

| Field | Type | Description |
|---|---|---|
| `allowed` | boolean | Whether the call was permitted |
| `matched_rule` | string \| null | Name of the rule that produced a `deny`/`require_approval` decision, if any |
| `reason` / `description` | string \| null | Human-readable explanation (from the matched rule's `description`), surfaced via `GovernanceDenied` on deny, or implicit (no exception) on allow |
| `result` | any \| null | Return value of the underlying callable, present only when `allowed = true` |

**State transitions**: Terminal — a Decision Record is produced once per call and not mutated afterward. No persistence required beyond the demo's stdout output (per Storage: N/A in plan.md).
