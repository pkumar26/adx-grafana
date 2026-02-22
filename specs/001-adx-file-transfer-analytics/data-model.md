# Data Model: ADX File-Transfer Analytics

**Branch**: `001-adx-file-transfer-analytics` | **Date**: 2026-02-21  
**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md) | **Research**: [research.md](research.md)

---

## Entity Overview

```text
┌───────────────────────────┐     update policy      ┌───────────────────────────┐
│ FileTransferEvents_Raw    │ ──────────────────────▶ │ FileTransferEvents        │
│ (staging table)           │   coalesce(             │ (target table)            │
│                           │    SourceLastModifiedUtc,│                           │
│ 8 columns (no Timestamp)  │    ingestion_time())    │ 9 columns (+ Timestamp)   │
└───────────────────────────┘                         └──────────┬────────────────┘
                                                                 │
                                                      materialized view
                                                                 │
                                                                 ▼
┌───────────────────────────┐                         ┌───────────────────────────┐
│ FileTransferEvents_Errors │                         │ DailySummary              │
│ (dead-letter table)       │                         │ (materialized view)       │
│                           │                         │                           │
│ Auto-populated by ADX     │                         │ 8 columns (aggregated)    │
│ ingestion error routing   │                         │ 730-day retention         │
└───────────────────────────┘                         └───────────────────────────┘
```

**Data flow**: Blob lands in Storage → Event Grid → ADX data connection → `FileTransferEvents_Raw` → update policy → `FileTransferEvents` → materialized view → `DailySummary`.

---

## Entity 1: FileTransferEvents_Raw (Staging Table)

**Purpose**: Receives raw ingestion from Event Grid data connection. All blobs (CSV/JSON) land here. The update policy on `FileTransferEvents` consumes rows from this table and derives `Timestamp`.

**Retention**: 1 day (staging data is redundant after the update policy processes it).

| Column | Type | Nullable | Source | Description |
|--------|------|----------|--------|-------------|
| Filename | `string` | No | CSV col 0 / `$.Filename` | Logical name of the monitored file (e.g., `partner-a/daily-report.csv`) |
| SourcePresent | `bool` | No | CSV col 1 / `$.SourcePresent` | Whether the file exists at the source location |
| TargetPresent | `bool` | No | CSV col 2 / `$.TargetPresent` | Whether the file exists at the target (destination) location |
| SourceLastModifiedUtc | `datetime` | Yes | CSV col 3 / `$.SourceLastModifiedUtc` | Last-modified timestamp at source; null if source not present |
| TargetLastModifiedUtc | `datetime` | Yes | CSV col 4 / `$.TargetLastModifiedUtc` | Last-modified timestamp at target; null if target not present |
| AgeMinutes | `real` | Yes | CSV col 5 / `$.AgeMinutes` | Difference in minutes between current time and `SourceLastModifiedUtc`; null if source absent |
| Status | `string` | No | CSV col 6 / `$.Status` | Transfer status: `OK`, `MISSING`, `DELAYED`, `ERROR` |
| Notes | `string` | Yes | CSV col 7 / `$.Notes` | Free-text notes (e.g., error details, SLA violation reason) |

**DDL**:
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

**Retention policy**:
```kql
.alter table FileTransferEvents_Raw policy retention
@'{"SoftDeletePeriod": "1.00:00:00", "Recoverability": "Disabled"}'
```

**Ingestion batching policy** (1-minute window for <5 min E2E latency):
```kql
.alter table FileTransferEvents_Raw policy ingestionbatching
@'{"MaximumBatchingTimeSpan": "00:01:00", "MaximumNumberOfItems": 20, "MaximumRawDataSizeMB": 256}'
```

---

## Entity 2: FileTransferEvents (Target Table)

**Purpose**: System of record for file-transfer health events. All dashboard queries, alert rules, and the materialized view read from this table. The `Timestamp` column is derived at ingestion time via the update policy.

**Retention**: 90 days (prod), 30 days (non-prod).

| Column | Type | Nullable | Source | Description |
|--------|------|----------|--------|-------------|
| Filename | `string` | No | Update policy (passthrough) | Logical name of the monitored file |
| SourcePresent | `bool` | No | Update policy (passthrough) | File exists at source |
| TargetPresent | `bool` | No | Update policy (passthrough) | File exists at target |
| SourceLastModifiedUtc | `datetime` | Yes | Update policy (passthrough) | Last-modified at source |
| TargetLastModifiedUtc | `datetime` | Yes | Update policy (passthrough) | Last-modified at target |
| AgeMinutes | `real` | Yes | Update policy (passthrough) | Age in minutes |
| Status | `string` | No | Update policy (passthrough) | `OK` / `MISSING` / `DELAYED` / `ERROR` |
| Notes | `string` | Yes | Update policy (passthrough) | Free-text notes |
| **Timestamp** | `datetime` | **No** | **Update policy (derived)** | `coalesce(SourceLastModifiedUtc, ingestion_time())` — primary time axis for all queries |

**DDL**:
```kql
.create-merge table FileTransferEvents (
    Filename: string,
    SourcePresent: bool,
    TargetPresent: bool,
    SourceLastModifiedUtc: datetime,
    TargetLastModifiedUtc: datetime,
    AgeMinutes: real,
    Status: string,
    Notes: string,
    Timestamp: datetime
)
```

**Retention policy** (prod example):
```kql
.alter table FileTransferEvents policy retention
@'{"SoftDeletePeriod": "90.00:00:00", "Recoverability": "Enabled"}'
```

### Update Policy

**Transformation function**:
```kql
.create-or-alter function FileTransferEvents_Transform() {
    FileTransferEvents_Raw
    | extend Timestamp = coalesce(SourceLastModifiedUtc, ingestion_time())
    | project Filename, SourcePresent, TargetPresent,
              SourceLastModifiedUtc, TargetLastModifiedUtc,
              AgeMinutes, Status, Notes, Timestamp
}
```

**Policy attachment**:
```kql
.alter table FileTransferEvents policy update
@'[{"IsEnabled": true, "Source": "FileTransferEvents_Raw", "Query": "FileTransferEvents_Transform()", "IsTransactional": true, "PropagateIngestionProperties": true}]'
```

- **`IsTransactional: true`** — if transformation fails, the staging extent is also rolled back.
- **`PropagateIngestionProperties: true`** — preserves `ingestion_time()` accuracy from the source extent.

### Validation Rules

| Rule | Implementation | FR |
|------|---------------|----|
| Timestamp is never null | `coalesce()` fallback ensures a value; `ingestion_time()` is always non-null | FR-002 |
| Status is one of 4 values | Validated at source; no ADX-level constraint (ADX has no CHECK constraints). Queries use `Status in ("OK","MISSING","DELAYED","ERROR")` | FR-003 |
| Filename is non-empty | Validated at source; blank filenames would still ingest (ADX accepts empty strings) | FR-001 |

---

## Entity 3: FileTransferEvents_Errors (Dead-Letter Table)

**Purpose**: Captures rows that fail ingestion mapping validation (e.g., malformed CSV, type coercion failures, missing required fields). Automatically populated by ADX when ingestion errors occur.

**Retention**: 30 days (all environments).

| Column | Type | Description |
|--------|------|-------------|
| RawData | `string` | The original raw text of the failed row |
| Database | `string` | Database name where ingestion was attempted |
| Table | `string` | Target table name (always `FileTransferEvents_Raw`) |
| FailedOn | `datetime` | When the failure occurred |
| Error | `string` | Error message describing the failure |
| OperationId | `guid` | Correlation ID for the ingestion operation |

**DDL**:
```kql
.create-merge table FileTransferEvents_Errors (
    RawData: string,
    Database: string,
    ['Table']: string,
    FailedOn: datetime,
    Error: string,
    OperationId: guid
)
```

**Retention policy**:
```kql
.alter table FileTransferEvents_Errors policy retention
@'{"SoftDeletePeriod": "30.00:00:00", "Recoverability": "Disabled"}'
```

**Error routing** — configure the staging table's ingestion error policy to route to this table:
```kql
.alter table FileTransferEvents_Raw policy ingestionfailure
@'{"IsEnabled": true}'
```

> **Note**: ADX does not have a built-in "route errors to table" policy out-of-the-box. The dead-letter pattern is typically implemented by:
> 1. Enabling `IngestionFailures` on the data connection/ingestion command.
> 2. Querying `.show ingestion failures` for diagnostics.
> 3. For persistent dead-letter storage, using a separate queued ingestion with error handling in the Python runbook, or a lightweight Azure Function that monitors `.show ingestion failures` and inserts into the errors table.
>
> For the initial implementation (US-1), the errors table serves as a manual diagnostics target. The dead-letter alert (FR-029) queries `.show ingestion failures` or a dedicated table populated by the runbook's error path.

---

## Entity 4: DailySummary (Materialized View)

**Purpose**: Pre-aggregated daily metrics for the Business Analytics dashboard. Retained for 730 days (2 years) independently of the source table's 90-day retention.

| Column | Type | Description | Aggregation |
|--------|------|-------------|-------------|
| Date | `datetime` | Day boundary (`startofday(Timestamp)`) | Group key |
| TotalCount | `long` | Total events for the day | `count()` |
| OkCount | `long` | Events with Status = "OK" | `countif(Status == "OK")` |
| MissingCount | `long` | Events with Status = "MISSING" | `countif(Status == "MISSING")` |
| DelayedCount | `long` | Events with Status = "DELAYED" | `countif(Status == "DELAYED")` |
| AvgAgeMinutes | `real` | Average `AgeMinutes` for the day | `avg(AgeMinutes)` |
| AgeDigest | `dynamic` | T-digest sketch for percentile computation | `tdigest(AgeMinutes)` |

> **P95AgeMinutes** and **SlaAdherencePct** are not stored as columns. They are computed at query time:
> ```kql
> materialized_view("DailySummary")
> | extend P95AgeMinutes = percentile_tdigest(AgeDigest, 95),
>         SlaAdherencePct = round(100.0 * OkCount / TotalCount, 2)
> | project Date, TotalCount, OkCount, MissingCount, DelayedCount,
>          AvgAgeMinutes, P95AgeMinutes, SlaAdherencePct
> ```
> `percentile()` and `round()` are not supported in materialized view aggregations — `tdigest()` produces the sketch resolved at read time, and `SlaAdherencePct` is derived from the stored `OkCount`/`TotalCount` columns.

**DDL**:
```kql
.create ifnotexists materialized-view DailySummary on table FileTransferEvents {
    FileTransferEvents
    | summarize
        TotalCount      = count(),
        OkCount         = countif(Status == "OK"),
        MissingCount    = countif(Status == "MISSING"),
        DelayedCount    = countif(Status == "DELAYED"),
        AvgAgeMinutes   = avg(AgeMinutes),
        AgeDigest       = tdigest(AgeMinutes)
        // SlaAdherencePct is computed at query time: round(100.0 * OkCount / TotalCount, 2)
    by Date = startofday(Timestamp)
}
```

**Retention policy** (730 days):
```kql
.alter materialized-view DailySummary policy retention
@'{"SoftDeletePeriod": "730.00:00:00", "Recoverability": "Enabled"}'
```

---

## Ingestion Mappings

### CSV Mapping (on staging table)

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

### JSON Mapping (on staging table)

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

---

## DDL Execution Order

For a clean deployment (empty database), execute in this order:

| Step | Command | Target |
|------|---------|--------|
| 1 | `.create-merge table FileTransferEvents (...)` | Target table |
| 2 | `.create-merge table FileTransferEvents_Raw (...)` | Staging table |
| 3 | `.create-merge table FileTransferEvents_Errors (...)` | Dead-letter table |
| 4 | `.create-or-alter function FileTransferEvents_Transform()` | Transformation function |
| 5 | `.alter table FileTransferEvents policy update [...]` | Update policy on target |
| 6 | `.create-or-alter table FileTransferEvents_Raw ingestion csv mapping ...` | CSV mapping |
| 7 | `.create-or-alter table FileTransferEvents_Raw ingestion json mapping ...` | JSON mapping |
| 8 | `.alter table FileTransferEvents policy retention [...]` | Target retention |
| 9 | `.alter table FileTransferEvents_Raw policy retention [...]` | Staging retention (1 day) |
| 10 | `.alter table FileTransferEvents_Errors policy retention [...]` | Dead-letter retention (30 days) |
| 11 | `.alter table FileTransferEvents_Raw policy ingestionbatching [...]` | Batching (1 min) |
| 12 | `.create ifnotexists materialized-view DailySummary on table FileTransferEvents {...}` | Materialized view |
| 13 | `.alter materialized-view DailySummary policy retention [...]` | View retention (730 days) |

---

## State Transitions

The `Status` field represents the assessed state of a file transfer:

```text
            source found,
            age ≤ SLA threshold
  ┌─────────────────────────────┐
  │                             ▼
  │    ┌────────┐          ┌────────┐
  │    │ CHECK  │          │   OK   │
  │    │(input) │          │        │
  │    └───┬────┘          └────────┘
  │        │
  │        │ source found,
  │        │ age > SLA threshold
  │        ├──────────────────┐
  │        │                  ▼
  │        │             ┌─────────┐
  │        │             │ DELAYED │
  │        │             └─────────┘
  │        │
  │        │ source not found
  │        ├──────────────────┐
  │        │                  ▼
  │        │             ┌─────────┐
  │        │             │ MISSING │
  │        │             └─────────┘
  │        │
  │        │ error during check
  │        └──────────────────┐
  │                           ▼
  │                      ┌─────────┐
  │                      │  ERROR  │
  │                      └─────────┘
  │
  └── (assessed per check cycle; each event is a point-in-time snapshot,
       not an evolving state machine — statuses do not "transition" from
       one row to another; each ingested row is an independent observation)
```

> **Important**: File-transfer events are **point-in-time observations**, not state transitions. Each row represents the state of a file at the time of the health check. The same filename may have `MISSING` at 08:00 and `OK` at 09:00 — these are two independent observations, not a transition. ADX's append-only model naturally supports this pattern.
