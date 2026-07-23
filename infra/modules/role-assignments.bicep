// role-assignments.bicep — Least-privilege RBAC for the MCP Server Container App identity
// and AI Foundry Hub/Project identities.
//
// NOTE: Subscription-scope Reader for the Container App MI is assigned in main.bicep
// (subscription targetScope required). All assignments here are RG-scoped.
// NOTE: AcrPull is no longer needed — the MCP server uses the public MCR image directly.

param containerAppPrincipalId string
param hubPrincipalId string
param projectPrincipalId string
// New-style CognitiveServices project MI (shown in new AI Foundry UI)
param newProjectPrincipalId string = ''

param keyVaultId string
param cosmosAccountId string
param searchId string
param storageAccountId string
param aiServicesId string
param azureSpObjectId string = ''
param acrId string = ''
param governanceProxyPrincipalId string = ''

// Built-in role definition IDs
var kvSecretsUserRoleId           = '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User
var cosmosContributorRoleId       = '5bd9cd88-fe45-4216-938b-f97437e15450' // DocumentDB Account Contributor
var searchIndexDataRoleId         = '1407120a-92aa-4202-b7e9-c0e197c71c8f' // Search Index Data Reader
var searchServiceContribRoleId    = '7ca78c08-252a-4471-8644-bb5ff32d4ba0' // Search Service Contributor
var storageBlobContribRoleId      = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor
var cognitiveServicesOpenAiUserId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd' // Cognitive Services OpenAI User
var cognitiveServicesUserRoleId   = 'a97b65f3-24c7-4388-baec-2e87135dc908' // Cognitive Services User
var acrPullRoleId                 = '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull

// ── Container App → Key Vault Secrets User ───────────────────────────────────
resource appKvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVaultId, containerAppPrincipalId, kvSecretsUserRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: containerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── Container App → Cosmos DB Contributor ────────────────────────────────────
resource appCosmosRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cosmosAccountId, containerAppPrincipalId, cosmosContributorRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cosmosContributorRoleId)
    principalId: containerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── Container App → AI Search Index Data Reader ───────────────────────────────
resource appSearchDataRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchId, containerAppPrincipalId, searchIndexDataRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataRoleId)
    principalId: containerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── Container App → AI Search Service Contributor ─────────────────────────────
resource appCogOpenAiRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiServicesId, containerAppPrincipalId, cognitiveServicesOpenAiUserId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAiUserId)
    principalId: containerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── Container App → Cognitive Services User (AI Services account access) ─────
resource appCogUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiServicesId, containerAppPrincipalId, cognitiveServicesUserRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: containerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── AI Foundry Hub → Storage Blob Data Contributor ───────────────────────────
resource hubStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountId, hubPrincipalId, storageBlobContribRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobContribRoleId)
    principalId: hubPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── AI Foundry Hub → Key Vault Secrets User ───────────────────────────────────
resource hubKvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVaultId, hubPrincipalId, kvSecretsUserRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: hubPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── AI Foundry Hub → Cognitive Services User ─────────────────────────────────
resource hubCogUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiServicesId, hubPrincipalId, cognitiveServicesUserRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: hubPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── AI Foundry Project → Storage Blob Data Contributor ───────────────────────
resource projectStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountId, projectPrincipalId, storageBlobContribRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobContribRoleId)
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── AI Foundry Project → Cognitive Services OpenAI User ─────────────────────
resource projectCogOpenAiRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiServicesId, projectPrincipalId, cognitiveServicesOpenAiUserId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAiUserId)
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── New-style Foundry Project → Storage Blob Data Contributor ────────────────
resource newProjectStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(newProjectPrincipalId)) {
  name: guid(storageAccountId, newProjectPrincipalId, storageBlobContribRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobContribRoleId)
    principalId: newProjectPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── New-style Foundry Project → Cognitive Services OpenAI User ───────────────
resource newProjectCogOpenAiRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(newProjectPrincipalId)) {
  name: guid(aiServicesId, newProjectPrincipalId, cognitiveServicesOpenAiUserId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAiUserId)
    principalId: newProjectPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── User SP (MCP Server credentials) → roles on all services ────────────────
// These are conditional — only created if azureSpObjectId is provided.
// Get the object ID with: az ad sp show --id <AZURE_CLIENT_ID> --query id -o tsv

resource spKvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(azureSpObjectId)) {
  name: guid(keyVaultId, azureSpObjectId, kvSecretsUserRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: azureSpObjectId
    principalType: 'ServicePrincipal'
  }
}

resource spCosmosRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(azureSpObjectId)) {
  name: guid(cosmosAccountId, azureSpObjectId, cosmosContributorRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cosmosContributorRoleId)
    principalId: azureSpObjectId
    principalType: 'ServicePrincipal'
  }
}

resource spSearchDataRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(azureSpObjectId)) {
  name: guid(searchId, azureSpObjectId, searchIndexDataRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataRoleId)
    principalId: azureSpObjectId
    principalType: 'ServicePrincipal'
  }
}

resource spSearchSvcRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(azureSpObjectId)) {
  name: guid(searchId, azureSpObjectId, searchServiceContribRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchServiceContribRoleId)
    principalId: azureSpObjectId
    principalType: 'ServicePrincipal'
  }
}

resource spCogOpenAiRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(azureSpObjectId)) {
  name: guid(aiServicesId, azureSpObjectId, cognitiveServicesOpenAiUserId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAiUserId)
    principalId: azureSpObjectId
    principalType: 'ServicePrincipal'
  }
}

resource spCogUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(azureSpObjectId)) {
  name: guid(aiServicesId, azureSpObjectId, cognitiveServicesUserRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: azureSpObjectId
    principalType: 'ServicePrincipal'
  }
}

resource spStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(azureSpObjectId)) {
  name: guid(storageAccountId, azureSpObjectId, storageBlobContribRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobContribRoleId)
    principalId: azureSpObjectId
    principalType: 'ServicePrincipal'
  }
}

// ── Governance Proxy → AcrPull (pulls its own image from ACR) ───────────────
// Conditional — only created when both the ACR resource ID and the proxy's
// principal ID are supplied (governance-proxy.bicep, deployed alongside).
resource governanceProxyAcrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(acrId) && !empty(governanceProxyPrincipalId)) {
  name: guid(acrId, governanceProxyPrincipalId, acrPullRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: governanceProxyPrincipalId
    principalType: 'ServicePrincipal'
  }
}
