# ADX File-Transfer Analytics Runbook

A Python CLI and interactive notebook for setting up, ingesting data, and verifying the ADX file-transfer analytics pipeline. Uses the same schema, mappings, and update policy as the production Event Grid pipeline — ensuring full ingestion parity between manual testing and automated operation.

| Interface | File | Best for |
|-----------|------|----------|
| **Notebook** | `adx_runbook.ipynb` | Interactive exploration, ad-hoc queries, step-by-step walkthroughs |
| **CLI** | `adx_runbook.py` | Scripted runs, CI/CD pipelines, automation |

## Prerequisites

- **Python** 3.9+
- **[uv](https://docs.astral.sh/uv/)** — fast Python package manager (`curl -LsSf https://astral.sh/uv/install.sh | sh`)
- **Azure CLI** (`az login`) for interactive authentication
- Access to an Azure Data Explorer cluster and database

## Installation

```bash
cd runbook
uv venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
uv pip install -r requirements.txt
```

For the notebook, also install `ipykernel`:

```bash
uv pip install ipykernel
```

Required packages:
- `azure-kusto-data` — ADX query and management commands
- `azure-kusto-ingest` — Queued ingestion client
- `azure-identity` — Azure authentication (interactive, managed identity, service principal)
- `certifi` — CA certificate bundle (needed when uv-managed Python lacks system CA certs)

## Authentication Methods

### Azure CLI (default)

Uses your existing `az login` session. Works in WSL, SSH, and containers:

```bash
az login
python adx_runbook.py setup --cluster <URI> --database <DB>
```

### Interactive (browser)

Launches a browser-based Azure login. Best for local desktop development:

```bash
python adx_runbook.py --auth-method interactive ...
```

### Managed Identity

For Azure VMs, containers, or Azure services with a configured managed identity:

```bash
python adx_runbook.py --auth-method managed-identity ...
```

### Service Principal

For CI/CD pipelines or automation. Provide credentials via CLI args or environment variables:

```bash
# Via CLI args
python adx_runbook.py --auth-method service-principal \
  --client-id <APP_ID> \
  --client-secret <SECRET> \
  --tenant-id <TENANT_ID> \
  ...

# Via environment variables
export AZURE_CLIENT_ID=<APP_ID>
export AZURE_CLIENT_SECRET=<SECRET>
export AZURE_TENANT_ID=<TENANT_ID>
python adx_runbook.py --auth-method service-principal ...
```

## Commands

### `setup` — Create ADX Schema

Creates the full object chain: staging table, target table, dead-letter table, transformation function, update policy, CSV/JSON ingestion mappings, retention policies, batching policy, and the DailySummary materialized view.

All commands are idempotent — safe to run multiple times.

> **Note**: For fresh Bicep deployments, the schema is applied automatically via the
> [`adx-schema.bicep`](../infra/modules/adx-schema.bicep) Kusto database script.
> Use this command for existing clusters managed outside Bicep, or for troubleshooting.

```bash
python adx_runbook.py setup \
  --cluster https://adx-ft-dev.eastus2.kusto.windows.net \
  --database ftevents_dev
```

### `ingest-local` — Ingest a Local File

Ingests a local CSV or JSON file into the staging table (`FileTransferEvents_Raw`) via queued ingestion. The update policy automatically moves rows to the target table with a derived `Timestamp`.

```bash
# CSV file
python adx_runbook.py ingest-local \
  --cluster https://adx-ft-dev.eastus2.kusto.windows.net \
  --ingest-uri https://ingest-adx-ft-dev.eastus2.kusto.windows.net \
  --database ftevents_dev \
  --file ../samples/sample-events.csv

# JSON file
python adx_runbook.py ingest-local \
  --cluster https://adx-ft-dev.eastus2.kusto.windows.net \
  --ingest-uri https://ingest-adx-ft-dev.eastus2.kusto.windows.net \
  --database ftevents_dev \
  --file ../samples/sample-events.json
```

The format and mapping are auto-detected from the file extension. Override with `--format csv|json` and `--mapping <NAME>` if needed.

### `ingest-blob` — Ingest from Azure Blob Storage

Ingests a blob directly from Azure Storage:

```bash
python adx_runbook.py ingest-blob \
  --cluster https://adx-ft-dev.eastus2.kusto.windows.net \
  --ingest-uri https://ingest-adx-ft-dev.eastus2.kusto.windows.net \
  --database ftevents_dev \
  --blob-uri "https://stfteventsdev.blob.core.windows.net/file-transfer-events/data.csv"
```

### `verify` — Check Ingested Data

Queries the target table and displays the 20 most recent rows. Validates that `Timestamp` is non-null for all rows.

```bash
python adx_runbook.py verify \
  --cluster https://adx-ft-dev.eastus2.kusto.windows.net \
  --database ftevents_dev
```

## End-to-End Example

Complete setup + ingest + verify in under 5 minutes:

> **Tip**: If you deployed via Bicep, skip step 1 — the schema is already applied.
> Start from step 2 (ingest) to load sample data and validate the pipeline.

```bash
# 1. Set up schema (skip if deployed via Bicep)
python adx_runbook.py setup \
  --cluster https://adx-ft-dev.eastus2.kusto.windows.net \
  --database ftevents_dev

# 2. Ingest sample data
python adx_runbook.py ingest-local \
  --cluster https://adx-ft-dev.eastus2.kusto.windows.net \
  --ingest-uri https://ingest-adx-ft-dev.eastus2.kusto.windows.net \
  --database ftevents_dev \
  --file ../samples/sample-events.csv

# 3. Wait for queued ingestion + update policy (~1-3 min)
sleep 120

# 4. Verify
python adx_runbook.py verify \
  --cluster https://adx-ft-dev.eastus2.kusto.windows.net \
  --database ftevents_dev
```

## Troubleshooting

| Issue | Resolution |
|-------|-----------|
| `ModuleNotFoundError: azure.kusto` | Run `pip install -r requirements.txt` |
| Auth failure with interactive | Run `az login` first, or try `--auth-method managed-identity` on Azure |
| No rows after ingest | Wait 1-3 minutes for queued ingestion + update policy, then run `verify` |
| Mapping errors | Ensure your file matches the expected schema (8 columns for CSV) |
| Timeout errors | Check cluster URI — use the query endpoint for `setup`/`verify`, ingest endpoint for ingestion |
