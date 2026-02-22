// Grafana Configuration — Deployment Script
// Creates ADX data source and imports dashboards via Azure CLI deployment script.
// Uses a user-assigned managed identity with Grafana Admin role.
// Re-runs automatically when dashboards or connection details change.

@description('Name of the Managed Grafana instance')
param grafanaName string

@description('URI of the ADX cluster (e.g., https://mycluster.eastus2.kusto.windows.net)')
param adxClusterUri string

@description('Name of the ADX database')
param adxDatabaseName string

@description('Azure region')
param location string

@description('Name of the storage account to use for deployment script execution (avoids auto-provisioned storage that may be blocked by Azure Policy)')
param storageAccountName string

@description('Tags to apply to resources')
param tags object = {}

// Load dashboard JSON files (resolved at Bicep compile time)
var operatorDashboard = loadTextContent('../../dashboards/operator-dashboard.json')
var businessDashboard = loadTextContent('../../dashboards/business-dashboard.json')

// Config version — changes when dashboards or connection details change, triggering re-run
var configVersion = uniqueString(operatorDashboard, businessDashboard, adxClusterUri, adxDatabaseName)

// Grafana Admin role definition ID
var grafanaAdminRoleId = '22926164-76b3-42b3-bc55-97df8dab3e41'

// Built-in role: Storage Blob Data Contributor (for deployment script MI → storage account)
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

// Reference the Grafana instance (must already exist via grafana module or pre-existing)
resource grafana 'Microsoft.Dashboard/grafana@2023-09-01' existing = {
  name: grafanaName
}

// Reference the storage account used for deployment script execution
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// User-assigned managed identity for the deployment script
resource scriptIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${grafanaName}-deployer'
  location: location
  tags: tags
}

// Grant Grafana Admin to the deployment script identity (scoped to Grafana instance)
resource scriptGrafanaAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(grafana.id, scriptIdentity.id, grafanaAdminRoleId)
  scope: grafana
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', grafanaAdminRoleId)
    principalId: scriptIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Grant Storage Blob Data Contributor to the script identity (required for MI-based deployment script storage)
resource scriptStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, scriptIdentity.id, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: scriptIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Deployment script — creates ADX data source and imports dashboards
resource configScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${grafanaName}-configure'
  location: location
  kind: 'AzureCLI'
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${scriptIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.63.0'
    retentionInterval: 'PT1H'
    timeout: 'PT10M'
    cleanupPreference: 'OnSuccess'
    forceUpdateTag: configVersion
    storageAccountSettings: {
      storageAccountName: storageAccountName
    }
    environmentVariables: [
      { name: 'GRAFANA_NAME', value: grafanaName }
      { name: 'ADX_CLUSTER_URI', value: adxClusterUri }
      { name: 'ADX_DATABASE', value: adxDatabaseName }
      { name: 'OPERATOR_DASHBOARD', value: operatorDashboard }
      { name: 'BUSINESS_DASHBOARD', value: businessDashboard }
    ]
    scriptContent: '''
#!/bin/bash
set -e

# Install Managed Grafana CLI extension
az extension add --name amg --yes

# Wait for RBAC propagation (role assignments may take 1-5 minutes to propagate in Azure AD)
echo "Waiting 120 seconds for RBAC propagation..."
sleep 120

# Use Python for reliable JSON handling (avoids shell quoting issues with large JSON payloads)
python3 << 'PYEOF'
import json, os, subprocess, sys

grafana = os.environ['GRAFANA_NAME']
cluster = os.environ['ADX_CLUSTER_URI']
db = os.environ['ADX_DATABASE']
ds_name = f"Azure Data Explorer - {db}"

# Step 1: Create or get the ADX data source
ds_uid = None
try:
    r = subprocess.run(
        ["az", "grafana", "data-source", "show",
         "--name", grafana, "--data-source", ds_name, "-o", "json"],
        capture_output=True, text=True, check=True
    )
    ds_uid = json.loads(r.stdout)["uid"]
    print(f"Data source already exists with UID: {ds_uid}")
except subprocess.CalledProcessError:
    ds_def = {
        "name": ds_name,
        "type": "grafana-azure-data-explorer-datasource",
        "access": "proxy",
        "jsonData": {
            "azureCredentials": {"authType": "msi"},
            "clusterUrl": cluster,
            "defaultDatabase": db
        }
    }
    r = subprocess.run(
        ["az", "grafana", "data-source", "create",
         "--name", grafana, "--definition", json.dumps(ds_def), "-o", "json"],
        capture_output=True, text=True, check=True
    )
    ds_uid = json.loads(r.stdout)["uid"]
    print(f"Created data source with UID: {ds_uid}")

# Step 2: Import dashboards with resolved data source UIDs
for key in ["OPERATOR_DASHBOARD", "BUSINESS_DASHBOARD"]:
    raw = os.environ[key]
    # Replace template variable with actual data source UID
    raw = raw.replace("${DS_AZURE_DATA_EXPLORER}", ds_uid)
    dash = json.loads(raw)
    # Remove Grafana template metadata (not needed for API import)
    dash.pop("__inputs", None)
    dash.pop("__requires", None)
    # Write wrapped payload to temp file for az CLI
    path = f"/tmp/{key.lower()}.json"
    with open(path, "w") as f:
        json.dump({"dashboard": dash, "overwrite": True}, f)
    r = subprocess.run(
        ["az", "grafana", "dashboard", "create",
         "--name", grafana, "--definition", f"@{path}", "--overwrite"],
        capture_output=True, text=True
    )
    title = dash.get("title", key)
    if r.returncode != 0:
        print(f"ERROR importing {title}: {r.stderr}", file=sys.stderr)
        sys.exit(1)
    print(f"Imported dashboard: {title}")

# Write outputs for ARM template
output_dir = os.environ.get("AZ_SCRIPTS_OUTPUT_DIRECTORY", "/mnt/azscripts/azscriptoutput")
with open(os.path.join(output_dir, "scriptoutputs.json"), "w") as f:
    json.dump({"dataSourceUid": ds_uid}, f)

print("Grafana configuration complete")
PYEOF
'''
  }
  dependsOn: [
    scriptGrafanaAdmin
    scriptStorageRole
  ]
}

@description('Data source UID created/found in Grafana')
output dataSourceUid string = configScript.properties.outputs.dataSourceUid
