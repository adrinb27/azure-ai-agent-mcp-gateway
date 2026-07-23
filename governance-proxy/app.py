"""
Governance Proxy — centralized AGT policy enforcement for the Azure MCP server.

Sits between APIM and the real Azure MCP Container App:

    Foundry / any caller ──▶ APIM (auth + OBO/CC token exchange) ──▶ [this proxy] ──▶ MCP Container App

APIM already validated the caller's Entra token and exchanged it for a token
scoped to the MCP CA app (see infra/apim-obo-policy.xml), plus injected
trusted X-User-* headers. This proxy trusts that upstream work and does NOT
re-authenticate — its job is to evaluate every MCP `tools/call` request
against policies/governance-policy.yaml *before* it ever reaches the real
MCP server, then transparently relay the request (headers, Authorization
token, body) unchanged if allowed.

This is what makes governance apply to EVERY caller (Foundry Playground,
test_agent_mcp.py, or any future client) — not just callers that happen to
import agentmesh.governance themselves, because APIM's backend is now this
proxy instead of the MCP server directly.
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse

from agentmesh.governance import govern, GovernanceDenied

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("governance-proxy")

# ── Config ───────────────────────────────────────────────────────────────────
# Real MCP Container App backend — the proxy's only job is to sit in front of it.
MCP_BACKEND_URL = os.environ["MCP_BACKEND_URL"].rstrip("/")
POLICY_FILE = os.environ.get(
    "GOVERNANCE_POLICY_FILE",
    os.path.join(os.path.dirname(__file__), "policies", "governance-policy.yaml"),
)
GOVERNANCE_ENABLED = os.environ.get("GOVERNANCE_ENABLED", "true").strip().lower() in ("1", "true", "yes")
REQUEST_TIMEOUT = float(os.environ.get("BACKEND_TIMEOUT_SECONDS", "30"))

# Headers that must never be forwarded as-is (hop-by-hop / rewritten per-hop).
_HOP_BY_HOP = {"host", "content-length", "connection", "keep-alive", "transfer-encoding"}

app = FastAPI(title="AGT Governance Proxy", version="1.0")

_client: httpx.AsyncClient | None = None


@app.on_event("startup")
async def _startup() -> None:
    global _client
    _client = httpx.AsyncClient(timeout=REQUEST_TIMEOUT)
    logger.info("Governance proxy starting. backend=%s policy=%s governance_enabled=%s",
                MCP_BACKEND_URL, POLICY_FILE, GOVERNANCE_ENABLED)


@app.on_event("shutdown")
async def _shutdown() -> None:
    if _client is not None:
        await _client.aclose()


@app.get("/healthz")
async def healthz() -> dict:
    """Liveness/readiness probe — not part of the MCP protocol surface."""
    return {"status": "ok", "backend": MCP_BACKEND_URL, "governance_enabled": GOVERNANCE_ENABLED}


def _extract_tool_call(body: bytes) -> dict[str, Any] | None:
    """
    Parse an MCP JSON-RPC request body and return {id, name, arguments} if this
    is a `tools/call` request, otherwise None (pass-through, not evaluated).
    """
    try:
        payload = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    if not isinstance(payload, dict) or payload.get("method") != "tools/call":
        return None
    params = payload.get("params") or {}
    return {
        "id": payload.get("id"),
        "name": params.get("name", "unknown_tool"),
        "arguments": params.get("arguments") or {},
    }


def _jsonrpc_deny_response(request_id: Any, rule: str, reason: str) -> dict:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {
            "code": -32001,
            "message": f"Blocked by governance policy (rule: {rule})",
            "data": {"reason": reason},
        },
    }


async def _forward(method: str, path: str, headers: dict, body: bytes, **_ignored: Any) -> httpx.Response:
    """
    Relay the request unchanged to the real MCP Container App.

    Accepts and ignores **_ignored because GovernedCallable.__call__ forwards
    ALL original kwargs (including the synthetic `action` kwarg used purely
    for policy evaluation) through to the wrapped function on allow.
    """
    assert _client is not None
    url = f"{MCP_BACKEND_URL}{path}"
    return await _client.request(method, url, headers=headers, content=body)


# Lazily-built governed wrapper around _forward — governance-proxy only cares
# whether a given tool CALL is allowed, so the "action" evaluated is the tool
# name + its arguments, matching the schema demo_governance.py/test_agent_mcp.py
# already use against the same policies/governance-policy.yaml file.
_governed_forward = None


def _get_governed_forward():
    global _governed_forward
    if _governed_forward is None:
        _governed_forward = govern(_forward, policy=POLICY_FILE)
    return _governed_forward


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def proxy(request: Request, path: str) -> Response:
    body = await request.body()
    forward_headers = {
        k: v for k, v in request.headers.items() if k.lower() not in _HOP_BY_HOP
    }
    forward_path = f"/{path}" if path else "/"

    tool_call = _extract_tool_call(body) if request.method == "POST" else None

    if tool_call is not None and GOVERNANCE_ENABLED:
        user = request.headers.get("x-user-upn", "unknown")
        start = time.monotonic()
        try:
            governed = _get_governed_forward()
            resp = await governed(
                action={"type": tool_call["name"], **tool_call["arguments"]},
                method="POST", path=forward_path, headers=forward_headers, body=body,
            )
        except GovernanceDenied as denied:
            elapsed_ms = round((time.monotonic() - start) * 1000, 1)
            logger.warning(
                "DENY tool=%s user=%s rule=%s reason=%s (%sms)",
                tool_call["name"], user, denied.decision.matched_rule,
                denied.decision.reason, elapsed_ms,
            )
            return JSONResponse(
                status_code=200,  # MCP JSON-RPC errors are HTTP 200 with an "error" body
                content=_jsonrpc_deny_response(
                    tool_call["id"], denied.decision.matched_rule or "unknown", denied.decision.reason or ""
                ),
            )
        else:
            elapsed_ms = round((time.monotonic() - start) * 1000, 1)
            logger.info("ALLOW tool=%s user=%s (%sms)", tool_call["name"], user, elapsed_ms)
    else:
        resp = await _forward("POST" if request.method == "POST" else request.method,
                               forward_path, forward_headers, body)

    response_headers = {
        k: v for k, v in resp.headers.items() if k.lower() not in _HOP_BY_HOP
    }
    return Response(content=resp.content, status_code=resp.status_code, headers=response_headers)
