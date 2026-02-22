# Research: ADX File-Transfer Analytics

**Branch**: `001-adx-file-transfer-analytics` | **Date**: 2026-02-21 | **Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

---

## Topic 1: ADX Staging Table + Update Policy Pattern

### Decision

Use a two-table pattern: a **staging table** (`FileTransferEvents_Raw`) receives all raw ingestion, and an **update policy** on the **target table** (`FileTransferEvents`) runs a KQL transformation function that derives the `Timestamp` column at ingestion time. The staging table schema mirrors the target table minus the `Timestamp` column. The transformation function uses `coalesce(SourceLastModifiedUtc, ingestion_time())` to populate `Timestamp`.

### Rationale

- **Concrete, indexed Timestamp**: By computing `Timestamp` during ingestion rather than at query time, every downstream query, materialized view, and alert operates on a real column with a datetime index. No query-time `coalesce()` is needed, which simplifies all KQL and improves scan performance.
- **Separation of concerns**: The staging table absorbs raw ingestion (including malformed data handling), while the target table always contains clean, transformed data. This is the canonical ADX pattern recommended by Microsoft for ingestion-time enrichment.
- **`ingestion_time()` availability**: The `ingestion_time()` function is only callable within an update policy transformation function—it is not available in regular queries. This makes the update policy the natural place for the fallback logic.
- **Staging table without `Timestamp`**: The staging table omits `Timestamp` because that column is derived, not supplied by the source. Including it would risk confusion (a null column that is never populated by ingestion). The staging table includes all source-provided columns only.

### Alternatives Considered

| Alternative | Why Rejected |
|---|---|
| **Single table, query-time `coalesce()`** | Every KQL query, dashboard panel, alert rule, and materialized view must repeat the coalesce logic. Timestamp is not indexed. Violates FR-002. |
| **Single table with `ingestion_time()` policy enabled** | `ingestion_time()` returns the ingestion timestamp but cannot be combined with `coalesce(SourceLastModifiedUtc, ...)` at query time without embedding logic in every query. Does not produce a concrete column. |
| **Staging table with identical schema (including `Timestamp`)** | Adds a column that is always null in the staging table. Wastes storage and invites confusion. Marginally simpler DDL but semantically misleading. |
| **Azure Data Factory / Logic Apps transformation** | Adds external orchestration, cost, and latency. ADX update policies run in-process during ingestion with sub-second overhead—far simpler for column derivation. |

### Key Implementation Notes

1. **Create the transformation function first**, then the update policy. The function must exist before it can be referenced:

   ```kql
   .create-or-alter function FileTransferEvents_Transform() {
       FileTransferEvents_Raw
       | extend Timestamp = coalesce(SourceLastModifiedUtc, ingestion_time())
       | project Filename, SourcePresent, TargetPresent,
                 SourceLastModifiedUtc, TargetLastModifiedUtc,
                 AgeMinutes, Status, Notes, Timestamp
   }
   ```

   `.create-or-alter function` is idempotent—safe to re-run in scripts and CI/CD.

2. **Attach the update policy to the target table**:

   ```kql
   .alter table FileTransferEvents policy update
   @'[{"IsEnabled": true, "Source": "FileTransferEvents_Raw", "Query": "FileTransferEvents_Transform()", "IsTransactional": true, "PropagateIngestionProperties": true}]'
   ```

   - `IsTransactional: true` — if the transformation fails, the raw extent is also rolled back, preventing data from being stuck in the staging table with no corresponding target rows.
   - `PropagateIngestionProperties: true` — preserves ingestion-time tags and properties (e.g., `ingestion_time()` remains accurate for the source extent).

3. **Staging table DDL** uses `.create-merge table` for idempotency:

   ```kql
   .create-merge table FileTransferEvents_Raw (
       Filename: string,
       SourcePresent: bool,
       TargetPresent: bool,
       SourceLastModifiedUtc: datetime,
       TargetLastModifiedUtc: datetime,
       AgeMinutes: real,
       Status: string,
       Notes: string
   )
   ```

4. **Retention on the staging table** should be short (e.g., 1 day). After the update policy moves data to the target table, the staging data is redundant. Set via:

   ```kql
   .alter table FileTransferEvents_Raw policy retention
   @'{"SoftDeletePeriod": "1.00:00:00", "Recoverability": "Disabled"}'
   ```

5. **Error handling**: Rows that fail the transformation function are governed by the update policy's error behavior. With `IsTransactional: true`, a failure rolls back the entire extent. For partial-failure tolerance (ingest good rows, route bad rows to errors table), consider a try-catch pattern within the function or a separate error-routing update policy. For this project (well-defined CSV/JSON schema, <1,000 events/day), transactional mode is preferred for simplicity—malformed files are caught earlier by ingestion mapping validation and routed to `FileTransferEvents_Errors`.

6. **Order of DDL execution**:
   1. `.create-merge table FileTransferEvents` (target)
   2. `.create-merge table FileTransferEvents_Raw` (staging)
   3. `.create-merge table FileTransferEvents_Errors` (dead-letter)
   4. `.create-or-alter function FileTransferEvents_Transform()`
   5. `.alter table FileTransferEvents policy update [...]`
   6. Create ingestion mappings on the staging table
   7. Set retention policies on all tables

---

## Topic 2: ADX Event Grid Native Ingestion

### Decision

Use **Event Grid subscription → ADX native data connection** to automatically ingest blobs as they land in the storage account. The ADX data connection points to the **staging table** (`FileTransferEvents_Raw`), not the target table directly. Both CSV and JSON formats are supported via separate ingestion mappings. The `IngestionBatching` policy is tuned to achieve <5 minute end-to-end latency.

### Rationale

- **Zero-code ingestion**: ADX's native Event Grid data connection handles the entire pipeline from blob-created event to ingested extent. No Azure Functions, Data Factory, or custom code required.
- **Staging table target**: Ingestion must feed the staging table so the update policy can derive `Timestamp`. Pointing the data connection directly at the target table would bypass the transformation.
- **Event Grid + ADX is a first-class integration**: Microsoft maintains and optimizes this path. It supports blob lifecycle events, filtering by blob path prefix and suffix, and automatic retry.

### Alternatives Considered

| Alternative | Why Rejected |
|---|---|
| **Azure Data Factory pipeline** | Adds orchestration complexity, ADF runtime cost, and additional latency. Overkill for simple blob → ADX ingestion at <1,000 events/day. |
| **Azure Functions with Kusto SDK** | Custom code to maintain, monitor, and scale. The native data connection does the same thing with zero code. |
| **Queued ingestion via Python runbook only** | Not automated—requires manual trigger. Suitable for dev/test bootstrapping but not production. |
| **Direct ingestion (streaming)** | Streaming ingestion has different consistency guarantees and is not needed at this volume. Event Grid + batched ingestion is the standard pattern. |

### Key Implementation Notes

1. **Event Grid subscription configuration**:
   - **Source**: Azure Storage account (the ingestion landing zone).
   - **Event types**: `Microsoft.Storage.BlobCreated` only.
   - **Subject filter**: Filter by blob path prefix (e.g., `/blobServices/default/containers/file-transfer-events/`) and suffix (`.csv` or `.json`) to avoid triggering on unrelated blobs.
   - **Destination**: ADX data connection (Event Grid type).

2. **ADX data connection resource** (`Microsoft.Kusto/clusters/databases/dataConnections`):
   - `kind: EventGrid`
   - `storageAccountResourceId`: The landing zone storage account.
   - `eventHubResourceId`: Event Grid creates a system topic that routes through an Event Hub namespace (auto-managed when using the ADX data connection resource in Bicep/ARM — or you provision one explicitly).
   - `consumerGroup`: `$Default` or a dedicated consumer group.
   - `tableName`: `FileTransferEvents_Raw` (the staging table).
   - `dataFormat`: Set per data connection. Create **two data connections** if both CSV and JSON files land in the same container, differentiated by blob path suffix filter. Alternatively, use a single data connection with `dataFormat` set dynamically by using blob metadata or separate containers per format.
   - `mappingRuleName`: `FileTransferEvents_CsvMapping` or `FileTransferEvents_JsonMapping`.

3. **CSV vs JSON ingestion mapping differences**:

   | Aspect | CSV Mapping | JSON Mapping |
   |---|---|---|
   | Column reference | By ordinal position (`"Ordinal": 0, 1, 2, ...`) | By JSON property path (`"Path": "$.Filename"`) |
   | Header handling | First row as header if `ignoreFirstRecord: true` set in ingestion properties | N/A (JSON is self-describing) |
   | Null handling | Empty string → null for typed columns (datetime, bool, real) | Absent key → null |
   | Nested data | Not supported | Supported via JSONPath (`$.parent.child`) |
   | Multi-record | One row per CSV line | One record per JSON object; supports JSON lines or JSON array |

   Example CSV mapping on the staging table:
   ```kql
   .create-or-alter table FileTransferEvents_Raw ingestion csv mapping 'FileTransferEvents_CsvMapping'
   '[
       {"Name": "Filename",              "DataType": "string",   "Ordinal": 0},
       {"Name": "SourcePresent",          "DataType": "bool",     "Ordinal": 1},
       {"Name": "TargetPresent",          "DataType": "bool",     "Ordinal": 2},
       {"Name": "SourceLastModifiedUtc",  "DataType": "datetime", "Ordinal": 3},
       {"Name": "TargetLastModifiedUtc",  "DataType": "datetime", "Ordinal": 4},
       {"Name": "AgeMinutes",             "DataType": "real",     "Ordinal": 5},
       {"Name": "Status",                 "DataType": "string",   "Ordinal": 6},
       {"Name": "Notes",                  "DataType": "string",   "Ordinal": 7}
   ]'
   ```

   Example JSON mapping on the staging table:
   ```kql
   .create-or-alter table FileTransferEvents_Raw ingestion json mapping 'FileTransferEvents_JsonMapping'
   '[
       {"column": "Filename",              "path": "$.Filename",              "datatype": "string"},
       {"column": "SourcePresent",          "path": "$.SourcePresent",          "datatype": "bool"},
       {"column": "TargetPresent",          "path": "$.TargetPresent",          "datatype": "bool"},
       {"column": "SourceLastModifiedUtc",  "path": "$.SourceLastModifiedUtc",  "datatype": "datetime"},
       {"column": "TargetLastModifiedUtc",  "path": "$.TargetLastModifiedUtc",  "datatype": "datetime"},
       {"column": "AgeMinutes",             "path": "$.AgeMinutes",             "datatype": "real"},
       {"column": "Status",                 "path": "$.Status",                 "datatype": "string"},
       {"column": "Notes",                  "path": "$.Notes",                  "datatype": "string"}
   ]'
   ```

4. **`IngestionBatching` policy** — controls how long ADX waits to batch incoming blobs before sealing an extent:

   ```kql
   .alter table FileTransferEvents_Raw policy ingestionbatching
   @'{"MaximumBatchingTimeSpan": "00:01:00", "MaximumNumberOfItems": 20, "MaximumRawDataSizeMB": 256}'
   ```

   - **Default**: 5 minutes batching time. For <5 min end-to-end latency target, reduce to **1 minute**.
   - The policy triggers sealing when *any* of the three thresholds is hit (time, count, or size). At <1,000 events/day the time threshold will almost always be the trigger.
   - **Trade-off**: Shorter batching = more extents = more merge operations. At this volume (a few blobs/day), the overhead is negligible even on a Dev/Test SKU.
   - Also consider setting the batching policy on the **database level** if all tables should share the same latency target.

5. **End-to-end latency breakdown** (target <5 minutes):
   - Blob created → Event Grid notification: ~seconds (typically <30 s)
   - Event Grid → ADX data connection pickup: ~seconds
   - ADX batching window: 1 minute (configured above)
   - Update policy execution: sub-second
   - **Total expected**: ~1.5–2 minutes with a 1-minute batching policy. Well within the 5-minute target.

6. **RBAC for ingestion**: The ADX cluster's managed identity (or an Event Grid system topic identity) needs:
   - `Storage Blob Data Reader` on the storage account (to read blobs during ingestion).
   - The Event Grid subscription needs `Microsoft.EventGrid/eventSubscriptions/write` on the storage account.
   - The ADX data connection resource handles the Event Hub consumer internally.

---

## Topic 3: Managed Grafana ADX Plugin Configuration

### Decision

Use **Azure Managed Grafana** with the built-in **Azure Data Explorer (ADX) data source plugin**, authenticated via the Grafana instance's **system-assigned managed identity**. Dashboards are authored in the Grafana UI and exported as JSON models for version control. Alerts are defined using Grafana Alerting (unified alerting) with KQL-backed queries.

### Rationale

- **Managed identity eliminates secrets**: No client secrets, API keys, or password rotation. The Grafana managed identity is granted `Viewer` (or `AllDatabasesViewer`) role on the ADX cluster. Authentication is transparent and auditable via Entra ID.
- **Built-in ADX plugin**: Azure Managed Grafana ships with the ADX data source plugin pre-installed. No custom plugin installation required.
- **JSON export/import for GitOps**: Grafana's JSON model is the standard mechanism for dashboard-as-code. Export → commit → import provides version control and environment promotion.
- **Unified alerting**: Grafana's built-in alerting engine supports KQL data source queries, evaluation intervals, multi-dimensional labels, and contact point routing—sufficient for the MISSING file and dead-letter alerts.

### Alternatives Considered

| Alternative | Why Rejected |
|---|---|
| **Service principal auth for Grafana** | Requires secret management (Key Vault, rotation schedule). Managed identity is simpler and more secure. |
| **Self-hosted Grafana on AKS/VM** | Significant operational overhead (patching, scaling, HA). Managed Grafana is PaaS—Microsoft handles infrastructure. |
| **Azure Monitor Workbooks** | Limited visualization flexibility compared to Grafana. No equivalent of Grafana variables, alerting integration, or community dashboard ecosystem. ADX integration is weaker. |
| **Power BI** | Better for business users but worse for operational dashboards. No real-time refresh, no built-in alerting, requires Power BI license per user. |
| **Terraform-provisioned Grafana dashboards** | Grafana Terraform provider exists but adds Terraform state management. JSON export/import is simpler and Bicep handles the infrastructure. |

### Key Implementation Notes

1. **Data source configuration** in Grafana:
   - **Type**: `grafana-azure-data-explorer-datasource` (pre-installed in Azure Managed Grafana)
   - **Connection**:
     - **Cluster URL**: `https://<cluster-name>.<region>.kusto.windows.net`
     - **Database**: e.g., `ftevents_dev`, `ftevents_prod`
   - **Authentication**: `Managed Identity` (select in the data source config UI). No credentials fields are shown.
   - **Query timeout**: 30 seconds (default, aligned with Grafana's panel timeout).
   - One **data source per environment** (dev/test/prod), each pointing to its respective ADX database per FR-026.

2. **RBAC**: Grant the Grafana managed identity the `Viewer` role on the ADX database:
   ```kql
   .add database ftevents_dev viewers ('aadapp=<grafana-managed-identity-client-id>;<tenant-id>') 'Managed Grafana'
   ```
   Alternatively, assign `AllDatabasesViewer` at the cluster level if the identity should read all databases. In Bicep, this is a `Microsoft.Kusto/clusters/databases/principalAssignments` resource.

3. **KQL macros in Grafana panels**:

   | Macro | Expands To | Usage |
   |---|---|---|
   | `$__timeFilter(Timestamp)` | `Timestamp >= datetime(...) and Timestamp <= datetime(...)` | **Mandatory** in every panel query's `where` clause. Binds to the Grafana time picker. |
   | `$__interval` | Duration string (e.g., `5m`, `1h`) | Used in `bin(Timestamp, $__interval)` for adaptive aggregation. Grafana auto-calculates based on the time range and panel width. |
   | `$__from` / `$__to` | `datetime(...)` literals | Available for manual range references but `$__timeFilter` is preferred. |
   | `$__timeFilter()` (no column) | N/A — requires a column name | Common mistake: always pass the column name. |

   Example panel query:
   ```kql
   FileTransferEvents
   | where $__timeFilter(Timestamp)
   | summarize AvgAge = avg(AgeMinutes), P95Age = percentile(AgeMinutes, 95) by bin(Timestamp, $__interval)
   | order by Timestamp asc
   ```

4. **"Format as" setting per panel**:
   - **Table panels**: Format as = `Table`. KQL returns tabular results directly.
   - **Time-series panels** (line charts, stat panels over time): Format as = `Time series`. The query must return a `datetime` column (typically `Timestamp`) — Grafana uses it as the x-axis.
   - **Stat panels** (single-value): Format as = `Table` with a single-row result, or `Time series` with `reduce` depending on the metric.

5. **Dashboard provisioning workflow**:
   1. Author dashboard in Grafana UI (dev environment).
   2. Export JSON model via Grafana UI: Dashboard Settings → JSON Model → Copy.
   3. Commit JSON to `dashboards/operator-dashboard.json` and `dashboards/business-dashboard.json`.
   4. To deploy to another environment: Import the JSON model into the target Grafana instance, updating the data source UID to match the target environment's ADX data source.
   5. **Data source UID abstraction**: Use Grafana's `${DS_AZURE_DATA_EXPLORER}` variable syntax or a `__inputs` block in the exported JSON to make the data source reference portable across environments.
   6. **Programmatic import** (optional): Use the Grafana HTTP API (`POST /api/dashboards/db`) for CI/CD-driven deployment. Managed Grafana exposes the standard Grafana API.

6. **Alert rule definition**:
   - **Evaluation interval**: 5 minutes (balances responsiveness with ADX query cost). At <1,000 events/day, the query cost is negligible.
   - **Condition type**: Query result threshold. E.g., `WHEN last() OF query(MissingCount, 1h, now) IS ABOVE 3` (fires when >3 MISSING files in the last hour).
   - **Labels**: Include `environment`, `alert_type` (business vs. infrastructure), `severity`. These enable routing in the notification policy tree.
   - **Contact points**: Configure email, Microsoft Teams webhook, or PagerDuty integration in Grafana. Specific contact point setup is out of scope per the spec but the alert rule definition includes the necessary labels for routing.
   - **Two alert rules**:
     1. **Missing files alert** (FR-022): Fires when `countif(Status == "MISSING")` in the last hour exceeds a threshold (default: 3). Labels: `alert_type=business`, `severity=warning`.
     2. **Dead-letter alert** (FR-029): Fires when `count()` on `FileTransferEvents_Errors` in the last evaluation window is > 0. Labels: `alert_type=infrastructure`, `severity=critical`.
   - **Auto-resolve**: Both alert rules auto-resolve when the condition is no longer met in the next evaluation cycle (default Grafana behavior for threshold alerts).

7. **Dashboard variables**:
   - **Time range**: Built-in Grafana time picker (no custom variable needed).
   - **Environment**: Effectively the data source selector. Each environment has its own data source pointing to its own ADX database. Use a Grafana data source variable or a custom variable that maps to data source UIDs.
   - **Partner / System** (future): Custom query variables backed by KQL `distinct` queries when those columns are added to the schema.

---

## Topic 4: Bicep Modules for ADX + Grafana + Storage + Event Grid

### Decision

Use a **modular Bicep architecture** with a top-level orchestrator (`main.bicep`) that composes individual resource modules. Each major resource type gets its own module. Environment parameterization uses `.bicepparam` files for dev/test/prod. Managed identities and RBAC role assignments are centralized in an identity module.

### Rationale

- **Bicep is Azure-native**: First-class ARM integration, no state file to manage (unlike Terraform), built-in `what-if` for dry-run validation. Chosen per FR-025.
- **Modular decomposition**: Each module is independently testable and reusable. Modules can be deployed individually during development but are orchestrated together for environment provisioning.
- **`.bicepparam` files**: Provide a clean, type-safe way to parameterize per environment without environment-specific Bicep files. This is the modern Bicep approach (replacing JSON parameter files).

### Alternatives Considered

| Alternative | Why Rejected |
|---|---|
| **Terraform** | Requires state file management (remote backend, locking). Bicep's stateless deployment model is simpler for a single-team Azure project. |
| **ARM JSON templates** | Verbose, error-prone, no type system. Bicep compiles to ARM JSON but is far more readable and maintainable. |
| **Pulumi** | General-purpose IaC with real programming languages. Adds SDK dependency and state management. Overkill for this scope. |
| **Single monolithic Bicep file** | Becomes unreadable beyond ~200 lines. Modular structure scales better and enables targeted deployments. |
| **JSON parameter files** | Legacy approach. `.bicepparam` files offer type checking, expressions, and better IDE support. |

### Key Implementation Notes

1. **Module inventory and resource types**:

   | Module | Primary Resource Type(s) | Purpose |
   |---|---|---|
   | `adx-cluster.bicep` | `Microsoft.Kusto/clusters`, `Microsoft.Kusto/clusters/databases` | ADX cluster (Dev/Test SKU) + database per environment |
   | `grafana.bicep` | `Microsoft.Dashboard/grafana` | Managed Grafana instance with system-assigned managed identity |
   | `storage.bicep` | `Microsoft.Storage/storageAccounts`, `Microsoft.Storage/storageAccounts/blobServices/containers` | ADLS Gen2 ingestion landing zone with `file-transfer-events` container |
   | `event-grid.bicep` | `Microsoft.Kusto/clusters/databases/dataConnections` (kind: EventGrid) | ADX Event Grid data connection. The Event Grid system topic and subscription are implicitly managed by the ADX data connection resource, or explicitly via `Microsoft.EventGrid/systemTopics` and `Microsoft.EventGrid/systemTopics/eventSubscriptions` |
   | `identity.bicep` | `Microsoft.Authorization/roleAssignments`, `Microsoft.Kusto/clusters/databases/principalAssignments` | Managed identity RBAC: Grafana → ADX, ADX → Storage, Event Grid → Storage |
   | `networking.bicep` | `Microsoft.Network/privateEndpoints`, `Microsoft.Kusto/clusters/managedPrivateEndpoints`, `Microsoft.Dashboard/grafana/managedPrivateEndpoints` | Private Link for ADX and Grafana; managed private endpoints for outbound connectivity |

2. **ADX cluster + database Bicep**:
   ```bicep
   resource adxCluster 'Microsoft.Kusto/clusters@2024-04-13' = {
     name: clusterName
     location: location
     sku: {
       name: 'Dev(No SLA)_Standard_E2a_v4'  // Dev/Test SKU
       tier: 'Basic'
       capacity: 1
     }
     identity: {
       type: 'SystemAssigned'
     }
     properties: {
       enableStreamingIngest: false
       enablePurge: false
     }
   }

   resource database 'Microsoft.Kusto/clusters/databases@2024-04-13' = {
     parent: adxCluster
     name: databaseName  // e.g., 'ftevents_dev'
     location: location
     kind: 'ReadWrite'
     properties: {
       softDeletePeriod: retentionDays  // 'P90D' for prod, 'P30D' for non-prod
       hotCachePeriod: hotCacheDays     // 'P30D' typically
     }
   }
   ```

3. **ADX Event Grid data connection Bicep**:
   ```bicep
   resource dataConnection 'Microsoft.Kusto/clusters/databases/dataConnections@2024-04-13' = {
     parent: database
     name: 'FileTransferEventsConnection'
     location: location
     kind: 'EventGrid'
     properties: {
       storageAccountResourceId: storageAccountId
       eventGridResourceId: eventGridSystemTopicId  // if using explicit system topic
       eventHubResourceId: eventHubId               // required for Event Grid → Event Hub → ADX path
       consumerGroup: '$Default'
       tableName: 'FileTransferEvents_Raw'          // staging table, NOT target
       dataFormat: 'CSV'                              // or 'JSON'; use separate connections per format
       mappingRuleName: 'FileTransferEvents_CsvMapping'
       blobStorageEventType: 'Microsoft.Storage.BlobCreated'
       ignoreFirstRecord: true                       // for CSV with headers
     }
   }
   ```

   **Note**: The Event Grid data connection in ADX requires an intermediate Event Hub. Options:
   - Let ADX create it automatically (managed Event Hub) — simplest.
   - Provision an Event Hub namespace explicitly in Bicep for full control.
   - With the `Microsoft.Kusto/clusters/databases/dataConnections` resource kind `EventGrid`, Azure provisions the Event Grid system topic → Event Hub → ADX consumer pipeline. Specify `eventHubResourceId` and `consumerGroup` when using an explicit Event Hub.

4. **Managed identity RBAC role assignments**:

   | Principal | Target Resource | Role | Purpose |
   |---|---|---|---|
   | Grafana system-assigned MI | ADX database | `Viewer` (ADX database principal) | Read-only KQL query access |
   | ADX cluster system-assigned MI | Storage account | `Storage Blob Data Reader` | Read blobs during Event Grid ingestion |
   | ADX cluster system-assigned MI | Storage account | `Storage Blob Data Contributor` | Write transient blobs for queued ingestion (SDK uploads) |
   | Event Grid system topic MI | Storage account | `Storage Blob Data Reader` | Read blob metadata for event delivery |

   In Bicep, ADX database-level roles are assigned via `Microsoft.Kusto/clusters/databases/principalAssignments`:
   ```bicep
   resource grafanaAdxRole 'Microsoft.Kusto/clusters/databases/principalAssignments@2024-04-13' = {
     parent: database
     name: 'grafana-viewer'
     properties: {
       principalId: grafanaManagedIdentityPrincipalId
       principalType: 'App'
       role: 'Viewer'
       tenantId: tenantId
     }
   }
   ```

   Storage-level roles use standard `Microsoft.Authorization/roleAssignments`:
   ```bicep
   resource adxStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
     scope: storageAccount
     name: guid(storageAccount.id, adxCluster.id, storageBlobDataReaderRoleId)
     properties: {
       roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
       principalId: adxCluster.identity.principalId
       principalType: 'ServicePrincipal'
     }
   }
   ```

5. **Private Link / Managed Private Endpoints**:
   - **ADX managed private endpoint to Storage**: Created via `Microsoft.Kusto/clusters/managedPrivateEndpoints`. Allows the ADX cluster to reach the storage account over private networking without public internet.
   - **Grafana managed private endpoint to ADX**: Created via `Microsoft.Dashboard/grafana/managedPrivateEndpoints`. Allows Grafana to query ADX over a private connection.
   - **Approval**: Managed private endpoints require approval on the target resource. Bicep can create them, but approval is a separate step (auto-approved if the deploying identity has sufficient permissions on the target resource, or manual approval in the portal).
   - **Public network access**: Set `publicNetworkAccess: 'Disabled'` on ADX and Grafana in production. In dev, `Enabled` may be acceptable for simplicity.

6. **`.bicepparam` parameterization strategy**:

   ```bicep
   // parameters/dev.bicepparam
   using '../main.bicep'

   param environmentName = 'dev'
   param location = 'eastus2'
   param adxClusterName = 'adx-ft-dev'
   param adxDatabaseName = 'ftevents_dev'
   param adxSkuName = 'Dev(No SLA)_Standard_E2a_v4'
   param adxSkuTier = 'Basic'
   param retentionDays = 'P30D'
   param hotCacheDays = 'P7D'
   param storageAccountName = 'stfteventsdev'
   param grafanaName = 'grafana-ft-dev'
   param enablePublicAccess = true   // true for dev, false for prod
   param enablePrivateEndpoints = false  // false for dev, true for prod
   ```

   Key parameterization dimensions:
   - **Environment name**: Drives resource naming and tagging.
   - **ADX SKU**: Dev/Test for non-prod, Standard for prod.
   - **Retention periods**: 30 days non-prod, 90 days prod.
   - **Networking**: Public access enabled for dev, Private Link for prod.
   - **Location**: Consistent across environments or varied by org policy.

7. **Deployment command**:
   ```bash
   az deployment group create \
     --resource-group rg-file-transfer-dev \
     --template-file infra/main.bicep \
     --parameters infra/parameters/dev.bicepparam
   ```

   Dry-run validation:
   ```bash
   az deployment group what-if \
     --resource-group rg-file-transfer-dev \
     --template-file infra/main.bicep \
     --parameters infra/parameters/dev.bicepparam
   ```

---

## Topic 5: ADX Materialized Views

### Decision

Create a **materialized view** (`DailySummary`) over `FileTransferEvents` that pre-aggregates daily metrics. The view has a 730-day retention policy independent of the source table's 90-day retention. The `effectiveDateTime` parameter is **not** used — the view processes all historical data from the source table. On a Dev/Test SKU, the default `MaterializedViewsCapacity` is sufficient given the low data volume.

### Rationale

- **Performance**: The `DailySummary` materialized view pre-computes daily aggregates, eliminating the need for business dashboard queries to scan 30–90 days of raw events on every panel load.
- **Long-term retention**: Business reporting needs 2 years of daily aggregates even though raw events are retained for only 90 days. The materialized view's independent retention policy achieves this—once a daily aggregate is materialized, it persists even after the source rows expire.
- **Cost efficiency**: At <1,000 events/day, the materialization overhead is trivial. The view processes a small delta on each materialization cycle (typically every few minutes).

### Alternatives Considered

| Alternative | Why Rejected |
|---|---|
| **Query-time aggregation only** | Business dashboard queries scanning 90 days of raw data every time a panel loads. Slow and expensive at scale (even if acceptable at current volume, this doesn't scale and violates <5 s load SLO for 30-day range). |
| **Scheduled KQL `.set-or-append`** | Requires external orchestration (Logic App, Azure Function, or scheduled pipeline) to run a daily aggregation query and append results to a summary table. More moving parts than a materialized view, which ADX manages automatically. |
| **Azure Data Factory aggregation** | External tool, additional cost and complexity. The aggregation logic is pure KQL — keeping it inside ADX is simpler. |
| **Continuous export to external store** | Adds external dependencies (Data Lake, Synapse). Unnecessary when ADX materialized views handle the retention and aggregation natively. |

### Key Implementation Notes

1. **Materialized view DDL**:

   ```kql
   .create materialized-view DailySummary on table FileTransferEvents {
       FileTransferEvents
       | summarize
           TotalCount     = count(),
           OkCount        = countif(Status == "OK"),
           MissingCount   = countif(Status == "MISSING"),
           DelayedCount   = countif(Status == "DELAYED"),
           AvgAgeMinutes  = avg(AgeMinutes),
           P95AgeMinutes  = percentile(AgeMinutes, 95),
           SlaAdherencePct = round(100.0 * countif(Status == "OK") / count(), 2)
       by Date = startofday(Timestamp)
   }
   ```

   **Important**: The `by` clause defines the grouping key (`Date = startofday(Timestamp)`). Each unique `Date` value produces one row in the materialized view.

2. **Retention policy on the materialized view** (730 days):

   ```kql
   .alter materialized-view DailySummary policy retention
   @'{"SoftDeletePeriod": "730.00:00:00", "Recoverability": "Enabled"}'
   ```

   This is **independent** of the source table's retention. When raw events in `FileTransferEvents` expire after 90 days, the corresponding daily aggregate rows in `DailySummary` remain for 2 years.

3. **`effectiveDateTime` parameter — not needed**:
   - The `effectiveDateTime` parameter on `.create materialized-view` tells ADX to only materialize records ingested *after* the specified datetime, skipping historical backfill.
   - **For this project**: The source table starts empty (new deployment). There is no large historical backlog to skip. Omitting `effectiveDateTime` means the view processes all data from the beginning, which is the desired behavior.
   - **When to use `effectiveDateTime`**: If the source table already contained millions of rows and you wanted to avoid the cost of backfilling the materialized view, you would set `effectiveDateTime` to "now" to start materializing only new data going forward. Not applicable here.

4. **`MaterializedViewsCapacity` on Dev/Test SKU**:
   - The Dev/Test SKU (`Dev(No SLA)_Standard_E2a_v4`) has **1 node** with limited CPU and memory.
   - The default `MaterializedViewsCapacity` policy allows a configurable number of concurrent materialization jobs. The default (typically 1 on a single-node cluster) is sufficient for one materialized view with <1,000 rows/day input.
   - **No tuning needed** at this volume. If additional materialized views are added or volume increases significantly, check the view's health:
     ```kql
     .show materialized-view DailySummary
     ```
     Key fields: `IsHealthy`, `MaterializedTo` (how far behind the view is), `LastRun`, `FailureRate`.
   - If the view falls behind, increase the cluster SKU or adjust the `MaterializedViewsCapacity`:
     ```kql
     .alter cluster policy materialized_views_capacity
     @'{"ClusterMaximumConcurrentOperations": 2, "ExtentsRebuildCapacity": 1}'
     ```

5. **Querying the materialized view**:
   - Query it like a regular table:
     ```kql
     DailySummary
     | where Date >= ago(30d)
     | order by Date desc
     ```
   - For the business dashboard, use `materialized_view("DailySummary")` to explicitly query only the materialized portion (excluding any not-yet-materialized delta). This ensures consistent results:
     ```kql
     materialized_view("DailySummary")
     | where Date >= ago(30d)
     | order by Date desc
     ```
   - Without the `materialized_view()` function, ADX returns the union of the materialized portion and a live aggregation of the un-materialized delta — which is also correct but may show slightly different numbers for the current day until the next materialization cycle.

6. **Idempotent creation**: `.create materialized-view` fails if the view already exists. For idempotent scripts, use `.create-or-alter materialized-view` (available in newer ADX API versions) or wrap in `.create materialized-view ifnotexists`:
   ```kql
   .create ifnotexists materialized-view DailySummary on table FileTransferEvents {
       FileTransferEvents
       | summarize ...
       by Date = startofday(Timestamp)
   }
   ```

7. **`percentile()` in materialized views — important caveat**:
   - `percentile()` is **not natively supported** as an aggregation function in materialized views. Materialized views support a subset of aggregation functions: `count`, `countif`, `sum`, `sumif`, `min`, `max`, `avg`, `avgif`, `dcount`, `dcountif`, `arg_min`, `arg_max`, `any`, `anyif`, `take_any`, `take_anyif`, `hll`, `hll_if`, `tdigest`, `tdigest_if`, `percentile` (via `tdigest`), and `percentiles_array`.
   - To compute P95 in a materialized view, use the **`tdigest`** aggregation function, which produces a serialized t-digest sketch that can later be merged and queried with `percentile_tdigest()`:
     ```kql
     .create materialized-view DailySummary on table FileTransferEvents {
         FileTransferEvents
         | summarize
             TotalCount      = count(),
             OkCount         = countif(Status == "OK"),
             MissingCount    = countif(Status == "MISSING"),
             DelayedCount    = countif(Status == "DELAYED"),
             AvgAgeMinutes   = avg(AgeMinutes),
             AgeDigest       = tdigest(AgeMinutes),
             SlaAdherencePct = round(100.0 * countif(Status == "OK") / count(), 2)
         by Date = startofday(Timestamp)
     }
     ```
   - Then query P95 at read time:
     ```kql
     materialized_view("DailySummary")
     | project Date, TotalCount, OkCount, MissingCount, DelayedCount,
               AvgAgeMinutes,
               P95AgeMinutes = percentile_tdigest(AgeDigest, 95),
               SlaAdherencePct
     ```
   - This approach stores the t-digest sketch (compact binary) in the materialized view and computes the actual percentile value at query time from the sketch — accurate and efficient.

---

## Summary of Decisions

| # | Topic | Decision |
|---|---|---|
| 1 | Staging Table + Update Policy | Two-table pattern: `FileTransferEvents_Raw` → update policy with `coalesce(SourceLastModifiedUtc, ingestion_time())` → `FileTransferEvents`. Staging omits `Timestamp`. Transactional policy with `PropagateIngestionProperties`. |
| 2 | Event Grid Native Ingestion | Event Grid data connection targets the staging table. Separate CSV/JSON mappings. 1-minute batching policy for <5 min E2E latency. ~1.5–2 min expected. |
| 3 | Managed Grafana ADX Plugin | System-assigned managed identity auth. One data source per environment. `$__timeFilter(Timestamp)` mandatory. JSON model export for GitOps. Unified alerting with 5-min eval interval. |
| 4 | Bicep Modules | 6 modules (ADX, Grafana, Storage, Event Grid, Identity, Networking) + `main.bicep` orchestrator. `.bicepparam` per environment. Managed identity RBAC via `principalAssignments` + `roleAssignments`. |
| 5 | Materialized Views | `DailySummary` with `tdigest()` for P95. 730-day independent retention. No `effectiveDateTime` needed. Dev/Test SKU capacity sufficient. Use `materialized_view()` function for consistent reads. |
