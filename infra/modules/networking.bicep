// Networking Bicep Module
// Configures Private Link / Managed Private Endpoints for ADX and Grafana.

@description('Name of the ADX cluster')
param adxClusterName string

@description('Name of the Managed Grafana instance')
param grafanaName string

@description('Resource ID of the storage account')
param storageAccountId string

@description('Resource ID of the ADX cluster')
param adxClusterId string

@description('Azure region')
param location string

@description('Whether to enable private endpoints')
param enablePrivateEndpoints bool = false

@description('Tags to apply to resources')
param tags object = {}

// --- ADX Managed Private Endpoint to Storage ---
// Allows ADX to reach Storage over private networking
resource adxStoragePrivateEndpoint 'Microsoft.Kusto/clusters/managedPrivateEndpoints@2024-04-13' = if (enablePrivateEndpoints) {
  name: '${adxClusterName}/storage-pe'
  properties: {
    privateLinkResourceId: storageAccountId
    groupId: 'blob'
    requestMessage: 'ADX cluster requires blob access for Event Grid ingestion'
  }
}

// --- Grafana Managed Private Endpoint to ADX ---
// Allows Grafana to query ADX over a private connection
resource grafanaAdxPrivateEndpoint 'Microsoft.Dashboard/grafana/managedPrivateEndpoints@2023-09-01' = if (enablePrivateEndpoints) {
  name: '${grafanaName}/adx-pe'
  location: location
  tags: tags
  properties: {
    privateLinkResourceId: adxClusterId
    groupIds: ['cluster']
    requestMessage: 'Grafana requires query access to ADX cluster'
  }
}
