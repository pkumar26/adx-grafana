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

### User Story 3 — SLA and delay metrics dashboard (Priority: P3)

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

### Edge Cases

- **Empty file**: A CSV/JSON file with headers but zero data rows lands in the ingestion path. The system must not error; it should complete ingestion with zero rows added.
- **Duplicate file delivery**: The same file is delivered twice. ADX append-only semantics mean both copies are ingested. No deduplication logic is required at ingestion or query time — duplicate rows are accepted. At <1,000 events/day, the volume impact is negligible and the simplicity benefit outweighs the risk of inflated counts.
- **Extremely large file**: A file with 100 000+ rows lands at once. Batched ingestion must handle it without timeouts or memory issues.
- **Clock skew / future timestamps**: A record arrives with `SourceLastModifiedUtc` in the future. The system should ingest it but the anomaly should be visible in queries (e.g., negative AgeMinutes).
- **Null TargetLastModifiedUtc for MISSING files**: By definition, MISSING files have no target timestamp. The schema must accommodate nullable datetime, and queries must handle this gracefully (no divide-by-zero, no null-propagation errors).
- **Schema evolution**: A new column is added to the source CSV (e.g., `Partner`). Ingestion must not break for files with the old schema; new columns should be addable via `.alter table` without data loss.
- **ADX cluster unavailable**: During an ADX maintenance window or outage, file delivery continues. Files must queue in the storage account and be ingested when ADX recovers (at-least-once delivery).

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

- **FR-002**: The `Timestamp` column MUST be derived as follows: use `SourceLastModifiedUtc` as the primary event timestamp. If `SourceLastModifiedUtc` is null, fall back to the ingestion time (`ingestion_time()`).

- **FR-003**: The system MUST define a `FileTransferEvents_Errors` dead-letter table with the same columns as `FileTransferEvents` plus an `Error` (string) column and a `RawPayload` (string) column containing the original unparsed row.

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

- **FR-013**: The system MUST provide a "Missing/Failed Files Count" KQL query that uses `bin(Timestamp, $__interval)` and `summarize` with `countif()` to return `MissingCount`, `OkCount`, and `DelayedCount` per time bucket — suitable for both visualization and alerting.

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
  - A time-series panel for avg/p95 AgeMinutes over time.
  - A time-series panel for Missing/OK/Delayed counts over time.

- **FR-020**: The system MUST provide a "Business Analytics Dashboard" containing at minimum:
  - A "Files per Day" bar chart.
  - An "SLA Adherence %" stat panel (percentage of files with Status = OK).
  - A "Volume by Partner/Environment" table or bar chart (when dimensions are available).

- **FR-021**: All dashboards MUST support Grafana template variables for: time range (built-in), Environment, and optionally Partner and System — so that users can filter without editing queries. The Environment variable MUST be derived from the ADX database name (e.g., the Grafana data source pointing to `ftevents_prod` implies Environment = `prod`). Since each environment uses a separate ADX database and Grafana data source (per FR-026), the Environment filter is effectively the data source selector rather than a column-level filter.

#### Alerting

- **FR-022**: The system MUST define a Grafana alert rule that fires when the count of MISSING-status files in the last evaluation period exceeds a configurable threshold.

- **FR-023**: Alert notifications MUST include labels for environment, file type, and source system to enable routing to the correct on-call team.

- **FR-024**: Infrastructure alerts (ADX cluster health, ingestion failures) MUST be kept separate from business/SLA alerts but visible within the same Grafana workspace.

- **FR-029**: The system MUST define a Grafana alert rule that fires when **any** rows appear in the `FileTransferEvents_Errors` dead-letter table within an evaluation window. This alert MUST be classified as an infrastructure alert (separate from business/SLA alerts per FR-024) and MUST include labels for environment and error type.

#### Infrastructure & Governance

- **FR-025**: All infrastructure (ADX cluster/database, Managed Grafana, storage accounts, networking, identity/RBAC) MUST be defined in Bicep and version-controlled in this repository. Bicep is chosen for its Azure-native alignment, first-class ARM integration, and zero state-file management overhead.

- **FR-026**: Environments (dev, test, prod) MUST be fully isolated: separate ADX databases, separate Grafana data sources, separate storage accounts. Production and non-production data MUST NOT be mixed.

- **FR-027**: KQL queries, ADX schema commands (`.create table`, `.create ingestion mapping`), and Grafana dashboard JSON MUST be version-controlled artifacts in this repository.

- **FR-028**: All changes to schema, ingestion mappings, KQL queries, or dashboards MUST be submitted via pull request with at least one peer review.

### Key Entities

- **FileTransferEvent**: A single record representing the health status of one file at one point in time. Key attributes: Filename, SourcePresent, TargetPresent, SourceLastModifiedUtc, TargetLastModifiedUtc, AgeMinutes, Status, Notes, Timestamp. This is an append-only, immutable event.

- **FileTransferError**: A failed ingestion record. Same attributes as FileTransferEvent plus Error (reason for failure) and RawPayload (original unparsed content). Used for debugging and operational triage.

- **DailySummary** (materialized view): An aggregated daily roll-up of FileTransferEvents — counts by status, average/p95 AgeMinutes, SLA adherence percentage. Used for long-term business reporting beyond the 90-day retention of raw events.

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

---

## Assumptions

- **Timestamp semantics**: `Timestamp` = `SourceLastModifiedUtc` (with fallback to ingestion time if null). This aligns with the constitution's requirement for a single, explicit event timestamp.
- **SLA threshold**: The default SLA for file transfers is assumed to be 15 minutes (AgeMinutes ≤ 15 = within SLA). This is a configurable parameter, not hard-coded.
- **Status values**: The system assumes three primary status values — `OK`, `MISSING`, `DELAYED` — plus an optional `ERROR` for ingestion-time failures. Additional statuses may be added via schema evolution.
- **Partner/System/Environment dimensions**: The initial schema does not include Partner, System, or Environment columns. Environment is derived from the ADX database name (each environment has its own database per FR-026), so no `Environment` column is needed in the table schema. Partner and System columns can be added later via `.alter table` and updated ingestion mappings as a non-breaking change. Dashboard variables are designed to support Partner and System dimensions when present.
- **Ingestion trigger**: Event Grid + ADX native ingestion (data connection) is assumed as the default pattern. Alternative patterns (e.g., Azure Data Factory, Logic Apps) are out of scope for this spec.
- **Alert routing**: The spec assumes Grafana-native alerting with contact point configuration (e.g., email, Teams, PagerDuty). Specific contact point setup is outside this spec's scope.
- **Authentication**: All Grafana-to-ADX connectivity uses Azure Managed Identity. No service principal secrets or API keys are used.
- **Daily volume**: Under 1,000 file-transfer events per day in production (small, single-system monitoring). This informs ADX SKU sizing (Dev/Test SKU sufficient initially), ingestion batching defaults, and confirms that the 1,000-row Grafana panel limit is comfortable for raw table views within a 24-hour window.
- **Retention**: 90 days full-resolution in production, 30 days in non-production, 2 years for daily aggregated summaries. These can be adjusted per organizational policy.
