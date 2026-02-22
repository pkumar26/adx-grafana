using '../main.bicep'

// Dev environment parameters
// Deploy: az deployment group create -g rg-file-transfer-dev --template-file infra/main.bicep --parameters infra/parameters/dev.bicepparam

param environmentName = 'dev'
param location = 'eastus2'

// ADX — Dev/Test SKU, short retention
param adxClusterName = 'adx-ft-dev'
param adxDatabaseName = 'ftevents_dev'
param adxSkuName = 'Dev(No SLA)_Standard_E2a_v4'
param adxSkuTier = 'Basic'
param adxSkuCapacity = 1
param retentionPeriod = 'P30D'
param hotCachePeriod = 'P7D'

// Storage
param storageAccountName = 'stfteventsdev'
param containerName = 'file-transfer-events'
param blobRetentionDays = 7

// Grafana — public access for development
param grafanaName = 'grafana-ft-dev'
param enableGrafanaPublicAccess = true

// Event Grid — automatic blob ingestion (set enableEventGrid = false for runbook-only ingestion)
param enableEventGrid = true
param eventHubNamespaceName = 'evhns-ft-dev'
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

// Networking — no private endpoints for dev
param enablePrivateEndpoints = false

param tags = {
  team: 'data-platform'
  costCenter: 'dev'
}
