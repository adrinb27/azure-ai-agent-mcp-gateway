# Contract: Governance Policy File (`policies/governance-policy.yaml`)

This is the interface this feature exposes to demo operators/presenters — the single
file they edit to change what's allowed/denied during a live demo. It must conform to
AGT's documented policy schema (`apiVersion: governance.toolkit/v1`) so it is
lintable/verifiable with AGT's own CLI (`agt lint-policy`, `agt verify`).

## Schema

```yaml
apiVersion: governance.toolkit/v1   # required, fixed literal
name: <string>                      # required, policy identifier
default_action: allow | deny        # required — this demo MUST use "allow"
rules:                              # required, list, >= 1 item
  - name: <string>                  # required, unique per policy
    condition: <string>             # required, AGT condition expression referencing action.type (or other action fields)
    action: allow | deny | require_approval   # required
    description: <string>           # required — shown to the audience on deny
    priority: <int>                 # optional but recommended when multiple rules exist
```

## Demo policy contents (concrete instance)

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

## Consumers of this contract

| Consumer | How it uses the policy |
|---|---|
| `demo_governance.py` | Passes the file path to `govern(fn, policy="policies/governance-policy.yaml")` for both the allow and deny demo calls |
| `test_agent_mcp.py` (governed mode) | Same file path, same `govern()` call, wrapping the real MCP `tools/call` dispatch function |
| `agt lint-policy policies/` | Validates the YAML conforms to the schema above (User Story 3) |
| `agt verify` | Confirms overall governance coverage / OWASP-style compliance reporting against this policy (User Story 3) |

## Compatibility / change rules

- Adding a new rule MUST include `name`, `condition`, `action`, `description` (all required fields above) — a rule missing any of these is expected to fail `agt lint-policy`.
- `default_action` MUST remain `allow` for this demo's narrative (default-allow, deny-by-exception) — changing it to `deny` would require every demoed action to have an explicit `allow` rule, which is out of scope here.
- The two demo call sites (`demo_governance.py` and `test_agent_mcp.py`) MUST reference the same policy file path (no forked copies), so a single edit changes behavior everywhere — this is what FR-002's "self-explanatory, single policy" intent (and the plan's "single shared policy" research decision) requires.
