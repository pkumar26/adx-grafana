// Event Grid Data Connection Bicep Module
// Creates an ADX Event Grid data connection for automatic blob ingestion.
// Targets the staging table (FileTransferEvents_Raw).
// Uses managed-identity auth throughout (Event Grid → Event Hub, ADX → Storage/Event Hub)
// to work in environments where Event Hub local auth (SAS) is disabled.

@description('Name of the ADX cluster')
param clusterName string

@description('Name of the ADX database')
param databaseName string

@description('Azure region')
param location string

@description('Resource ID of the storage account')
param storageAccountId string

@description('Target staging table name')
param tableName string = 'FileTransferEvents_Raw'

@description('Data format for ingestion (CSV or JSON)')
param dataFormat string = 'csv'

@description('Ingestion mapping rule name')
param mappingRuleName string = 'FileTransferEvents_CsvMapping'

@description('Whether to ignore the first record (header row for CSV)')
param ignoreFirstRecord bool = true

@description('Blob container name for event filtering')
param containerName string = 'file-transfer-events'

@description('Name of the Event Hub namespace for Event Grid routing')
param eventHubNamespaceName string

@description('Principal ID of the ADX cluster system-assigned managed identity (for Event Hub RBAC)')
param adxClusterPrincipalId string

@description('Tags to apply to resources')
param tags object = {}

// Event Hub namespace for Event Grid → ADX routing
resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: eventHubNamespaceName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: 1
  }
}

// Event Hub within the namespace for the data connection
resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: eventHubNamespace
  name: 'file-transfer-events'
  properties: {
    messageRetentionInDays: 1
    partitionCount: 1
  }
}

// Consumer group for ADX
resource consumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  parent: eventHub
  name: 'adx-consumer'
  properties: {}
}

// Built-in role IDs
var eventHubsDataReceiverRoleId = 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde'
var eventHubsDataSenderRoleId = '2b629674-e913-4c01-ae53-ef4638d8f975'

// ADX MI → Event Hubs Data Receiver (required for MI-based data connection)
resource adxEventHubReceiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(eventHubNamespace.id, adxClusterPrincipalId, eventHubsDataReceiverRoleId)
  scope: eventHubNamespace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventHubsDataReceiverRoleId)
    principalId: adxClusterPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Event Grid system topic on the storage account (with MI for authenticated delivery)
resource systemTopic 'Microsoft.EventGrid/systemTopics@2023-12-15-preview' = {
  name: '${clusterName}-storage-topic'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    source: storageAccountId
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

// Event Grid MI → Event Hubs Data Sender (required when Event Hub disableLocalAuth=true)
resource eventGridEventHubSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(eventHubNamespace.id, systemTopic.id, eventHubsDataSenderRoleId)
  scope: eventHubNamespace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventHubsDataSenderRoleId)
    principalId: systemTopic.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Event Grid subscription to route blob events to Event Hub (MI-based delivery)
resource eventSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2023-12-15-preview' = {
  parent: systemTopic
  name: 'blob-to-eventhub'
  properties: {
    deliveryWithResourceIdentity: {
      identity: {
        type: 'SystemAssigned'
      }
      destination: {
        endpointType: 'EventHub'
        properties: {
          resourceId: eventHub.id
        }
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Storage.BlobCreated'
      ]
      subjectBeginsWith: '/blobServices/default/containers/${containerName}/'
      subjectEndsWith: ''
    }
    eventDeliverySchema: 'EventGridSchema'
  }
  dependsOn: [
    eventGridEventHubSender // MI must have Send permission before subscription validates
  ]
}

// ADX Event Grid data connection
resource dataConnection 'Microsoft.Kusto/clusters/databases/dataConnections@2024-04-13' = {
  name: '${clusterName}/${databaseName}/FileTransferEventsConnection'
  location: location
  kind: 'EventGrid'
  properties: {
    storageAccountResourceId: storageAccountId
    eventGridResourceId: systemTopic.id
    eventHubResourceId: eventHub.id
    consumerGroup: consumerGroup.name
    tableName: tableName
    dataFormat: dataFormat
    mappingRuleName: mappingRuleName
    ignoreFirstRecord: ignoreFirstRecord
    blobStorageEventType: 'Microsoft.Storage.BlobCreated'
    managedIdentityResourceId: resourceId('Microsoft.Kusto/clusters', clusterName)
  }
  dependsOn: [
    eventSubscription
    adxEventHubReceiver // MI must have Event Hub access before data connection validates
  ]
}

@description('The resource ID of the Event Hub namespace')
output eventHubNamespaceId string = eventHubNamespace.id

@description('The resource ID of the data connection')
output dataConnectionId string = dataConnection.id
