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
| Resource group | Pre-created: e.g., `rg-file-transfer-dev` |

---

## Step 1: Deploy Infrastructure (Bicep)

### Option A: Provision new resources

```bash
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

This single command provisions the complete end-to-end pipeline:
- ADX cluster (Dev/Test SKU) + database (`ftevents_dev`)
- **ADX schema**: tables, mappings, policies, and materialized views (via Kusto database script)
- Storage account with `file-transfer-events` container + lifecycle policy
- Event Grid → Event Hub → ADX data connection (automatic blob ingestion)
- Managed Grafana instance with **ADX data source** and **both dashboards** auto-imported
- All RBAC: Grafana→ADX Viewer, ADX→Storage Blob Reader/Contributor, deployer Grafana Admin
- Private endpoints (if enabled for the environment)

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

## Step 5: Grafana Dashboards (automatic)

The Bicep deployment in Step 1 **automatically configures Grafana** via a [deployment script](../../infra/modules/grafana-config.bicep):
- Creates an ADX data source with managed identity authentication
- Imports both dashboards (`operator-dashboard.json` and `business-dashboard.json`) with the data source pre-configured

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
