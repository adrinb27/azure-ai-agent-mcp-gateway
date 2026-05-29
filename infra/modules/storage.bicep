// storage.bicep — Storage Account required by AI Foundry Hub

param location string
param resourceToken string
param tags object = {}

// Storage account names: 3-24 chars, lowercase alphanumeric only
// Using 'stor' (4 chars) prefix ensures name is always >= 3 chars
#disable-next-line BCP334
var storName = take(replace('stor${resourceToken}', '-', ''), 24)

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  #disable-next-line BCP334
  name: storName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
  }
}

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
