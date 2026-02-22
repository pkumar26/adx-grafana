// Main Bicep Orchestrator
// Deploys all infrastructure for ADX File-Transfer Analytics.
// Supports using existing ADX cluster and/or Grafana instance via "existing*" parameters.
// Usage: az deployment group create --template-file infra/main.bicep --parameters infra/parameters/dev.bicepparam

targetScope = 'resourceGroup'

// --- Shared Parameters ---

@description('Environment name (dev, test, prod)')
param environmentName string

@description('Azure region for all resources')
param location string

@description('Tags applied to all resources')
param tags object = {}

// --- ADX Parameters ---

@description('Name of the ADX cluster (used for new or existing)')
param adxClusterName string

@description('Name of the ADX database')
param adxDatabaseName string

@description('ADX SKU name (ignored when using existing cluster)')
param adxSkuName string = 'Dev(No SLA)_Standard_E2a_v4'

@description('ADX SKU tier (ignored when using existing cluster)')
param adxSkuTier string = 'Basic'

@description('ADX SKU capacity (ignored when using existing cluster)')
param adxSkuCapacity int = 1

@description('Data retention period (ISO 8601)')
param retentionPeriod string = 'P90D'

@description('Hot cache period (ISO 8601)')
param hotCachePeriod string = 'P30D'

// --- Existing ADX Parameters (optional — set to use an existing cluster) ---

@description('Resource ID of an existing ADX cluster. Leave empty to provision a new one.')
param existingAdxClusterId string = ''

@description('URI of the existing ADX cluster (e.g., https://mycluster.eastus2.kusto.windows.net). Required when existingAdxClusterId is set.')
param existingAdxClusterUri string = ''

@description('Principal ID (object ID) of the existing ADX cluster system-assigned managed identity. Required when existingAdxClusterId is set.')
param existingAdxPrincipalId string = ''

// --- Storage Parameters ---

@description('Name of the storage account')
param storageAccountName string

@description('Blob container name')
param containerName string = 'file-transfer-events'

@description('Blob retention in days (0 = no lifecycle)')
param blobRetentionDays int = 30

// --- Grafana Parameters ---

@description('Name of the Managed Grafana instance (used for new or existing)')
param grafanaName string

@description('Whether to enable public access on Grafana (ignored when using existing)')
param enableGrafanaPublicAccess bool = true

// --- Existing Grafana Parameters (optional — set to use an existing instance) ---

@description('Resource ID of an existing Managed Grafana instance. Leave empty to provision a new one.')
param existingGrafanaId string = ''

@description('Principal ID (object ID) of the existing Grafana system-assigned managed identity. Required when existingGrafanaId is set.')
param existingGrafanaPrincipalId string = ''

@description('Endpoint URL of the existing Grafana instance (e.g., https://mygrafana-xxxx.xxx.grafana.azure.com). Required when existingGrafanaId is set.')
param existingGrafanaEndpoint string = ''

// --- Event Grid Parameters ---

@description('Whether to deploy Event Grid + Event Hub for automatic blob ingestion. Set to false for runbook-only (manual) ingestion.')
param enableEventGrid bool = true

@description('Name of the Event Hub namespace for Event Grid routing (ignored when enableEventGrid=false)')
param eventHubNamespaceName string = ''

@description('Data format for ingestion (csv or json)')
param dataFormat string = 'csv'

@description('Ingestion mapping rule name')
param mappingRuleName string = 'FileTransferEvents_CsvMapping'

// --- Networking Parameters ---

@description('Whether to enable private endpoints')
param enablePrivateEndpoints bool = false

@description('Azure AD Object ID of the deployer. Grants Grafana Admin role for portal access. Leave empty to skip.')
param deployerPrincipalId string = ''

// --- Computed Values ---

var useExistingAdx = !empty(existingAdxClusterId)
var useExistingGrafana = !empty(existingGrafanaId)

var allTags = union(tags, {
  environment: environmentName
  project: 'adx-file-transfer-analytics'
})

// --- Module: ADX Cluster + Database (uses existing when existingAdxClusterId is set) ---

module adxCluster 'modules/adx-cluster.bicep' = {
  name: 'deploy-adx-cluster'
  params: {
    clusterName: adxClusterName
    location: location
    skuName: adxSkuName
    skuTier: adxSkuTier
    skuCapacity: adxSkuCapacity
    databaseName: adxDatabaseName
    retentionPeriod: retentionPeriod
    hotCachePeriod: hotCachePeriod
    tags: allTags
    useExisting: useExistingAdx
    existingClusterId: existingAdxClusterId
    existingClusterUri: existingAdxClusterUri
    existingPrincipalId: existingAdxPrincipalId
  }
}

// --- Module: Storage Account ---

module storage 'modules/storage.bicep' = {
  name: 'deploy-storage'
  params: {
    storageAccountName: storageAccountName
    location: location
    containerName: containerName
    blobRetentionDays: blobRetentionDays
    tags: allTags
  }
}

// --- Module: Managed Grafana (uses existing when existingGrafanaId is set) ---

module grafana 'modules/grafana.bicep' = {
  name: 'deploy-grafana'
  params: {
    grafanaName: grafanaName
    location: location
    enablePublicAccess: enableGrafanaPublicAccess
    tags: allTags
    useExisting: useExistingGrafana
    existingGrafanaId: existingGrafanaId
    existingPrincipalId: existingGrafanaPrincipalId
    existingEndpoint: existingGrafanaEndpoint
  }
}

// --- Module: Event Grid Data Connection (optional — skipped when enableEventGrid=false) ---

module eventGrid 'modules/event-grid.bicep' = if (enableEventGrid) {
  name: 'deploy-event-grid'
  params: {
    clusterName: adxClusterName
    databaseName: adxDatabaseName
    location: location
    storageAccountId: storage.outputs.storageAccountId
    tableName: 'FileTransferEvents_Raw'
    dataFormat: dataFormat
    mappingRuleName: mappingRuleName
    containerName: containerName
    eventHubNamespaceName: eventHubNamespaceName
    adxClusterPrincipalId: adxCluster.outputs.clusterPrincipalId
    tags: allTags
  }
  dependsOn: [
    adxSchema  // Schema must exist before data connection (table + mapping validation)
    identity   // ADX MI must have Storage Blob Data Reader before data connection can ingest
  ]
}

// --- Module: ADX Schema Initialization (creates tables, mappings, policies via Kusto script) ---

module adxSchema 'modules/adx-schema.bicep' = {
  name: 'deploy-adx-schema'
  params: {
    clusterName: adxClusterName
    databaseName: adxDatabaseName
  }
  dependsOn: [
    adxCluster
  ]
}

// --- Module: Identity & RBAC ---

module identity 'modules/identity.bicep' = {
  name: 'deploy-identity'
  params: {
    grafanaPrincipalId: grafana.outputs.grafanaPrincipalId
    adxClusterPrincipalId: adxCluster.outputs.clusterPrincipalId
    adxClusterId: adxCluster.outputs.clusterId
    adxClusterName: adxClusterName
    adxDatabaseName: adxDatabaseName
    storageAccountId: storage.outputs.storageAccountId
    storageAccountName: storageAccountName
    grafanaName: grafanaName
    deployerPrincipalId: deployerPrincipalId
  }
}

// --- Module: Networking (Private Endpoints) ---

module networking 'modules/networking.bicep' = if (enablePrivateEndpoints) {
  name: 'deploy-networking'
  params: {
    adxClusterName: adxClusterName
    grafanaName: grafanaName
    storageAccountId: storage.outputs.storageAccountId
    adxClusterId: adxCluster.outputs.clusterId
    location: location
    enablePrivateEndpoints: enablePrivateEndpoints
    tags: allTags
  }
}

// --- Outputs ---

@description('ADX cluster URI')
output adxClusterUri string = adxCluster.outputs.clusterUri

@description('ADX database name')
output adxDatabaseName string = adxDatabaseName

@description('Grafana endpoint URL')
output grafanaEndpoint string = grafana.outputs.grafanaEndpoint

@description('Storage account name')
output storageAccountName string = storage.outputs.storageAccountName

@description('Environment name')
output environmentName string = environmentName

@description('Whether an existing ADX cluster was used')
output usedExistingAdx bool = useExistingAdx

@description('Whether an existing Grafana instance was used')
output usedExistingGrafana bool = useExistingGrafana

@description('Whether Event Grid + Event Hub were provisioned')
output eventGridEnabled bool = enableEventGrid

@description('Grafana instance name (used by deploy.sh for post-deployment configuration)')
output grafanaName string = grafanaName
