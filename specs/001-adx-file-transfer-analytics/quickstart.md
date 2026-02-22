# Quickstart: ADX File-Transfer Analytics

**Branch**: `001-adx-file-transfer-analytics` | **Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Azure subscription | With permissions to create ADX, Grafana, Storage, Event Grid resources |
| Azure CLI | `az` ≥ 2.55+ with `kusto` extension installed |
| Bicep CLI | `az bicep install` (or bundled with Azure CLI) |
| Python | 3.9+ for the runbook |
| Resource group | Created automatically by `deploy.sh`, or pre-create: `az group create -n rg-file-transfer-dev -l eastus2` |

---

## Step 1: Deploy Infrastructure (Bicep)

### Option A: Provision new resources (recommended)

The interactive deploy script handles resource group creation, environment selection, and deployer identity:

```bash
./deploy.sh
```

Or non-interactively:

```bash
./deploy.sh dev                # Prompts for resource group
./deploy.sh dev my-rg          # Fully non-interactive
```

### Option A (manual): Provision new resources

```bash
# Create the resource group first (if it doesn't exist)
az group create --name rg-file-transfer-dev --location eastus2

# Get your Azure AD Object ID (grants Grafana Admin portal access)
DEPLOYER_ID=$(az ad signed-in-user show --query id -o tsv)

# Validate the deployment (dry run)
az deployment group what-if \
  --resource-group rg-file-transfer-dev \
  --template-file infra/main.bicep \
  --parameters infra/parameters/dev.bicepparam \
  --parameters deployerPrincipalId="$DEPLOYER_ID"

# Deploy
az deployment group create \
  --resource-group rg-file-transfer-dev \
  --template-file infra/main.bicep \
  --parameters infra/parameters/dev.bicepparam \
  --parameters deployerPrincipalId="$DEPLOYER_ID"
```

This single command provisions the infrastructure:
- ADX cluster (Dev/Test SKU) + database (`ftevents_dev`)
- **ADX schema**: tables, mappings, policies, and materialized views (via Kusto database script)
- Storage account with `file-transfer-events` container + lifecycle policy
- Event Grid → Event Hub → ADX data connection (automatic blob ingestion)
- Managed Grafana instance (provisioned with RBAC, but **not yet configured** with data source/dashboards)
- All RBAC: Grafana→ADX Viewer, ADX→Storage Blob Reader/Contributor, deployer Grafana Admin
- Private endpoints (if enabled for the environment)

> **Important**: Manual `az deployment group create` deploys infrastructure only. You must configure Grafana (data source + dashboards) as a separate step — see [Step 5](#step-5-configure-grafana-dashboards). If you use `./deploy.sh` (Option A), this is handled automatically.

> **`deployerPrincipalId`** is optional — omit it for CI/CD pipelines that don't need Grafana portal access.

> **Runbook-only mode**: If you don't need automatic blob ingestion, add `--parameters enableEventGrid=false` to skip Event Hub + Event Grid provisioning. You can still ingest data via the Python runbook (Step 3 → "Via runbook").

### Option B: Use existing ADX and/or Grafana

If you already have an ADX cluster or Grafana instance, provide their resource details as override parameters. The deployment skips provisioning those resources and wires Event Grid, RBAC, and networking to your existing setup.

```bash
# Find your existing resource details
az kusto cluster show --name <cluster> --resource-group <rg> \
  --query "{id: id, uri: uri, principalId: identity.principalId}" -o json

az grafana show --name <grafana> --resource-group <rg> \
  --query "{id: id, principalId: identity.principalId, endpoint: properties.endpoint}" -o json
```

```bash
# Deploy with existing ADX cluster
DEPLOYER_ID=$(az ad signed-in-user show --query id -o tsv)
az deployment group create \
  --resource-group rg-file-transfer-dev \
  --template-file infra/main.bicep \
  --parameters infra/parameters/dev.bicepparam \
  --parameters deployerPrincipalId="$DEPLOYER_ID" \
  --parameters \
    existingAdxClusterId='<resource-id>' \
    existingAdxClusterUri='https://<name>.<region>.kusto.windows.net' \
    existingAdxPrincipalId='<object-id>'
```

> **Note**: When using an existing ADX cluster, the database (`adxDatabaseName`) must already exist. The Bicep deployment will apply the schema to that database automatically via the Kusto database script.

---

## Step 2: ADX Schema (automatic)

The Bicep deployment in Step 1 **automatically applies the full ADX schema** via a [Kusto database script](../../infra/modules/adx-schema.bicep) that loads all KQL files from `kql/schema/`. This includes:
- Tables: `FileTransferEvents`, `FileTransferEvents_Raw`, `FileTransferEvents_Errors`
- Transformation function + update policy
- CSV and JSON ingestion mappings
- Retention and batching policies
- `DailySummary` materialized view

All commands are idempotent — re-deploying the Bicep is safe.

> **Manual alternative** (for troubleshooting or existing clusters managed outside Bicep):
> ```bash
> # Option A: Python runbook (recommended)
> cd runbook
> uv pip install -r requirements.txt
> python3 adx_runbook.py setup \
>   --cluster "https://adx-ft-dev.eastus2.kusto.windows.net" \
>   --database "ftevents_dev"
>
> # Option B: Azure CLI (one script at a time)
> az kusto script create \
>   --cluster-name adx-ft-dev \
>   --database-name ftevents_dev \
>   --resource-group rg-file-transfer-dev \
>   --name "initial-schema" \
>   --script-content "$(cat kql/schema/tables.kql)"
> # Repeat for mappings.kql, policies.kql, materialized-views.kql
> ```

---

## Step 3: Ingest Sample Data

### Via blob upload (Event Grid path — requires `enableEventGrid=true`):

```bash
# Upload sample CSV to the ingestion landing zone
az storage blob upload \
  --account-name stfteventsdev \
  --container-name file-transfer-events \
  --name "sample-events.csv" \
  --file samples/sample-events.csv \
  --auth-mode login

# Wait ~2 minutes for Event Grid → ADX ingestion + update policy
```

### Via runbook (queued ingestion):

```bash
# Local file ingestion
python3 adx_runbook.py ingest-local \
  --cluster "https://adx-ft-dev.eastus2.kusto.windows.net" \
  --ingest-uri "https://ingest-adx-ft-dev.eastus2.kusto.windows.net" \
  --database "ftevents_dev" \
  --file ../samples/sample-events.csv
```

---

## Step 4: Verify Ingestion

```bash
# Query ADX to confirm data landed in the target table
az kusto query \
  --cluster-name adx-ft-dev \
  --database-name ftevents_dev \
  --resource-group rg-file-transfer-dev \
  --query "FileTransferEvents | count"

# Expected: count > 0

# Verify the staging table is empty (update policy moved data to target)
az kusto query \
  --cluster-name adx-ft-dev \
  --database-name ftevents_dev \
  --resource-group rg-file-transfer-dev \
  --query "FileTransferEvents_Raw | count"

# Expected: count = 0 (staging data expires after 1 day)

# Check the materialized view
az kusto query \
  --cluster-name adx-ft-dev \
  --database-name ftevents_dev \
  --resource-group rg-file-transfer-dev \
  --query "materialized_view('DailySummary') | take 10"
```

---

## Step 5: Configure Grafana Dashboards

If you used `./deploy.sh`, the data source and dashboards are already configured — skip to viewing.

If you deployed manually via `az deployment group create`, you need to configure Grafana as a post-deployment step:

```bash
# Install the Managed Grafana CLI extension
az extension add --name amg --yes

# Get deployment outputs
GRAFANA_NAME=$(az deployment group show \
  --resource-group rg-file-transfer-dev --name main \
  --query "properties.outputs.grafanaName.value" -o tsv)
ADX_URI=$(az deployment group show \
  --resource-group rg-file-transfer-dev --name main \
  --query "properties.outputs.adxClusterUri.value" -o tsv)
ADX_DB=$(az deployment group show \
  --resource-group rg-file-transfer-dev --name main \
  --query "properties.outputs.adxDatabaseName.value" -o tsv)

# Create ADX data source in Grafana (managed identity auth)
DS_UID=$(az grafana data-source create --name "$GRAFANA_NAME" --definition '{
  "name": "Azure Data Explorer - '"$ADX_DB"'",
  "type": "grafana-azure-data-explorer-datasource",
  "access": "proxy",
  "jsonData": {
    "azureCredentials": {"authType": "msi"},
    "clusterUrl": "'"$ADX_URI"'",
    "defaultDatabase": "'"$ADX_DB"'"
  }
}' --query uid -o tsv)

echo "Data source UID: $DS_UID"

# Prepare and import dashboards (replace placeholder with actual data source UID)
for DASH in dashboards/operator-dashboard.json dashboards/business-dashboard.json; do
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    dash = json.load(f)
raw = json.dumps(dash).replace('\${DS_AZURE_DATA_EXPLORER}', sys.argv[2])
dash = json.loads(raw)
dash.pop('__inputs', None); dash.pop('__requires', None)
with open('/tmp/gf-import.json', 'w') as f:
    json.dump({'dashboard': dash, 'overwrite': True}, f)
" "$DASH" "$DS_UID"
  az grafana dashboard create --name "$GRAFANA_NAME" --definition @/tmp/gf-import.json --overwrite
done
```

Open the Grafana endpoint (from the deployment output `grafanaEndpoint`) and navigate to **Dashboards** — both "File Transfer Operations" and "File Transfer Business Analytics" will be ready.

### Configure Alerts (optional)

1. Navigate to **Alerting → Alert Rules**
2. Create rules matching the contracts in [contracts/alert-queries.kql](contracts/alert-queries.kql)
3. Set up notification contact points (email, Teams, etc.) and routing policies

> **Manual data source + dashboard import** (for existing Grafana instances managed outside Bicep):
> 1. Go to **Configuration → Data Sources → Add data source**
> 2. Select **Azure Data Explorer**, set Cluster URL and Database, use **Managed Identity** auth
> 3. Click **Save & Test** — should show "Success"
> 4. Go to **Dashboards → Import** → upload `dashboards/operator-dashboard.json`, select the data source
> 5. Repeat for `dashboards/business-dashboard.json`
>
> See [DATASOURCE.md](../../dashboards/DATASOURCE.md) for full details.

---

## Step 6: End-to-End Validation Checklist

| Check | Command / Action | Expected Result | SC |
|-------|-----------------|-----------------|-----|
| Bicep deploys cleanly | `az deployment group create ...` exits 0 | All resources provisioned | SC-009 |
| Schema applies idempotently | Run schema commands twice | No errors on second run | SC-010 |
| CSV ingestion works | Upload `samples/sample-events.csv` to blob | Rows appear in `FileTransferEvents` within 5 min | SC-001 |
| JSON ingestion works | Upload `samples/sample-events.json` to blob | Rows appear in `FileTransferEvents` within 5 min | SC-001 |
| Timestamp is derived | Query `FileTransferEvents \| project Timestamp, SourceLastModifiedUtc` | Timestamp = SourceLastModifiedUtc (or ingestion time if null) | FR-002 |
| Operator dashboard loads <3 s | Open Operator Dashboard (24 h range) | All panels populate within 3 s | SC-002 |
| Business dashboard loads <5 s | Open Business Dashboard (30 d range) | All panels populate within 5 s | SC-003 |
| Panels return ≤1,000 rows | Check query inspector on each panel | No panel exceeds 1,000 rows | SC-004 |
| Missing file alert fires | Ingest >3 MISSING events | Alert triggers within 5 min | SC-005 |
| Dead-letter alert fires | Upload malformed CSV | Alert triggers within 5 min | SC-006 |
| Runbook end-to-end | `python adx_runbook.py setup && python adx_runbook.py ingest-local ...` | Completes <5 min, data in ADX | SC-011 |
| DailySummary populates | Query `materialized_view("DailySummary")` | Aggregated rows present | FR-036 |
| Environment isolation | Access dev Grafana, confirm no prod data | Only dev database data visible | SC-007 |

---

## Troubleshooting

| Issue | Diagnostic | Resolution |
|-------|-----------|------------|
| No data after blob upload | `az kusto query ... --query ".show ingestion failures"` | Check mapping name, blob format, column types |
| Staging table has rows | `.show table FileTransferEvents policy update` | Verify update policy is enabled and function exists |
| Materialized view unhealthy | `.show materialized-view DailySummary` | Check `IsHealthy`, `LastRun`, `FailureRate` |
| Grafana "no data" | Test query in ADX web explorer first | Verify data source auth, database name, time range |
| Alert not firing | Check Grafana Alerting → State history | Verify evaluation interval, condition threshold, data source |
| Runbook auth failure | `python adx_runbook.py setup --help` | Use `az login` or set `AZURE_CLIENT_ID`/`AZURE_TENANT_ID` env vars |
