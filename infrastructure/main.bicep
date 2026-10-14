param location string = resourceGroup().location

@description('Name of the Function App.')
param functionAppName string

@description('Name of the Flex Consumption hosting plan.')
param functionPlanName string

@description('Globally unique name for the Storage Account.')
param storageAccountName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location

  sku: {
    name: 'Standard_LRS'
  }

  kind: 'StorageV2'

  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource rawDataContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'raw-data'

  properties: {
    publicAccess: 'None'
  }
}

@description('Globally unique name for the Cosmos DB account.')
param cosmosAccountName string

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: cosmosAccountName
  location: location

  kind: 'GlobalDocumentDB'

  properties: {
    databaseAccountOfferType: 'Standard'

    locations: [
      {
        locationName: location
        failoverPriority: 0
      }
    ]

    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]

    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }

    publicNetworkAccess: 'Enabled'

    backupPolicy: {
      type: 'Periodic'
      periodicModeProperties: {
        backupIntervalInMinutes: 240
        backupRetentionIntervalInHours: 8
        backupStorageRedundancy: 'Local'
      }
    }
  }
}

resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: cosmosAccount
  name: 'pipeline-db'

  properties: {
    resource: {
      id: 'pipeline-db'
    }
  }
}

resource resultsContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: cosmosDatabase
  name: 'results'

  properties: {
    resource: {
      id: 'results'

      partitionKey: {
        paths: [
          '/source_file'
        ]
        kind: 'Hash'
      }
    }
  }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${functionAppName}-logs'
  location: location

  properties: {
    retentionInDays: 30
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${functionAppName}-insights'
  location: location
  kind: 'web'

  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource functionPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: functionPlanName
  location: location

  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }

  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'

  identity: {
    type: 'SystemAssigned'
  }

  properties: {
    serverFarmId: functionPlan.id
    httpsOnly: true

    siteConfig: {
      linuxFxVersion: 'Python|3.11'

      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.properties.ConnectionString
        }
        {
          name: 'COSMOS_ENDPOINT'
          value: cosmosAccount.properties.documentEndpoint
        }
        {
          name: 'COSMOS_DATABASE'
          value: 'pipeline-db'
        }
        {
          name: 'COSMOS_CONTAINER'
          value: 'results'
        }
      ]
    }
  }
}

// Built-in Azure RBAC role IDs
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'

// Give the Function Managed Identity access to Blob Storage
resource blobRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageBlobDataOwnerRoleId)
  scope: storageAccount

  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      storageBlobDataOwnerRoleId
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Azure Functions also requires Queue access for the Blob trigger infrastructure
resource queueRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageQueueDataContributorRoleId)
  scope: storageAccount

  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      storageQueueDataContributorRoleId
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

var cosmosDataContributorRoleId = '00000000-0000-0000-0000-000000000002'

resource cosmosDataContributorRole 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmosAccount

  name: guid(
    cosmosAccount.id,
    functionApp.id,
    cosmosDataContributorRoleId
  )

  properties: {
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/${cosmosDataContributorRoleId}'
    principalId: functionApp.identity.principalId
    scope: cosmosAccount.id
  }
}

resource eventGridSystemTopic 'Microsoft.EventGrid/systemTopics@2023-12-15-preview' = {
  name: '${storageAccountName}-events'
  location: location

  properties: {
    source: storageAccount.id
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

resource blobCreatedSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2023-12-15-preview' = {
  parent: eventGridSystemTopic
  name: 'raw-data-blob-created'

  properties: {
    filter: {
      includedEventTypes: [
        'Microsoft.Storage.BlobCreated'
      ]

      subjectBeginsWith: '/blobServices/default/containers/raw-data/'
    }

    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}
