# Tasks: ADX File-Transfer Analytics

**Input**: Design documents from `/specs/001-adx-file-transfer-analytics/`  
**Prerequisites**: plan.md ✅, spec.md ✅, research.md ✅, data-model.md ✅, contracts/ ✅, quickstart.md ✅

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story this task belongs to (e.g., [US1], [US2])
- Tasks without a story label are shared infrastructure (Setup/Foundational/Polish)

---

## Phase 1: Setup

**Purpose**: Create project directory structure and shared configuration

- [ ] T001 Create project directory structure per plan.md: `infra/modules/`, `infra/parameters/`, `kql/schema/`, `kql/queries/`, `dashboards/`, `runbook/`, `samples/`
- [ ] T002 [P] Create .gitignore with patterns for Python (__pycache__, *.pyc, .venv/), Bicep ARM outputs (infra/**/*.generated.json), IDE files (.vscode/, .idea/), and OS files (.DS_Store). Note: do NOT exclude dashboards/*.json — those are version-controlled artifacts.

---

## Phase 2: User Story 1 — Ingest file-transfer health data into ADX (Priority: P1) 🎯 MVP

**Goal**: Define the complete ADX schema (tables, mappings, policies, materialized view) and sample test data so that CSV/JSON files can be ingested into the staging table, transformed via the update policy into the target table with a derived `Timestamp`, and aggregated via the `DailySummary` materialized view.

**Independent Test**: Apply all KQL schema commands (steps 1–13 from data-model.md) against a dev ADX database. Upload `samples/sample-events.csv` to the staging table. Verify rows appear in `FileTransferEvents` with correct types and a non-null `Timestamp` column. Verify `DailySummary` materialized view produces aggregated rows.

### Implementation for User Story 1

- [ ] T003 [P] [US1] Create ADX table DDL for staging table (`FileTransferEvents_Raw`), target table (`FileTransferEvents`), and dead-letter table (`FileTransferEvents_Errors`) in kql/schema/tables.kql per data-model.md Steps 1–3
- [ ] T004 [P] [US1] Create CSV ingestion mapping (`FileTransferEvents_CsvMapping`) and JSON ingestion mapping (`FileTransferEvents_JsonMapping`) on the staging table in kql/schema/mappings.kql per data-model.md Steps 6–7
- [ ] T005 [P] [US1] Create transformation function (`FileTransferEvents_Transform`), update policy (including error routing to `FileTransferEvents_Errors` per FR-009), retention policies (90d target, 1d staging, 30d errors), and ingestion batching policy (1 min) in kql/schema/policies.kql per data-model.md Steps 4–5, 8–11
- [ ] T006 [P] [US1] Create `DailySummary` materialized view DDL with `tdigest(AgeMinutes)` for P95 and 730-day retention policy in kql/schema/materialized-views.kql per data-model.md Steps 12–13
- [ ] T007 [P] [US1] Create sample CSV test data with 8–10 rows covering all statuses (OK, MISSING, DELAYED, ERROR), nullable fields, and edge cases in samples/sample-events.csv
- [ ] T008 [P] [US1] Create sample JSON test data matching the same rows as sample-events.csv in samples/sample-events.json

**Checkpoint**: All KQL schema files are complete. Applying them to an ADX database + ingesting sample data yields rows in `FileTransferEvents` with derived `Timestamp` and aggregated rows in `DailySummary`. US1 is independently testable.

> **Note**: US1 validates schema via manual `.ingest` commands or the Python runbook (US7). End-to-end pipeline validation with Event Grid auto-ingestion (FR-008) requires the IaC deployment from US6 (T022).

---

## Phase 3: User Story 2 — Operator dashboard for file-transfer health (Priority: P2)

**Goal**: Create KQL panel queries and a Grafana dashboard JSON for operators to view recent file transfers, current issues, and summary statistics at a glance.

**Independent Test**: Import `dashboards/operator-dashboard.json` into Grafana, select a 1-hour range. Verify: "Recent File Transfers" table shows latest records, stat panels show counts, Missing/Failed time-series renders. All panels load within 3 seconds.

### Implementation for User Story 2

- [ ] T009 [P] [US2] Create Recent File Health KQL query with `$__timeFilter(Timestamp)`, `arg_max(Timestamp, *)` by Filename, sorted by Status/Filename in kql/queries/recent-file-health.kql per contracts/grafana-queries.kql Panel 1
- [ ] T010 [P] [US2] Create Missing/Failed Files Count KQL query with `$__timeFilter(Timestamp)`, `countif()` for MISSING/ERROR by `bin(Timestamp, $__interval)` in kql/queries/missing-failed-counts.kql per contracts/grafana-queries.kql Panel 3
- [ ] T011 [US2] Create Operator Dashboard Grafana JSON with: "Recent File Transfers" table panel, "Current Issues" table (MISSING/DELAYED filter), "Files Processed" stat, "Missing Files" stat, "Missing/Failed Counts" time-series panel, and Grafana template variables in dashboards/operator-dashboard.json per FR-019, FR-021

**Checkpoint**: Operator Dashboard displays table panels, stat panels, and missing/failed counts time-series. SLA panels are added in US3.

---

## Phase 4: User Story 3 — SLA and delay metrics (Priority: P3)

**Goal**: Add SLA/delay trend time-series panels to the Operator Dashboard showing avg and P95 AgeMinutes over time with adaptive binning.

**Independent Test**: Open the Operator Dashboard with a 24-hour range. Verify the SLA & Delay Metrics time-series shows avg and P95 AgeMinutes series, aggregation bins adapt to the selected range, and data stays under 1,000 rows per panel.

### Implementation for User Story 3

- [ ] T012 [P] [US3] Create SLA & Delay Metrics KQL query with `avg(AgeMinutes)`, `percentile(AgeMinutes, 95)` by `bin(Timestamp, $__interval)` and optional Status breakdown in kql/queries/sla-delay-metrics.kql per contracts/grafana-queries.kql Panel 2
- [ ] T013 [US3] Add SLA & Delay Metrics time-series panel and SLA Adherence Rate stat panel to Operator Dashboard in dashboards/operator-dashboard.json per FR-019, contracts/grafana-queries.kql Panel 4

**Checkpoint**: Operator Dashboard is now complete with all FR-019 panels: tables, stats, counts, and SLA trends.

---

## Phase 5: User Story 4 — Missing/failed files alerting (Priority: P4)

**Goal**: Define KQL alert queries and Grafana alert rules for MISSING file threshold alerts, DELAYED file threshold alerts, and dead-letter (ingestion error) alerts with proper label-based routing.

**Independent Test**: Ingest >3 MISSING-status records. Verify the alert query returns `MissingCount > 3`. Ingest >5 DELAYED-status records. Verify the DELAYED alert query returns `DelayedCount > 5`. Upload a malformed CSV. Verify the dead-letter alert query returns `ErrorCount > 0`. Confirm labels include `alert_type`, `severity`, `environment`.

### Implementation for User Story 4

- [ ] T014 [P] [US4] Create Missing Files alert KQL query with 1-hour lookback and `countif(Status == "MISSING")` in kql/queries/alert-missing-files.kql per contracts/alert-queries.kql Alert 1
- [ ] T015 [P] [US4] Create Dead-Letter alert KQL query with 10-minute lookback and `count()` on `FileTransferEvents_Errors` in kql/queries/alert-dead-letter.kql per contracts/alert-queries.kql Alert 2
- [ ] T036 [P] [US4] Create Delayed Files alert KQL query with 1-hour lookback and `countif(Status == "DELAYED")` in kql/queries/alert-delayed-files.kql per contracts/alert-queries.kql Alert 3, FR-038
- [ ] T016 [US4] Add Grafana alert rule definitions (5-min evaluation, threshold conditions, `alert_type`/`severity`/`environment` labels) and Ingestion Errors table panel to Operator Dashboard in dashboards/operator-dashboard.json per FR-022, FR-023, FR-024, FR-029, FR-038, contracts/grafana-queries.kql Panel 5

**Checkpoint**: Alert queries are defined and labeled. Grafana alert rules fire on MISSING threshold, DELAYED threshold (FR-038), and dead-letter conditions. Operator Dashboard includes ingestion errors panel.

---

## Phase 6: User Story 5 — Business analytics dashboard (Priority: P5)

**Goal**: Create a Business Analytics Dashboard with daily volume charts, SLA adherence trend, and P95 age trend — all backed by the `DailySummary` materialized view for long-term reporting over 30–730 day ranges.

**Independent Test**: Import `dashboards/business-dashboard.json` into Grafana, select a 30-day range. Verify: "Files per Day" bar chart renders, "SLA Adherence %" stat shows a percentage, daily trends use `materialized_view("DailySummary")` with `percentile_tdigest()` for P95. All panels load within 5 seconds.

### Implementation for User Story 5

- [ ] T017 [P] [US5] Create Volume & Business KPIs KQL query using `materialized_view("DailySummary")` with `$__timeFilter(Date)` for daily totals, SLA trend, and P95 age trend (via `percentile_tdigest(AgeDigest, 95)`) in kql/queries/volume-business-kpis.kql per contracts/grafana-queries.kql Panels 6–9
- [ ] T018 [US5] Create Business Analytics Dashboard Grafana JSON with: "Files per Day" bar chart, "SLA Adherence %" stat, "Daily SLA Trend" time-series, "Daily P95 Age Trend" time-series, "Average Age Trend" time-series, and Grafana template variables in dashboards/business-dashboard.json per FR-020, FR-021

**Checkpoint**: Business Analytics Dashboard provides daily aggregated views over 30–730 day ranges using the materialized view. US5 is independently testable.

---

## Phase 7: User Story 6 — Infrastructure provisioning via IaC (Priority: P6)

**Goal**: Define all Azure infrastructure in modular Bicep templates — ADX cluster/database, Managed Grafana, Storage account, Event Grid data connection, managed identity RBAC, and Private Link networking — parameterized per environment (dev/test/prod).

**Independent Test**: Run `az deployment group what-if` with dev parameters. Verify all resources would be created. Deploy to a dev resource group. Verify ADX cluster, database, Grafana, Storage, Event Grid data connection, RBAC, and networking are provisioned. Confirm Grafana can query ADX via managed identity.

### Implementation for User Story 6

- [ ] T019 [P] [US6] Create ADX cluster + database Bicep module with Dev/Test SKU, retention parameters, and system-assigned identity in infra/modules/adx-cluster.bicep per research.md Topic 4
- [ ] T020 [P] [US6] Create Managed Grafana Bicep module with system-assigned identity and configurable public access in infra/modules/grafana.bicep per research.md Topic 4
- [ ] T021 [P] [US6] Create Storage account Bicep module with ADLS Gen2, `file-transfer-events` container, and blob lifecycle in infra/modules/storage.bicep per research.md Topic 4
- [ ] T022 [P] [US6] Create Event Grid data connection Bicep module targeting staging table with CSV/JSON format support and blob path filtering in infra/modules/event-grid.bicep per research.md Topic 4
- [ ] T023 [P] [US6] Create identity and RBAC Bicep module with Grafana→ADX Viewer, ADX→Storage Blob Reader, and Event Grid role assignments in infra/modules/identity.bicep per research.md Topic 4
- [ ] T024 [P] [US6] Create networking Bicep module with ADX and Grafana managed private endpoints and configurable public access toggle in infra/modules/networking.bicep per research.md Topic 4
- [ ] T025 [US6] Create main orchestrator Bicep that composes all modules with shared parameters (location, environment, naming) in infra/main.bicep
- [ ] T026 [P] [US6] Create dev environment parameters with Dev/Test SKU, 30d retention, public access enabled in infra/parameters/dev.bicepparam per research.md Topic 4
- [ ] T027 [P] [US6] Create test environment parameters with Dev/Test SKU, 30d retention, private endpoints enabled in infra/parameters/test.bicepparam
- [ ] T028 [P] [US6] Create prod environment parameters with Standard SKU, 90d retention, private endpoints enabled, public access disabled in infra/parameters/prod.bicepparam

**Checkpoint**: Full IaC stack deployable via `az deployment group create --parameters infra/parameters/dev.bicepparam`. All resources provisioned with correct RBAC and networking.

---

## Phase 8: User Story 7 — Python runbook for manual setup and testing (Priority: P7)

**Goal**: Provide a Python CLI script that creates the full ADX object chain (staging table, update policy, target table, mappings), ingests local or blob CSV/JSON via `QueuedIngestClient`, and runs verification queries — enabling developer-driven setup and testing with production-parity schema.

**Independent Test**: Install Python packages. Run `python adx_runbook.py setup --cluster <URI> --database <DB>`. Verify tables and mappings created. Run `python adx_runbook.py ingest-local --file ../samples/sample-events.csv`. Verify data in `FileTransferEvents`. Complete end-to-end in <5 minutes.

### Implementation for User Story 7

- [ ] T029 [P] [US7] Create Python dependencies file with azure-kusto-data, azure-kusto-ingest, azure-identity in runbook/requirements.txt
- [ ] T030 [US7] Implement Python runbook CLI with subcommands (setup, ingest-local, ingest-blob, verify), auth methods (interactive/managed-identity/service-principal), QueuedIngestClient ingestion to staging table, and `--help` documentation in runbook/adx_runbook.py per FR-030 through FR-034
- [ ] T031 [US7] Create runbook README with Python version requirement, pip install instructions, auth method configuration, and example invocations for CSV/JSON/verify-only in runbook/README.md per FR-035

**Checkpoint**: Runbook creates full ADX object chain, ingests sample data via queued ingestion through staging table, and verifies results — all matching production Event Grid pipeline parity (FR-034). End-to-end <5 min (SC-011).

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Documentation, validation, and cross-cutting improvements

- [ ] T032 [P] Create project-level README.md at repository root with architecture overview, directory layout, setup instructions, and links to quickstart.md
- [ ] T033 [P] Validate all KQL schema files in kql/schema/ match contracts/adx-schema.kql DDL exactly (tables, mappings, policies, materialized view)
- [ ] T035 Configure Grafana ADX data source (cluster URI, database name, managed identity auth per FR-016/FR-017) — document as a quickstart.md step or automate via Grafana provisioning API in dashboards/. **Note**: This is a prerequisite for testing any dashboard panel (US2–US5). Complete before or alongside Phase 3.
- [ ] T034 Run quickstart.md end-to-end validation: deploy infra, apply schema, ingest sample data, verify dashboards load, verify alerts fire per quickstart.md checklist

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **US1 (Phase 2)**: Depends on Setup — defines ALL ADX schema; **BLOCKS all downstream stories**
- **US2 (Phase 3)**: Depends on US1 schema — creates Operator Dashboard
- **US3 (Phase 4)**: Depends on US2 dashboard JSON — adds SLA panels to it
- **US4 (Phase 5)**: Depends on US2 dashboard JSON — adds alert rules and errors panel to it
- **US5 (Phase 6)**: Depends on US1 schema (DailySummary MV) — independent of US2/US3/US4
- **US6 (Phase 7)**: Depends on US1 schema knowledge — independent of US2–US5
- **US7 (Phase 8)**: Depends on US1 schema knowledge — independent of US2–US6
- **Polish (Phase 9)**: Depends on all desired stories being complete

### User Story Dependencies

```text
Setup (Phase 1)
  └── US1 (Phase 2) ← BLOCKS ALL
        ├── US2 (Phase 3)
        │     ├── US3 (Phase 4) ← edits US2 dashboard JSON
        │     └── US4 (Phase 5) ← edits US2 dashboard JSON
        ├── US5 (Phase 6) ← independent (own dashboard)
        ├── US6 (Phase 7) ← independent (Bicep IaC)
        └── US7 (Phase 8) ← independent (Python runbook)
              └── Polish (Phase 9)
```

### Within Each User Story

1. KQL query files before dashboard JSON (queries are embedded in panels)
2. Core panels before supplementary panels
3. Story complete before moving to next priority (unless parallelizing independent stories)

### Parallel Opportunities

**After US1 completes, these stories can run in parallel** (if team capacity allows):
- **US2** + **US5** + **US6** + **US7** (all independent — different file sets)
- US3 and US4 must wait for US2's dashboard JSON to exist

**Within US6 (IaC)**: All 6 Bicep modules (T019–T024) can be developed in parallel before the orchestrator (T025). All 3 parameter files (T026–T028) can be developed in parallel after T025.

---

## Parallel Examples

### After US1 Completes — Maximum Parallelism

```
Developer A: US2 → US3 → US4  (Operator dashboard + SLA panels + alerts)
Developer B: US5              (Business dashboard)
Developer C: US6              (Bicep IaC — all modules in parallel)
Developer D: US7              (Python runbook)
```

### Solo Developer — Sequential Priority Order

```
Setup → US1 (MVP!) → US2 → US3 → US4 → US5 → US6 → US7 → Polish
```

### Within US6 (IaC) — Module Parallelism

```bash
# All modules in parallel (different files):
T019: infra/modules/adx-cluster.bicep
T020: infra/modules/grafana.bicep
T021: infra/modules/storage.bicep
T022: infra/modules/event-grid.bicep
T023: infra/modules/identity.bicep
T024: infra/modules/networking.bicep

# Then sequentially:
T025: infra/main.bicep (orchestrator — references all modules)

# Then all params in parallel:
T026: infra/parameters/dev.bicepparam
T027: infra/parameters/test.bicepparam
T028: infra/parameters/prod.bicepparam
```

---

## Implementation Strategy

### MVP First (US1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: US1 — ADX schema + sample data
3. **STOP and VALIDATE**: Apply schema to ADX, ingest sample data, verify `FileTransferEvents` and `DailySummary`
4. This is the MVP — data is in ADX and queryable

### Incremental Delivery

1. Setup + US1 → **MVP: Data pipeline works** ✅
2. Add US2 → **Operators can see data** ✅
3. Add US3 → **Operators see SLA trends** ✅
4. Add US4 → **Automated alerting active** ✅
5. Add US5 → **Business reporting available** ✅
6. Add US6 → **Infrastructure reproducible via IaC** ✅
7. Add US7 → **Developer self-service tooling** ✅
8. Polish → **Documentation and validation complete** ✅

Each story adds value without breaking previous stories.

---

## Notes

- No automated tests are generated (not requested in spec). Validation is via quickstart.md manual checklist and SC criteria.
- All KQL schema files use idempotent commands (`.create-merge`, `.create-or-alter`, `.create ifnotexists`) — safe to re-run.
- Dashboard JSON files embed KQL queries inline. Standalone `.kql` query files serve as development references and documentation.
- The `DailySummary` materialized view uses `tdigest()` (not `percentile()` directly) per research.md Topic 5 findings. P95 is resolved at query time via `percentile_tdigest()`.
- US3 and US4 edit the Operator Dashboard JSON created in US2 — these cannot run in parallel with each other but can overlap with US5/US6/US7.
