# Grafana ADX Data Source Configuration

## Overview

Both dashboards (`operator-dashboard.json` and `business-dashboard.json`) use the
Azure Data Explorer (ADX) data source plugin, which is pre-installed in Azure
Managed Grafana. Authentication uses the Grafana instance's system-assigned
managed identity — no secrets or API keys are needed.

**Automatic setup**: The `deploy.sh` script automatically provisions the ADX
data source, imports both dashboards, and configures all RBAC as a
post-deployment step. No manual steps are needed when using `./deploy.sh`.

If you deploy via `az deployment group create` directly (without `deploy.sh`),
Grafana is provisioned but **not configured** — you must create the data source
and import dashboards manually. See the [README Quick Start](../README.md#5-configure-grafana-dashboards)
for CLI commands, or follow the manual steps below.

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
- Configure private endpoints (if enabled)

After Bicep completes, configure Grafana using the CLI commands in the
[README Quick Start](../README.md#5-configure-grafana-dashboards), or use
`./deploy.sh` which handles this automatically.

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
| Deployment script fails with 401 | RBAC propagation takes 1-5 min; wait and re-run `./deploy.sh` |
| Dashboards missing after deploy | If you used `az deployment group create` directly, run the post-deploy Grafana config — see [README](../README.md#5-configure-grafana-dashboards) |
| Panels show data but Event Grid blobs don't ingest | ADX MI needs Storage Blob Data Reader on the storage account — check `.show ingestion failures` in ADX. See [README FAQ](../README.md#ingestion-says-queued--but-no-data-appears) |
