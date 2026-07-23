# governance-proxy/Dockerfile
# Build from the REPO ROOT (not this directory) so the image can bake in
# policies/governance-policy.yaml — the same policy file used by
# demo_governance.py and test_agent_mcp.py --governed, kept as a single
# source of truth.
#
# Build + push (from repo root):
#   az acr build --registry <acrName> --image governance-proxy:latest \
#     --file governance-proxy/Dockerfile .

FROM python:3.11-slim

WORKDIR /app

COPY governance-proxy/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY governance-proxy/app.py ./app.py
COPY policies/governance-policy.yaml ./policies/governance-policy.yaml

ENV PORT=8080
EXPOSE 8080

CMD ["sh", "-c", "uvicorn app:app --host 0.0.0.0 --port ${PORT}"]
