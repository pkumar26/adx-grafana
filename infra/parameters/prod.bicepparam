using '../main.bicep'

// Prod environment parameters
// Deploy: az deployment group create -g rg-file-transfer-prod --template-file infra/main.bicep --parameters infra/parameters/prod.bicepparam

param environmentName = 'prod'
param location = 'eastus2'

// ADX — Standard SKU, full retention
param adxClusterName = 'adx-ft-prod'
param adxDatabaseName = 'ftevents_prod'
param adxSkuName = 'Standard_E2a_v4'
param adxSkuTier = 'Standard'
param adxSkuCapacity = 2
param retentionPeriod = 'P90D'
param hotCachePeriod = 'P30D'

// Storage
param storageAccountName = 'stfteventsprod'
param containerName = 'file-transfer-events'
param blobRetentionDays = 30

// Grafana — public access disabled for production
param grafanaName = 'grafana-ft-prod'
param enableGrafanaPublicAccess = false

// Event Grid — automatic blob ingestion (set enableEventGrid = false for runbook-only ingestion)
param enableEventGrid = true
param eventHubNamespaceName = 'evhns-ft-prod'
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

// Networking — private endpoints required for production
param enablePrivateEndpoints = true

param tags = {
  team: 'data-platform'
  costCenter: 'prod'
}
