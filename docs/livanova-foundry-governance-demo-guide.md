# LivaNova × Microsoft — Azure AI Foundry & Agent Governance Demo Guide

**Audience:** Prakash / LivaNova engineering & automation stakeholders
**Duration:** ~30 minutes total (this guide maps directly to the agenda below)
**Presenter goal:** Show Foundry as the platform, then prove — live, not slideware —
that agent governance and control-plane concerns are solved problems using the
governance toolkit built in this repo.

---

## Agenda mapping (use this as your run-of-show)

| # | Agenda item | Time | What you actually do |
|---|---|---|---|
| 1 | Objectives & LivaNova context | 3 min | Talk only — no repo/demo needed |
| 2 | Azure AI Foundry overview | 5 min | Slides/portal tour — Section 1 below |
| 3 | Models, APIs & agent dev framework | 8 min | Foundry model catalog + Agents API — Section 2 below |
| 4 | Governance & control plane for AI agents | 10 min | **Live demo — this is the centerpiece.** Section 3 below |
| 5 | Discussion & next steps | 4 min | Talking points — Section 4 below |

Total live-demo time is tight (10 min in section 4, plus maybe 2 min borrowed from
section 3 if things go fast). **Rehearse the timed script in Section 3 beforehand** —
it's written to fit in ~8–10 minutes including narration.

---

## 1. Azure AI Foundry Overview (5 min)

Keep this conceptual — no repo needed yet. Suggested talking points:

- **What Foundry is**: Microsoft's unified platform for building, evaluating,
  governing, and operating AI applications and agents — spans model access,
  agent orchestration, evaluation, observability, and now a **compliance/control
  plane** (Operate → Compliance) for guardrails and security posture.
- **Where it fits in the Microsoft AI stack**: sits above raw Azure OpenAI /
  Azure AI Services model deployments, and below/adjacent to Copilot Studio and
  Microsoft 365 Copilot — Foundry is the "build your own agent" layer for
  engineering teams, as opposed to the "extend an existing Copilot" layer.
- **Three pillars to name explicitly** (ties directly into agenda item 4):
  1. **Build** — model catalog, Agents API, tools/MCP integration.
  2. **Govern** — guardrail policies, RBAC, Microsoft Purview integration,
     Defender for Cloud security posture.
  3. **Operate** — Monitor dashboard (agent runs, tool calls, error rates),
     Traces, Evaluation.
- Optionally show the Foundry portal (ai.azure.com) landing page and the
  **Operate → Compliance** tab live for 30 seconds — just to establish it
  exists before the deep dive in Section 3. Don't demo policies yet — that's
  the live section.

---

## 2. Models, APIs & Agent Development Framework (8 min)

Also mostly portal/conceptual, but you can ground it in this repo's real,
deployed example instead of a generic slide.

- **Model catalog ("model garden")**: open Foundry → Model catalog. Point out
  breadth (OpenAI, Meta, Mistral, Microsoft, etc.) and that model choice is a
  **swap, not a rebuild** — the agent code in this repo (`test_agent_mcp.py`)
  references a model deployment name (`AGENT_MODEL` in `.env`, e.g. `gpt-4.1`)
  that can be repointed to any deployed model without touching the agent's
  tool-calling logic.
- **Agent development options**: mention the **Agents API** (what this repo
  uses — `azure.ai.agents` SDK, `AgentsClient`, threads/runs/tool-approval
  loop) vs. lower-level direct chat-completions calls vs. Copilot Studio's
  low-code agent builder. Position: Agents API = the pro-code option for
  engineering teams like LivaNova's, with full control over tools and
  governance hooks (segue to Section 3).
- **Multi-model strategy**: LivaNova's discussion point — different agents/
  tasks may warrant different models (cost vs. capability vs. data residency).
  Foundry's per-project model deployment list makes this a config choice, not
  an architecture change.
- **This repo's real example**: a Foundry Agent (`azure-assitant`) wired to a
  real tool surface — the **Azure MCP server** (Model Context Protocol) —
  exposing ~400 real Azure management tools (list/get across compute, storage,
  SQL, networking, etc.) through a secured, gated path. This is the natural
  bridge into governance: *"once an agent has real tools, how do you control
  what it's allowed to do with them?"*

---

## 3. Governance & Control Plane for AI Agents (10 min) — LIVE DEMO

This is the section to rehearse. Script below is written so you can read it
almost verbatim, with clear "click here / say this" beats.

### 3.0 Setup checklist (do this before the meeting, not during)

- [ ] Confirm `ca-govproxy-jyebupyg` Container App is running the latest
      policy image (`az containerapp show -n ca-govproxy-jyebupyg -g
      rg-azuremcp-governance-toolkit --query properties.template.containers[0].image`)
- [ ] Confirm `.venv-governance` exists and `test_agent_mcp.py --governed`
      still runs cleanly (`python3 test_agent_mcp.py --phase 1 --governed`)
- [ ] Have the **Foundry Playground** open in a browser tab, agent
      `azure-assitant` selected, MCP tool (`azure-mcp`) attached
- [ ] Have the **Foundry Monitor** tab open in a second browser tab
      (Operate → Monitor) — should show data from the traffic-generation runs
      already executed (60+ requests over the last hour), so the charts are
      populated, not empty
- [ ] Have a terminal open with `policies/governance-policy.yaml` ready to
      show (`cat` or open in editor) — don't edit live unless confident
- [ ] Optional safety net: keep `deny_test3.py` / a raw JSON-RPC test script
      handy in case the Playground has a transient auth hiccup (seen before —
      session token expiry on long-lived streaming connections, unrelated to
      governance, but good to know a fallback exists)

### 3.1 Frame the problem (60 sec, talking only)

> "An agent with real tools is only as safe as its weakest caller. Prompt-level
> instructions — 'please don't delete production resources' — are a *request*
> to a stochastic model, not a control. Two things can go wrong: the model
> ignores the instruction, or a completely different caller (a script, another
> team's integration, the Playground itself) never gets the instruction at
> all. We need enforcement that doesn't depend on the model's compliance and
> doesn't depend on every caller remembering to add a check."

### 3.2 Show the architecture (60–90 sec)

Show the architecture diagram from this repo's `README.md`
(`## Architecture Overview` mermaid diagram) or describe verbally:

```
Foundry Agent / Playground / any script
        │  Bearer token (Entra ID)
        ▼
   APIM Gateway  ── validates token, exchanges for backend token (OBO/CC)
        │
        ▼
 Governance Proxy  ── evaluates EVERY tool call against a YAML policy
        │  ALLOW → forward          DENY → reject before it happens
        ▼
   Azure MCP Server  (real Azure management tools — ~400 of them)
```

Key point to land: **the proxy sits at the network layer, not inside any one
agent's code.** Every caller — Foundry Playground, a teammate's script, a
future integration — is forced through the same gate. This directly answers
agenda item 4's "security, RBAC, monitoring, observability, and policy
controls" and "how Foundry supports enterprise agent operations at scale."

### 3.3 Live ALLOW demo (2 min)

In the **Foundry Playground**, with `azure-assitant` selected:

1. Type: `List the resource groups in my subscription.`
2. Approve the MCP tool-call prompt when it appears (`group_list`).
3. Narrate while it runs: *"This is a real, live call — Foundry through APIM
   through our governance proxy through the actual Azure MCP server, backed
   by a real Azure subscription. The proxy evaluated this call against policy
   and let it through because it's a safe, read-only action."*
4. Show the real resource-group list come back.

### 3.4 Live DENY demo (3 min) — the money shot

1. Type: `Delete the SQL database named 'legacy-db' on server 'sql-legacy' — use the MCP tool.`
   (or: `Delete the virtual machine named 'demo-vm-01'.`)
2. Approve the tool-call prompt (you still have to approve it — governance
   isn't about hiding tool calls from the user, it's about what happens after
   approval).
3. **Point out the error that comes back**: the model calls a real tool
   (`sql_db_delete` / `compute_vm_delete`), and the response is a governance
   rejection — `Blocked by governance policy (rule: block-real-mcp-delete-tools)`
   — **not** an Azure permissions error, not a model refusal. The call never
   reached the real Azure MCP server.
4. Optionally open `policies/governance-policy.yaml` and show the actual rule
   that fired — a plain, auditable YAML condition, not a black box:
   ```yaml
   - name: block-real-mcp-delete-tools
     condition: >-
       action.type in ['compute_vm_delete', 'sql_db_delete', ...]
     action: deny
     description: "Real Azure MCP server delete tools are blocked in this demo"
   ```
5. Land the point: *"This is deterministic. It's not 'the model usually
   refuses' — the action is structurally impossible to complete, regardless
   of which model is behind the agent. We validated this same policy blocks
   the same actions whether the agent is running gpt-4.1 or a completely
   different model — the enforcement point is the proxy, not the model."*

### 3.5 Show the Monitor dashboard (90 sec)

Switch to the **Operate → Monitor** tab (already populated from earlier
traffic-generation runs):

- Point out **Agent runs**, **Tool calls**, and **Error rate** panels now have
  real data — dozens of runs over the last hour, a mix of successful
  (ALLOW) and failed (DENY) tool calls.
- Narrate: *"Every one of these is a real interaction — some intentionally
  triggering denied actions to validate the policy stays enforced under
  sustained, varied load, not just a single hand-crafted test."*
- This addresses "monitoring, observability" directly from the agenda.

### 3.6 One-sentence summary for the section (10 sec)

> "Foundry gives you the platform — models, agents, tools, a compliance
> workspace. What we've built on top is a **centralized enforcement point**
> that makes agent governance a property of the infrastructure, not a promise
> from the model or a checklist for every developer."

---

## 4. Discussion & Next Steps (4 min)

Prompts to steer LivaNova's use-case discussion:

- **"What destructive or high-risk actions exist in your engineering/automation
  workflows today?"** — the governance policy here is a plain YAML allow-list/
  deny-list; any enumerable set of "never do this automatically" actions maps
  directly onto this pattern (manufacturing systems, quality/compliance data,
  regulated device data, etc. — LivaNova is medical devices, so this framing
  should resonate strongly).
- **"Where do you have multiple callers hitting the same backend system?"** —
  the proxy pattern generalizes beyond MCP/Azure tools to any API surface
  where you want enforcement independent of caller.
- **Possible follow-up deep dives / PoC opportunities**:
  1. Map LivaNova's own high-risk actions (e.g. changes to validated/regulated
     systems, PLM data, quality records) into a governance policy like the one
     shown.
  2. Explore Microsoft Purview integration for **data-layer** governance
     (sensitivity labels, DLP, audit) as a complement to this **action-layer**
     governance — note from our own testing: Purview's enforcement currently
     applies to Foundry's native chat-completions endpoint with user-context
     tokens, so it's a complementary (not overlapping) control to the proxy
     approach for Agents API + tool-call scenarios.
  3. Multi-model evaluation — swap the underlying model on this same agent/
     tool/governance stack to compare cost/quality without touching
     governance or tool-calling code at all.
- **Close with**: offer to share this repo (or a scoped equivalent) as a
  working reference architecture LivaNova's engineering team can extend
  directly, rather than starting governance from scratch.

---

## Appendix — quick reference / cheat sheet

**Key facts to have ready if asked:**

- Architecture: Foundry Agent → APIM (auth + token exchange) → Governance
  Proxy (policy enforcement) → Azure MCP Container App (~400 real Azure
  management tools).
- Policy engine: [Microsoft's open-source Agent Governance Toolkit (AGT)](https://github.com/microsoft/agent-governance-toolkit)
  — `agentmesh.governance.govern()`, YAML policy, default-allow/deny-by-exception.
- Policy file: `policies/governance-policy.yaml` — single source of truth,
  shared by the standalone demo, the governed test script, and the deployed
  proxy.
- Enforcement point: network layer (governance proxy Container App), not
  inside agent code — so it covers *every* caller, including the Foundry
  Playground itself.
- Verified live: DENY correctly triggers on real tool names
  (`compute_vm_delete`, `sql_db_delete`, `arm_create_or_update_resource_group`,
  and more) regardless of which model is behind the agent or how the model
  phrases its tool call — enforcement doesn't depend on the model's wording.
- Toggle: the whole proxy is optional infrastructure — `ENABLE_GOVERNANCE_PROXY`
  in `.env` / `enableGovernanceProxy` Bicep param — so the pattern can be
  demonstrated as an add-on to an existing architecture, not a rewrite.
- Auditable: `agt lint-policy` and `agt verify` give an independent,
  command-line-verifiable compliance report (OWASP ASI 2026 coverage) — good
  "trust but verify" evidence if asked how you know the policy is correct.

**If something breaks live:**

- Playground shows a raw transport/auth error unrelated to governance
  (`401`, "server did not return a valid MCP JSON-RPC response") → known,
  intermittent streaming-session token expiry; not a governance issue.
  Retry the message or start a new thread.
- If the proxy itself seems to be passing everything through unexpectedly →
  check the Container App is running the latest image tag (Azure Container
  Apps can silently not roll a new revision on a repeated `:latest` tag —
  `deploy.sh` now always uses a unique timestamp tag to avoid this).
- Fallback if Playground is uncooperative: run `python3 test_agent_mcp.py
  --phase 1 --governed` or a raw JSON-RPC script directly against APIM to
  show the same ALLOW/DENY behavior without depending on the Playground UI.
