// Managed Grafana Bicep Module
// Provisions Azure Managed Grafana instance with system-assigned managed identity.
// When useExisting=true, skips creation and returns the provided existing resource properties.

@description('Name of the Managed Grafana instance')
param grafanaName string

@description('Azure region')
param location string

@description('Whether to enable public network access')
param enablePublicAccess bool = true

@description('Grafana major version')
param grafanaMajorVersion string = '11'

@description('Grafana SKU')
param skuName string = 'Standard'

@description('Tags to apply to resources')
param tags object = {}

@description('Set to true to skip provisioning and use an existing Grafana instance')
param useExisting bool = false

@description('Resource ID of the existing Grafana instance (required when useExisting=true)')
param existingGrafanaId string = ''

@description('Principal ID of the existing Grafana managed identity (required when useExisting=true)')
param existingPrincipalId string = ''

@description('Endpoint URL of the existing Grafana instance (required when useExisting=true)')
param existingEndpoint string = ''

resource grafana 'Microsoft.Dashboard/grafana@2023-09-01' = if (!useExisting) {
  name: grafanaName
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: enablePublicAccess ? 'Enabled' : 'Disabled'
    zoneRedundancy: 'Disabled'
    apiKey: 'Disabled'
    deterministicOutboundIP: 'Disabled'
    grafanaMajorVersion: grafanaMajorVersion
  }
}

@description('The resource ID of the Managed Grafana instance')
output grafanaId string = useExisting ? existingGrafanaId : grafana.id

@description('The principal ID of the Grafana system-assigned managed identity')
output grafanaPrincipalId string = useExisting ? existingPrincipalId : grafana!.identity.principalId

@description('The Grafana endpoint URL')
output grafanaEndpoint string = useExisting ? existingEndpoint : grafana!.properties.endpoint
