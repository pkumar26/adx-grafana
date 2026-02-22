# ADX File-Transfer Analytics

Ingest CSV/JSON file-transfer health data into Azure Data Explorer (ADX), visualize operational and business metrics in Azure Managed Grafana, and alert on missing files and ingestion errors — all deployed via Bicep IaC with managed identity authentication.

## Architecture

```
┌──────────────┐     blob upload     ┌──────────────────┐
│ Source System │ ──────────────────▶ │ Azure Storage     │
│ (CSV / JSON)  │                     │ (ADLS Gen2)       │
└──────────────┘                     └────────┬─────────┘
                                              │ BlobCreated
                                              ▼
                                     ┌──────────────────┐
                                     │ Event Grid        │
                                     │ (system topic, MI)│
                                     └────────┬─────────┘
                                              │ MI-based delivery
                                              ▼
                                     ┌──────────────────┐
                                     │ Event Hub         │
                                     │ (Standard)        │
                                     └────────┬─────────┘
                                              │ ADX data connection (MI)
                                              ▼
┌──────────────────────────────────────────────────────────┐
│ Azure Data Explorer (ADX)                                │
│                                                          │
│  FileTransferEvents_Raw ──update policy──▶ FileTransferEvents
│       (staging)              coalesce()       (target)   │
│                                                 │        │
│                                    materialized view     │
│                                                 ▼        │
│  FileTransferEvents_Errors          DailySummary         │
│       (dead-letter)              (730-day aggregates)    │
└──────────────────────┬───────────────────────────────────┘
                       │ KQL queries (MI auth)
                       ▼
             ┌───────────────────┐
             │ Managed Grafana   │
             │  ├─ Operator      │
             │  │  Dashboard     │
             │  ├─ Business      │
             │  │  Dashboard     │
             │  └─ Alert Rules   │
             └───────────────────┘
```

All inter-service communication uses **managed identity (MI) authentication** — no secrets, connection strings, or SAS keys anywhere in the pipeline.

## How It Works

1. **Source systems upload files** — CSV or JSON files containing file-transfer health data (filename, status, timestamps, age) are uploaded to the Azure Storage blob container (`file-transfer-events`).
2. **Automatic ingestion triggers** — Event Grid detects the new blob and sends a notification through Event Hub to ADX. ADX fetches the file from Storage and ingests it into a staging table.
3. **Data transformation** — ADX's update policy automatically transforms raw rows into the target table, deriving a `Timestamp` from the source file's last-modified time. Malformed rows are routed to a dead-letter table for troubleshooting.
4. **Daily aggregation** — A materialized view (`DailySummary`) pre-computes daily totals, SLA adherence rates, and P95 latency metrics — retained for 2 years for long-term trend analysis.
5. **Dashboards in Grafana** — Two pre-built dashboards visualize the data in real time:
   - **Operator Dashboard** — Recent transfers, missing/failed file counts, SLA delay trends, ingestion errors
   - **Business Dashboard** — Daily volume, SLA adherence %, P95 age trends over 30–730 day ranges
6. **Alerting** — Grafana alert rules fire when missing files exceed a threshold, delayed files exceed a threshold, or ingestion errors appear in the dead-letter table.

> **End-to-end: a file lands in Storage → data appears in Grafana dashboards within ~2 minutes, with zero manual intervention.**

## Directory Layout

```
infra/                          # Bicep IaC
├── main.bicep                  # Orchestrator
├── modules/                    # Resource modules
│   ├── adx-cluster.bicep       #   ADX cluster + database
│   ├── adx-schema.bicep        #   Kusto script: tables, mappings, policies, views
│   ├── event-grid.bicep        #   Event Hub + Event Grid + ADX data connection
│   ├── grafana.bicep            #   Managed Grafana instance
│   ├── grafana-config.bicep    #   Deployment script: ADX data source + dashboards
│   ├── identity.bicep           #   RBAC: Grafana→ADX, ADX→Storage, deployer roles
│   ├── networking.bicep         #   Private Link / Managed Private Endpoints
│   └── storage.bicep            #   ADLS Gen2 storage account + container
└── parameters/                 # Environment params (dev, test, prod)

kql/                            # KQL definitions
├── schema/                     # Table DDL, mappings, policies, materialized views
└── queries/                    # Dashboard panel and alert queries

dashboards/                     # Grafana dashboard JSON (version-controlled)
├── operator-dashboard.json     # Operational monitoring
└── business-dashboard.json     # Business analytics (30-730 day range)

runbook/                        # Python CLI & notebook for dev setup & testing
├── adx_runbook.ipynb           # Interactive notebook (recommended)
├── adx_runbook.py              # CLI script (for CI/automation)
├── requirements.txt            # Python dependencies
└── README.md                   # Usage guide

samples/                        # Test data
├── sample-events.csv
└── sample-events.json
```

## Quick Start

### 1. Deploy Infrastructure

**New resources (default):**

```bash
# Get your Azure AD Object ID (grants Grafana Admin portal access)
DEPLOYER_ID=$(az ad signed-in-user show --query id -o tsv)

az deployment group create \
  --resource-group rg-file-transfer-dev \
  --template-file infra/main.bicep \
  --parameters infra/parameters/dev.bicepparam \
  --parameters deployerPrincipalId="$DEPLOYER_ID"
```

This single command provisions everything end-to-end:
- ADX cluster + database
- **ADX schema** (tables, mappings, policies, materialized views via Kusto database script)
- Storage account with blob container + lifecycle policy
- Event Grid → Event Hub → ADX data connection (automatic blob ingestion)
- Managed Grafana instance with **ADX data source** and **both dashboards** auto-imported
- All RBAC: Grafana→ADX Viewer, ADX→Storage Blob Reader/Contributor, Grafana Admin for deployer

> **`deployerPrincipalId`** is optional — omit it for CI/CD pipelines that don't need portal access.

**Use an existing ADX cluster and/or Grafana instance:**

If you already have an ADX cluster or Grafana instance, pass their details as override parameters. The deployment will skip provisioning those resources and wire everything else (schema, Event Grid, RBAC, dashboards, networking) to your existing setup.

```bash
# Existing ADX only
DEPLOYER_ID=$(az ad signed-in-user show --query id -o tsv)
az deployment group create \
  --resource-group rg-file-transfer-dev \
  --template-file infra/main.bicep \
  --parameters infra/parameters/dev.bicepparam \
  --parameters deployerPrincipalId="$DEPLOYER_ID" \
  --parameters \
    existingAdxClusterId='/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Kusto/clusters/<name>' \
    existingAdxClusterUri='https://<name>.<region>.kusto.windows.net' \
    existingAdxPrincipalId='<cluster-managed-identity-object-id>'

# Existing Grafana only
az deployment group create \
  --resource-group rg-file-transfer-dev \
  --template-file infra/main.bicep \
  --parameters infra/parameters/dev.bicepparam \
  --parameters \
    existingGrafanaId='/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Dashboard/grafana/<name>' \
    existingGrafanaPrincipalId='<grafana-managed-identity-object-id>' \
    existingGrafanaEndpoint='https://<name>.xxx.grafana.azure.com'

# Both existing
az deployment group create \
  --resource-group rg-file-transfer-dev \
  --template-file infra/main.bicep \
  --parameters infra/parameters/dev.bicepparam \
  --parameters \
    existingAdxClusterId='...' existingAdxClusterUri='...' existingAdxPrincipalId='...' \
    existingGrafanaId='...' existingGrafanaPrincipalId='...' existingGrafanaEndpoint='...'
```

See [Using Existing Resources](#using-existing-resources) below for details on finding these values.

### 2. Apply ADX Schema (automatic)

The Bicep deployment now applies the full ADX schema automatically via a [Kusto database script](infra/modules/adx-schema.bicep) that loads all KQL files from `kql/schema/`. No manual step needed.

> **Manual alternative** (for existing clusters or troubleshooting):
> ```bash
> cd runbook
> uv venv && source .venv/bin/activate
> uv pip install -r requirements.txt
> python adx_runbook.py setup \
>   --cluster https://adx-ft-dev.eastus2.kusto.windows.net \
>   --database ftevents_dev
> ```

### 3. Ingest Sample Data

```bash
python adx_runbook.py ingest-local \
  --cluster https://adx-ft-dev.eastus2.kusto.windows.net \
  --ingest-uri https://ingest-adx-ft-dev.eastus2.kusto.windows.net \
  --database ftevents_dev \
  --file ../samples/sample-events.csv
```

### 4. Verify

```bash
# Wait ~2 minutes for queued ingestion + update policy
python adx_runbook.py verify \
  --cluster https://adx-ft-dev.eastus2.kusto.windows.net \
  --database ftevents_dev
```

### 5. View Dashboards (automatic)

The Bicep deployment automatically:
- Creates an ADX data source in Grafana (managed identity auth)
- Imports both dashboards with the data source pre-configured

Open the Grafana endpoint (from deployment output `grafanaEndpoint`) and navigate to **Dashboards** — both "File Transfer Operations" and "File Transfer Business Analytics" will be ready.

> **Time range**: Dashboards default to "Last 1 hour". If your data has older timestamps, adjust the time picker (top-right) to a wider range (e.g., "Last 7 days" or a custom range) to see all data.

> **Manual import** (for existing Grafana or re-import): See [DATASOURCE.md](dashboards/DATASOURCE.md).

For the full walkthrough, see [quickstart.md](specs/001-adx-file-transfer-analytics/quickstart.md).

## Environments

| Environment | ADX SKU | Retention | Private Endpoints | Parameter File |
|-------------|---------|-----------|-------------------|---------------|
| dev | Dev/Test | 30 days | No | `infra/parameters/dev.bicepparam` |
| test | Dev/Test | 30 days | Yes | `infra/parameters/test.bicepparam` |
| prod | Standard | 90 days | Yes | `infra/parameters/prod.bicepparam` |

## Using Existing Resources

The deployment supports reusing an existing ADX cluster and/or Grafana instance instead of provisioning new ones. This is useful when you already have shared infrastructure or want to add the file-transfer analytics pipeline to an existing setup.

### Finding Required Values

**Existing ADX cluster:**

```bash
# Get cluster resource ID and URI
az kusto cluster show \
  --name <cluster-name> \
  --resource-group <rg> \
  --query "{id: id, uri: uri, principalId: identity.principalId}" -o json
```

**Existing Grafana instance:**

```bash
# Get Grafana resource ID, principal ID, and endpoint
az grafana show \
  --name <grafana-name> \
  --resource-group <rg> \
  --query "{id: id, principalId: identity.principalId, endpoint: properties.endpoint}" -o json
```

| Parameter | Source | Required When |
|-----------|--------|---------------|
| `existingAdxClusterId` | `az kusto cluster show ... --query id` | Using existing ADX |
| `existingAdxClusterUri` | `az kusto cluster show ... --query uri` | Using existing ADX |
| `existingAdxPrincipalId` | `az kusto cluster show ... --query identity.principalId` | Using existing ADX |
| `existingGrafanaId` | `az grafana show ... --query id` | Using existing Grafana |
| `existingGrafanaPrincipalId` | `az grafana show ... --query identity.principalId` | Using existing Grafana |
| `existingGrafanaEndpoint` | `az grafana show ... --query properties.endpoint` | Using existing Grafana |

### What Changes

| Scenario | ADX Module | ADX Schema | Grafana Module | Grafana Config | Event Grid / Event Hub | Storage / RBAC / Networking |
|----------|-----------|------------|----------------|----------------|------------------------|-----------------------------|
| All new (default) | Provisions cluster + DB | Applied via Kusto script | Provisions Grafana | Data source + dashboards | Provisioned | Provisioned as normal |
| Existing ADX | **Skipped** | Applied to existing DB | Provisions Grafana | Data source + dashboards | Provisioned | Wired to existing ADX cluster |
| Existing Grafana | Provisions cluster + DB | Applied via Kusto script | **Skipped** | Data source + dashboards | Provisioned | Wired to existing Grafana MI |
| Both existing | **Skipped** | Applied to existing DB | **Skipped** | Data source + dashboards | Provisioned | Wired to both existing resources |
| `enableEventGrid=false` | (per above) | (per above) | (per above) | (per above) | **Skipped** | Provisioned (no auto-ingestion) |

> **Note**: When using an existing ADX cluster, the database specified by `adxDatabaseName` must already exist on that cluster. The Bicep deployment will apply the schema (tables, mappings, policies) to that database automatically via a Kusto database script. You can also use the [runbook](runbook/README.md) `setup` command for manual schema management.

### Skipping Event Grid (Runbook-Only Ingestion)

Event Grid + Event Hub are only needed for **automatic** blob ingestion (files dropped into Storage are auto-ingested into ADX). If you only use the Python runbook for ingestion, you can skip these resources:

```bash
az deployment group create \
  --resource-group rg-file-transfer-dev \
  --template-file infra/main.bicep \
  --parameters infra/parameters/dev.bicepparam \
  --parameters enableEventGrid=false
```

This avoids provisioning the Event Hub namespace, Event Grid system topic, event subscription, and ADX data connection — reducing cost and deployment time. You can always enable it later by re-deploying with `enableEventGrid=true`.

## Key Design Decisions

- **Staging table + update policy**: `Timestamp` is derived at ingestion time via `coalesce(SourceLastModifiedUtc, ingestion_time())`, not at query time. All downstream queries use the concrete column.
- **Materialized view with tdigest**: `DailySummary` pre-aggregates daily metrics with a 730-day retention independent of the 90-day source table. P95 latency uses `tdigest()` / `percentile_tdigest()` since `percentile()` is not supported in materialized views.
- **Managed identities end-to-end**: Every service-to-service connection uses system-assigned managed identity — no secrets, SAS tokens, or connection strings are stored or generated:
  - Grafana → ADX: Database **Viewer** role
  - ADX → Storage: **Blob Data Reader** + **Blob Data Contributor** roles
  - ADX → Event Hub: **Event Hubs Data Receiver** role (MI-based data connection)
  - Event Grid → Event Hub: **Event Hubs Data Sender** role (MI-based delivery via `deliveryWithResourceIdentity`)
- **MI-based Event Grid delivery**: The Event Grid system topic uses a system-assigned managed identity to deliver events to Event Hub. This is compatible with environments where Event Hub `disableLocalAuth=true` is enforced by Azure Policy (SAS-based delivery would fail). The Bicep module (`event-grid.bicep`) provisions the system topic identity, RBAC role assignments, and `deliveryWithResourceIdentity` configuration automatically.
- **No file-extension filter**: The Event Grid subscription triggers on **any** blob uploaded to the `file-transfer-events` container (`subjectEndsWith: ''`), not just `.csv` or `.json`. ADX ingestion mappings handle format detection.
- **Queued ingestion parity**: The Python runbook uses `QueuedIngestClient` targeting the staging table — matching the same path as the Event Grid pipeline.
- **Data persistence**: ADX is an independent append-only store. Deleting source blobs from Storage does not affect ingested data in ADX. Data lifetime is controlled by retention policies (90 days target, 1 day staging, 30 days errors, 730 days materialized view).

## FAQ

### Why is Event Hub needed? Can't ADX ingest directly from Storage?

ADX **can** read blobs directly (via `.ingest into` commands or the Python SDK), but for **automatic event-driven ingestion** it needs a notification mechanism to know when a new blob arrives. ADX's data connection types are Event Hub, Event Grid, and IoT Hub — there is no direct "Storage" data connection. The Event Grid data connection uses Event Hub as the message transport: Storage → Event Grid → Event Hub → ADX (reads blob from Storage). If you only need manual ingestion, set `enableEventGrid=false` to skip Event Hub entirely.

### I uploaded a file but can't see data in Grafana

**Check the time range.** Dashboards default to "Last 1 hour". If your data has timestamps outside that window, no panels will show results. Click the time picker (top-right in Grafana) and widen the range to "Last 7 days" or a custom range that covers your data timestamps.

If the time range is correct, verify data landed in ADX:

```bash
python adx_runbook.py verify \
  --cluster https://adx-ft-dev.eastus2.kusto.windows.net \
  --database ftevents_dev
```

### What happens if I delete blobs from Storage?

Nothing changes in ADX. Once data is ingested, ADX stores it independently as an append-only store. Deleting source blobs has no effect on ingested rows. Data lifetime in ADX is controlled by retention policies (90 days target table, 1 day staging, 30 days errors, 730 days materialized view).

### Does Event Grid only trigger on CSV or JSON files?

No — the Event Grid subscription has `subjectEndsWith: ''`, which means **any** file uploaded to the `file-transfer-events` container triggers ingestion. There is no file-extension filter. The ADX data connection uses the configured ingestion mapping to parse the file content.

### My Event Hub has `disableLocalAuth=true` — will the pipeline work?

Yes. The Bicep deployment configures MI-based delivery throughout. Event Grid uses `deliveryWithResourceIdentity` (system-assigned MI with **Event Hubs Data Sender** role) instead of SAS keys. ADX uses `managedIdentityResourceId` on the data connection (with **Event Hubs Data Receiver** role). No SAS keys or connection strings are used anywhere.

### How do I ingest files with a different set of columns?

Three options:

1. **Separate pipeline** (recommended): Create a new staging table, mapping, transform function, and data connection for the new schema. Use a different container or blob path prefix to route files.
2. **Extend existing tables**: Use `.alter-merge table` to add columns — existing rows get `null` for new columns. Update the mapping and transform function.
3. **Dynamic column**: Add an `ExtendedProperties: dynamic` column to catch unmapped fields. Flexible but less type-safe.

See [data-model.md](specs/001-adx-file-transfer-analytics/data-model.md) for the current schema.

### How do I add a new environment (e.g., staging)?

1. Copy `infra/parameters/dev.bicepparam` to `infra/parameters/staging.bicepparam`
2. Update parameter values (cluster name, database name, SKU, retention, etc.)
3. Deploy: `az deployment group create --parameters infra/parameters/staging.bicepparam`

Each environment is fully isolated — separate ADX database, Storage container, Event Hub, and Grafana instance.

### Can I use this with an existing ADX cluster or Grafana?

Yes. Pass `existingAdxClusterId`, `existingAdxClusterUri`, and `existingAdxPrincipalId` to reuse an existing ADX cluster. Pass `existingGrafanaId`, `existingGrafanaPrincipalId`, and `existingGrafanaEndpoint` for Grafana. See [Using Existing Resources](#using-existing-resources) for details.

## Documentation

- [Specification](specs/001-adx-file-transfer-analytics/spec.md)
- [Implementation Plan](specs/001-adx-file-transfer-analytics/plan.md)
- [Data Model](specs/001-adx-file-transfer-analytics/data-model.md)
- [Research Decisions](specs/001-adx-file-transfer-analytics/research.md)
- [Quickstart Guide](specs/001-adx-file-transfer-analytics/quickstart.md)
- [Runbook README](runbook/README.md)
