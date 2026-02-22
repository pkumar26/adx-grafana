#!/usr/bin/env bash
# deploy.sh — Interactive deployment script for ADX File-Transfer Analytics
#
# Handles resource group creation/selection, deployer identity, and Bicep deployment.
#
# Usage:
#   ./deploy.sh              # Interactive — prompts for environment and resource group
#   ./deploy.sh dev          # Use dev parameters, prompt for resource group
#   ./deploy.sh dev my-rg    # Non-interactive — use existing resource group "my-rg"
#
# Environment variables (optional overrides):
#   RESOURCE_GROUP       — Resource group name (skips prompt)
#   LOCATION             — Azure region for new resource group (default: from parameter file)
#   DEPLOYER_ID          — Azure AD Object ID (skips az ad signed-in-user show)
#   SKIP_CONFIRM         — Set to "true" to skip deployment confirmation prompt
#   EXTRA_PARAMS         — Additional --parameters to pass to az deployment group create

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}ℹ${NC}  $*"; }
ok()    { echo -e "${GREEN}✓${NC}  $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
err()   { echo -e "${RED}✗${NC}  $*" >&2; }
header(){ echo -e "\n${BOLD}$*${NC}"; }

# ─── Prerequisites ────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_prereqs() {
    local missing=0

    if ! command -v az &>/dev/null; then
        err "Azure CLI (az) is not installed. Install: https://aka.ms/installazurecli"
        missing=1
    fi

    if ! command -v jq &>/dev/null; then
        warn "jq is not installed — some features may be limited. Install: https://jqlang.github.io/jq/"
    fi

    if [[ $missing -eq 1 ]]; then
        exit 1
    fi

    # Check if logged in
    if ! az account show &>/dev/null 2>&1; then
        err "Not logged in to Azure CLI. Run: az login"
        exit 1
    fi

    ok "Azure CLI logged in as $(az account show --query user.name -o tsv 2>/dev/null)"
    info "Subscription: $(az account show --query name -o tsv 2>/dev/null) ($(az account show --query id -o tsv 2>/dev/null))"
}

# ─── Environment Selection ────────────────────────────────────────────────────

select_environment() {
    local env="${1:-}"

    if [[ -n "$env" ]]; then
        case "$env" in
            dev|test|prod) ENV="$env" ;;
            *) err "Invalid environment: $env (must be dev, test, or prod)"; exit 1 ;;
        esac
    else
        header "Select environment"
        echo "  1) dev   — Dev/Test SKU, 30-day retention, public access"
        echo "  2) test  — Dev/Test SKU, 30-day retention, private endpoints"
        echo "  3) prod  — Standard SKU, 90-day retention, private endpoints"
        echo ""
        read -rp "Environment [1/2/3] (default: 1): " choice
        case "${choice:-1}" in
            1|dev)  ENV="dev" ;;
            2|test) ENV="test" ;;
            3|prod) ENV="prod" ;;
            *) err "Invalid choice: $choice"; exit 1 ;;
        esac
    fi

    PARAM_FILE="$REPO_ROOT/infra/parameters/${ENV}.bicepparam"
    if [[ ! -f "$PARAM_FILE" ]]; then
        err "Parameter file not found: $PARAM_FILE"
        exit 1
    fi

    ok "Environment: ${BOLD}$ENV${NC}"

    # Extract location from parameter file
    PARAM_LOCATION=$(grep "^param location" "$PARAM_FILE" | sed "s/.*= *'//" | sed "s/'.*//")
    if [[ -z "$PARAM_LOCATION" ]]; then
        PARAM_LOCATION="eastus2"
    fi
}

# ─── Resource Group Selection ─────────────────────────────────────────────────

select_resource_group() {
    local rg_arg="${1:-}"

    # Environment variable or CLI argument override
    if [[ -n "${RESOURCE_GROUP:-}" ]]; then
        RG="$RESOURCE_GROUP"
        info "Using resource group from RESOURCE_GROUP env var: $RG"
    elif [[ -n "$rg_arg" ]]; then
        RG="$rg_arg"
        info "Using resource group from argument: $RG"
    else
        header "Resource Group"
        echo ""
        echo "  The deployment needs an Azure resource group."
        echo "  Default for $ENV: rg-file-transfer-$ENV"
        echo ""
        echo "  1) Create new resource group"
        echo "  2) Use existing resource group"
        echo ""
        read -rp "Choice [1/2] (default: 1): " rg_choice

        case "${rg_choice:-1}" in
            1)
                read -rp "Resource group name [rg-file-transfer-$ENV]: " rg_name
                RG="${rg_name:-rg-file-transfer-$ENV}"
                CREATE_RG=true
                ;;
            2)
                # List existing resource groups for convenience
                echo ""
                info "Fetching resource groups..."
                local rg_list
                rg_list=$(az group list --query "[].{Name:name, Location:location, State:properties.provisioningState}" -o table 2>/dev/null || true)
                if [[ -n "$rg_list" ]]; then
                    echo "$rg_list"
                    echo ""
                fi
                read -rp "Resource group name: " rg_name
                if [[ -z "$rg_name" ]]; then
                    err "Resource group name cannot be empty"
                    exit 1
                fi
                RG="$rg_name"
                CREATE_RG=false
                ;;
            *)
                err "Invalid choice: $rg_choice"
                exit 1
                ;;
        esac
    fi

    # Check if the resource group exists
    if az group show --name "$RG" &>/dev/null 2>&1; then
        ok "Resource group ${BOLD}$RG${NC} exists"
        RG_LOCATION=$(az group show --name "$RG" --query location -o tsv 2>/dev/null)
        CREATE_RG=false
    else
        if [[ "${CREATE_RG:-true}" == "false" ]]; then
            err "Resource group '$RG' not found."
            read -rp "Create it? [Y/n]: " create_confirm
            if [[ "${create_confirm:-Y}" =~ ^[Nn] ]]; then
                err "Aborted."
                exit 1
            fi
        fi
        CREATE_RG=true
    fi

    # Create resource group if needed
    if [[ "${CREATE_RG:-false}" == "true" ]]; then
        local loc="${LOCATION:-$PARAM_LOCATION}"
        read -rp "Location for resource group [$loc]: " loc_input
        loc="${loc_input:-$loc}"

        info "Creating resource group ${BOLD}$RG${NC} in $loc..."
        az group create --name "$RG" --location "$loc" --tags environment="$ENV" project=adx-file-transfer-analytics -o none
        ok "Resource group ${BOLD}$RG${NC} created in $loc"
        RG_LOCATION="$loc"
    fi
}

# ─── Deployer Identity ────────────────────────────────────────────────────────

resolve_deployer_id() {
    if [[ -n "${DEPLOYER_ID:-}" ]]; then
        info "Using deployer ID from DEPLOYER_ID env var"
    else
        header "Deployer Identity"
        echo ""
        echo "  The deployer's Azure AD Object ID is used to grant Grafana Admin"
        echo "  portal access. This is optional (skip for CI/CD pipelines)."
        echo ""
        read -rp "Grant Grafana Admin to current user? [Y/n]: " grant_admin
        if [[ "${grant_admin:-Y}" =~ ^[Nn] ]]; then
            DEPLOYER_ID=""
            info "Skipping Grafana Admin role assignment"
        else
            DEPLOYER_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
            if [[ -z "$DEPLOYER_ID" ]]; then
                warn "Could not retrieve your Azure AD Object ID. Skipping Grafana Admin assignment."
                DEPLOYER_ID=""
            else
                ok "Deployer ID: $DEPLOYER_ID"
            fi
        fi
    fi
}

# ─── Deployment ───────────────────────────────────────────────────────────────

run_deployment() {
    header "Deployment Summary"
    echo ""
    echo "  Environment:    $ENV"
    echo "  Resource Group: $RG (${RG_LOCATION:-unknown})"
    echo "  Template:       infra/main.bicep"
    echo "  Parameters:     infra/parameters/${ENV}.bicepparam"
    echo "  Deployer ID:    ${DEPLOYER_ID:-<none>}"
    echo ""

    if [[ "${SKIP_CONFIRM:-false}" != "true" ]]; then
        read -rp "Proceed with deployment? [Y/n]: " confirm
        if [[ "${confirm:-Y}" =~ ^[Nn] ]]; then
            warn "Deployment cancelled."
            exit 0
        fi
    fi

    local cmd=(
        az deployment group create
        --resource-group "$RG"
        --template-file "$REPO_ROOT/infra/main.bicep"
        --parameters "$PARAM_FILE"
        --parameters deployerPrincipalId="$DEPLOYER_ID"
    )

    # Append any extra parameters
    if [[ -n "${EXTRA_PARAMS:-}" ]]; then
        cmd+=(--parameters $EXTRA_PARAMS)
    fi

    echo ""
    info "Running: ${cmd[*]}"
    echo ""

    if ! "${cmd[@]}"; then
        echo ""
        err "Deployment failed. Check the error output above."
        echo ""
        echo "  Common fixes:"
        echo "  - Quota exceeded: Request quota increase or use a different region"
        echo "  - Name conflict: Change resource names in infra/parameters/${ENV}.bicepparam"
        echo "  - Auth error: Run 'az login' and try again"
        echo ""
        exit 1
    fi

    echo ""
    ok "${BOLD}Infrastructure deployment succeeded!${NC}"

    # Extract outputs for post-deployment steps
    GRAFANA_NAME=$(az deployment group show \
        --resource-group "$RG" --name main \
        --query "properties.outputs.grafanaName.value" -o tsv 2>/dev/null || true)
    ADX_CLUSTER_URI=$(az deployment group show \
        --resource-group "$RG" --name main \
        --query "properties.outputs.adxClusterUri.value" -o tsv 2>/dev/null || true)
    ADX_DATABASE=$(az deployment group show \
        --resource-group "$RG" --name main \
        --query "properties.outputs.adxDatabaseName.value" -o tsv 2>/dev/null || true)

    if [[ -n "$GRAFANA_NAME" && -n "$ADX_CLUSTER_URI" && -n "$ADX_DATABASE" ]]; then
        configure_grafana
    else
        warn "Could not read deployment outputs. Skipping Grafana configuration."
        warn "Run manually: ./scripts/configure-grafana.sh <grafana-name> <adx-cluster-uri> <adx-database>"
    fi

    echo ""
    ok "${BOLD}Deployment complete!${NC}"
    echo ""
    header "Next Steps"
    echo "  1. Open the Grafana endpoint to view dashboards"
    echo "  2. Ingest sample data:"
    echo "     cd runbook && pip install -r requirements.txt"
    echo "     python adx_runbook.py ingest-local \\"
    echo "       --cluster $ADX_CLUSTER_URI \\"
    echo "       --ingest-uri https://ingest-${ADX_CLUSTER_URI#https://} \\"
    echo "       --database $ADX_DATABASE \\"
    echo "       --file ../samples/sample-events.csv"
    echo "  3. Verify: python adx_runbook.py verify --cluster $ADX_CLUSTER_URI --database $ADX_DATABASE"
    echo ""
}

# ─── Grafana Configuration (post-deployment) ─────────────────────────────────

configure_grafana() {
    header "Configuring Grafana (data source + dashboards)..."

    # Ensure the Managed Grafana CLI extension is available
    az extension add --name amg --yes 2>/dev/null || true

    local ds_name="Azure Data Explorer - ${ADX_DATABASE}"

    # Step 1: Create or verify ADX data source (with retry for RBAC propagation)
    info "Creating ADX data source in Grafana..."
    local ds_uid=""
    local max_retries=5
    local retry_delay=15

    for attempt in $(seq 1 $max_retries); do
        # Check if data source already exists
        ds_uid=$(az grafana data-source show \
            --name "$GRAFANA_NAME" --data-source "$ds_name" \
            --query uid -o tsv 2>/dev/null || true)

        if [[ -n "$ds_uid" ]]; then
            ok "Data source already exists: $ds_name (UID: $ds_uid)"
            break
        fi

        # Try to create the data source
        local ds_def
        ds_def=$(cat <<EOF
{
  "name": "$ds_name",
  "type": "grafana-azure-data-explorer-datasource",
  "access": "proxy",
  "jsonData": {
    "azureCredentials": {"authType": "msi"},
    "clusterUrl": "$ADX_CLUSTER_URI",
    "defaultDatabase": "$ADX_DATABASE"
  }
}
EOF
        )
        local create_output
        create_output=$(az grafana data-source create \
            --name "$GRAFANA_NAME" --definition "$ds_def" 2>&1) && {
            ds_uid=$(echo "$create_output" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uid',''))" 2>/dev/null || true)
            if [[ -n "$ds_uid" ]]; then
                ok "Created data source: $ds_name (UID: $ds_uid)"
                break
            fi
        }

        # Check if it failed because it already exists (409 Conflict)
        if echo "$create_output" | grep -qi "already exists"; then
            info "Data source exists but show failed — retrying lookup..."
            ds_uid=$(az grafana data-source show \
                --name "$GRAFANA_NAME" --data-source "$ds_name" \
                --query uid -o tsv 2>/dev/null || true)
            if [[ -n "$ds_uid" ]]; then
                ok "Data source found: $ds_name (UID: $ds_uid)"
                break
            fi
        fi

        if [[ $attempt -lt $max_retries ]]; then
            warn "Attempt $attempt/$max_retries failed. RBAC may still be propagating. Retrying in ${retry_delay}s..."
            sleep "$retry_delay"
        fi
    done

    if [[ -z "$ds_uid" ]]; then
        warn "Failed to create Grafana data source after $max_retries attempts."
        warn "This usually means RBAC hasn't propagated yet. Try again in a few minutes:"
        warn "  az grafana data-source show --name $GRAFANA_NAME --data-source \"$ds_name\""
        warn "Manual setup: see dashboards/DATASOURCE.md"
        return
    fi

    # Step 2: Import dashboards
    for dashboard_file in "$REPO_ROOT/dashboards/operator-dashboard.json" "$REPO_ROOT/dashboards/business-dashboard.json"; do
        local title
        title=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['title'])" "$dashboard_file" 2>/dev/null || basename "$dashboard_file" .json)

        info "Importing dashboard: $title..."

        # Replace data source placeholder with actual UID and prepare import payload
        local tmp_file="/tmp/grafana-import-$(basename "$dashboard_file")"
        python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    dash = json.load(f)
# Replace template variable with actual data source UID
raw = json.dumps(dash).replace('\${DS_AZURE_DATA_EXPLORER}', sys.argv[2])
dash = json.loads(raw)
dash.pop('__inputs', None)
dash.pop('__requires', None)
with open(sys.argv[3], 'w') as f:
    json.dump({'dashboard': dash, 'overwrite': True}, f)
" "$dashboard_file" "$ds_uid" "$tmp_file"

        if az grafana dashboard create \
            --name "$GRAFANA_NAME" --definition "@$tmp_file" --overwrite \
            -o none 2>&1; then
            ok "Imported dashboard: $title"
        else
            warn "Failed to import dashboard: $title"
        fi
        rm -f "$tmp_file"
    done
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    header "ADX File-Transfer Analytics — Deployment"
    echo ""

    check_prereqs
    select_environment "${1:-}"
    select_resource_group "${2:-}"
    resolve_deployer_id
    run_deployment
}

main "$@"
