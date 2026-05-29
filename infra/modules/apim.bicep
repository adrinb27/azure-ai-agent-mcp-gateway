// apim.bicep — API Management (BasicV2) acting as secure gateway to the MCP Container App
//
// Responsibilities:
//   - Validate incoming Entra ID tokens (audience = APIM gateway app)
//   - Exchange caller token for a backend token (OBO for user tokens, CC for app-only M2M)
//   - Forward authenticated requests to the MCP Container App backend
//
// Auth flow:
//   Caller ──(Bearer: api://APIM_APP)──▶ APIM ──(Bearer: api://MCP_CA_APP)──▶ MCP CA
//
// Named values injected by Bicep:
//   obo-client-id     = APIM Gateway App ID (non-secret)
//   obo-client-secret = APIM Gateway App client secret (secret)

param location string
param resourceToken string
param tags object = {}

@description('Publisher email address — required by APIM')
param publisherEmail string

@description('Entra ID tenant ID')
param tenantId string

@description('APIM Gateway app registration client ID (used to validate incoming tokens and as OBO client)')
param apimGatewayAppId string

@secure()
@description('APIM Gateway app registration client secret (used for token exchange)')
param apimGatewayClientSecret string

@description('MCP CA app registration client ID (used as token audience for backend)')
param mcpCaAppId string

@description('MCP Container App HTTPS URL (backend target)')
param mcpBackendUrl string

var apimName = 'apim-${resourceToken}'

// ── APIM Service ──────────────────────────────────────────────────────────────
resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: 'BasicV2'
    capacity: 1
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: 'Azure AI Agent POC'
  }
}

// ── Named Values ──────────────────────────────────────────────────────────────
resource nvClientId 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'obo-client-id'
  properties: {
    displayName: 'obo-client-id'
    value: apimGatewayAppId
    secret: false
  }
}

resource nvClientSecret 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'obo-client-secret'
  properties: {
    displayName: 'obo-client-secret'
    value: apimGatewayClientSecret
    secret: true
  }
}

// ── Backend (MCP Container App) ───────────────────────────────────────────────
resource mcpBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = {
  parent: apim
  name: 'mcp-server'
  properties: {
    description: 'Azure MCP Server (Container App)'
    url: mcpBackendUrl
    protocol: 'http'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

// ── MCP Gateway API ───────────────────────────────────────────────────────────
resource mcpApi 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'mcp-gateway'
  properties: {
    displayName: 'MCP Gateway (OBO)'
    path: 'mcp'
    protocols: ['https']
    subscriptionRequired: false
    isCurrent: true
  }
}

// Wildcard operations to forward all GET and POST requests
resource getOp 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: mcpApi
  name: 'get-wildcard'
  properties: {
    displayName: 'GET /*'
    method: 'GET'
    urlTemplate: '/*'
  }
}

resource postOp 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: mcpApi
  name: 'post-wildcard'
  properties: {
    displayName: 'POST /*'
    method: 'POST'
    urlTemplate: '/*'
  }
}

// ── API Policy ────────────────────────────────────────────────────────────────
// Load the policy template and substitute tenant/app IDs at deploy time.
// Placeholders in apim-obo-policy.xml:
//   APIM_TENANT_ID        → tenantId
//   APIM_GATEWAY_APP_ID   → apimGatewayAppId
//   MCP_CA_APP_ID         → mcpCaAppId
var policyTemplate = loadTextContent('../apim-obo-policy.xml')
var policyXml = replace(
  replace(
    replace(policyTemplate, 'APIM_TENANT_ID', tenantId),
    'APIM_GATEWAY_APP_ID', apimGatewayAppId
  ),
  'MCP_CA_APP_ID', mcpCaAppId
)

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = {
  parent: mcpApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: policyXml
  }
  dependsOn: [nvClientId, nvClientSecret, mcpBackend]
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output apimName string = apim.name
// gatewayUrl already contains the full https:// URL — no prefix needed
output apimGatewayUrl string = apim.properties.gatewayUrl
output apimId string = apim.id
