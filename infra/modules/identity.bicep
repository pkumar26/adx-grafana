// Identity and RBAC Bicep Module
// Assigns managed identity roles: Grafana→ADX Viewer, ADX→Storage Blob Reader,
// Event Grid roles, and optionally Grafana Admin for the deployer.

@description('Principal ID of the Grafana system-assigned managed identity')
param grafanaPrincipalId string

@description('Principal ID of the ADX cluster system-assigned managed identity')
param adxClusterPrincipalId string

@description('Resource ID of the ADX cluster')
param adxClusterId string

@description('Name of the ADX cluster')
param adxClusterName string

@description('Name of the ADX database')
param adxDatabaseName string

@description('Resource ID of the storage account')
param storageAccountId string

@description('Name of the Managed Grafana instance (for deployer role assignment)')
param grafanaName string

@description('Azure AD Object ID of the deployer (user or service principal). Leave empty to skip Grafana Admin assignment.')
param deployerPrincipalId string = ''

@description('Azure AD tenant ID')
param tenantId string = subscription().tenantId

// Built-in role definition IDs
var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var grafanaAdminRoleId = '22926164-76b3-42b3-bc55-97df8dab3e41'

// --- ADX Database Principal Assignments ---

// Grafana → ADX Viewer role
resource grafanaAdxViewer 'Microsoft.Kusto/clusters/databases/principalAssignments@2024-04-13' = {
  name: '${adxClusterName}/${adxDatabaseName}/grafana-viewer'
  properties: {
    principalId: grafanaPrincipalId
    principalType: 'App'
    role: 'Viewer'
    tenantId: tenantId
  }
}

// --- Storage RBAC Role Assignments ---

// ADX → Storage Blob Data Reader (for Event Grid ingestion)
resource adxStorageBlobReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountId, adxClusterId, storageBlobDataReaderRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
    principalId: adxClusterPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ADX → Storage Blob Data Contributor (for queued ingestion SDK uploads)
resource adxStorageBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountId, adxClusterId, storageBlobDataContributorRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: adxClusterPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// --- Grafana Admin for Deployer ---

// Reference Grafana instance (created by grafana module or pre-existing)
resource grafana 'Microsoft.Dashboard/grafana@2023-09-01' existing = {
  name: grafanaName
}

// Deployer → Grafana Admin role (enables portal/API access to Grafana)
// Skipped when deployerPrincipalId is empty (e.g., CI/CD pipelines that don't need portal access)
resource deployerGrafanaAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  name: guid(grafana.id, deployerPrincipalId, grafanaAdminRoleId)
  scope: grafana
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', grafanaAdminRoleId)
    principalId: deployerPrincipalId
    principalType: 'User'
  }
}
