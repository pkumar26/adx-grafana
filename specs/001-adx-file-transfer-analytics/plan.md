# Implementation Plan: ADX File-Transfer Analytics

**Branch**: `001-adx-file-transfer-analytics` | **Date**: 2026-02-21 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-adx-file-transfer-analytics/spec.md`

## Summary

Ingest CSV/JSON file-transfer health data into Azure Data Explorer (ADX) via Event Grid–triggered native ingestion through a staging table with an update policy that derives the `Timestamp` column at ingestion time. Visualize operational and business metrics in Azure Managed Grafana across two dashboards (Operator and Business Analytics). Provide KQL-based alerting for missing files and ingestion errors, a dead-letter table for malformed rows, a `DailySummary` materialized view retained for 2 years, full IaC provisioning via Bicep, and a Python runbook for developer-driven setup and testing. All connectivity uses managed identities over Private Link; environments are isolated by ADX database and Grafana data source.

## Technical Context

**Language/Version**: KQL (Kusto Query Language) for queries/schema; Bicep for IaC; Python 3.9+ for runbook; JSON for Grafana dashboard definitions  
**Primary Dependencies**: Azure Data Explorer (ADX), Azure Managed Grafana (ADX plugin), Event Grid, Azure Storage (ADLS Gen2 / Blob), Azure Managed Identities (Entra ID), `azure-kusto-data`, `azure-kusto-ingest`, `azure-identity`  
**Storage**: ADX (system of record, append-only time-series), ADLS Gen2/Blob (ingestion landing zone)  
**Testing**: Manual validation (upload sample CSV/JSON → verify ADX rows), KQL test queries, Bicep `what-if` dry-run, Python runbook end-to-end verification (SC-011), Grafana panel load assertions  
**Target Platform**: Azure (all services cloud-hosted; no local runtime except Python runbook)  
**Project Type**: Infrastructure + analytics + developer tooling (IaC templates, ADX schema, KQL queries, Grafana dashboards, Python CLI script — no application server code)  
**Performance Goals**: Dashboard panels load <3 s (operator, 24 h range), <5 s (business, 30 d range); ingestion latency <5 min; runbook end-to-end <5 min  
**Constraints**: <1,000 events/day; ADX Dev/Test SKU; all Grafana queries ≤1,000 result rows; 90-day full-resolution retention (prod), 30 days (non-prod), 730 days daily aggregates; 30 days dead-letter retention  
**Scale/Scope**: Single-system monitoring; 3 environments (dev/test/prod); 2 dashboards; ~6 KQL queries; ~10 Bicep resources; 2 alert rules; 1 Python runbook; 4 ADX tables/views (staging, target, errors, materialized view)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| # | Principle | Status | Evidence |
|---|-----------|--------|----------|
| I | Architecture & Azure Alignment | ✅ PASS | ADX as system of record, Managed Grafana for viz, managed identities + Private Link, all Azure-native services (FR-016, FR-025, FR-026). |
| II | Data Modeling & Ingestion | ✅ PASS | Append-only time-series model, strong types (datetime/bool/real/string), consistent schema across CSV/JSON, Timestamp derived at ingestion time via update policy, explicitly defined (FR-001, FR-002, FR-037). |
| III | Query & Dashboard Design | ✅ PASS | All aggregation via KQL `bin()`+`summarize`, `$__timeFilter` mandatory (FR-015), two audience dashboards (Operator + Business), clarity-first panels (FR-019, FR-020). |
| IV | Reliability, Performance & Limits | ✅ PASS | ≤1,000 result rows enforced (SC-004), <3 s / <5 s load SLOs (SC-002/003), retention policies per env (FR-004/005), Dev/Test SKU sized to volume. |
| V | Observability & Alerting | ✅ PASS | MISSING file alert (FR-022), DELAYED file alert (FR-038), dead-letter alert (FR-029), labels include env/alert_type/severity (FR-023), infra separated from business (FR-024). Volume anomaly alert explicitly deferred with rationale (see FR-038 note). |
| VI | Security, Compliance & Environments | ✅ PASS | Managed identity auth only (FR-016), no secrets in code, env isolation via separate ADX databases + Grafana data sources (FR-026), retention per policy (FR-004). |
| VII | Code Quality & Automation | ✅ PASS | All KQL/dashboard JSON/schema version-controlled (FR-027), PR + peer review required (FR-028), IaC via Bicep in-repo (FR-025). |
| VIII | AI/Agent Usage | ✅ PASS | Agent follows constitution in plan generation, highlights conflicts explicitly, favors readable KQL and documented dashboards. |

**Gate result**: ALL PASS — no violations. Proceeding to Phase 0.

**Post-Phase 1 re-evaluation** (after design artifacts complete):
- All 8 principles re-confirmed PASS.
- `tdigest()` for P95 in materialized view is ADX-native (Principle II).
- 9 panel queries all use `$__timeFilter` and server-side aggregation (Principle III).
- 1-minute batching yields ~2 min E2E latency, well within 5-min SLO (Principle IV).
- 3 alert rules with `alert_type`/`severity`/`environment` labels and routing contract (Principle V). Volume anomaly alert explicitly deferred (see FR-038).
- All RBAC via managed identity `principalAssignments` + `roleAssignments` — no secrets (Principle VI).
- No new violations or complexity added.

## Project Structure

### Documentation (this feature)

```text
specs/001-adx-file-transfer-analytics/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── adx-schema.kql       # Table/mapping/policy DDL
│   ├── grafana-queries.kql   # Panel KQL queries with Grafana macros
│   └── alert-queries.kql     # Alert rule KQL queries
└── tasks.md             # Phase 2 output (/speckit.tasks — NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
infra/
├── main.bicep                    # Orchestrator: deploys all modules
├── modules/
│   ├── adx-cluster.bicep         # ADX cluster + database
│   ├── adx-schema.bicep          # Kusto database script: tables, mappings, policies, views
│   ├── grafana.bicep             # Managed Grafana instance
│   ├── grafana-config.bicep      # Deployment script: ADX data source + dashboard import
│   ├── storage.bicep             # ADLS Gen2 ingestion landing zone
│   ├── event-grid.bicep          # Event Grid subscription → ADX data connection
│   ├── identity.bicep            # RBAC: Grafana→ADX, ADX→Storage, deployer Grafana Admin
│   └── networking.bicep          # Private Link / Managed Private Endpoints
└── parameters/
    ├── dev.bicepparam            # Dev environment parameters
    ├── test.bicepparam           # Test environment parameters
    └── prod.bicepparam           # Prod environment parameters

kql/
├── schema/
│   ├── tables.kql                # .create-merge table commands (staging, target, errors)
│   ├── mappings.kql              # .create-or-alter ingestion mappings (CSV + JSON)
│   ├── policies.kql              # Update policy, retention policies
│   └── materialized-views.kql   # DailySummary materialized view
└── queries/
    ├── recent-file-health.kql    # FR-011
    ├── sla-delay-metrics.kql     # FR-012
    ├── missing-failed-counts.kql # FR-013
    ├── volume-business-kpis.kql  # FR-014
    ├── alert-missing-files.kql   # FR-022
    ├── alert-delayed-files.kql   # FR-038
    └── alert-dead-letter.kql     # FR-029

dashboards/
├── operator-dashboard.json       # FR-019 Grafana dashboard JSON
└── business-dashboard.json       # FR-020 Grafana dashboard JSON

runbook/
├── adx_runbook.py                # FR-030–FR-035 Python CLI script
├── requirements.txt              # azure-kusto-data, azure-kusto-ingest, azure-identity
└── README.md                     # Usage docs, auth methods, examples

samples/
├── sample-events.csv             # Test data matching production schema
└── sample-events.json            # Test data matching production schema
```

**Structure Decision**: Custom infrastructure + analytics layout. No standard app template applies — this project is IaC, KQL schema/queries, Grafana dashboard JSON, and a Python developer utility. Each concern gets a top-level directory: `infra/`, `kql/`, `dashboards/`, `runbook/`, `samples/`.

## Complexity Tracking

> No violations detected — table left empty.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| *(none)* | — | — |
