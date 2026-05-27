#!/bin/bash
set -e

# ══════════════════════════════════════════════════════════════════════════════
# Industream Platform - Environment File Generator
# ══════════════════════════════════════════════════════════════════════════════
# First run (no .env): interactive mode, asks for key configuration
# Subsequent runs (.env exists): preserves existing values silently
# Usage: ./generate-env.sh > .env
# ══════════════════════════════════════════════════════════════════════════════

# Colors (used for stderr output only)
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helper Functions ───────────────────────────────────────────────────────

# Print to stderr (keeps stdout clean for .env output)
log() {
    echo -e "$1" >&2
}

# Ask user a question with a default value
# Prompts go to stderr, reads from /dev/tty so stdin redirection doesn't interfere
# Falls back to defaults when no tty is available (non-interactive/CI)
HAS_TTY=false
if (echo -n < /dev/tty) 2>/dev/null; then
    HAS_TTY=true
fi

ask_user() {
    local prompt="$1"
    local default="$2"
    local answer

    if [ "$HAS_TTY" = "true" ]; then
        echo -ne "  ${CYAN}${prompt}${NC} [${BOLD}${default}${NC}]: " >&2
        read -r answer < /dev/tty
        echo "${answer:-$default}"
    else
        echo -e "  ${CYAN}${prompt}${NC}: ${BOLD}${default}${NC} (auto)" >&2
        echo "$default"
    fi
}

# Get existing value from .env or generate a random password
get_or_generate_password() {
    local var_name=$1
    local existing_value=""

    if [ -f .env ] && [ "$FORCE_REGENERATE" != "true" ]; then
        existing_value=$(grep "^${var_name}=" .env 2>/dev/null | cut -d'=' -f2- || echo "")
    fi

    if [ -n "$existing_value" ]; then
        echo "$existing_value"
    else
        openssl rand -base64 32
    fi
}

# Get existing value from .env or use provided default
get_or_default() {
    local var_name=$1
    local default_value=$2
    local existing_value=""

    if [ -f .env ] && [ "$FORCE_REGENERATE" != "true" ]; then
        existing_value=$(grep "^${var_name}=" .env 2>/dev/null | cut -d'=' -f2- || echo "")
    fi

    if [ -n "$existing_value" ]; then
        echo "$existing_value"
    else
        echo "$default_value"
    fi
}

# Generate a random scheduler ID or preserve existing
generate_scheduler_id() {
    local existing_value=""
    if [ -f .env ] && [ "$FORCE_REGENERATE" != "true" ]; then
        existing_value=$(grep "^FLOWMAKER_SCHEDULER_ID=" .env 2>/dev/null | cut -d'=' -f2- || echo "")
    fi

    if [ -n "$existing_value" ]; then
        echo "$existing_value"
    else
        echo "RT-SCHED-$(openssl rand -hex 4 | tr '[:lower:]' '[:upper:]')"
    fi
}

# Suggest TLS mode based on domain suffix
suggest_tls_mode() {
    local domain="$1"
    case "$domain" in
        *.lan|*.local|*.test|localhost)
            echo "selfsigned"
            ;;
        *)
            echo "letsencrypt"
            ;;
    esac
}

# Auto-detect the server's primary IP address
detect_server_ip() {
    local existing_value=""
    if [ -f .env ] && [ "$FORCE_REGENERATE" != "true" ]; then
        existing_value=$(grep "^INDUSTREAM_SERVER_IP=" .env 2>/dev/null | cut -d'=' -f2- || echo "")
    fi

    if [ -n "$existing_value" ]; then
        echo "$existing_value"
    else
        hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"
    fi
}

# ─── Mode Detection ────────────────────────────────────────────────────────

INTERACTIVE=false
FORCE_REGENERATE="false"

if [ "$1" = "--force" ]; then
    FORCE_REGENERATE="true"
    INTERACTIVE=true
fi

if [ ! -f .env ]; then
    INTERACTIVE=true
fi

# ─── Status Messages ───────────────────────────────────────────────────────

if [ -f .env ] && [ "$1" != "--force" ]; then
    log "${YELLOW}⚠ .env file already exists${NC}"
    log "${BLUE}  Existing values will be preserved${NC}"
    log "${YELLOW}  Use '--force' to regenerate all values (⚠ breaks existing deployments!)${NC}"
    log ""
elif [ "$1" = "--force" ]; then
    log "${YELLOW}⚠ FORCE MODE: Regenerating all values${NC}"
    log ""
fi

# ─── Interactive Mode ───────────────────────────────────────────────────────

if [ "$INTERACTIVE" = "true" ]; then
    log ""
    log "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    log "${BOLD}║         Industream Platform — Environment Setup             ║${NC}"
    log "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    log ""
    log "${BLUE}  Configure your deployment. Press Enter to accept defaults.${NC}"
    log ""

    # Domain
    USER_DOMAIN=$(ask_user "Domain name" "industream.platform.lan")

    # TLS mode (smart default based on domain)
    SUGGESTED_TLS=$(suggest_tls_mode "$USER_DOMAIN")
    USER_TLS_MODE=$(ask_user "TLS mode (selfsigned/letsencrypt)" "$SUGGESTED_TLS")

    # ACME email (only relevant for letsencrypt)
    if [ "$USER_TLS_MODE" = "letsencrypt" ]; then
        USER_ACME_EMAIL=$(ask_user "ACME email (for Let's Encrypt notifications)" "admin@${USER_DOMAIN}")
    else
        USER_ACME_EMAIL="admin@${USER_DOMAIN}"
    fi

    # Timezone
    USER_TZ=$(ask_user "Timezone" "Europe/Berlin")

    # Docker registry
    USER_REGISTRY=$(ask_user "Docker registry" "842775dh.c1.gra9.container-registry.ovh.net")

    # Summary
    log ""
    log "${GREEN}✓ Configuration summary:${NC}"
    log "  Domain:   ${BOLD}${USER_DOMAIN}${NC}"
    log "  TLS:      ${BOLD}${USER_TLS_MODE}${NC}"
    if [ "$USER_TLS_MODE" = "letsencrypt" ]; then
        log "  ACME:     ${BOLD}${USER_ACME_EMAIL}${NC}"
    fi
    log "  Timezone: ${BOLD}${USER_TZ}${NC}"
    log "  Registry: ${BOLD}${USER_REGISTRY}${NC}"
    log ""
    log "${BLUE}  Generating secure random passwords...${NC}"
    log ""
else
    # Non-interactive: use existing values or defaults
    USER_DOMAIN=$(get_or_default 'INDUSTREAM_DOMAIN' 'industream.platform.lan')
    USER_TLS_MODE=$(get_or_default 'TLS_MODE' 'selfsigned')
    USER_ACME_EMAIL=$(get_or_default 'ACME_EMAIL' "admin@${USER_DOMAIN}")
    USER_TZ=$(get_or_default 'TZ' 'Europe/Berlin')
    USER_REGISTRY=$(get_or_default 'DOCKER_REGISTRY' '842775dh.c1.gra9.container-registry.ovh.net')
fi

# ─── Generate .env Output ──────────────────────────────────────────────────
# Everything below goes to stdout (redirected to .env by the caller)

echo "# Industream Docker Compose Environment Variables"
echo "# Generated on $(date)"
echo "# KEEP THIS FILE SECURE - chmod 600"
echo ""
echo "# ============================================"
echo "# Domain Configuration"
echo "# ============================================"
echo "INDUSTREAM_DOMAIN=${USER_DOMAIN}"
echo ""
echo "# ============================================"
echo "# TLS / Let's Encrypt Configuration"
echo "# ============================================"
echo "TLS_MODE=${USER_TLS_MODE}"
echo "ACME_EMAIL=${USER_ACME_EMAIL}"
echo ""
echo "# ============================================"
echo "# Docker Registry"
echo "# ============================================"
echo "DOCKER_REGISTRY=${USER_REGISTRY}"
echo ""
echo "# ============================================"
echo "# UIFusion Configuration"
echo "# ============================================"
echo "UIFUSION_VERSION=$(get_or_default 'UIFUSION_VERSION' '1.0.8')"
echo ""
echo "# ============================================"
echo "# PostgreSQL Configuration"
echo "# ============================================"
echo "POSTGRES_VERSION=$(get_or_default 'POSTGRES_VERSION' '18-alpine')"
echo "POSTGRES_ADMIN_USER=$(get_or_default 'POSTGRES_ADMIN_USER' 'postgres')"
echo "POSTGRES_ADMIN_PASSWORD=$(get_or_generate_password 'POSTGRES_ADMIN_PASSWORD')"
echo ""
echo "# ============================================"
echo "# Hub Backend (JWT auth) — community"
echo "# ============================================"
echo "HUB_AUTH_ISSUER=$(get_or_default 'HUB_AUTH_ISSUER' 'hub-backend')"
echo "HUB_AUTH_AUDIENCE=$(get_or_default 'HUB_AUTH_AUDIENCE' 'industream-hub')"
echo "# hub_backend_admin_user/password managed via Docker Secrets"
echo ""
echo "# ============================================"
echo "# Grafana Configuration"
echo "# ============================================"
echo "GRAFANA_VERSION=$(get_or_default 'GRAFANA_VERSION' '12.3.3')"
echo "GRAFANA_ADMIN_USER=$(get_or_default 'GRAFANA_ADMIN_USER' 'admin')"
echo "GRAFANA_ADMIN_PASSWORD=$(get_or_generate_password 'GRAFANA_ADMIN_PASSWORD')"
echo "GRAFANA_DB_NAME=$(get_or_default 'GRAFANA_DB_NAME' 'industream')"
echo "GRAFANA_DB_USER=$(get_or_default 'GRAFANA_DB_USER' 'dashboard')"
echo "GRAFANA_DB_PASSWORD=$(get_or_generate_password 'GRAFANA_DB_PASSWORD')"
echo "GRAFANA_OAUTH_ENABLED=$(get_or_default 'GRAFANA_OAUTH_ENABLED' 'true')"
echo "GRAFANA_OAUTH_CLIENT_ID=$(get_or_default 'GRAFANA_OAUTH_CLIENT_ID' 'uifusion')"
echo "GRAFANA_RENDERER_VERSION=$(get_or_default 'GRAFANA_RENDERER_VERSION' 'latest')"
echo ""
echo "# ============================================"
echo "# DataCatalog Configuration"
echo "# ============================================"
echo "DATACATALOG_API_VERSION=$(get_or_default 'DATACATALOG_API_VERSION' '1.0.0')"
echo "DATACATALOG_UI_VERSION=$(get_or_default 'DATACATALOG_UI_VERSION' '1.0.7')"
echo "DATACATALOG_DB_NAME=$(get_or_default 'DATACATALOG_DB_NAME' 'DataCatalog')"
echo "DATACATALOG_DB_USER=$(get_or_default 'DATACATALOG_DB_USER' 'datacatalog')"
echo "DATACATALOG_DB_PASSWORD=$(get_or_generate_password 'DATACATALOG_DB_PASSWORD')"
echo ""
echo "# ============================================"
echo "# CDN Cache Configuration"
echo "# ============================================"
echo "CDN_REGISTRY_URL=$(get_or_default 'CDN_REGISTRY_URL' 'http://cdn-server:4873')"
echo "CDN_URL=$(get_or_default 'CDN_URL' 'http://cdn-cache:8080')"
echo ""
echo "# ============================================"
echo "# InfluxDB Configuration"
echo "# ============================================"
echo "INFLUXDB_VERSION=$(get_or_default 'INFLUXDB_VERSION' '2.7.11')"
echo "INFLUX_ADMIN_USERNAME=$(get_or_default 'INFLUX_ADMIN_USERNAME' 'admin')"
echo "INFLUX_ADMIN_PASSWORD=$(get_or_generate_password 'INFLUX_ADMIN_PASSWORD')"
echo "INFLUX_ADMIN_TOKEN=$(get_or_generate_password 'INFLUX_ADMIN_TOKEN')"
echo "INFLUX_ORG=$(get_or_default 'INFLUX_ORG' 'industream')"
echo "INFLUX_BUCKET=$(get_or_default 'INFLUX_BUCKET' 'test')"
echo ""
echo "# ============================================"
echo "# Timeseries API Configuration"
echo "# ============================================"
echo "DATABRIDGE_API_VERSION=$(get_or_default 'DATABRIDGE_API_VERSION' '1.0.0-alpha.4')"
echo ""
echo "# ============================================"
echo "# FlowMaker Configuration"
echo "# ============================================"
echo "FLOWMAKER_CORE_VERSION=$(get_or_default 'FLOWMAKER_CORE_VERSION' '2.0.2')"
echo "FLOWMAKER_FRONTEND_VERSION=$(get_or_default 'FLOWMAKER_FRONTEND_VERSION' '2.0.2')"
echo "FLOWMAKER_BOX_VERSION=$(get_or_default 'FLOWMAKER_BOX_VERSION' '2.0.5')"
echo "FLOWMAKER_TOOLKIT_VERSION=$(get_or_default 'FLOWMAKER_TOOLKIT_VERSION' '1.10.1')"
echo ""
echo "# ============================================"
echo "# Monitoring Configuration"
echo "# ============================================"
echo "PROMETHEUS_VERSION=$(get_or_default 'PROMETHEUS_VERSION' 'v2.48.1')"
echo "NODE_EXPORTER_VERSION=$(get_or_default 'NODE_EXPORTER_VERSION' 'v1.7.0')"
echo "CADVISOR_VERSION=$(get_or_default 'CADVISOR_VERSION' 'v0.56.2')"
echo "POSTGRES_EXPORTER_VERSION=$(get_or_default 'POSTGRES_EXPORTER_VERSION' 'v0.16.0')"
echo ""
echo "# ============================================"
echo "# Alerting Configuration"
echo "# ============================================"
echo "ALERTMANAGER_VERSION=$(get_or_default 'ALERTMANAGER_VERSION' 'v0.26.0')"
echo "GOTIFY_VERSION=$(get_or_default 'GOTIFY_VERSION' '2.4.0')"
echo "GOTIFY_ADMIN_USER=$(get_or_default 'GOTIFY_ADMIN_USER' 'admin')"
echo ""
echo "# ============================================"
echo "# Timezone"
echo "# ============================================"
echo "TZ=${USER_TZ}"
echo ""
echo "# ============================================"
echo "# Backup Configuration"
echo "# ============================================"
echo "BACKUP_RETENTION_DAYS=$(get_or_default 'BACKUP_RETENTION_DAYS' '7')"
echo ""
echo "# ============================================"
echo "# Worker Versions"
echo "# ============================================"
echo "WORKER_CONDITIONAL_DATASET_VALIDATOR_VERSION=$(get_or_default 'WORKER_CONDITIONAL_DATASET_VALIDATOR_VERSION' '2.0.3')"
echo "WORKER_DATA_LOGGER_VERSION=$(get_or_default 'WORKER_DATA_LOGGER_VERSION' '2.0.3')"
echo "WORKER_ENQUEUE_VERSION=$(get_or_default 'WORKER_ENQUEUE_VERSION' '2.0.3')"
echo "WORKER_EQUATION_SOLVER_VERSION=$(get_or_default 'WORKER_EQUATION_SOLVER_VERSION' '2.0.3')"
echo "WORKER_HTTP_VERSION=$(get_or_default 'WORKER_HTTP_VERSION' '2.0.3')"
echo "WORKER_INFLUX_CLIENT_VERSION=$(get_or_default 'WORKER_INFLUX_CLIENT_VERSION' '2.0.3')"
echo "WORKER_JS_EXPRESSION_VERSION=$(get_or_default 'WORKER_JS_EXPRESSION_VERSION' '2.0.4')"
echo "WORKER_MODBUS_TCP_VERSION=$(get_or_default 'WORKER_MODBUS_TCP_VERSION' '2.0.3')"
echo "WORKER_MQTT_CLIENT_VERSION=$(get_or_default 'WORKER_MQTT_CLIENT_VERSION' '2.0.3')"
echo "WORKER_NOTIFICATIONS_VERSION=$(get_or_default 'WORKER_NOTIFICATIONS_VERSION' '2.0.3')"
echo "WORKER_OPC_UA_CLIENT_VERSION=$(get_or_default 'WORKER_OPC_UA_CLIENT_VERSION' '2.0.3')"
echo "WORKER_POSTGRES_CLIENT_VERSION=$(get_or_default 'WORKER_POSTGRES_CLIENT_VERSION' '2.0.3')"
echo "WORKER_TEST_DATA_GENERATOR_VERSION=$(get_or_default 'WORKER_TEST_DATA_GENERATOR_VERSION' '2.0.3')"
echo "WORKER_TIMER_VERSION=$(get_or_default 'WORKER_TIMER_VERSION' '2.0.3')"
echo "WORKER_TIMESERIES_VERSION=$(get_or_default 'WORKER_TIMESERIES_VERSION' '2.0.7')"
echo "WORKER_LUMINOSITY_BOX_VERSION=$(get_or_default 'WORKER_LUMINOSITY_BOX_VERSION' '1.0.0')"
echo "WORKER_MINIO_SINK_VERSION=$(get_or_default 'WORKER_MINIO_SINK_VERSION' '1.0.0')"
echo "WORKER_RTSP_CLIENT_VERSION=$(get_or_default 'WORKER_RTSP_CLIENT_VERSION' '1.0.1')"
echo "CDN_CACHE_VERSION=$(get_or_default 'CDN_CACHE_VERSION' '2.0.2')"
echo "CDN_SERVER_VERSION=$(get_or_default 'CDN_SERVER_VERSION' '2.0.0')"
echo "UIFUSION_API_VERSION=$(get_or_default 'UIFUSION_API_VERSION' '1.0.6')"
echo ""
echo "# ============================================"
echo "# IronStream Configuration"
echo "# ============================================"
echo "IRONSTREAM_DEMO_VERSION=$(get_or_default 'IRONSTREAM_DEMO_VERSION' '0.0.1')"
echo "IRONSTREAM_POSTGRES_VERSION=$(get_or_default 'IRONSTREAM_POSTGRES_VERSION' '18-alpine')"
echo "IRONSTREAM_DB_USER=$(get_or_default 'IRONSTREAM_DB_USER' 'ironstream')"
echo ""
echo "# ============================================"
echo "# Server IP (auto-detected)"
echo "# ============================================"
echo "INDUSTREAM_SERVER_IP=$(detect_server_ip)"

# ─── Final Message ──────────────────────────────────────────────────────────

if [ "$INTERACTIVE" = "true" ]; then
    log ""
    log "${GREEN}✓ .env file generated with secure random passwords${NC}"
    log "${BLUE}  Passwords have been auto-generated. View them in .env if needed.${NC}"
else
    log ""
    log "${GREEN}✓ .env file updated (existing values preserved)${NC}"
fi
