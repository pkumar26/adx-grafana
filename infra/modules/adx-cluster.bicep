// ADX Cluster + Database Bicep Module
// Provisions Azure Data Explorer cluster with system-assigned identity and a database.
// When useExisting=true, skips creation and returns the provided existing resource properties.

@description('Name of the ADX cluster')
param clusterName string

@description('Azure region for the cluster')
param location string

@description('ADX SKU name (e.g., Dev(No SLA)_Standard_E2a_v4 for dev/test, Standard_E2a_v4 for prod)')
param skuName string = 'Dev(No SLA)_Standard_E2a_v4'

@description('ADX SKU tier (Basic for dev/test, Standard for prod)')
param skuTier string = 'Basic'

@description('SKU capacity (number of instances)')
param skuCapacity int = 1

@description('Name of the database')
param databaseName string

@description('Data retention period (ISO 8601 duration, e.g., P90D)')
param retentionPeriod string = 'P90D'

@description('Hot cache period (ISO 8601 duration, e.g., P30D)')
param hotCachePeriod string = 'P30D'

@description('Tags to apply to resources')
param tags object = {}

@description('Set to true to skip provisioning and use an existing ADX cluster')
param useExisting bool = false

@description('Resource ID of the existing ADX cluster (required when useExisting=true)')
param existingClusterId string = ''

@description('URI of the existing ADX cluster (required when useExisting=true)')
param existingClusterUri string = ''

@description('Principal ID of the existing ADX cluster managed identity (required when useExisting=true)')
param existingPrincipalId string = ''

resource adxCluster 'Microsoft.Kusto/clusters@2024-04-13' = if (!useExisting) {
  name: clusterName
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuTier
    capacity: skuCapacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    enableStreamingIngest: false
    enablePurge: false
    enableAutoStop: true
  }
}

// Database uses full name syntax (not parent) because adxCluster is conditional
resource database 'Microsoft.Kusto/clusters/databases@2024-04-13' = if (!useExisting) {
  #disable-next-line use-parent-property
  name: '${clusterName}/${databaseName}'
  location: location
  kind: 'ReadWrite'
  properties: {
    softDeletePeriod: retentionPeriod
    hotCachePeriod: hotCachePeriod
  }
  dependsOn: [
    adxCluster
  ]
}

@description('The resource ID of the ADX cluster')
output clusterId string = useExisting ? existingClusterId : adxCluster.id

@description('The resource ID of the ADX database')
output databaseId string = useExisting ? existingClusterId : database.id

@description('The principal ID of the ADX cluster system-assigned managed identity')
output clusterPrincipalId string = useExisting ? existingPrincipalId : adxCluster!.identity.principalId

@description('The URI of the ADX cluster')
output clusterUri string = useExisting ? existingClusterUri : adxCluster!.properties.uri

@description('The name of the ADX cluster')
output clusterNameOutput string = clusterName
