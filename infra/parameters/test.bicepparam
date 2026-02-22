using '../main.bicep'

// Test environment parameters
// Deploy: az deployment group create -g rg-file-transfer-test --template-file infra/main.bicep --parameters infra/parameters/test.bicepparam

param environmentName = 'test'
param location = 'eastus2'

// ADX — Dev/Test SKU, moderate retention
param adxClusterName = 'adx-ft-test'
param adxDatabaseName = 'ftevents_test'
param adxSkuName = 'Dev(No SLA)_Standard_E2a_v4'
param adxSkuTier = 'Basic'
param adxSkuCapacity = 1
param retentionPeriod = 'P30D'
param hotCachePeriod = 'P14D'

// Storage
param storageAccountName = 'stfteventstest'
param containerName = 'file-transfer-events'
param blobRetentionDays = 14

// Grafana — public access for testing
param grafanaName = 'grafana-ft-test'
param enableGrafanaPublicAccess = true

// Event Grid — automatic blob ingestion (set enableEventGrid = false for runbook-only ingestion)
param enableEventGrid = true
param eventHubNamespaceName = 'evhns-ft-test'
param dataFormat = 'csv'
param mappingRuleName = 'FileTransferEvents_CsvMapping'

// Existing resources — leave empty to provision new ones
// param existingAdxClusterId = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Kusto/clusters/<name>'
// param existingAdxClusterUri = 'https://<name>.<region>.kusto.windows.net'
// param existingAdxPrincipalId = '<object-id>'
// param existingGrafanaId = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Dashboard/grafana/<name>'
// param existingGrafanaPrincipalId = '<object-id>'
// param existingGrafanaEndpoint = 'https://<name>.xxx.grafana.azure.com'

// Deployer identity — grants Grafana Admin role for portal access
// Get your Object ID: az ad signed-in-user show --query id -o tsv
param deployerPrincipalId = ''

// Networking — private endpoints enabled for test
param enablePrivateEndpoints = true

param tags = {
  team: 'data-platform'
  costCenter: 'test'
}
