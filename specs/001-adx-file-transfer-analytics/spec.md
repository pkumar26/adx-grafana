# Feature Specification: ADX File-Transfer Analytics

**Feature Branch**: `001-adx-file-transfer-analytics`  
**Created**: 2026-02-21  
**Status**: Draft  
**Input**: User description: "Ingest CSV/JSON file-transfer health data into Azure Data Explorer and visualize in Azure Managed Grafana for infrastructure and business analytics"

---

## Clarifications

### Session 2026-02-21

- Q: What is the expected daily volume of file-transfer events in production? → A: Under 1,000 events/day (small, single-system monitoring)
- Q: How should duplicate file deliveries be handled? → A: Accept duplicates (append-only, no dedup logic needed)
- Q: Which IaC tool should be used for provisioning? → A: Bicep (Azure-native, first-class ARM integration, no state file to manage)
- Q: Should the system alert on ingestion failures (dead-letter table rows)? → A: Yes — alert when any rows land in FileTransferEvents_Errors within an evaluation window
- Q: How should the Environment dimension be populated for each file-transfer event? → A: Derive from ADX database name (e.g., database `ftevents_prod` → Environment = `prod`)
- Q: What columns should the DailySummary materialized view contain? → A: Date, TotalCount, OkCount, MissingCount, DelayedCount, AvgAgeMinutes, P95AgeMinutes *(revised to AgeDigest in FR-036; P95 computed at query time via `percentile_tdigest()`)*, SlaAdherencePct *(revised: computed at query time via `round(100.0 * OkCount / TotalCount, 2)` — `round()` is unsupported in MV aggregations)*
- Q: Where should the Timestamp column derivation happen? → A: Ingestion-time via ADX update policy (staging table → target table). Column is concrete and indexed; queries stay simple.
- Q: Which dashboard hosts the SLA & Delay Metrics time-series panels (avg/p95 AgeMinutes)? → A: Operator Dashboard only. Business Dashboard retains its own SLA Adherence % stat panel.
- Q: Which ingestion mode should the Python runbook use? → A: Queued ingestion (QueuedIngestClient) for both local files and blob URLs. Ingest URI always required. Matches production Event Grid pipeline.
- Q: Should the runbook create the staging table and update policy, or only the final target table? → A: Full chain — staging table (FileTransferEvents_Raw), update policy, target table, and mappings. Ingest into staging table for true production parity.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Ingest file-transfer health data into ADX (Priority: P1)

As a **platform engineer**, I need CSV and JSON file-transfer health records ingested into ADX so that the data is queryable within minutes of arrival and available as the single source of truth for all downstream dashboards and alerts.

**Why this priority**: Without data in ADX, no dashboards or alerts can exist. This is the foundational data pipeline that everything else depends on.

**Independent Test**: Upload a sample CSV and a sample JSON file to the configured landing zone. Verify that records appear in the ADX `FileTransferEvents` table within 5 minutes with correct types and a derived `Timestamp` column.

**Acceptance Scenarios**:

1. **Given** a valid CSV file lands in the ingestion storage account, **When** the ingestion pipeline processes it, **Then** all rows appear in the `FileTransferEvents` table with correct strong types (datetime, bool, real, string) within 5 minutes.
2. **Given** a valid JSON file lands in the ingestion storage account, **When** the ingestion pipeline processes it, **Then** all rows appear in the same `FileTransferEvents` table using the JSON ingestion mapping, with identical column semantics as CSV.
3. **Given** a malformed file (e.g., missing columns, invalid datetime), **When** the ingestion pipeline encounters it, **Then** the failed rows are routed to a `FileTransferEvents_Errors` dead-letter table with the original payload plus an `Error` column, and the healthy rows from the same file are still ingested successfully.
4. **Given** the `Timestamp` column derivation rule (SourceLastModifiedUtc), **When** a record has a null SourceLastModifiedUtc, **Then** the system falls back to ingestion time as the Timestamp value.

---

### User Story 2 — Operator dashboard for file-transfer health (Priority: P2)

As an **operations engineer**, I need a Grafana dashboard that shows me the current state of file transfers at a glance — recent transfers, missing or delayed files, and SLA breach counts — so I can identify and respond to issues within minutes, not hours.

**Why this priority**: Operators are the primary consumers who act on incidents. Giving them visibility immediately after data lands delivers the first real value from the pipeline.

**Independent Test**: Open the operator dashboard, select the last 1 hour, and verify that: (a) the "Recent File Transfers" table shows the latest records sorted descending, (b) the "Current Issues" table filters to MISSING and DELAYED statuses only, (c) the stat panels show counts for the selected time range, and (d) all panels load within 3 seconds.

**Acceptance Scenarios**:

1. **Given** file-transfer events exist in ADX for the past hour, **When** the operator opens the dashboard and selects a 1-hour range, **Then** the "Recent File Transfers" table displays Timestamp, Filename, Status, AgeMinutes, SourcePresent, TargetPresent, and Notes — sorted by Timestamp descending.
2. **Given** at least one MISSING file exists in the selected range, **When** the operator views the "Current Issues" panel, **Then** only records with Status in (MISSING, DELAYED) are shown, with clear visual distinction (color-coded status).
3. **Given** the operator changes the time range or applies an environment/partner filter variable, **When** the dashboard refreshes, **Then** all panels update within 3 seconds and reflect only the filtered data.
4. **Given** the dashboard is loaded with a 24-hour range encompassing thousands of events, **When** the time-series panels render, **Then** data is aggregated server-side via KQL `bin()` and `summarize`, keeping panel data under 1 000 rows.

---

### User Story 3 — SLA and delay metrics panels (Priority: P3)

As an **operations engineer**, I need time-series charts showing average and p95 file-transfer age over time, broken down by status, so I can spot emerging delay trends before they breach SLAs.

**Why this priority**: Trend visibility enables proactive response. While the operator table (P2) shows *current* issues, this story shows *developing* issues over time.

**Independent Test**: Load the SLA metrics dashboard with a 24-hour range. Verify that the avg AgeMinutes and p95 AgeMinutes time-series render correctly, that multiple series appear when broken down by status, and that aggregation bins adapt to the selected range.

**Acceptance Scenarios**:

1. **Given** events with varying AgeMinutes values across the past 24 hours, **When** the SLA metrics panel renders, **Then** it displays two series (avg and p95) with time on the x-axis and minutes on the y-axis, aggregated by Grafana's adaptive `$__interval` bin.
2. **Given** the operator enables the "breakdown by status" toggle, **When** the panel re-renders, **Then** separate series for OK, MISSING, and DELAYED appear, each with distinct colors.
3. **Given** a 7-day time range is selected, **When** the panel renders, **Then** the bin size automatically increases (e.g., 1h bins instead of 5m) to stay within panel row limits.

---

### User Story 4 — Missing/failed files alerting query (Priority: P4)

As an **operations engineer**, I need a KQL query (and corresponding Grafana alert rule) that fires when the count of MISSING files in the last hour exceeds a threshold, so that on-call staff are notified automatically rather than polling dashboards.

**Why this priority**: Alerts close the loop from visibility to action. They depend on the data pipeline (P1) and are enhanced by dashboards (P2/P3) but deliver independent value.

**Independent Test**: Manually insert a batch of MISSING-status records into ADX. Verify that the alerting query returns a non-zero MissingCount, and that the Grafana alert rule transitions to "Alerting" state within one evaluation cycle.

**Acceptance Scenarios**:

1. **Given** 5 MISSING records ingested in the last hour, **When** the alerting query evaluates, **Then** it returns `MissingCount = 5` for the most recent evaluation window.
2. **Given** the configured threshold is 3, **When** MissingCount exceeds 3, **Then** the Grafana alert fires with labels including environment, file type, and source system.
3. **Given** all files return to OK status, **When** the next evaluation cycle runs, **Then** the alert auto-resolves.
4. **Given** a malformed file causes rows to land in `FileTransferEvents_Errors`, **When** the dead-letter alert rule evaluates, **Then** it fires immediately (any row count > 0) with infrastructure alert labels including environment and error type.

---

### User Story 5 — Business analytics dashboard (Priority: P5)

As a **business analyst**, I need a dashboard showing file transfer volumes over time, SLA adherence percentages, and breakdowns by partner/region/environment, so I can report on operational performance to stakeholders without depending on the engineering team.

**Why this priority**: Business reporting is high-value but not operationally urgent. It builds on the same data and queries as the operator dashboards but with different aggregations and time horizons.

**Independent Test**: Open the business dashboard, select a 30-day range, and verify that: volume-per-day bar charts render, the SLA adherence stat shows a percentage, and the partner/environment drill-down filters work correctly.

**Acceptance Scenarios**:

1. **Given** 30 days of ingested events, **When** the business user opens the dashboard, **Then** a "Files per Day" bar chart displays daily counts, and a "SLA Adherence" stat panel shows the percentage of files with Status = OK.
2. **Given** the user filters by a specific partner or environment using dashboard variables, **When** the dashboard refreshes, **Then** all panels update to show only the filtered data.
3. **Given** the user selects a 90-day range, **When** the volume panels render, **Then** data is aggregated to daily bins and the total row count stays under 1 000.

---

### User Story 6 — Infrastructure provisioning via IaC (Priority: P6)

As a **platform engineer**, I need the ADX cluster/database, Managed Grafana instance, networking (Private Link/Managed Private Endpoints), managed identity assignments, and ingestion storage account provisioned via IaC (Bicep or Terraform), so that environments can be created, torn down, and promoted consistently.

**Why this priority**: IaC is foundational for environment isolation and repeatability but can initially be done manually while other stories deliver user-facing value. It formalizes what was set up ad-hoc.

**Independent Test**: Run the IaC deployment to a dev resource group. Verify that all resources are created, that managed identity has the correct RBAC roles on ADX and Grafana, and that the Grafana data source can connect to ADX.

**Acceptance Scenarios**:

1. **Given** IaC templates for dev environment, **When** deployed to an empty resource group, **Then** ADX cluster, database, Managed Grafana, storage account, Private Endpoints, and managed identity role assignments are all provisioned.
2. **Given** a deployed environment, **When** the Grafana data source is configured with managed identity auth, **Then** a test KQL query from Grafana returns results without any manual credential exchange.
3. **Given** the same IaC templates with parameterized environment names, **When** deployed with `env=test`, **Then** all resources are created in isolation from the dev deployment with no shared data or networking.

---

### User Story 7 — Python runbook for manual setup and testing (Priority: P7)

As a **platform engineer** or **developer**, I need a Python runbook script that can create the ADX table and ingestion mappings, ingest a local or Azure Storage CSV/JSON file, and run a verification KQL query — so that I can manually set up, validate, and test the ADX schema and ingestion without depending on the full IaC pipeline or Event Grid automation.

**Why this priority**: The runbook is a developer-facing utility that accelerates inner-loop testing and environment bootstrapping. It is not user-facing and does not block dashboards or alerts, but it significantly reduces friction when iterating on schema changes, testing ingestion mappings, or onboarding new team members.

**Independent Test**: From a developer workstation with Python 3.9+ and the `azure-kusto-data` / `azure-kusto-ingest` packages installed, run the runbook against a dev ADX cluster. Verify that: (a) the table and mappings are created if absent, (b) a sample CSV file is ingested, (c) a verification query returns the ingested rows with correct types, and (d) the script exits with a clear success/failure message.

**Acceptance Scenarios**:

1. **Given** a developer has Python 3.9+, `azure-kusto-data`, and `azure-kusto-ingest` installed, **When** they run the runbook with `--cluster-uri`, `--database`, and `--file` arguments using interactive login, **Then** the script authenticates, creates the table/mappings if needed, ingests the file, and prints verification query results.
2. **Given** the `FileTransferEvents` table already exists in the target database, **When** the runbook runs with the create-table step, **Then** it detects the existing table and skips creation without error (idempotent).
3. **Given** a sample CSV file matching the production schema, **When** ingested via the runbook, **Then** the resulting rows in ADX are identical in schema and types to rows ingested via the Event Grid pipeline (FR-001, FR-006).
4. **Given** a sample JSON file, **When** ingested via the runbook with the JSON mapping, **Then** the resulting rows match the same schema as CSV-ingested rows (FR-007).
5. **Given** the `--auth-method` parameter is set to `managed-identity`, **When** the runbook runs in an Azure VM or container with a configured managed identity, **Then** it authenticates without any interactive prompt and completes all steps.
6. **Given** the `--auth-method` parameter is set to `service-principal`, **When** the runbook is provided with `--client-id`, `--client-secret`, and `--tenant-id` (or environment variables), **Then** it authenticates non-interactively and completes all steps.

---

### Edge Cases

- **Empty file**: A CSV/JSON file with headers but zero data rows lands in the ingestion path. The system must not error; it should complete ingestion with zero rows added.
- **Duplicate file delivery**: The same file is delivered twice. ADX append-only semantics mean both copies are ingested. No deduplication logic is required at ingestion or query time — duplicate rows are accepted. At <1,000 events/day, the volume impact is negligible and the simplicity benefit outweighs the risk of inflated counts.
- **Extremely large file**: A file with 100 000+ rows lands at once. Batched ingestion must handle it without timeouts or memory issues.
- **Clock skew / future timestamps**: A record arrives with `SourceLastModifiedUtc` in the future. The system should ingest it but the anomaly should be visible in queries (e.g., negative AgeMinutes).
- **Null TargetLastModifiedUtc for MISSING files**: By definition, MISSING files have no target timestamp. The schema must accommodate nullable datetime, and queries must handle this gracefully (no divide-by-zero, no null-propagation errors).
- **Schema evolution**: A new column is added to the source CSV (e.g., `Partner`). Ingestion must not break for files with the old schema; new columns should be addable via `.alter table` without data loss.
- **ADX cluster unavailable**: During an ADX maintenance window or outage, file delivery continues. Files must queue in the storage account and be ingested when ADX recovers (at-least-once delivery).
- **Runbook against empty database**: The runbook is run against a database with no existing tables or mappings. It must create all required objects from scratch without error.
- **Runbook re-run (idempotency)**: The runbook is run twice in succession. The second run must not fail or duplicate schema objects; table/mapping creation must be idempotent.

---

## Requirements *(mandatory)*

### Functional Requirements

#### Data Model & ADX Schema

- **FR-001**: The system MUST define a `FileTransferEvents` table in ADX with the following columns and types:

  | Column                  | Type       | Purpose                                             |
  |-------------------------|------------|-----------------------------------------------------|
  | Filename                | string     | Name of the transferred file                        |
  | SourcePresent           | bool       | Whether the file exists at the source                |
  | TargetPresent           | bool       | Whether the file exists at the target                |
  | SourceLastModifiedUtc   | datetime   | Last-modified timestamp at the source                |
  | TargetLastModifiedUtc   | datetime   | Last-modified timestamp at the target (nullable)     |
  | AgeMinutes              | real       | Transfer delay in minutes                            |
  | Status                  | string     | Transfer outcome: OK, MISSING, DELAYED, or ERROR     |
  | Notes                   | string     | Human-readable context for the event                 |
  | Timestamp               | datetime   | Primary event time used for all time-based queries   |

- **FR-002**: The `Timestamp` column MUST be derived at ingestion time, not query time. The derivation rule is: use `SourceLastModifiedUtc` as the primary event timestamp; if `SourceLastModifiedUtc` is null, fall back to the ingestion time (`ingestion_time()`). This MUST be implemented via an ADX update policy that transforms rows from a staging table into the `FileTransferEvents` target table with the `Timestamp` column populated. The resulting `Timestamp` column is a concrete, indexed value — no query-time `coalesce()` is required. See FR-037 for staging table mechanics.

- **FR-037**: The system MUST define a `FileTransferEvents_Raw` staging table with the same columns as `FileTransferEvents` except `Timestamp`. An ADX update policy on `FileTransferEvents` MUST transform rows from the staging table by computing `Timestamp` per the derivation rule in FR-002 and inserting completed rows into the target table. Ingestion mappings (FR-006, FR-007) and the Event Grid data connection (FR-008) MUST point to the staging table, not the target table directly. See FR-002 for the Timestamp derivation rule.

- **FR-003**: The system MUST define a `FileTransferEvents_Errors` dead-letter table that captures rows failing ingestion mapping validation. This table uses ADX's ingestion-failure schema (not the `FileTransferEvents` schema):

  | Column       | Type     | Purpose                                            |
  |--------------|----------|----------------------------------------------------||
  | RawData      | string   | Original raw text of the failed row                |
  | Database     | string   | Database name where ingestion was attempted        |
  | Table        | string   | Target table name (`FileTransferEvents_Raw`)       |
  | FailedOn     | datetime | When the failure occurred                          |
  | Error        | string   | Error message describing the failure               |
  | OperationId  | guid     | Correlation ID for the ingestion operation         |

  See data-model.md Entity 3 for DDL and error routing details.

- **FR-004**: ADX retention policy for `FileTransferEvents` MUST be set to 90 days at full resolution in production, and 30 days in non-production environments. A separate long-term aggregated materialized view (daily summaries) SHOULD be retained for 2 years.

- **FR-005**: The dead-letter table `FileTransferEvents_Errors` MUST have a retention policy of 30 days in all environments.

#### Ingestion & ETL

- **FR-006**: The system MUST support CSV ingestion via a defined CSV ingestion mapping (`FileTransferEvents_CsvMapping`) that maps source columns to the table schema and derives the `Timestamp` column.

- **FR-007**: The system MUST support JSON ingestion via a defined JSON ingestion mapping (`FileTransferEvents_JsonMapping`) that maps JSON property names to the table schema and derives the `Timestamp` column.

- **FR-008**: Ingestion MUST be triggered automatically when files land in an Azure Storage account (ADLS Gen2 or Blob Storage) via Event Grid notifications to ADX.

- **FR-009**: Malformed rows that fail type conversion or schema validation during ingestion MUST be routed to the `FileTransferEvents_Errors` table rather than silently dropped.

- **FR-010**: The ingestion pipeline MUST handle files with missing optional columns (e.g., `TargetLastModifiedUtc`, `AgeMinutes` for MISSING-status files) by inserting null/default values without failing the entire file.

#### KQL Query Patterns

- **FR-011**: The system MUST provide a "Recent File Health" KQL query that filters by Grafana's time range macro (`$__timeFilter(Timestamp)`), returns Timestamp, Filename, Status, AgeMinutes, SourcePresent, TargetPresent, and Notes, and sorts by Timestamp descending with a configurable row limit (default 500).

- **FR-012**: The system MUST provide an "SLA & Delay Metrics" KQL query that uses `bin(Timestamp, $__interval)` and `summarize` to compute `avg(AgeMinutes)` and `percentile(AgeMinutes, 95)` per time bucket, with optional breakdown by Status.

- **FR-013**: The system MUST provide a "Missing/Failed Files Count" KQL query that uses `bin(Timestamp, $__interval)` and `summarize` with `countif()` to return `MissingCount` and `ErrorCount` per time bucket, filtered to anomalous statuses (`MISSING`, `ERROR`) — suitable for both visualization and alerting. A broader breakdown including `OkCount` and `DelayedCount` is available via FR-014 (Volume KPIs) and the DailySummary materialized view.

- **FR-014**: The system MUST provide "Volume & Business KPIs" KQL queries that aggregate file counts per day, filterable by partner, system, and environment dimensions where those dimensions exist in the data.

- **FR-015**: All KQL queries MUST include `$__timeFilter(Timestamp)` to enforce time-bounded scans. No query may perform an unbounded full-table scan.

#### Grafana Configuration

- **FR-016**: The ADX data source in Azure Managed Grafana MUST authenticate via managed identity (no stored credentials or secrets).

- **FR-017**: The ADX data source connection MUST specify the cluster URI and database name, and SHOULD set a query timeout aligned with Grafana's configured limits (default: 30 seconds).

- **FR-018**: Each Grafana panel query MUST specify the correct "Format as" setting — Table for tabular panels and Time series for time-series/stat panels — and MUST alias the time column as `time` where required by Grafana conventions.

#### Dashboard & Panels

- **FR-019**: The system MUST provide an "Operator Dashboard" containing at minimum:
  - A "Recent File Transfers" table panel (all statuses, latest N records).
  - A "Current Issues" table panel (MISSING and DELAYED only).
  - A stat panel showing "Files Processed (last 24h)".
  - A stat panel showing "Missing Files (last 24h)".
  - A time-series panel for avg/p95 AgeMinutes over time (SLA & Delay Metrics from US-3).
  - A time-series panel for Missing/OK/Delayed counts over time.

  The SLA & Delay Metrics panels (US-3) are hosted exclusively on the Operator Dashboard. The Business Analytics Dashboard (FR-020) provides a separate, complementary "SLA Adherence %" stat for business reporting.

  > **Implementation note**: The "Current Issues" table is a filtered variant of "Recent File Transfers" (Panel 1 with `Status in ("MISSING", "DELAYED")`). The "Files Processed" and "Missing Files" stat panels use `count()` / `countif()` single-value queries. These are lightweight derived panels that share query patterns with Panel 1 and Panel 3 rather than requiring separate contract queries.

- **FR-020**: The system MUST provide a "Business Analytics Dashboard" containing at minimum:
  - A "Files per Day" bar chart.
  - An "SLA Adherence %" stat panel (percentage of files with Status = OK).
  - A "Volume by Partner/Environment" table or bar chart (when dimensions are available).

- **FR-021**: All dashboards MUST support Grafana template variables for: time range (built-in), Environment, and optionally Partner and System — so that users can filter without editing queries. The Environment variable MUST be derived from the ADX database name (e.g., the Grafana data source pointing to `ftevents_prod` implies Environment = `prod`). Since each environment uses a separate ADX database and Grafana data source (per FR-026), the Environment filter is effectively the data source selector rather than a column-level filter.

#### Alerting

- **FR-022**: The system MUST define a Grafana alert rule that fires when the count of MISSING-status files in the last evaluation period exceeds a configurable threshold.

- **FR-023**: Alert notifications MUST include labels for environment, file type, and source system to enable routing to the correct on-call team. Note: the `partner` label required by Constitution Principle V is deferred until the Partner column is added to the schema (see Assumption 4). Alert labels initially include `alert_type`, `severity`, and `environment`.

- **FR-024**: Infrastructure alerts (ADX cluster health, ingestion failures) MUST be kept separate from business/SLA alerts but visible within the same Grafana workspace.

- **FR-029**: The system MUST define a Grafana alert rule that fires when **any** rows appear in the `FileTransferEvents_Errors` dead-letter table within an evaluation window. This alert MUST be classified as an infrastructure alert (separate from business/SLA alerts per FR-024) and MUST include labels for environment and error type.

- **FR-038**: The system MUST define a Grafana alert rule that fires when the count of DELAYED-status files in the last evaluation period exceeds a configurable threshold (default: 5). This addresses Constitution Principle V's requirement for alerts on "late files exceeding SLA thresholds." Alert labels MUST include `alert_type` (`business`), `severity` (`warning`), and `environment`. See contracts/alert-queries.kql Alert 3.

  > **Volume anomaly alert deferral (Constitution Principle V)**: Principle V also requires alerts for "abnormal volume patterns (spikes or drops)." This is explicitly deferred from v1: anomaly detection requires historical baseline computation (e.g., current volume vs. 7-day rolling average) which is non-trivial at <1,000 events/day where natural variance is high. The `DailySummary` materialized view (FR-036) provides the foundation; a volume anomaly alert will be added as a follow-up by comparing daily counts against a rolling baseline. This is an explicit constitutional exception, not a silent omission.

#### Infrastructure & Governance

- **FR-025**: All infrastructure (ADX cluster/database, Managed Grafana, storage accounts, networking, identity/RBAC) MUST be defined in Bicep and version-controlled in this repository. Bicep is chosen for its Azure-native alignment, first-class ARM integration, and zero state-file management overhead.

- **FR-026**: Environments (dev, test, prod) MUST be fully isolated: separate ADX databases, separate Grafana data sources, separate storage accounts. Production and non-production data MUST NOT be mixed.

- **FR-027**: KQL queries, ADX schema commands (`.create table`, `.create ingestion mapping`), and Grafana dashboard JSON MUST be version-controlled artifacts in this repository.

- **FR-028**: All changes to schema, ingestion mappings, KQL queries, or dashboards MUST be submitted via pull request with at least one peer review.

#### Tooling & Python Runbook

- **FR-030**: The repository MUST include a Python runbook script that uses the official Azure Data Explorer Python libraries (`azure-kusto-data` for queries and management commands, `azure-kusto-ingest` for ingestion).

- **FR-031**: The runbook MUST accept the following configuration parameters (via CLI arguments, environment variables, or a combination):

  | Parameter       | Required | Purpose                                                    |
  |-----------------|----------|------------------------------------------------------------|
  | Cluster URI     | Yes      | ADX cluster endpoint (e.g., `https://<cluster>.<region>.kusto.windows.net`) |
  | Ingest URI      | Yes      | ADX ingestion endpoint (e.g., `https://ingest-<cluster>.<region>.kusto.windows.net`). Always required — the runbook uses queued ingestion for both local and blob sources. |
  | Database name   | Yes      | Target ADX database                                        |
  | Table name      | No       | Defaults to `FileTransferEvents`                           |
  | Mapping name    | No       | Defaults to `FileTransferEvents_CsvMapping` or `_JsonMapping` based on file type |
  | File path / URL | Yes      | Local file path or Azure Blob Storage URL to ingest        |
  | Auth method     | No       | `interactive` (default), `managed-identity`, or `service-principal` |

- **FR-032**: The runbook MUST support the following operations, executable individually via sub-commands or as a single end-to-end flow:
  1. **Authenticate** to ADX using the configured auth method.
  2. **Create tables** — Create the staging table (`FileTransferEvents_Raw` per FR-037) and the target table (`FileTransferEvents` per FR-001) if they do not exist. Creation MUST be idempotent (`.create-merge table`).
  3. **Create update policy** — Create the ADX update policy on `FileTransferEvents` that transforms rows from the staging table by computing `Timestamp` per FR-002. Creation MUST be idempotent.
  4. **Create mappings** — Create CSV and JSON ingestion mappings on the staging table if they do not exist, matching FR-006 and FR-007. Creation MUST be idempotent.
  5. **Ingest file** — Ingest a sample CSV or JSON file from a local path or Azure Storage blob URL into the **staging table** (`FileTransferEvents_Raw`) using the appropriate mapping. Ingestion MUST use queued ingestion (`QueuedIngestClient`) for both local files and blob URLs, matching the same queued ingestion path used by the production Event Grid pipeline. Local files are uploaded to a transient blob by the SDK before queuing. The update policy then moves rows into the target table with `Timestamp` populated.
  6. **Verify** — Run a KQL query against the target `FileTransferEvents` table that retrieves the most recently ingested rows, confirms column names and types match the production schema (including a non-null `Timestamp`), and prints results to stdout.

- **FR-033**: The runbook MUST support interactive browser-based login (Azure CLI device-code flow or `InteractiveBrowserCredential`) as the default auth method for local developer use. It MUST also accept `managed-identity` and `service-principal` auth methods via a parameter switch, so that the same script can be reused in CI/CD or automation contexts without code changes.

- **FR-034**: The full ADX object chain created by the runbook — staging table (`FileTransferEvents_Raw`), update policy, target table (`FileTransferEvents`), and ingestion mappings — MUST be identical to those used by the production Event Grid ingestion pipeline (FR-001, FR-002, FR-006, FR-007, FR-037). Data ingested via the runbook MUST flow through the staging table and update policy, producing rows in the target table that are indistinguishable from data ingested via the automated pipeline.

- **FR-035**: The runbook MUST include inline usage documentation (e.g., `--help` output) and a companion README section covering:
  - Python version requirement (3.9+).
  - Required pip packages (`azure-kusto-data`, `azure-kusto-ingest`, `azure-identity`).
  - Configuration instructions for each auth method.
  - Example invocations for CSV ingestion, JSON ingestion, and verification-only mode.

#### Materialized Views

- **FR-036**: The system MUST define a `DailySummary` materialized view over `FileTransferEvents` that aggregates to one row per calendar day (UTC) with the following columns:

  | Column            | Type     | Derivation                                           |
  |-------------------|----------|------------------------------------------------------|
  | Date              | datetime | `startofday(Timestamp)`                              |
  | TotalCount        | long     | `count()`                                            |
  | OkCount           | long     | `countif(Status == "OK")`                           |
  | MissingCount      | long     | `countif(Status == "MISSING")`                     |
  | DelayedCount      | long     | `countif(Status == "DELAYED")`                     |
  | AvgAgeMinutes     | real     | `avg(AgeMinutes)`                                    |
  | AgeDigest         | dynamic  | `tdigest(AgeMinutes)`                                |

  > **Note**: `percentile()` and `round()` are not supported in ADX materialized view aggregations. P95AgeMinutes and SlaAdherencePct are computed at query time — P95 via `percentile_tdigest(AgeDigest, 95)` and SLA% via `round(100.0 * OkCount / TotalCount, 2)`. See data-model.md Entity 4 for details.

  The materialized view MUST have a retention policy of 730 days (2 years) as specified in FR-004.

### Key Entities

- **FileTransferEvent**: A single record representing the health status of one file at one point in time. Key attributes: Filename, SourcePresent, TargetPresent, SourceLastModifiedUtc, TargetLastModifiedUtc, AgeMinutes, Status, Notes, Timestamp. This is an append-only, immutable event.

- **FileTransferError**: A failed ingestion record using ADX's ingestion-failure schema: RawData (original raw text), Database, Table, FailedOn (datetime), Error (failure reason), OperationId (guid). Not a superset of FileTransferEvent — uses system columns. See FR-003 and data-model.md Entity 3. Used for debugging and operational triage.

- **DailySummary** (materialized view): An aggregated daily roll-up of FileTransferEvents — one row per calendar day (UTC). Columns: Date, TotalCount, OkCount, MissingCount, DelayedCount, AvgAgeMinutes, AgeDigest (dynamic — t-digest sketch; P95 resolved at query time via `percentile_tdigest()`). SlaAdherencePct is computed at query time via `round(100.0 * OkCount / TotalCount, 2)` (not stored — `round()` is unsupported in MV aggregations). Retained for 2 years (730 days). Used for long-term business reporting beyond the 90-day retention of raw events. Defined in FR-036.

---

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: File-transfer records are queryable in ADX within 5 minutes of the source file landing in the ingestion storage account.
- **SC-002**: All operator dashboard panels load within 3 seconds for a 24-hour time range with up to 1 000 events.
- **SC-003**: All business dashboard panels load within 5 seconds for a 30-day time range.
- **SC-004**: No KQL query returns more than 1 000 rows to a Grafana panel; aggregation is performed server-side.
- **SC-005**: Alerts for MISSING files fire within 10 minutes of the condition being met (one alert evaluation cycle + ingestion latency).
- **SC-006**: 100% of file-transfer events with valid schemas are ingested without data loss; malformed rows are captured in the dead-letter table.
- **SC-007**: Operators can identify a missing or delayed file and its metadata within 30 seconds of opening the dashboard.
- **SC-008**: Business users can produce an SLA adherence report for any 30-day period using dashboard filters alone, without writing KQL.
- **SC-009**: A new environment (dev/test/prod) can be provisioned from Bicep templates in under 30 minutes with no manual configuration steps beyond parameter input.
- **SC-010**: All schema, query, and dashboard artifacts are version-controlled; no production change bypasses the PR review process.
- **SC-011**: A developer can run the Python runbook end-to-end (authenticate, create table/mappings, ingest a sample file, and verify results) in under 5 minutes on a workstation with Python and the required packages pre-installed.

---

## Assumptions

- **Timestamp semantics**: `Timestamp` = `SourceLastModifiedUtc` (with fallback to ingestion time if null). Derived at ingestion time via an ADX update policy on a staging table (`FileTransferEvents_Raw` → `FileTransferEvents`). This aligns with the constitution's requirement for a single, explicit event timestamp and keeps all downstream queries and materialized views operating on a concrete, indexed column.
- **SLA threshold**: The default SLA for file transfers is assumed to be 15 minutes (AgeMinutes ≤ 15 = within SLA). This is a configurable parameter, not hard-coded.
- **Status values**: The system assumes three primary status values — `OK`, `MISSING`, `DELAYED` — plus an optional `ERROR` for ingestion-time failures. Additional statuses may be added via schema evolution.
- **Partner/System/Environment dimensions**: The initial schema does not include Partner, System, or Environment columns. Environment is derived from the ADX database name (each environment has its own database per FR-026), so no `Environment` column is needed in the table schema. Partner and System columns can be added later via `.alter table` and updated ingestion mappings as a non-breaking change. Dashboard variables are designed to support Partner and System dimensions when present.
- **Ingestion trigger**: Event Grid + ADX native ingestion (data connection) is assumed as the default pattern. Alternative patterns (e.g., Azure Data Factory, Logic Apps) are out of scope for this spec.
- **Alert routing**: The spec assumes Grafana-native alerting with contact point configuration (e.g., email, Teams, PagerDuty). Specific contact point setup is outside this spec's scope.
- **Authentication**: All Grafana-to-ADX connectivity uses Azure Managed Identity. No service principal secrets or API keys are used.
- **Daily volume**: Under 1,000 file-transfer events per day in production (small, single-system monitoring). This informs ADX SKU sizing (Dev/Test SKU sufficient initially), ingestion batching defaults, and confirms that the 1,000-row Grafana panel limit is comfortable for raw table views within a 24-hour window.
- **Retention**: 90 days full-resolution in production, 30 days in non-production, 2 years for daily aggregated summaries. These can be adjusted per organizational policy.
- **Python runbook scope**: The runbook is a developer/ops utility for manual setup and ad-hoc testing. It is not part of the production ingestion pipeline (which uses Event Grid + ADX native data connections). The runbook shares the same table schema and mappings as production to ensure parity.
- **Python version**: The runbook targets Python 3.9+ for compatibility with current `azure-kusto-data` and `azure-kusto-ingest` SDK versions. No other runtime dependencies beyond standard pip packages are assumed.
