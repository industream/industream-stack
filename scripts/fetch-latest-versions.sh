#!/bin/bash
# =============================================================================
# FETCH LATEST VERSIONS FROM RELEASE TRACKER
# =============================================================================
# Fetches latest component versions from the industream/release-tracker repo
# and updates the .env file.
#
# Usage:
#   ./scripts/fetch-latest-versions.sh              # Show versions only
#   ./scripts/fetch-latest-versions.sh --apply       # Update .env file
#   ./scripts/fetch-latest-versions.sh --apply --env-file .env.prod
# =============================================================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
APPLY=false
ENV_FILE="${PROJECT_DIR}/.env"
REPO="industream/release-tracker"

while [[ $# -gt 0 ]]; do
    case $1 in
        --apply) APPLY=true; shift ;;
        --env-file) ENV_FILE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--apply] [--env-file <path>]"
            echo "  --apply       Update the .env file with latest versions"
            echo "  --env-file    Path to .env file (default: .env)"
            exit 0 ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

echo -e "${BLUE}Fetching latest versions from ${REPO}...${NC}"

# Fetch README.md from GitHub
README=$(gh api "repos/${REPO}/contents/README.md" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)

if [ -z "$README" ]; then
    echo -e "${RED}Failed to fetch release-tracker README. Check gh auth status.${NC}"
    exit 1
fi

# Parse version from a markdown table line matching a component name
# Usage: parse_version "component-name"
parse_version() {
    local component="$1"
    echo "$README" | grep -i "| \`${component}\`" | head -1 | awk -F'|' '{print $4}' | sed 's/[` ]//g'
}

# Fetch all versions
FLOWMAKER_RUNTIME=$(parse_version "flowmaker-runtime")
FLOWMAKER_CONFIGHUB=$(parse_version "flowmaker-confighub")
FLOWMAKER_LOGGER=$(parse_version "flowmaker-logger")
FLOWMAKER_FRONT=$(parse_version "flowmaker-front")
CDN_CACHE=$(parse_version "cdn-cache")
CDN_SERVER=$(parse_version "cdn-server")

# Workers
BOX_DATA_LOGGER=$(parse_version "flow-box-data-logger")
BOX_TIMER=$(parse_version "flow-box-timer")
BOX_JS_EXPRESSION=$(parse_version "flow-box-js-expression")
BOX_HTTP=$(parse_version "flow-box-http")
BOX_POSTGRES_CLIENT=$(parse_version "flow-box-postgres-client")
BOX_TIMESERIES=$(parse_version "flow-box-timeseries-workers")
BOX_INFLUX_CLIENT=$(parse_version "flow-box-influx-client")
BOX_NOTIFICATION=$(parse_version "flow-box-notification")
BOX_MQTT_CLIENT=$(parse_version "flow-box-mqtt-client")
BOX_MODBUS_TCP=$(parse_version "flow-box-modbus-tcp")
BOX_OPC_UA=$(parse_version "flow-box-opc-ua-client")
BOX_S7_CLIENT=$(parse_version "flow-box-s7-client")
BOX_TEST_DATA_GEN=$(parse_version "flow-box-test-data-generator")
BOX_CONDITIONAL=$(parse_version "flow-box-conditional-dataset-validator")
BOX_ENQUEUE=$(parse_version "flow-box-enqueue")
BOX_EQUATION_SOLVER=$(parse_version "flow-box-equation-solver")
BOX_TOOLKIT=$(parse_version "flow-box-toolkit")
BOX_LUMINOSITY=$(parse_version "flow-box-luminosity-box")
BOX_MINIO_SINK=$(parse_version "flow-box-minio-sink")
BOX_RTSP_CLIENT=$(parse_version "flow-box-rtsp-client")

# DataCatalog
DATACATALOG_API=$(parse_version "datacatalog.*api" 2>/dev/null)
DATACATALOG_UI=$(parse_version "datacatalog.*ui" 2>/dev/null)
# Fallback: parse from DataCatalog section
if [ -z "$DATACATALOG_API" ]; then
    DATACATALOG_API=$(echo "$README" | sed -n '/## DataCatalog/,/## /p' | grep '| `api`' | head -1 | awk -F'|' '{print $4}' | sed 's/[` ]//g')
fi
if [ -z "$DATACATALOG_UI" ]; then
    DATACATALOG_UI=$(echo "$README" | sed -n '/## DataCatalog/,/## /p' | grep '| `ui`' | head -1 | awk -F'|' '{print $4}' | sed 's/[` ]//g')
fi

# UIFusion
UIFUSION_API=$(echo "$README" | sed -n '/## UIFusion/,/## /p' | grep '| `api`' | head -1 | awk -F'|' '{print $4}' | sed 's/[` ]//g')
UIFUSION_UI=$(echo "$README" | sed -n '/## UIFusion/,/## /p' | grep '| `ui`' | head -1 | awk -F'|' '{print $4}' | sed 's/[` ]//g')

# Grafana
GRAFANA_INDUSTREAM=$(echo "$README" | sed -n '/## Grafana/,/## /p' | grep '| `grafana-industream`' | head -1 | awk -F'|' '{print $4}' | sed 's/[` ]//g')

# Timeseries / DataBridge
DATABRIDGE_API=$(echo "$README" | sed -n '/## Timeseries/,/## /p' | grep '| `api`' | head -1 | awk -F'|' '{print $4}' | sed 's/[` ]//g')

# UIMaker
UIMAKER_BACKEND=$(parse_version "uimaker-backend")
UIMAKER_FRONT=$(parse_version "uimaker-front")

# Determine common worker box version (most common version among workers)
WORKER_VERSIONS=("$BOX_DATA_LOGGER" "$BOX_TIMER" "$BOX_JS_EXPRESSION" "$BOX_POSTGRES_CLIENT" "$BOX_TIMESERIES" "$BOX_INFLUX_CLIENT" "$BOX_NOTIFICATION" "$BOX_MQTT_CLIENT" "$BOX_MODBUS_TCP" "$BOX_OPC_UA" "$BOX_ENQUEUE" "$BOX_EQUATION_SOLVER" "$BOX_CONDITIONAL" "$BOX_TEST_DATA_GEN" "$BOX_LUMINOSITY" "$BOX_MINIO_SINK" "$BOX_RTSP_CLIENT")
COMMON_BOX_VERSION=$(printf '%s\n' "${WORKER_VERSIONS[@]}" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')

# Use the highest version between runtime/confighub/logger as FLOWMAKER_CORE_VERSION
FLOWMAKER_CORE="$FLOWMAKER_RUNTIME"

# UIMaker: use same version if backend == front
UIMAKER_VERSION="$UIMAKER_BACKEND"

# =============================================================================
# Display results
# =============================================================================
echo ""
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Latest Versions from Release Tracker${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo ""

# Read current .env values for comparison
current_val() {
    local key="$1"
    if [ -f "$ENV_FILE" ]; then
        grep "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 | head -1
    fi
}

show_version() {
    local label="$1"
    local env_key="$2"
    local new_val="$3"
    local current=$(current_val "$env_key")

    if [ -z "$new_val" ] || [ "$new_val" = "N/A" ]; then
        printf "  %-35s %-20s -> ${YELLOW}%-12s${NC} (not found)\n" "$label" "$env_key" "${current:-?}"
        return
    fi

    if [ "$current" = "$new_val" ]; then
        printf "  %-35s %-20s ${GREEN}%-12s${NC}\n" "$label" "$env_key" "$new_val"
    else
        printf "  %-35s %-20s ${YELLOW}%-12s${NC} -> ${GREEN}%-12s${NC}\n" "$label" "$env_key" "${current:-?}" "$new_val"
    fi
}

echo -e "${BLUE}FlowMaker Core:${NC}"
show_version "Runtime/ConfigHub/Logger" "FLOWMAKER_CORE_VERSION" "$FLOWMAKER_CORE"
show_version "Frontend" "FLOWMAKER_FRONTEND_VERSION" "$FLOWMAKER_FRONT"

echo ""
echo -e "${BLUE}FlowMaker Workers:${NC}"
show_version "Workers (common)" "FLOWMAKER_BOX_VERSION" "$COMMON_BOX_VERSION"
show_version "Toolkit" "FLOWMAKER_TOOLKIT_VERSION" "$BOX_TOOLKIT"
# Show specific overrides if different from common
for worker_var in "WORKER_HTTP_CLIENT_VERSION:$BOX_HTTP:Http" "WORKER_S7_CLIENT_VERSION:$BOX_S7_CLIENT:S7 Client"; do
    IFS=':' read -r var val label <<< "$worker_var"
    if [ -n "$val" ] && [ "$val" != "$COMMON_BOX_VERSION" ]; then
        show_version "  $label (override)" "$var" "$val"
    fi
done

echo ""
echo -e "${BLUE}CDN:${NC}"
show_version "CDN Cache" "CDN_CACHE_VERSION" "$CDN_CACHE"
show_version "CDN Server" "CDN_SERVER_VERSION" "$CDN_SERVER"

echo ""
echo -e "${BLUE}DataCatalog:${NC}"
show_version "API" "DATACATALOG_API_VERSION" "$DATACATALOG_API"
show_version "UI" "DATACATALOG_UI_VERSION" "$DATACATALOG_UI"

echo ""
echo -e "${BLUE}UIFusion:${NC}"
show_version "UI" "UIFUSION_VERSION" "$UIFUSION_UI"
show_version "API" "UIFUSION_API_VERSION" "$UIFUSION_API"

echo ""
echo -e "${BLUE}Grafana:${NC}"
show_version "Grafana Industream" "GRAFANA_VERSION" "$GRAFANA_INDUSTREAM"

echo ""
echo -e "${BLUE}Timeseries / DataBridge:${NC}"
show_version "API" "DATABRIDGE_API_VERSION" "$DATABRIDGE_API"

echo ""
echo -e "${BLUE}UIMaker:${NC}"
show_version "Backend/Frontend" "UIMAKER_VERSION" "$UIMAKER_VERSION"

echo ""

# Check for deprecated components in use
HTTP_CLIENT_DEPRECATED=$(echo "$README" | grep -i "http-client" | grep -i "deprecated" || true)
if [ -n "$HTTP_CLIENT_DEPRECATED" ]; then
    echo -e "${YELLOW}Warning: flow-box-http-client is DEPRECATED. Replace with flow-box-http.${NC}"
    echo ""
fi

# =============================================================================
# Apply updates to .env
# =============================================================================
if [ "$APPLY" = true ]; then
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}File not found: $ENV_FILE${NC}"
        exit 1
    fi

    echo -e "${BLUE}Updating $ENV_FILE...${NC}"

    # Compare semver: returns 0 if $1 > $2, 1 otherwise
    version_gt() {
        local v1="${1#v}" v2="${2#v}"
        # "latest" is never considered newer than a specific version
        if [ "$v1" = "latest" ] && [ "$v2" != "latest" ]; then
            return 1
        fi
        # Strip pre-release suffixes for comparison, treat release > pre-release
        local v1_clean=$(echo "$v1" | sed 's/-.*//') v2_clean=$(echo "$v2" | sed 's/-.*//')
        if [ "$(printf '%s\n%s' "$v1_clean" "$v2_clean" | sort -V | tail -1)" = "$v1_clean" ] && [ "$v1_clean" != "$v2_clean" ]; then
            return 0
        fi
        # Same base version: non-prerelease > prerelease
        if [ "$v1_clean" = "$v2_clean" ]; then
            local v1_pre=$(echo "$v1" | grep -o '\-.*' || true)
            local v2_pre=$(echo "$v2" | grep -o '\-.*' || true)
            if [ -z "$v1_pre" ] && [ -n "$v2_pre" ]; then
                return 0
            fi
        fi
        return 1
    }

    update_env() {
        local key="$1"
        local value="$2"
        if [ -z "$value" ] || [ "$value" = "N/A" ]; then
            return
        fi
        if grep -q "^${key}=" "$ENV_FILE"; then
            local current=$(grep "^${key}=" "$ENV_FILE" | cut -d= -f2)
            # Skip if current version is already newer
            if [ -n "$current" ] && [ "$current" != "$value" ]; then
                if version_gt "$current" "$value"; then
                    echo -e "  ${YELLOW}⏭ ${key}: keeping ${current} (newer than tracker's ${value})${NC}"
                    return
                fi
            fi
            sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
            echo -e "  ${GREEN}✓ ${key}=${value}${NC}"
        else
            echo "${key}=${value}" >> "$ENV_FILE"
            echo -e "  ${GREEN}+ ${key}=${value}${NC}"
        fi
    }

    update_env "FLOWMAKER_CORE_VERSION" "$FLOWMAKER_CORE"
    update_env "FLOWMAKER_FRONTEND_VERSION" "$FLOWMAKER_FRONT"
    update_env "FLOWMAKER_BOX_VERSION" "$COMMON_BOX_VERSION"
    update_env "FLOWMAKER_TOOLKIT_VERSION" "$BOX_TOOLKIT"
    # Individual worker versions (matching WORKER_*_VERSION in docker-stack.workers.yml)
    update_env "WORKER_CONDITIONAL_DATASET_VALIDATOR_VERSION" "$BOX_CONDITIONAL"
    update_env "WORKER_DATA_LOGGER_VERSION" "$BOX_DATA_LOGGER"
    update_env "WORKER_ENQUEUE_VERSION" "$BOX_ENQUEUE"
    update_env "WORKER_EQUATION_SOLVER_VERSION" "$BOX_EQUATION_SOLVER"
    update_env "WORKER_HTTP_VERSION" "$BOX_HTTP"
    update_env "WORKER_INFLUX_CLIENT_VERSION" "$BOX_INFLUX_CLIENT"
    update_env "WORKER_JS_EXPRESSION_VERSION" "$BOX_JS_EXPRESSION"
    update_env "WORKER_MODBUS_TCP_VERSION" "$BOX_MODBUS_TCP"
    update_env "WORKER_MQTT_CLIENT_VERSION" "$BOX_MQTT_CLIENT"
    update_env "WORKER_NOTIFICATIONS_VERSION" "$BOX_NOTIFICATION"
    update_env "WORKER_OPC_UA_CLIENT_VERSION" "$BOX_OPC_UA"
    update_env "WORKER_POSTGRES_CLIENT_VERSION" "$BOX_POSTGRES_CLIENT"
    update_env "WORKER_TEST_DATA_GENERATOR_VERSION" "$BOX_TEST_DATA_GEN"
    update_env "WORKER_TIMER_VERSION" "$BOX_TIMER"
    update_env "WORKER_TIMESERIES_VERSION" "$BOX_TIMESERIES"
    update_env "WORKER_LUMINOSITY_BOX_VERSION" "$BOX_LUMINOSITY"
    update_env "WORKER_MINIO_SINK_VERSION" "$BOX_MINIO_SINK"
    update_env "WORKER_RTSP_CLIENT_VERSION" "$BOX_RTSP_CLIENT"
    update_env "CDN_CACHE_VERSION" "$CDN_CACHE"
    update_env "CDN_SERVER_VERSION" "$CDN_SERVER"
    update_env "DATACATALOG_API_VERSION" "$DATACATALOG_API"
    update_env "DATACATALOG_UI_VERSION" "$DATACATALOG_UI"
    update_env "UIFUSION_VERSION" "$UIFUSION_UI"
    update_env "UIFUSION_API_VERSION" "$UIFUSION_API"
    update_env "UIMAKER_VERSION" "$UIMAKER_VERSION"
    update_env "GRAFANA_VERSION" "$GRAFANA_INDUSTREAM"
    update_env "DATABRIDGE_API_VERSION" "$DATABRIDGE_API"

    echo ""
    echo -e "${GREEN}✓ $ENV_FILE updated with latest versions${NC}"

    # Also update .env.example so new deployments start with current versions
    ENV_EXAMPLE="${PROJECT_DIR}/.env.example"
    if [ -f "$ENV_EXAMPLE" ] && [ "$ENV_FILE" != "$ENV_EXAMPLE" ]; then
        echo -e "${BLUE}Updating $ENV_EXAMPLE...${NC}"
        ENV_FILE="$ENV_EXAMPLE"
        update_env "FLOWMAKER_CORE_VERSION" "$FLOWMAKER_CORE"
        update_env "FLOWMAKER_FRONTEND_VERSION" "$FLOWMAKER_FRONT"
        update_env "FLOWMAKER_BOX_VERSION" "$COMMON_BOX_VERSION"
        update_env "FLOWMAKER_TOOLKIT_VERSION" "$BOX_TOOLKIT"
        # Individual worker versions (matching WORKER_*_VERSION in docker-stack.workers.yml)
        update_env "WORKER_CONDITIONAL_DATASET_VALIDATOR_VERSION" "$BOX_CONDITIONAL"
        update_env "WORKER_DATA_LOGGER_VERSION" "$BOX_DATA_LOGGER"
        update_env "WORKER_ENQUEUE_VERSION" "$BOX_ENQUEUE"
        update_env "WORKER_EQUATION_SOLVER_VERSION" "$BOX_EQUATION_SOLVER"
        update_env "WORKER_HTTP_VERSION" "$BOX_HTTP"
        update_env "WORKER_INFLUX_CLIENT_VERSION" "$BOX_INFLUX_CLIENT"
        update_env "WORKER_JS_EXPRESSION_VERSION" "$BOX_JS_EXPRESSION"
        update_env "WORKER_MODBUS_TCP_VERSION" "$BOX_MODBUS_TCP"
        update_env "WORKER_MQTT_CLIENT_VERSION" "$BOX_MQTT_CLIENT"
        update_env "WORKER_NOTIFICATIONS_VERSION" "$BOX_NOTIFICATION"
        update_env "WORKER_OPC_UA_CLIENT_VERSION" "$BOX_OPC_UA"
        update_env "WORKER_POSTGRES_CLIENT_VERSION" "$BOX_POSTGRES_CLIENT"
        update_env "WORKER_TEST_DATA_GENERATOR_VERSION" "$BOX_TEST_DATA_GEN"
        update_env "WORKER_TIMER_VERSION" "$BOX_TIMER"
        update_env "WORKER_TIMESERIES_VERSION" "$BOX_TIMESERIES"
        update_env "WORKER_LUMINOSITY_BOX_VERSION" "$BOX_LUMINOSITY"
        update_env "WORKER_MINIO_SINK_VERSION" "$BOX_MINIO_SINK"
        update_env "WORKER_RTSP_CLIENT_VERSION" "$BOX_RTSP_CLIENT"
        update_env "CDN_CACHE_VERSION" "$CDN_CACHE"
        update_env "CDN_SERVER_VERSION" "$CDN_SERVER"
        update_env "DATACATALOG_API_VERSION" "$DATACATALOG_API"
        update_env "DATACATALOG_UI_VERSION" "$DATACATALOG_UI"
        update_env "UIFUSION_VERSION" "$UIFUSION_UI"
        update_env "UIFUSION_API_VERSION" "$UIFUSION_API"
        update_env "UIMAKER_VERSION" "$UIMAKER_VERSION"
        update_env "GRAFANA_VERSION" "$GRAFANA_INDUSTREAM"
    update_env "DATABRIDGE_API_VERSION" "$DATABRIDGE_API"
        echo ""
        echo -e "${GREEN}✓ .env.example updated with latest versions${NC}"
    fi
else
    echo -e "${YELLOW}Dry run. Use --apply to update $ENV_FILE${NC}"
fi
