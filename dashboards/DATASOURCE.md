# Grafana ADX Data Source Configuration

## Overview

Both dashboards (`operator-dashboard.json` and `business-dashboard.json`) use the
Azure Data Explorer (ADX) data source plugin, which is pre-installed in Azure
Managed Grafana. Authentication uses the Grafana instance's system-assigned
managed identity — no secrets or API keys are needed.

**Automatic setup**: The Bicep deployment (`infra/main.bicep`) automatically
provisions the ADX data source, imports both dashboards, and configures all RBAC
via the [`grafana-config.bicep`](../infra/modules/grafana-config.bicep) deployment
script. No manual steps are needed for a fresh deployment.

The sections below are for **manual setup** (e.g., existing Grafana instances
managed outside Bicep, re-importing dashboards, or troubleshooting).

## Manual Setup Steps

### 1. Add the ADX Data Source

1. Open your Managed Grafana instance (endpoint URL from the Azure portal)
2. Navigate to **Configuration → Data Sources → Add data source**
3. Search for **Azure Data Explorer**
4. Configure:
   - **Cluster URL**: `https://<cluster-name>.<region>.kusto.windows.net`
   - **Database**: e.g., `ftevents_dev`, `ftevents_test`, `ftevents_prod`
   - **Authentication**: Select **Managed Identity** (auto-configured for Azure Managed Grafana)
5. Click **Save & Test** — should show "Success"

### 2. RBAC Requirement

The Grafana managed identity must have the **Viewer** role on the ADX database.
This is automatically provisioned by the Bicep `identity.bicep` module (see
`infra/modules/identity.bicep` → `grafanaAdxViewer` resource).

To verify or manually assign:

```kql
// Check existing principals
.show database ftevents_dev principals

// Manually add if needed (replace with actual principal ID)
.add database ftevents_dev viewers ('aadapp=<grafana-managed-identity-client-id>;<tenant-id>') 'Managed Grafana'
```

### 3. Import Dashboards

1. Go to **Dashboards → Import**
2. Upload `dashboards/operator-dashboard.json`
3. When prompted, select the ADX data source created above
4. Repeat for `dashboards/business-dashboard.json`

The dashboards use `__inputs` blocks to make the data source reference portable.
On import, Grafana maps `${DS_AZURE_DATA_EXPLORER}` to your selected data source.

### 4. Environment Isolation (FR-026)

Each environment (dev/test/prod) should have:
- Its own ADX database (e.g., `ftevents_dev`, `ftevents_prod`)
- Its own Grafana data source pointing to that database
- Its own Grafana instance (deployed by Bicep per environment, or an existing shared instance)

This ensures environment data isolation — dev dashboards never show prod data.

### 5. Using an Existing Grafana Instance

If you're connecting to a pre-existing Grafana instance (deployed outside this Bicep stack), ensure:

1. **Managed identity is enabled** on the Grafana resource (system-assigned)
2. **The Grafana MI has ADX Viewer role** on the target database — the Bicep `identity.bicep` module handles this automatically when you provide `existingGrafanaPrincipalId`
3. **The ADX data source plugin is available** — it is pre-installed in Azure Managed Grafana
4. **Your user has Grafana Admin role** — the Bicep `identity.bicep` module grants this when you provide `deployerPrincipalId`

To deploy with an existing Grafana:

```bash
DEPLOYER_ID=$(az ad signed-in-user show --query id -o tsv)
az deployment group create \
  --resource-group rg-file-transfer-dev \
  --template-file infra/main.bicep \
  --parameters infra/parameters/dev.bicepparam \
  --parameters deployerPrincipalId="$DEPLOYER_ID" \
  --parameters \
    existingGrafanaId='<grafana-resource-id>' \
    existingGrafanaPrincipalId='<grafana-mi-object-id>' \
    existingGrafanaEndpoint='https://<name>.xxx.grafana.azure.com'
```

The deployment will automatically:
- Assign RBAC (Grafana → ADX Viewer, deployer Grafana Admin)
- Create the ADX data source with managed identity auth
- Import both dashboards with the data source pre-configured
- Configure private endpoints (if enabled)

## Data Source Settings Reference

| Setting | Value | Notes |
|---------|-------|-------|
| Type | `grafana-azure-data-explorer-datasource` | Pre-installed in Managed Grafana |
| Cluster URL | `https://<cluster>.<region>.kusto.windows.net` | From Bicep output `adxClusterUri` |
| Database | Environment-specific (e.g., `ftevents_dev`) | From Bicep output `adxDatabaseName` |
| Authentication | Managed Identity | No credentials needed |
| Query timeout | 30s (default) | Sufficient for all panel queries |

## Troubleshooting

| Issue | Resolution |
|-------|-----------|
| "Unauthorized" on Save & Test | Verify Grafana MI has Viewer role on the ADX database |
| "No data" in panels | Check time range, verify data exists via ADX Web Explorer |
| Data source not found on import | Create the ADX data source before importing dashboards |
| Wrong environment data | Verify the data source points to the correct database |
| Deployment script fails with 401 | RBAC propagation takes 1-5 min; re-run the Bicep deployment |
| Dashboards missing after deploy | Check Grafana endpoint, or re-deploy — the script is idempotent |
