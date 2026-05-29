// ai-services.bicep — Azure AI Services account with gpt-5.3-codex model deployment
// This is the CognitiveServices backend for AI Foundry Hub model hosting.

param location string
param resourceToken string
param tags object = {}

var aiServicesName = 'aiss-${resourceToken}'

resource aiServices 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: aiServicesName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    customSubDomainName: aiServicesName
    disableLocalAuth: false
    allowProjectManagement: true
  }
}

// Deploy gpt-5.3-codex (latest Codex model available in swedencentral)
resource codexDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: aiServices
  name: 'gpt-5-codex'
  sku: {
    name: 'GlobalStandard'
    capacity: 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5.3-codex'
      version: '2026-02-24'
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

// New-style AI Foundry project (CognitiveServices/accounts/projects).
// This is what appears in the new Azure AI Foundry UI (ai.azure.com).
// The old Hub+Project (MachineLearningServices/workspaces) model is kept in
// ai-foundry.bicep for backward compatibility and monitoring wiring.
resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: aiServices
  name: 'agent-project'
  location: location
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

output aiServicesId string = aiServices.id
output aiServicesName string = aiServices.name
output aiServicesEndpoint string = aiServices.properties.endpoint
output aiServicesPrincipalId string = aiServices.identity.principalId
output codexDeploymentName string = codexDeployment.name
output newProjectName string = foundryProject.name
output newProjectId string = foundryProject.id
output newProjectPrincipalId string = foundryProject.identity.principalId
output newProjectEndpoint string = 'https://${aiServicesName}.services.ai.azure.com/api/projects/${foundryProject.name}'
