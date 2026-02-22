#!/usr/bin/env python3
"""ADX File-Transfer Analytics Runbook.

A developer CLI for setting up, ingesting data, and verifying the ADX
file-transfer analytics pipeline. Uses the same schema, mappings, and
update policy as the production Event Grid pipeline for full parity (FR-034).

Usage:
    python adx_runbook.py setup    --cluster <URI> --database <DB>
    python adx_runbook.py ingest-local  --cluster <URI> --ingest-uri <URI> --database <DB> --file <PATH>
    python adx_runbook.py ingest-blob   --cluster <URI> --ingest-uri <URI> --database <DB> --blob-uri <URI>
    python adx_runbook.py verify   --cluster <URI> --database <DB>

Auth methods (--auth-method):
    interactive        Azure CLI / browser-based login (default)
    managed-identity   Azure Managed Identity (for VMs, containers, Azure services)
    service-principal  App registration (requires --client-id, --client-secret, --tenant-id)
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# SSL fix: uv-managed Python may ship without CA certs. If SSL_CERT_FILE is
# not set, point it at certifi's bundle so TLS connections work out of the box.
# ---------------------------------------------------------------------------
if not os.environ.get("SSL_CERT_FILE"):
    try:
        import certifi
        os.environ["SSL_CERT_FILE"] = certifi.where()
    except ImportError:
        pass  # certifi not installed — rely on system certs

from azure.identity import (
    DefaultAzureCredential,
    InteractiveBrowserCredential,
    ManagedIdentityCredential,
    ClientSecretCredential,
)
from azure.kusto.data import KustoClient, KustoConnectionStringBuilder
from azure.kusto.data.data_format import DataFormat
from azure.kusto.data.exceptions import KustoServiceError
from azure.kusto.ingest import (
    QueuedIngestClient,
    IngestionProperties,
    FileDescriptor,
    BlobDescriptor,
)

# ---------------------------------------------------------------------------
# KQL Schema Commands — identical to kql/schema/*.kql (FR-034)
# ---------------------------------------------------------------------------

# DDL Execution Order per data-model.md
SCHEMA_COMMANDS: list[tuple[str, str]] = [
    # Step 1: Target table
    (
        "Create target table (FileTransferEvents)",
        """\
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
)""",
    ),
    # Step 2: Staging table
    (
        "Create staging table (FileTransferEvents_Raw)",
        """\
.create-merge table FileTransferEvents_Raw (
    Filename: string,
    SourcePresent: bool,
    TargetPresent: bool,
    SourceLastModifiedUtc: datetime,
    TargetLastModifiedUtc: datetime,
    AgeMinutes: real,
    Status: string,
    Notes: string
)""",
    ),
    # Step 3: Dead-letter table
    (
        "Create dead-letter table (FileTransferEvents_Errors)",
        """\
.create-merge table FileTransferEvents_Errors (
    RawData: string,
    Database: string,
    ['Table']: string,
    FailedOn: datetime,
    Error: string,
    OperationId: guid
)""",
    ),
    # Step 4: Transformation function
    (
        "Create transformation function",
        """\
.create-or-alter function FileTransferEvents_Transform() {
    FileTransferEvents_Raw
    | extend Timestamp = coalesce(SourceLastModifiedUtc, ingestion_time())
    | project Filename, SourcePresent, TargetPresent,
              SourceLastModifiedUtc, TargetLastModifiedUtc,
              AgeMinutes, Status, Notes, Timestamp
}""",
    ),
    # Step 5: Update policy
    (
        "Attach update policy",
        """\
.alter table FileTransferEvents policy update
@'[{"IsEnabled": true, "Source": "FileTransferEvents_Raw", "Query": "FileTransferEvents_Transform()", "IsTransactional": true, "PropagateIngestionProperties": true}]'""",
    ),
    # Step 6: CSV mapping  (single-line body — execute_mgmt requires it)
    (
        "Create CSV ingestion mapping",
        ".create-or-alter table FileTransferEvents_Raw ingestion csv mapping 'FileTransferEvents_CsvMapping' "
        "'["
        '{"Name":"Filename","DataType":"string","Ordinal":0},'
        '{"Name":"SourcePresent","DataType":"bool","Ordinal":1},'
        '{"Name":"TargetPresent","DataType":"bool","Ordinal":2},'
        '{"Name":"SourceLastModifiedUtc","DataType":"datetime","Ordinal":3},'
        '{"Name":"TargetLastModifiedUtc","DataType":"datetime","Ordinal":4},'
        '{"Name":"AgeMinutes","DataType":"real","Ordinal":5},'
        '{"Name":"Status","DataType":"string","Ordinal":6},'
        '{"Name":"Notes","DataType":"string","Ordinal":7}'
        "]'",
    ),
    # Step 7: JSON mapping  (single-line body — execute_mgmt requires it)
    (
        "Create JSON ingestion mapping",
        ".create-or-alter table FileTransferEvents_Raw ingestion json mapping 'FileTransferEvents_JsonMapping' "
        "'["
        '{"column":"Filename","path":"$.Filename","datatype":"string"},'
        '{"column":"SourcePresent","path":"$.SourcePresent","datatype":"bool"},'
        '{"column":"TargetPresent","path":"$.TargetPresent","datatype":"bool"},'
        '{"column":"SourceLastModifiedUtc","path":"$.SourceLastModifiedUtc","datatype":"datetime"},'
        '{"column":"TargetLastModifiedUtc","path":"$.TargetLastModifiedUtc","datatype":"datetime"},'
        '{"column":"AgeMinutes","path":"$.AgeMinutes","datatype":"real"},'
        '{"column":"Status","path":"$.Status","datatype":"string"},'
        '{"column":"Notes","path":"$.Notes","datatype":"string"}'
        "]'",
    ),
    # Step 8: Target table retention (90d default; override in non-prod)
    (
        "Set target table retention (90 days)",
        """\
.alter table FileTransferEvents policy retention
@'{"SoftDeletePeriod": "90.00:00:00", "Recoverability": "Enabled"}'""",
    ),
    # Step 9: Staging table retention (1 day)
    (
        "Set staging table retention (1 day)",
        """\
.alter table FileTransferEvents_Raw policy retention
@'{"SoftDeletePeriod": "1.00:00:00", "Recoverability": "Disabled"}'""",
    ),
    # Step 10: Dead-letter retention (30 days)
    (
        "Set dead-letter table retention (30 days)",
        """\
.alter table FileTransferEvents_Errors policy retention
@'{"SoftDeletePeriod": "30.00:00:00", "Recoverability": "Disabled"}'""",
    ),
    # Step 11: Ingestion batching (1 minute)
    (
        "Set ingestion batching policy (1 min)",
        """\
.alter table FileTransferEvents_Raw policy ingestionbatching
@'{"MaximumBatchingTimeSpan": "00:01:00", "MaximumNumberOfItems": 20, "MaximumRawDataSizeMB": 256}'""",
    ),
    # Step 12: Materialized view
    (
        "Create DailySummary materialized view",
        """\
.create ifnotexists materialized-view DailySummary on table FileTransferEvents {
    FileTransferEvents
    | summarize
        TotalCount      = count(),
        OkCount         = countif(Status == "OK"),
        MissingCount    = countif(Status == "MISSING"),
        DelayedCount    = countif(Status == "DELAYED"),
        AvgAgeMinutes   = avg(AgeMinutes),
        AgeDigest       = tdigest(AgeMinutes)
    by Date = startofday(Timestamp)
}""",
    ),
    # Step 13: Materialized view retention (730 days)
    (
        "Set DailySummary retention (730 days)",
        """\
.alter materialized-view DailySummary policy retention
@'{"SoftDeletePeriod": "730.00:00:00", "Recoverability": "Enabled"}'""",
    ),
]

VERIFY_QUERY = """\
FileTransferEvents
| order by Timestamp desc
| take 20
| project Filename, SourcePresent, TargetPresent,
          SourceLastModifiedUtc, TargetLastModifiedUtc,
          AgeMinutes, Status, Notes, Timestamp
"""


# ---------------------------------------------------------------------------
# Authentication helpers
# ---------------------------------------------------------------------------

def _build_kcsb(cluster_uri: str, args: argparse.Namespace) -> KustoConnectionStringBuilder:
    """Build a KustoConnectionStringBuilder based on the chosen auth method."""
    auth = args.auth_method
    if auth == "az-cli":
        # Uses the token from `az login` — works in WSL, SSH, containers
        credential = DefaultAzureCredential(
            exclude_interactive_browser_credential=True,
            exclude_shared_token_cache_credential=True,
        )
        return KustoConnectionStringBuilder.with_azure_token_credential(cluster_uri, credential)
    elif auth == "interactive":
        return KustoConnectionStringBuilder.with_interactive_login(cluster_uri)
    elif auth == "managed-identity":
        return KustoConnectionStringBuilder.with_aad_managed_service_identity_authentication(
            cluster_uri
        )
    elif auth == "service-principal":
        client_id = args.client_id or os.environ.get("AZURE_CLIENT_ID")
        client_secret = args.client_secret or os.environ.get("AZURE_CLIENT_SECRET")
        tenant_id = args.tenant_id or os.environ.get("AZURE_TENANT_ID")
        if not all([client_id, client_secret, tenant_id]):
            print(
                "ERROR: --client-id, --client-secret, and --tenant-id are required "
                "for service-principal auth (or set AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, "
                "AZURE_TENANT_ID environment variables).",
                file=sys.stderr,
            )
            sys.exit(1)
        return KustoConnectionStringBuilder.with_aad_application_key_authentication(
            cluster_uri, client_id, client_secret, tenant_id
        )
    else:
        print(f"ERROR: Unknown auth method: {auth}", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Retry helper
# ---------------------------------------------------------------------------

_MAX_RETRIES = 3
_RETRY_DELAY_SECONDS = 5


def _execute_with_retry(
    client: KustoClient, database: str, command: str, *, retries: int = _MAX_RETRIES
) -> object:
    """Execute a management command with retries for transient network errors."""
    last_exc: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            return client.execute_mgmt(database, command)
        except KustoServiceError as e:
            error_msg = str(e)
            # Retry only on network / metadata errors (transient)
            if "failed to process network request" in error_msg.lower() or "auth/metadata" in error_msg.lower():
                last_exc = e
                if attempt < retries:
                    print(f"RETRY ({attempt}/{retries}, waiting {_RETRY_DELAY_SECONDS}s)...", end=" ", flush=True)
                    time.sleep(_RETRY_DELAY_SECONDS)
                    continue
            raise  # Non-transient errors propagate immediately
    raise last_exc  # type: ignore[misc]


# ---------------------------------------------------------------------------
# Sub-commands
# ---------------------------------------------------------------------------

def cmd_setup(args: argparse.Namespace) -> None:
    """Create the full ADX object chain (tables, mappings, policies, MV)."""
    kcsb = _build_kcsb(args.cluster, args)
    client = KustoClient(kcsb)

    print(f"Setting up ADX schema in {args.database}...")
    print(f"  Cluster: {args.cluster}")
    print()

    for i, (description, command) in enumerate(SCHEMA_COMMANDS, start=1):
        step_label = f"[{i:2d}/{len(SCHEMA_COMMANDS)}]"
        print(f"  {step_label} {description}...", end=" ", flush=True)
        try:
            _execute_with_retry(client, args.database, command)
            print("OK")
        except KustoServiceError as e:
            # Some commands (e.g., create ifnotexists) may warn but not fail
            error_msg = str(e)
            if "already exists" in error_msg.lower():
                print("SKIPPED (already exists)")
            else:
                print(f"FAILED\n         {error_msg}")
                raise

    print()
    print("Setup complete. All tables, mappings, policies, and views are ready.")


def cmd_ingest_local(args: argparse.Namespace) -> None:
    """Ingest a local CSV or JSON file into the staging table via QueuedIngestClient."""
    ingest_uri = args.ingest_uri
    if not ingest_uri:
        print("ERROR: --ingest-uri is required for ingestion.", file=sys.stderr)
        sys.exit(1)

    file_path = Path(args.file)
    if not file_path.exists():
        print(f"ERROR: File not found: {file_path}", file=sys.stderr)
        sys.exit(1)

    # Determine format and mapping from file extension
    data_format, mapping_name = _resolve_format_and_mapping(file_path, args)

    kcsb = _build_kcsb(ingest_uri, args)
    ingest_client = QueuedIngestClient(kcsb)

    ingestion_props = IngestionProperties(
        database=args.database,
        table="FileTransferEvents_Raw",
        data_format=data_format,
        ingestion_mapping_reference=mapping_name,
        ignore_first_record=(data_format == DataFormat.CSV),
    )

    print(f"Ingesting {file_path.name} into FileTransferEvents_Raw...")
    print(f"  Format: {data_format.name}, Mapping: {mapping_name}")
    print(f"  Ingest URI: {ingest_uri}")

    file_descriptor = FileDescriptor(str(file_path), file_path.stat().st_size)
    ingest_client.ingest_from_file(file_descriptor, ingestion_properties=ingestion_props)

    print()
    print(
        "Ingestion queued successfully. Data flows through the staging table and "
        "update policy. Allow 1-3 minutes for rows to appear in FileTransferEvents."
    )


def cmd_ingest_blob(args: argparse.Namespace) -> None:
    """Ingest a blob from Azure Storage into the staging table via QueuedIngestClient."""
    ingest_uri = args.ingest_uri
    if not ingest_uri:
        print("ERROR: --ingest-uri is required for ingestion.", file=sys.stderr)
        sys.exit(1)

    blob_uri = args.blob_uri
    if not blob_uri:
        print("ERROR: --blob-uri is required for blob ingestion.", file=sys.stderr)
        sys.exit(1)

    # Determine format from blob URI extension
    data_format, mapping_name = _resolve_format_and_mapping_from_uri(blob_uri, args)

    kcsb = _build_kcsb(ingest_uri, args)
    ingest_client = QueuedIngestClient(kcsb)

    ingestion_props = IngestionProperties(
        database=args.database,
        table="FileTransferEvents_Raw",
        data_format=data_format,
        ingestion_mapping_reference=mapping_name,
        ignore_first_record=(data_format == DataFormat.CSV),
    )

    print(f"Ingesting blob into FileTransferEvents_Raw...")
    print(f"  Blob: {blob_uri}")
    print(f"  Format: {data_format.name}, Mapping: {mapping_name}")

    blob_descriptor = BlobDescriptor(blob_uri)
    ingest_client.ingest_from_blob(blob_descriptor, ingestion_properties=ingestion_props)

    print()
    print(
        "Ingestion queued successfully. Data flows through the staging table and "
        "update policy. Allow 1-3 minutes for rows to appear in FileTransferEvents."
    )


def cmd_verify(args: argparse.Namespace) -> None:
    """Query FileTransferEvents and display the latest rows to confirm ingestion."""
    kcsb = _build_kcsb(args.cluster, args)
    client = KustoClient(kcsb)

    print(f"Verifying data in {args.database}.FileTransferEvents...")
    print()

    response = client.execute(args.database, VERIFY_QUERY)

    # Get column names
    columns = [col.column_name for col in response.primary_results[0].columns]

    # Collect rows
    rows = list(response.primary_results[0])

    if not rows:
        print("  No rows found in FileTransferEvents.")
        print("  If you recently ingested data, wait 1-3 minutes and try again.")
        return

    print(f"  Found {len(rows)} recent rows (showing up to 20):")
    print()

    # Print header
    header = " | ".join(f"{col:>20s}" for col in columns)
    print(f"  {header}")
    print(f"  {'-' * len(header)}")

    # Print rows
    for row in rows:
        values = []
        for col in columns:
            val = row[col]
            values.append(f"{str(val):>20s}")
        print(f"  {' | '.join(values)}")

    print()

    # Validate Timestamp is never null
    null_timestamps = sum(1 for row in rows if row["Timestamp"] is None)
    if null_timestamps > 0:
        print(f"  WARNING: {null_timestamps} row(s) have null Timestamp!")
    else:
        print("  All rows have non-null Timestamp. Schema verification PASSED.")

    # Count by status
    status_counts: dict[str, int] = {}
    for row in rows:
        status = str(row["Status"])
        status_counts[status] = status_counts.get(status, 0) + 1

    print(f"  Status distribution: {status_counts}")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _resolve_format_and_mapping(
    file_path: Path, args: argparse.Namespace
) -> tuple[DataFormat, str]:
    """Determine ingestion format and mapping name from file extension or args."""
    fmt = getattr(args, "format", None)
    mapping = getattr(args, "mapping", None)

    if fmt:
        fmt_lower = fmt.lower()
    else:
        ext = file_path.suffix.lower()
        if ext == ".csv":
            fmt_lower = "csv"
        elif ext in (".json", ".jsonl"):
            fmt_lower = "json"
        else:
            print(
                f"ERROR: Cannot determine format from extension '{ext}'. "
                "Use --format csv or --format json.",
                file=sys.stderr,
            )
            sys.exit(1)

    if fmt_lower == "csv":
        data_format = DataFormat.CSV
        mapping_name = mapping or "FileTransferEvents_CsvMapping"
    elif fmt_lower == "json":
        data_format = DataFormat.JSON
        mapping_name = mapping or "FileTransferEvents_JsonMapping"
    else:
        print(f"ERROR: Unsupported format: {fmt_lower}", file=sys.stderr)
        sys.exit(1)

    return data_format, mapping_name


def _resolve_format_and_mapping_from_uri(
    uri: str, args: argparse.Namespace
) -> tuple[DataFormat, str]:
    """Determine format from a blob URI or explicit args."""
    fmt = getattr(args, "format", None)
    mapping = getattr(args, "mapping", None)

    if fmt:
        fmt_lower = fmt.lower()
    else:
        # Extract extension from URI (strip query params)
        path_part = uri.split("?")[0]
        if path_part.endswith(".csv"):
            fmt_lower = "csv"
        elif path_part.endswith(".json") or path_part.endswith(".jsonl"):
            fmt_lower = "json"
        else:
            print(
                "ERROR: Cannot determine format from blob URI. "
                "Use --format csv or --format json.",
                file=sys.stderr,
            )
            sys.exit(1)

    if fmt_lower == "csv":
        data_format = DataFormat.CSV
        mapping_name = mapping or "FileTransferEvents_CsvMapping"
    elif fmt_lower == "json":
        data_format = DataFormat.JSON
        mapping_name = mapping or "FileTransferEvents_JsonMapping"
    else:
        print(f"ERROR: Unsupported format: {fmt_lower}", file=sys.stderr)
        sys.exit(1)

    return data_format, mapping_name


# ---------------------------------------------------------------------------
# CLI Parser
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    """Build the argument parser with sub-commands."""

    # Shared parent parser — flags available on every sub-command
    shared = argparse.ArgumentParser(add_help=False)
    shared.add_argument(
        "--cluster",
        required=True,
        help="ADX cluster URI (e.g., https://adx-ft-dev.eastus2.kusto.windows.net)",
    )
    shared.add_argument(
        "--database",
        required=True,
        help="ADX database name (e.g., ftevents_dev)",
    )
    shared.add_argument(
        "--auth-method",
        choices=["az-cli", "interactive", "managed-identity", "service-principal"],
        default="az-cli",
        help="Authentication method (default: az-cli — uses your `az login` session)",
    )
    shared.add_argument("--client-id", help="Service principal client ID")
    shared.add_argument("--client-secret", help="Service principal client secret")
    shared.add_argument("--tenant-id", help="Azure AD tenant ID")

    parser = argparse.ArgumentParser(
        prog="adx_runbook",
        description=(
            "ADX File-Transfer Analytics Runbook — set up schema, ingest data, "
            "and verify the ADX pipeline. Uses the same schema and mappings as "
            "the production Event Grid pipeline (FR-034)."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Examples:
  # Set up schema in dev cluster
  python adx_runbook.py setup \\
    --cluster https://adx-ft-dev.eastus2.kusto.windows.net \\
    --database ftevents_dev

  # Ingest a local CSV file
  python adx_runbook.py ingest-local \\
    --cluster https://adx-ft-dev.eastus2.kusto.windows.net \\
    --ingest-uri https://ingest-adx-ft-dev.eastus2.kusto.windows.net \\
    --database ftevents_dev \\
    --file ../samples/sample-events.csv

  # Ingest a JSON file from blob storage
  python adx_runbook.py ingest-blob \\
    --cluster https://adx-ft-dev.eastus2.kusto.windows.net \\
    --ingest-uri https://ingest-adx-ft-dev.eastus2.kusto.windows.net \\
    --database ftevents_dev \\
    --blob-uri "https://stfteventsdev.blob.core.windows.net/file-transfer-events/data.json"

  # Verify ingested data
  python adx_runbook.py verify \\
    --cluster https://adx-ft-dev.eastus2.kusto.windows.net \\
    --database ftevents_dev

Auth methods:
  --auth-method interactive         Browser-based login (default)
  --auth-method managed-identity    Azure Managed Identity
  --auth-method service-principal   App registration (requires --client-id,
                                    --client-secret, --tenant-id or env vars)
""",
    )

    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # setup
    setup_parser = subparsers.add_parser(
        "setup",
        parents=[shared],
        help="Create the full ADX object chain (tables, mappings, policies, materialized view)",
    )

    # ingest-local
    ingest_local_parser = subparsers.add_parser(
        "ingest-local",
        parents=[shared],
        help="Ingest a local CSV/JSON file into the staging table",
    )
    ingest_local_parser.add_argument(
        "--ingest-uri",
        required=True,
        help="ADX ingestion URI (e.g., https://ingest-adx-ft-dev.eastus2.kusto.windows.net)",
    )
    ingest_local_parser.add_argument(
        "--file",
        required=True,
        help="Path to the local CSV or JSON file",
    )
    ingest_local_parser.add_argument(
        "--format",
        choices=["csv", "json"],
        help="Data format (auto-detected from file extension if omitted)",
    )
    ingest_local_parser.add_argument(
        "--mapping",
        help="Ingestion mapping name (defaults based on format)",
    )

    # ingest-blob
    ingest_blob_parser = subparsers.add_parser(
        "ingest-blob",
        parents=[shared],
        help="Ingest a blob from Azure Storage into the staging table",
    )
    ingest_blob_parser.add_argument(
        "--ingest-uri",
        required=True,
        help="ADX ingestion URI (e.g., https://ingest-adx-ft-dev.eastus2.kusto.windows.net)",
    )
    ingest_blob_parser.add_argument(
        "--blob-uri",
        required=True,
        help="Azure Blob Storage URI for the file to ingest",
    )
    ingest_blob_parser.add_argument(
        "--format",
        choices=["csv", "json"],
        help="Data format (auto-detected from blob URI extension if omitted)",
    )
    ingest_blob_parser.add_argument(
        "--mapping",
        help="Ingestion mapping name (defaults based on format)",
    )

    # verify
    verify_parser = subparsers.add_parser(
        "verify",
        parents=[shared],
        help="Query FileTransferEvents and display recent rows to confirm ingestion",
    )

    return parser


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    command_map = {
        "setup": cmd_setup,
        "ingest-local": cmd_ingest_local,
        "ingest-blob": cmd_ingest_blob,
        "verify": cmd_verify,
    }

    handler = command_map.get(args.command)
    if handler is None:
        parser.print_help()
        sys.exit(1)

    try:
        handler(args)
    except KustoServiceError as e:
        print(f"\nERROR: ADX service error: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"\nERROR: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
