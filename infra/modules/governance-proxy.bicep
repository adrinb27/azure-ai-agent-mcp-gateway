// governance-proxy.bicep — Governance Proxy Container App
//
// Sits between APIM and the real MCP Container App so that AGT policy
// (policies/governance-policy.yaml) is enforced for EVERY caller that goes
// through APIM, not just calls made through this repo's local Python scripts.
//
//   APIM ──(Bearer: MCP-CA-audience token, X-User-* headers)──▶ [this proxy] ──▶ MCP Container App
//
// The proxy does NOT re-authenticate callers — APIM has already validated the
// incoming token and exchanged it for a token scoped to the MCP CA app before
// forwarding here. The proxy simply relays that same Authorization header
// (and X-User-* headers) through to the real MCP server unchanged, after
// evaluating any `tools/call` request against the governance policy baked
// into the image.
//
// Deployment note: `image` defaults to a small public placeholder so this
// module can deploy on the very first `az deployment sub create` run, before
// the real governance-proxy image has been built/pushed to ACR (chicken/egg:
// the ACR itself is created in the same deployment). deploy.sh builds and
// pushes the real image via `az acr build` right after the Bicep deployment,
// then swaps it in with `az containerapp update --image ...`.

param location string
param resourceToken string
param tags object = {}
param containerAppsEnvId string

@description('Real Azure MCP Container App HTTPS URL — the proxy forwards allowed requests here')
param mcpBackendUrl string

@description('Container image for the governance proxy. Defaults to a placeholder until the real image is built and pushed (see deploy.sh).')
param governanceProxyImage string = 'mcr.microsoft.com/azuredocs/aci-helloworld:latest'

@description('Set to "false" to run the proxy in transparent pass-through mode (no policy enforcement) — useful for rollback/debugging.')
param governanceEnabled string = 'true'

@description('ACR login server (e.g. myacr.azurecr.io) the proxy image is pulled from. When non-empty, the Container App is configured to authenticate to that registry using its own system-assigned identity, so `az containerapp update --image <acr>/...` pulls succeed. Leave empty if the image comes from a public registry.')
param acrLoginServer string = ''

var appName = 'ca-govproxy-${resourceToken}'

resource governanceProxy 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    environmentId: containerAppsEnvId
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
        allowInsecure: false
      }
      // Lets the Container App authenticate to the private ACR using its own
      // system-assigned identity when pulling the real governance-proxy image
      // (RBAC AcrPull role alone is not sufficient — Container Apps also needs
      // this explicit registry-auth config). Granting the AcrPull role itself
      // happens in role-assignments.bicep. No-op / empty when acrLoginServer
      // is not supplied (e.g. proxy pulling a public image).
      registries: !empty(acrLoginServer) ? [
        {
          server: acrLoginServer
          identity: 'system'
        }
      ] : []
    }
    template: {
      containers: [
        {
          name: 'governance-proxy'
          image: governanceProxyImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'MCP_BACKEND_URL', value: mcpBackendUrl }
            { name: 'GOVERNANCE_ENABLED', value: governanceEnabled }
            { name: 'PORT', value: '8080' }
          ]
          // No probes: the placeholder image used on first deploy (before the
          // real governance-proxy image is built/pushed — see deploy.sh) does
          // not expose /healthz, and a failing readiness probe would block
          // the initial deployment. Re-add a /healthz readiness probe once
          // the environment is stable and running the real image.
          probes: []
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: '20'
              }
            }
          }
        ]
      }
    }
  }
}

output containerAppName string = governanceProxy.name
output containerAppFqdn string = governanceProxy.properties.configuration.ingress.fqdn
output containerAppPrincipalId string = governanceProxy.identity.principalId
