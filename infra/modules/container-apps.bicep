// container-apps.bicep — Container Apps Environment + Azure MCP Server Container App
// The MCP Server uses its system-assigned managed identity for outbound Azure calls.
// Incoming requests are authenticated via Entra ID (azureAdClientId app registration).
//
// Architecture:
//   [Foundry] → HTTPS :443 → [Container Apps Envoy (TLS termination)] → [mcp-server :8080]
//
// The MCR image mcr.microsoft.com/azure-sdk/azure-mcp:latest requires '--transport http'
// args to start in HTTP mode (default is stdio). No nginx sidecar needed.

param location string
param resourceToken string
param tags object = {}
param logAnalyticsWorkspaceId string
@secure()
param logAnalyticsKey string
param appInsightsConnectionString string

// Azure AD app registration client ID used to validate incoming tokens (Entra auth)
param azureAdClientId string
param azureTenantId string
param azureSubscriptionId string

// Cosmos DB
param cosmosEndpoint string

// AI Search
param searchEndpoint string

// AI Foundry Project
param foundryProjectName string
param aiServicesEndpoint string

var envName = 'cae-${resourceToken}'
var appName = 'ca-mcp-${resourceToken}'

resource containerAppsEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: envName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspaceId
        sharedKey: logAnalyticsKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

resource mcpServer 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    environmentId: containerAppsEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'mcp-server'
          image: 'mcr.microsoft.com/azure-sdk/azure-mcp:latest'
          // HTTP transport required for remote hosting in Container Apps
          args: [
            '--transport'
            'http'
            '--outgoing-auth-strategy'
            'UseHostingEnvironmentIdentity'
            '--mode'
            'all'
          ]
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            // MCP server binds on 8080; Container Apps Envoy terminates TLS externally
            { name: 'ASPNETCORE_URLS', value: 'http://+:8080' }
            // Use the Container App's system-assigned managed identity for outbound Azure calls
            { name: 'AZURE_TOKEN_CREDENTIALS', value: 'managedidentitycredential' }
            // Required: Container Apps Envoy terminates TLS externally; container runs plain HTTP internally
            { name: 'AZURE_MCP_DANGEROUSLY_DISABLE_HTTPS_REDIRECTION', value: 'true' }
            // Required: read X-Forwarded-Proto so OAuth metadata advertises the correct HTTPS scheme
            { name: 'AZURE_MCP_DANGEROUSLY_ENABLE_FORWARDED_HEADERS', value: 'true' }
            // Entra ID settings for validating incoming bearer tokens
            { name: 'AzureAd__Instance', value: environment().authentication.loginEndpoint }
            { name: 'AzureAd__TenantId', value: azureTenantId }
            { name: 'AzureAd__ClientId', value: azureAdClientId }
            // Audience must match the HTTPS FQDN — this is what Foundry uses when requesting tokens
            // Using the HTTPS URL (not api://) forces Foundry to acquire fresh tokens after role grants
            { name: 'AzureAd__Audience', value: 'https://${appName}.${containerAppsEnv.properties.defaultDomain}' }
            { name: 'AZURE_SUBSCRIPTION_ID', value: azureSubscriptionId }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
            { name: 'COSMOS_ENDPOINT', value: cosmosEndpoint }
            { name: 'AZURE_SEARCH_ENDPOINT', value: searchEndpoint }
            { name: 'AZURE_AI_PROJECT_NAME', value: foundryProjectName }
            { name: 'AZURE_AI_SERVICES_ENDPOINT', value: aiServicesEndpoint }
          ]
          // No HTTP health probes — the MCP server doesn't expose a /health endpoint
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

output containerAppEnvId string = containerAppsEnv.id
output containerAppId string = mcpServer.id
output containerAppName string = mcpServer.name
output containerAppFqdn string = mcpServer.properties.configuration.ingress.fqdn
output containerAppPrincipalId string = mcpServer.identity.principalId
