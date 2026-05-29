// ai-search.bicep — Azure AI Search (Basic SKU) for RAG / vector indexing

param location string
param resourceToken string
param tags object = {}

var searchName = 'srch-${resourceToken}'

resource aiSearch 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: searchName
  location: location
  tags: tags
  sku: { name: 'basic' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    publicNetworkAccess: 'enabled'
    semanticSearch: 'free' // Free semantic search tier included with Basic
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
  }
}

output searchId string = aiSearch.id
output searchName string = aiSearch.name
output searchEndpoint string = 'https://${aiSearch.name}.search.windows.net'
