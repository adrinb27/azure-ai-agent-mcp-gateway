// ai-foundry.bicep — AI Foundry Hub + Project
// Hub is a MachineLearningServices workspace with kind=Hub
// Project is a MachineLearningServices workspace with kind=Project linked to the Hub

param location string
param resourceToken string
param tags object = {}
param appInsightsId string
param keyVaultId string
param storageAccountId string

// AI Services connection
param aiServicesId string
param aiServicesEndpoint string

var hubName = 'aih-${resourceToken}'
var projectName = 'aip-${resourceToken}'

resource foundryHub 'Microsoft.MachineLearningServices/workspaces@2024-04-01' = {
  name: hubName
  location: location
  tags: tags
  kind: 'Hub'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    friendlyName: 'AI Foundry Hub'
    description: 'Azure AI Foundry Hub for the agent POC'
    keyVault: keyVaultId
    storageAccount: storageAccountId
    applicationInsights: appInsightsId
    primaryUserAssignedIdentity: null
    publicNetworkAccess: 'Enabled'
    hbiWorkspace: false
  }
}

// Connect the AI Services account to the Hub so models are available in the project
resource aiServicesConnection 'Microsoft.MachineLearningServices/workspaces/connections@2024-04-01' = {
  parent: foundryHub
  name: 'ai-services-connection'
  properties: {
    category: 'AIServices'
    target: aiServicesEndpoint
    authType: 'AAD'
    isSharedToAll: true
    metadata: {
      ApiType: 'Azure'
      ResourceId: aiServicesId
    }
  }
}

resource foundryProject 'Microsoft.MachineLearningServices/workspaces@2024-04-01' = {
  name: projectName
  location: location
  tags: tags
  kind: 'Project'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    friendlyName: 'AI Agent POC Project'
    description: 'AI Foundry Project — hosts agent powered by gpt-5.3-codex'
    hubResourceId: foundryHub.id
    publicNetworkAccess: 'Enabled'
    hbiWorkspace: false
  }
}

output hubId string = foundryHub.id
output hubName string = foundryHub.name
output hubPrincipalId string = foundryHub.identity.principalId
output projectId string = foundryProject.id
output projectName string = foundryProject.name
output projectPrincipalId string = foundryProject.identity.principalId
output connectionName string = aiServicesConnection.name
