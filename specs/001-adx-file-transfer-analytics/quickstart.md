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

```bash
# Validate the deployment (dry run)
az deployment group what-if \
  --resource-group rg-file-transfer-dev \
  --template-file infra/main.bicep \
  --parameters infra/parameters/dev.bicepparam

# Deploy
az deployment group create \
  --resource-group rg-file-transfer-dev \
  --template-file infra/main.bicep \
  --parameters infra/parameters/dev.bicepparam
```

This provisions:
- ADX cluster (Dev/Test SKU) + database (`ftevents_dev`)
- Storage account with `file-transfer-events` container
- Managed Grafana instance
- Event Grid data connection (Storage → ADX staging table)
- Managed identity RBAC assignments
- Private endpoints (if enabled for the environment)

---

## Step 2: Apply ADX Schema

Use the Azure CLI Kusto extension or the runbook to execute schema commands:

```bash
# Option A: Azure CLI
az kusto script create \
  --cluster-name adx-ft-dev \
  --database-name ftevents_dev \
  --resource-group rg-file-transfer-dev \
  --name "initial-schema" \
  --script-content "$(cat kql/schema/tables.kql)"

# Repeat for other schema files:
# kql/schema/mappings.kql
# kql/schema/policies.kql
# kql/schema/materialized-views.kql
```

```bash
# Option B: Python runbook (recommended for dev — creates full chain)
cd runbook
pip install -r requirements.txt
python adx_runbook.py setup \
  --cluster "https://adx-ft-dev.eastus2.kusto.windows.net" \
  --database "ftevents_dev"
```

The runbook creates all tables, mappings, functions, update policy, retention policies, and the materialized view in the correct order (see [data-model.md](data-model.md) → DDL Execution Order).

---

## Step 3: Ingest Sample Data

### Via blob upload (Event Grid path):

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
python adx_runbook.py ingest-local \
  --cluster "https://adx-ft-dev.eastus2.kusto.windows.net" \
  --database "ftevents_dev" \
  --file ../samples/sample-events.csv \
  --format csv \
  --mapping FileTransferEvents_CsvMapping
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

1. **Open Managed Grafana**: Navigate to the Grafana instance in the Azure portal → click the endpoint URL.

2. **Add ADX data source**:
   - Go to **Configuration → Data Sources → Add data source**
   - Search for **Azure Data Explorer**
   - Connection:
     - Cluster URL: `https://adx-ft-dev.eastus2.kusto.windows.net`
     - Database: `ftevents_dev`
   - Authentication: **Managed Identity** (auto-configured for Azure Managed Grafana)
   - Click **Save & Test** — should show "Success"

3. **Import dashboards**:
   - Go to **Dashboards → Import**
   - Upload `dashboards/operator-dashboard.json`
   - Select the ADX data source created above
   - Repeat for `dashboards/business-dashboard.json`

4. **Configure alerts** (if not embedded in dashboard JSON):
   - Navigate to **Alerting → Alert Rules**
   - Create rules matching the contracts in [contracts/alert-queries.kql](contracts/alert-queries.kql)
   - Set up notification contact points (email, Teams, etc.) and routing policies

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
