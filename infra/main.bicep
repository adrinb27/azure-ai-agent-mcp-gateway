// main.bicep — Subscription-scope orchestrator
// Deploys all resources for the Azure AI Agent POC (USG)
//
// Deploy with:
//   az deployment sub create \
//     --location swedencentral \
//     --template-file infra/main.bicep \
//     --parameters infra/main.parameters.json \
//     --parameters apimGatewayClientSecret="<apim-app-secret>"

targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Environment name used for tagging and deriving the default resource group name')
param environmentName string

@description('Resource group name. Defaults to rg-{environmentName}. You can use any existing or new RG name — Bicep will create it if it does not exist.')
param resourceGroupName string = 'rg-${environmentName}'

@minLength(1)
@description('Azure region for all resources')
param location string = 'swedencentral'

@description('Entra ID app registration client ID — used to validate incoming bearer tokens on the MCP server')
param azureAdClientId string

@description('Service Principal Tenant ID (non-sensitive)')
param azureTenantId string

@description('Azure Subscription ID')
param azureSubscriptionId string

@description('APIM Gateway app registration client ID (receives incoming tokens, performs OBO/CC exchange)')
param apimGatewayAppId string

@secure()
@description('APIM Gateway app registration client secret (required for token exchange)')
param apimGatewayClientSecret string

@description('Publisher email for the APIM service')
param apimPublisherEmail string = 'admin@contoso.com'

@description('Object ID of the Service Principal (run: az ad sp show --id <appId> --query id -o tsv). If provided, RBAC roles are assigned to the SP directly so the MCP server can authenticate with its credentials.')
param azureSpObjectId string = ''

@description('Governance proxy container image (owner/governance-proxy:tag from ACR). Defaults to a placeholder on first deploy — deploy.sh builds/pushes the real image and swaps it in via az containerapp update.')
param governanceProxyImage string = 'mcr.microsoft.com/azuredocs/aci-helloworld:latest'

@description('Set to false to skip the governance proxy entirely — APIM routes directly to the MCP Container App (no centralized policy enforcement). Defaults to true.')
param enableGovernanceProxy bool = true

// Built-in role IDs (subscription scope)
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader

var tags = {
  environment: environmentName
  project: 'az-agent-poc-usg'
  managedBy: 'bicep'
}

var resourceToken = take(uniqueString(subscription().id, resourceGroupName, location), 8)

// ── Resource Group ────────────────────────────────────────────────────────────
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// ── Monitoring ────────────────────────────────────────────────────────────────
module monitoring './modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
  }
}

// ── Storage (required by AI Foundry Hub) ─────────────────────────────────────
module storage './modules/storage.bicep' = {
  name: 'storage'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
  }
}

// ── Key Vault ─────────────────────────────────────────────────────────────────
module keyVault './modules/key-vault.bicep' = {
  name: 'keyVault'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    clientSecret: 'placeholder-not-used'
  }
}

// ── Cosmos DB ─────────────────────────────────────────────────────────────────
module cosmosDb './modules/cosmos-db.bicep' = {
  name: 'cosmosDb'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
  }
}

// ── AI Search ─────────────────────────────────────────────────────────────────
module aiSearch './modules/ai-search.bicep' = {
  name: 'aiSearch'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
  }
}

// ── Azure AI Services (model hosting for Foundry) ────────────────────────────
module aiServices './modules/ai-services.bicep' = {
  name: 'aiServices'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
  }
}

// ── AI Foundry Hub + Project ──────────────────────────────────────────────────
module aiFoundry './modules/ai-foundry.bicep' = {
  name: 'aiFoundry'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    appInsightsId: monitoring.outputs.appInsightsId
    keyVaultId: keyVault.outputs.keyVaultId
    storageAccountId: storage.outputs.storageAccountId
    aiServicesId: aiServices.outputs.aiServicesId
    aiServicesEndpoint: aiServices.outputs.aiServicesEndpoint
  }
}

// ── Container Registry ────────────────────────────────────────────────────────
// Optional: use for custom MCP server images. The default deployment pulls
// mcr.microsoft.com/azure-sdk/azure-mcp:latest directly (no ACR needed).
module acr './modules/container-registry.bicep' = {
  name: 'acr'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
  }
}

// ── Container Apps (MCP Server) ───────────────────────────────────────────────
module containerApps './modules/container-apps.bicep' = {
  name: 'containerApps'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    logAnalyticsKey: monitoring.outputs.logAnalyticsKey
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    azureAdClientId: azureAdClientId
    azureTenantId: azureTenantId
    azureSubscriptionId: azureSubscriptionId
    cosmosEndpoint: cosmosDb.outputs.cosmosEndpoint
    searchEndpoint: aiSearch.outputs.searchEndpoint
    foundryProjectName: aiFoundry.outputs.projectName
    aiServicesEndpoint: aiServices.outputs.aiServicesEndpoint
  }
}

// ── Governance Proxy ──────────────────────────────────────────────────────────
// Sits between APIM and the real MCP Container App so AGT policy
// (policies/governance-policy.yaml) applies to EVERY caller that reaches the
// MCP server through APIM — not just calls made through this repo's local
// Python demo scripts. See governance-proxy/ for the service source and
// docs/governance-demo.md for the enforcement architecture.
//
// Deployed only when enableGovernanceProxy is true (default). When false,
// APIM routes directly to the MCP Container App and no proxy resources are
// created at all — useful for environments that don't need centralized
// enforcement or want to avoid the extra hop/cost.
module governanceProxy './modules/governance-proxy.bicep' = if (enableGovernanceProxy) {
  name: 'governanceProxy'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    containerAppsEnvId: containerApps.outputs.containerAppEnvId
    mcpBackendUrl: 'https://${containerApps.outputs.containerAppFqdn}'
    governanceProxyImage: governanceProxyImage
    acrLoginServer: acr.outputs.acrLoginServer
  }
}

// Governance proxy's own image-pull permission (RBAC role + registry auth
// config) is granted via the roleAssignments module below and the
// `registries` block baked into governance-proxy.bicep — both only apply
// when the proxy is actually deployed.

// ── API Management (MCP Gateway) ──────────────────────────────────────────────
// APIM sits between AI Foundry and the backend. When the governance proxy is
// enabled, it sits in front of the real MCP Container App and APIM routes to
// it; the proxy relays the already-exchanged token through unchanged to the
// MCP CA. When disabled, APIM routes directly to the MCP Container App.
module apim './modules/apim.bicep' = {
  name: 'apim'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    publisherEmail: apimPublisherEmail
    tenantId: azureTenantId
    apimGatewayAppId: apimGatewayAppId
    apimGatewayClientSecret: apimGatewayClientSecret
    mcpCaAppId: azureAdClientId
    mcpBackendUrl: enableGovernanceProxy ? 'https://${governanceProxy.outputs.containerAppFqdn}' : 'https://${containerApps.outputs.containerAppFqdn}'
  }
}

// ── Subscription Reader — Container App MI ────────────────────────────────────
// Grants the MCP server's managed identity read access to the subscription so it
// can enumerate resource groups, Fabric capacities, and other Azure resources.
resource containerAppSubscriptionReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, environmentName, 'containerapp-reader', readerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: containerApps.outputs.containerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── Role Assignments ──────────────────────────────────────────────────────────
module roleAssignments './modules/role-assignments.bicep' = {
  name: 'roleAssignments'
  scope: rg
  params: {
    containerAppPrincipalId: containerApps.outputs.containerAppPrincipalId
    hubPrincipalId: aiFoundry.outputs.hubPrincipalId
    projectPrincipalId: aiFoundry.outputs.projectPrincipalId
    newProjectPrincipalId: aiServices.outputs.newProjectPrincipalId
    keyVaultId: keyVault.outputs.keyVaultId
    cosmosAccountId: cosmosDb.outputs.cosmosAccountId
    searchId: aiSearch.outputs.searchId
    storageAccountId: storage.outputs.storageAccountId
    aiServicesId: aiServices.outputs.aiServicesId
    azureSpObjectId: azureSpObjectId
    acrId: acr.outputs.acrId
    governanceProxyPrincipalId: enableGovernanceProxy ? governanceProxy.outputs.containerAppPrincipalId : ''
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output resourceGroupName string = rg.name
output mcpServerUrl string = 'https://${containerApps.outputs.containerAppFqdn}'
output governanceProxyEnabled bool = enableGovernanceProxy
output governanceProxyName string = enableGovernanceProxy ? governanceProxy.outputs.containerAppName : ''
output governanceProxyUrl string = enableGovernanceProxy ? 'https://${governanceProxy.outputs.containerAppFqdn}' : ''
output acrLoginServer string = acr.outputs.acrLoginServer
output acrName string = acr.outputs.acrName
output apimGatewayUrl string = apim.outputs.apimGatewayUrl
output keyVaultName string = keyVault.outputs.keyVaultName
output cosmosEndpoint string = cosmosDb.outputs.cosmosEndpoint
output searchEndpoint string = aiSearch.outputs.searchEndpoint
output foundryHubName string = aiFoundry.outputs.hubName
output foundryProjectName string = aiFoundry.outputs.projectName
output aiServicesEndpoint string = aiServices.outputs.aiServicesEndpoint
output codexDeploymentName string = aiServices.outputs.codexDeploymentName
output appInsightsConnectionString string = monitoring.outputs.appInsightsConnectionString
// New-style project (visible in new AI Foundry UI at ai.azure.com)
output newFoundryProjectName string = aiServices.outputs.newProjectName
output newFoundryProjectEndpoint string = aiServices.outputs.newProjectEndpoint
output newFoundryProjectPrincipalId string = aiServices.outputs.newProjectPrincipalId
