<!--
  Sync Impact Report
  ==================
  Version change: 0.0.0 → 1.0.0
  Bump rationale: MAJOR — initial constitution creation.

  Modified principles:
    - (new) I. Architecture & Azure Alignment
    - (new) II. Data Modeling & Ingestion
    - (new) III. Query & Dashboard Design
    - (new) IV. Reliability, Performance & Limits
    - (new) V. Observability & Alerting
    - (new) VI. Security, Compliance & Environments
    - (new) VII. Code Quality & Automation
    - (new) VIII. AI/Agent Usage

  Added sections:
    - Core Principles (8 principles)
    - Technology Stack
    - Development Workflow
    - Governance

  Removed sections: (none — initial creation)

  Templates requiring updates:
    - .specify/templates/plan-template.md        ✅ no update needed
      (Constitution Check section is dynamic; populated at plan time)
    - .specify/templates/spec-template.md         ✅ no update needed
      (Generic template; no constitution-specific references)
    - .specify/templates/tasks-template.md        ✅ no update needed
      (Task phases are generic; no outdated principle refs)
    - .specify/templates/checklist-template.md    ✅ no update needed
    - .specify/templates/agent-file-template.md   ✅ no update needed
    - No commands/ directory exists              ✅ N/A

  Follow-up TODOs: none
-->

# ADX-Grafana File-Transfer Analytics Constitution

## Core Principles

### I. Architecture & Azure Alignment

- All services MUST prefer Azure-native offerings: Azure Data Explorer
  (ADX) for time-series analytics, Azure Managed Grafana for
  visualization, and Azure Monitor / Log Analytics for infrastructure
  telemetry.
- ADX MUST be treated as the system of record for file-transfer events,
  optimized for time-based queries and aggregations.
- All data-source connectivity MUST use managed identities with
  least-privilege RBAC and Private Link / Managed Private Endpoints.
  Direct credential sharing is prohibited.

**Rationale**: Consolidating on Azure-native services reduces
operational complexity, leverages built-in security integrations, and
keeps the blast radius within a single control plane.

### II. Data Modeling & Ingestion

- File-transfer events MUST be modeled as append-only, time-series
  records with a single, clearly defined primary event timestamp.
- ADX columns MUST use strong types: `datetime` for all timestamps,
  `bool` for presence flags, numeric (`real`/`int`) for metrics such as
  `AgeMinutes`, and `string` for identifiers and notes.
- CSV and JSON ingestion MUST be normalized to a consistent schema.
  Canonical columns: `Filename`, `SourcePresent`, `TargetPresent`,
  `SourceLastModifiedUtc`, `TargetLastModifiedUtc`, `AgeMinutes`,
  `Status`, `Notes`, `Timestamp`.
- The meaning of `Timestamp` (e.g., source or target last-modified)
  MUST be explicitly defined and kept consistent across all dashboards
  and queries.

**Rationale**: Consistent, strongly typed schemas prevent silent
type-coercion bugs, make KQL queries predictable, and ensure that
dashboards across teams share a single source of truth.

### III. Query & Dashboard Design

- Aggregation MUST be pushed into KQL using `bin()` and `summarize`;
  Grafana panels MUST NOT perform heavy client-side aggregation on raw
  row sets.
- Every Grafana query MUST include a time filter (e.g.,
  `$__timeFilter(Timestamp)`); open-ended scans are prohibited.
- Dashboards MUST serve two audiences:
  - **Operators**: missing/delayed files, SLA breaches, recent
    incidents — actionable at a glance.
  - **Business users**: trends over time, SLA adherence by
    partner/region, transfer volumes per period.
- Visualizations MUST favor clarity and low cognitive load: prefer
  time-series, stat, and table panels. Avoid over-dense grids or
  decorative elements that do not convey information.

**Rationale**: Server-side aggregation respects Azure Managed Grafana
query-time and response-size limits, keeps dashboards responsive, and
provides a consistently fast user experience.

### IV. Reliability, Performance & Limits

- All KQL and dashboard designs MUST account for Azure Managed Grafana
  query-time and response-size limits by aggregating and down-sampling
  rather than streaming raw rows.
- ADX best practices MUST be followed: columnar-friendly schema design,
  batched ingestion, and explicit retention policies per
  table/environment.
- SLOs MUST be established for query latency and dashboard load times.
  Regressions against these SLOs MUST be treated as defects, not
  accepted as normal degradation.

**Rationale**: Proactive limit-awareness prevents production surprises;
treating performance regressions as defects maintains trust in the
platform over time.

### V. Observability & Alerting

- File-transfer metrics MUST be part of the observability stack with
  alerts configured for:
  - Missing files past expected delivery windows.
  - Late files exceeding SLA thresholds.
  - Abnormal volume patterns (spikes or drops).
- Alert labels MUST be clear and actionable, including at minimum: file
  type, source system, partner, and environment.
- Infrastructure alerts (cluster health, ingestion pipeline failures,
  network issues) MUST be kept separate from business/SLA alerts, but
  both MUST be accessible within the same Grafana workspace.

**Rationale**: Separating infra and business alerts prevents alert
fatigue and ensures that the right team responds to the right signal
without cross-contamination.

### VI. Security, Compliance & Environments

- Secrets MUST NOT appear in code, specs, configuration files, or
  version-controlled artifacts. All credentials MUST be stored in Azure
  Key Vault and accessed via managed identities.
- Environments (dev, test, prod) MUST be clearly isolated with separate
  ADX clusters/databases and Grafana data sources. Production and
  non-production data MUST NOT be mixed.
- Data retention and access patterns MUST comply with organizational and
  regulatory requirements, with special attention to healthcare or other
  sensitive domains where applicable.

**Rationale**: Strict environment isolation and secret management
eliminate classes of security incidents; compliance alignment from day
one avoids costly retroactive remediation.

### VII. Code Quality & Automation

- KQL queries, Grafana dashboard JSON, and ADX schema definitions MUST
  be version-controlled artifacts.
- All changes to schema, ingestion logic, or dashboards MUST be
  submitted via pull requests with peer review and automated validation
  where tooling permits.
- Infrastructure MUST be provisioned via IaC (Bicep or Terraform). IaC
  definitions SHOULD reside in the same repository as the analytics
  artifacts they support.

**Rationale**: Version control and PR-based workflows provide audit
trails, enable rollback, and ensure that no single change bypasses
review — critical for a system underpinning SLA reporting.

### VIII. AI/Agent Usage

- The AI agent MUST respect this constitution when generating specs,
  plans, tasks, KQL, infrastructure code, and documentation.
- The agent MUST favor clarity and maintainability over cleverness:
  readable KQL, well-named tables/columns, and documented dashboards.
- When a requirement conflicts with this constitution, the agent MUST
  explicitly highlight the conflict and propose constitution-aligned
  alternatives. Silent violations are prohibited.

**Rationale**: Codifying agent behavior ensures that AI-assisted
development accelerates delivery without eroding governance or
introducing undiscovered technical debt.

## Technology Stack

| Layer              | Service / Tool                          |
|--------------------|-----------------------------------------|
| Analytics engine   | Azure Data Explorer (ADX)               |
| Visualization      | Azure Managed Grafana                   |
| Infra telemetry    | Azure Monitor / Log Analytics           |
| Secret management  | Azure Key Vault                         |
| Identity           | Azure Managed Identities (Entra ID)     |
| Networking         | Private Link / Managed Private Endpoints|
| IaC                | Bicep or Terraform                      |
| Query language     | KQL (Kusto Query Language)              |
| Ingestion formats  | CSV, JSON                               |
| Version control    | Git (this repository)                   |

## Development Workflow

1. **All changes via PR**: Schema changes, KQL queries, Grafana
   dashboard JSON, IaC definitions, and documentation MUST be submitted
   as pull requests.
2. **Peer review required**: Every PR MUST receive at least one
   approving review before merge.
3. **Automated validation**: Where tooling permits, PRs MUST include
   automated checks (linting, schema validation, Bicep/Terraform plan).
4. **Environment promotion**: Changes MUST be validated in a
   non-production environment before promotion to production.
5. **Constitution compliance**: Reviewers MUST verify that changes align
   with the principles in this constitution. Non-compliance MUST be
   resolved before merge or explicitly documented with justification.

## Governance

- This constitution supersedes ad-hoc practices. When a principle
  conflicts with an existing habit, the principle prevails.
- **Amendment procedure**: Amendments MUST be proposed via PR to this
  file, reviewed by at least one stakeholder, and merged only after
  consensus. Each amendment MUST update the version and
  last-amended date.
- **Versioning policy**: Constitution versions follow Semantic
  Versioning (MAJOR.MINOR.PATCH):
  - MAJOR: Backward-incompatible principle removals or redefinitions.
  - MINOR: New principles/sections added or materially expanded.
  - PATCH: Clarifications, wording, or non-semantic refinements.
- **Compliance review**: At least once per quarter, the team SHOULD
  review active dashboards, queries, and infrastructure against this
  constitution and file corrective PRs for any drift.

**Version**: 1.0.0 | **Ratified**: 2026-02-21 | **Last Amended**: 2026-02-21
