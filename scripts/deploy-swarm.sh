#!/bin/bash
# =============================================================================
# INDUSTREAM PLATFORM - MULTI-ENVIRONMENT SWARM DEPLOYMENT
# =============================================================================
# Deploy the Industream platform for a specific environment (prod/dev/staging)
#
# Prerequisites:
#   1. Deploy Traefik shared stack: ./scripts/deploy-traefik.sh
#   2. Create secrets: ./scripts/setup/create-secrets.sh --env <ENV>
#
# Usage:
#   ./scripts/deploy-swarm.sh --env prod       # Deploy production
#   ./scripts/deploy-swarm.sh --env dev        # Deploy development
#   ./scripts/deploy-swarm.sh --env staging    # Deploy staging
#   ./scripts/deploy-swarm.sh --env prod --with-demo  # With demo simulators
# =============================================================================

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
DEPLOY_DEMO=false
DEPLOY_IRONSTREAM=false
WITH_EE_OVERLAY=false
WITH_GRAFANA_SSO=false
CLEANUP_LEGACY=false
ENV=""

# Change to project directory
cd "$PROJECT_DIR"

# =============================================================================
# Parse arguments
# =============================================================================
EXCLUDE_SERVICES=""
COMMUNITY_MODE=false
SKIP_MEMORY_CHECK=false
SHOW_CREDENTIALS=false
NO_CUSTOM=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --env)
            ENV="$2"
            shift 2
            ;;
        --with-demo)
            DEPLOY_DEMO=true
            shift
            ;;
        --with-ironstream)
            DEPLOY_IRONSTREAM=true
            shift
            ;;
        --with-ee-overlay)
            WITH_EE_OVERLAY=true
            shift
            ;;
        --with-grafana-sso)
            WITH_GRAFANA_SSO=true
            shift
            ;;
        --cleanup-legacy)
            CLEANUP_LEGACY=true
            shift
            ;;
        --exclude)
            EXCLUDE_SERVICES="$2"
            shift 2
            ;;
        --no-custom)
            NO_CUSTOM=true
            shift
            ;;
        --community)
            COMMUNITY_MODE=true
            shift
            ;;
        --skip-memory-check)
            SKIP_MEMORY_CHECK=true
            shift
            ;;
        --show-credentials)
            SHOW_CREDENTIALS=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 --env <prod|dev|staging> [OPTIONS]"
            echo ""
            echo "Required:"
            echo "  --env <env>    Environment to deploy (prod, dev, staging)"
            echo ""
            echo "Options:"
            echo "  --with-demo        Also deploy demo simulators (dev env only - OPC-UA, MQTT, S7, Modbus, RTSP)"
            echo "  --with-ironstream  Include IronStream business services"
            echo "  --with-ee-overlay  Include the Enterprise overlay (Logto OIDC + uifusion-api EE image)"
            echo "  --with-grafana-sso Wrap Grafana in grafana-hub-wrapper (JWT/JWKS SSO via Hub backend) — CE/EE-compatible"
            echo "  --cleanup-legacy       Remove legacy worker services (after flow migration)"
            echo "  --skip-memory-check    Skip system memory validation"
            echo "  --show-credentials     Print admin credentials to stdout (default: path only)"
            echo "  --no-custom            Skip auto-discovery of custom stack files (debug)"
            echo "  --help, -h             Show this help message"
            echo ""
            echo "Prerequisites:"
            echo "  1. Deploy Traefik first: ./scripts/deploy-traefik.sh"
            echo "  2. Create secrets: ./scripts/setup/create-secrets.sh --env <ENV>"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# =============================================================================
# Validate environment
# =============================================================================
if [ -z "$ENV" ]; then
    echo -e "${RED}✗ Environment not specified${NC}"
    echo "Usage: $0 --env <prod|dev|staging>"
    exit 1
fi

if [[ ! "$ENV" =~ ^(prod|dev|staging)$ ]]; then
    echo -e "${RED}✗ Invalid environment: $ENV${NC}"
    echo "Valid environments: prod, dev, staging"
    exit 1
fi

# Set stack name based on environment
STACK_NAME="industream-${ENV}"

echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Industream Platform - ${ENV^^} Environment${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Stack name: ${STACK_NAME}${NC}"

# Demo simulators are only allowed in dev (ports would conflict with other envs)
if [ "$DEPLOY_DEMO" = "true" ] && [ "$ENV" != "dev" ]; then
    echo -e "${YELLOW}⚠ Demo simulators are only available for the dev environment${NC}"
    echo -e "${YELLOW}  (ingress ports 1883, 50000, 102, 5020 would conflict across envs)${NC}"
    echo -e "${YELLOW}  Ignoring --with-demo for ${ENV}${NC}"
    echo ""
    DEPLOY_DEMO=false
fi

if [ "$DEPLOY_DEMO" = "true" ] && [ "$DEPLOY_IRONSTREAM" = "true" ]; then
    echo -e "${BLUE}Mode: Platform + Demo simulators + IronStream${NC}"
elif [ "$DEPLOY_DEMO" = "true" ]; then
    echo -e "${BLUE}Mode: Platform + Demo simulators${NC}"
elif [ "$DEPLOY_IRONSTREAM" = "true" ]; then
    echo -e "${BLUE}Mode: Platform + IronStream${NC}"
else
    echo -e "${BLUE}Mode: Platform only${NC}"
fi
echo ""

# =============================================================================
# Check prerequisites
# =============================================================================

# Check if Swarm is initialized
if [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" != "active" ]; then
    echo -e "${RED}✗ Docker Swarm is not initialized${NC}"
    echo "Run: docker swarm init"
    exit 1
fi
echo -e "${GREEN}✓ Docker Swarm is active${NC}"

# Check if Traefik shared stack is deployed
if ! docker stack ls --format '{{.Name}}' | grep -q "^traefik-shared$"; then
    echo -e "${RED}✗ Traefik shared stack is not deployed${NC}"
    echo "Run: ./scripts/deploy-traefik.sh"
    exit 1
fi
echo -e "${GREEN}✓ Traefik shared stack is running${NC}"

# Check python3 and pyyaml (needed for fix-swarm-yaml.py)
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}✗ Python 3 is not installed (required for YAML processing)${NC}"
    echo "  Install: sudo pacman -S python (Arch) / sudo apt install python3 (Debian)"
    exit 1
fi
if ! python3 -c "import yaml" &> /dev/null; then
    echo -e "${RED}✗ PyYAML module not found (required for YAML processing)${NC}"
    echo "  Install: sudo pacman -S python-yaml (Arch) / sudo apt install python3-yaml (Debian)"
    exit 1
fi
echo -e "${GREEN}✓ Python 3 + PyYAML available${NC}"

# Check envsubst
if ! command -v envsubst &> /dev/null; then
    echo -e "${RED}✗ envsubst not found (part of gettext package)${NC}"
    echo "  Install: sudo pacman -S gettext (Arch) / sudo apt install gettext-base (Debian)"
    exit 1
fi

# =============================================================================
# Fetch latest versions from release tracker
# =============================================================================
echo ""
echo -e "${BLUE}Fetching latest versions from release tracker...${NC}"
if [ -f "$SCRIPT_DIR/fetch-latest-versions.sh" ] && command -v gh &>/dev/null; then
    bash "$SCRIPT_DIR/fetch-latest-versions.sh" --apply --env-file "$PROJECT_DIR/.env"
else
    echo -e "${YELLOW}⚠ Skipping version fetch (gh CLI not available or script missing)${NC}"
fi

# =============================================================================
# Load environment variables
# =============================================================================
echo ""
echo -e "${BLUE}Loading environment variables...${NC}"

# Save ENV from command line (before loading env files that might override it)
SAVED_ENV="${ENV}"
SAVED_STACK_NAME="${STACK_NAME}"

# Load base .env (create from .env.example if needed)
if [ ! -f ".env" ]; then
    if [ -f ".env.example" ]; then
        echo -e "${YELLOW}⚠ No .env file found, creating from .env.example${NC}"
        cp .env.example .env
        echo -e "${GREEN}✓ Created .env from .env.example${NC}"
        echo ""
        echo -e "${YELLOW}Please review and edit .env to set correct values for your environment.${NC}"
        echo -e "${YELLOW}Key settings to verify:${NC}"
        echo "  - INDUSTREAM_DOMAIN (your domain)"
        echo "  - ACME_EMAIL (for Let's Encrypt)"
        echo "  - TLS_MODE (selfsigned or letsencrypt)"
        echo "  - Service versions (UIFUSION_VERSION, FLOWMAKER_*, etc.)"
        echo ""
        if [ -t 0 ]; then
            read -p "Press Enter to continue after reviewing .env, or Ctrl+C to abort... "
        fi
    else
        echo -e "${YELLOW}⚠ No .env file found, using defaults${NC}"
    fi
fi

if [ -f ".env" ]; then
    set -a
    source .env
    set +a
    echo -e "${GREEN}✓ Base .env loaded${NC}"
    echo ""
    echo -e "${BLUE}Current configuration:${NC}"
    echo "  INDUSTREAM_DOMAIN=${INDUSTREAM_DOMAIN:-not set}"
    echo "  TLS_MODE=${TLS_MODE:-selfsigned}"
    echo "  UIFUSION_VERSION=${UIFUSION_VERSION:-not set}"
    echo "  FLOWMAKER_CORE_VERSION=${FLOWMAKER_CORE_VERSION:-not set}"
    echo ""
fi

# Restore ENV from command line
ENV="${SAVED_ENV}"
STACK_NAME="${SAVED_STACK_NAME}"

# Load environment-specific .env (overrides only: ENV, STACK_NAME, BACKUP, etc.)
# Domain and TLS always come from the base .env
ENV_FILE=".env.${ENV}"
if [ ! -f "$ENV_FILE" ]; then
    if [ -f "${ENV_FILE}.example" ]; then
        echo -e "${YELLOW}⚠ No ${ENV_FILE} found, creating from ${ENV_FILE}.example${NC}"
        cp "${ENV_FILE}.example" "$ENV_FILE"
        echo -e "${GREEN}✓ Created ${ENV_FILE}${NC}"
        echo ""
        echo -e "${BLUE}${ENV_FILE} configuration:${NC}"
        grep -E "^[A-Z]" "$ENV_FILE" | while read line; do
            echo "  $line"
        done
        echo ""
    else
        echo -e "${YELLOW}⚠ ${ENV_FILE} not found, using base configuration${NC}"
    fi
fi

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
    echo -e "${GREEN}✓ $ENV_FILE loaded (domain: ${INDUSTREAM_DOMAIN})${NC}"
fi

if [ "$COMMUNITY_MODE" = "true" ]; then
    echo -e "${GREEN}✓ Community mode enabled — using COMMUNITY_REGISTRY=${COMMUNITY_REGISTRY:-ghcr.io/industream}${NC}"
fi

# Ensure ENV and STACK_NAME are from command line
ENV="${SAVED_ENV}"
STACK_NAME="${SAVED_STACK_NAME}"

# Export ENV for variable substitution in YAML files
export ENV
export STACK_NAME

# Inject hub-backend admin creds from secrets/ into env vars (uifusion-api
# 2.1.0 does not support *_FILE suffix; we read the secret files here and
# export IH_USERNAME/IH_PASSWORD via HUB_BACKEND_ADMIN_* for compose interp).
HUB_USER_FILE="secrets/${ENV}/hub_backend_admin_user"
HUB_PASS_FILE="secrets/${ENV}/hub_backend_admin_password"
if [ -f "${HUB_USER_FILE}" ] && [ -f "${HUB_PASS_FILE}" ]; then
    export HUB_BACKEND_ADMIN_USER
    export HUB_BACKEND_ADMIN_PASSWORD
    HUB_BACKEND_ADMIN_USER=$(cat "${HUB_USER_FILE}")
    HUB_BACKEND_ADMIN_PASSWORD=$(cat "${HUB_PASS_FILE}")
fi

echo -e "${GREEN}✓ Environment: ENV=${ENV}${NC}"
echo -e "${GREEN}✓ Domain: INDUSTREAM_DOMAIN=${INDUSTREAM_DOMAIN:-not set}${NC}"

# =============================================================================
# Check environment-specific secrets
# =============================================================================
echo ""
echo -e "${BLUE}Checking Docker secrets for ${ENV} environment...${NC}"

REQUIRED_SECRETS=(
    "${ENV}_postgres_admin_password"
    "${ENV}_grafana_admin_password"
    "${ENV}_grafana_db_password"
    "${ENV}_datacatalog_db_password"
    "${ENV}_influx_admin_password"
    "${ENV}_influx_admin_token"
    "${ENV}_hub_backend_admin_user"
    "${ENV}_hub_backend_admin_password"
)

MISSING_SECRETS=0
for secret in "${REQUIRED_SECRETS[@]}"; do
    if ! docker secret ls --format '{{.Name}}' | grep -q "^${secret}$"; then
        echo -e "${YELLOW}  ✗ Missing secret: $secret${NC}"
        MISSING_SECRETS=$((MISSING_SECRETS + 1))
    else
        echo -e "${GREEN}  ✓ $secret${NC}"
    fi
done

if [ $MISSING_SECRETS -gt 0 ]; then
    echo ""
    echo -e "${RED}✗ $MISSING_SECRETS secret(s) missing!${NC}"
    echo "Create them with: ./scripts/setup/create-secrets.sh --env $ENV"
    exit 1
fi

# =============================================================================
# Postgres major-version pre-flight
# =============================================================================
# Detects PG_VERSION inside the existing ${ENV}-postgres-data volume and
# refuses to deploy if a major-version migration is needed (e.g. PG17 → PG18).
# Skipped for fresh installs (no volume yet). Bypassable via env var.
if [ "${SKIP_PG_MIGRATION:-false}" != "true" ] && [ -x "${SCRIPT_DIR}/setup/migrate-postgres.sh" ]; then
    echo ""
    echo -e "${BLUE}Checking PostgreSQL major version vs target...${NC}"
    set +e
    "${SCRIPT_DIR}/setup/migrate-postgres.sh" --env "$ENV" --check-only
    PG_CHECK=$?
    set -e
    if [ $PG_CHECK -eq 2 ]; then
        echo -e "${YELLOW}A major-version migration is required.${NC}"
        echo "Run: ./scripts/setup/migrate-postgres.sh --env $ENV"
        echo "Or bypass with: SKIP_PG_MIGRATION=true ./scripts/deploy-swarm.sh --env $ENV"
        exit 1
    elif [ $PG_CHECK -ne 0 ]; then
        echo -e "${RED}Postgres pre-flight failed (exit $PG_CHECK).${NC}"
        exit 1
    fi
fi

# =============================================================================
# Auto-detect server IP for dnsmasq DNS resolution
# =============================================================================
detect_server_ip() {
    local ip=""

    # Method 1: Get IP from default route interface
    local default_iface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ -n "$default_iface" ]; then
        ip=$(ip -4 addr show "$default_iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    fi

    # Method 2: Fallback to hostname -I (first non-localhost IP)
    if [ -z "$ip" ] || [ "$ip" = "127.0.0.1" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    # Method 3: Last resort - get any non-docker, non-localhost IP
    if [ -z "$ip" ] || [ "$ip" = "127.0.0.1" ]; then
        ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | grep -v '^172\.1[7-9]\.' | grep -v '^172\.2[0-9]\.' | grep -v '^172\.3[0-1]\.' | head -1)
    fi

    echo "$ip"
}

echo ""
echo -e "${BLUE}Detecting server IP for DNS resolution...${NC}"
if [ -z "$INDUSTREAM_SERVER_IP" ] || [ "$INDUSTREAM_SERVER_IP" = "127.0.0.1" ]; then
    DETECTED_IP=$(detect_server_ip)
    if [ -n "$DETECTED_IP" ] && [ "$DETECTED_IP" != "127.0.0.1" ]; then
        export INDUSTREAM_SERVER_IP="$DETECTED_IP"
        echo -e "${GREEN}✓ Auto-detected server IP: ${INDUSTREAM_SERVER_IP}${NC}"
    else
        export INDUSTREAM_SERVER_IP="127.0.0.1"
        echo -e "${YELLOW}⚠ Could not detect server IP, using 127.0.0.1 (local only)${NC}"
    fi
else
    echo -e "${GREEN}✓ Using configured IP: ${INDUSTREAM_SERVER_IP}${NC}"
fi

# =============================================================================
# Generate Traefik dynamic config
# =============================================================================
echo ""
echo -e "${BLUE}Generating Traefik dynamic configuration...${NC}"
if [ -f "traefik-dynamic/traefik-dynamic.yml.template" ]; then
    envsubst < traefik-dynamic/traefik-dynamic.yml.template > traefik-dynamic/traefik-dynamic.yml
    echo -e "${GREEN}✓ Traefik config generated${NC}"
else
    echo -e "${YELLOW}⚠ Template not found, skipping${NC}"
fi

# =============================================================================
# Generate SSL certificates if needed
# =============================================================================
echo -e "${BLUE}Checking SSL certificates...${NC}"
CERT_DIR="./certs"
DOMAIN="${INDUSTREAM_DOMAIN:-industream.platform.lan}"
if [ ! -f "${CERT_DIR}/${DOMAIN}.crt" ] || [ ! -f "${CERT_DIR}/${DOMAIN}.key" ]; then
    echo -e "${BLUE}Generating self-signed certificate for ${DOMAIN}...${NC}"
    mkdir -p "${CERT_DIR}"
    # Fix ownership if dir was created by root (e.g. previous sudo run)
    if [ -d "${CERT_DIR}" ] && [ ! -w "${CERT_DIR}" ]; then
        sudo chown -R "$(id -u):$(id -g)" "${CERT_DIR}" 2>/dev/null || true
    fi
    openssl req -x509 -nodes -days 1825 -newkey rsa:2048 \
        -keyout "${CERT_DIR}/${DOMAIN}.key" \
        -out "${CERT_DIR}/${DOMAIN}.crt" \
        -subj "/CN=${DOMAIN}" \
        -addext "subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN}" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Certificate generated (5 years)${NC}"
    else
        echo -e "${RED}✗ Certificate generation failed${NC}"
        echo -e "${YELLOW}  Try: sudo chown -R \$(whoami) ${CERT_DIR}${NC}"
    fi
else
    echo -e "${GREEN}✓ Certificate exists${NC}"
fi

# =============================================================================
# Enable Docker daemon metrics for Prometheus (Swarm metrics)
# =============================================================================
echo ""
echo -e "${BLUE}Checking Docker daemon metrics endpoint...${NC}"
DAEMON_JSON="/etc/docker/daemon.json"
METRICS_NEEDED=false

if [ -f "$DAEMON_JSON" ]; then
    if ! grep -q '"metrics-addr"' "$DAEMON_JSON" 2>/dev/null; then
        METRICS_NEEDED=true
    else
        echo -e "${GREEN}✓ Docker metrics endpoint already configured${NC}"
    fi
else
    METRICS_NEEDED=true
fi

if [ "$METRICS_NEEDED" = "true" ]; then
    echo -e "${BLUE}Enabling Docker daemon metrics on port 9323...${NC}"
    # Check if we can sudo before attempting (skip if no sudo access)
    if sudo -n true 2>/dev/null; then
        if [ -f "$DAEMON_JSON" ]; then
            TEMP_JSON=$(python3 -c "
import json, sys
try:
    with open('$DAEMON_JSON') as f:
        cfg = json.load(f)
except:
    cfg = {}
cfg['metrics-addr'] = '127.0.0.1:9323'
cfg['experimental'] = True
print(json.dumps(cfg, indent=2))
" 2>/dev/null)
            if [ -n "$TEMP_JSON" ]; then
                echo "$TEMP_JSON" | sudo tee "$DAEMON_JSON" > /dev/null
            fi
        else
            sudo mkdir -p /etc/docker
            echo '{"metrics-addr": "127.0.0.1:9323", "experimental": true}' | sudo tee "$DAEMON_JSON" > /dev/null
        fi
        echo -e "${YELLOW}⚠ Docker daemon metrics enabled - Docker restart may be needed${NC}"
    else
        echo -e "${YELLOW}⚠ Skipping Docker metrics (no sudo access). Enable manually:${NC}"
        echo -e "${YELLOW}  sudo tee /etc/docker/daemon.json <<< '{\"metrics-addr\":\"127.0.0.1:9323\",\"experimental\":true}'${NC}"
    fi
fi

# =============================================================================
# Generate legacy worker services (multi-version support)
# =============================================================================
echo ""
echo -e "${BLUE}Checking worker version changes...${NC}"
if [ -f "$SCRIPT_DIR/generate/generate-legacy-workers.sh" ]; then
    if [ "$CLEANUP_LEGACY" = "true" ]; then
        bash "$SCRIPT_DIR/generate/generate-legacy-workers.sh" --cleanup
    else
        bash "$SCRIPT_DIR/generate/generate-legacy-workers.sh"
    fi
else
    echo -e "${YELLOW}⚠ Legacy workers script not found, skipping${NC}"
fi

# =============================================================================
# Build stack files list
# =============================================================================
echo ""
echo -e "${BLUE}Resolving docker-compose variables...${NC}"

# Define stack files based on environment.
#
# Custom stack files (client overrides / extensions) are auto-discovered later
# in this block, after the conditional stacks. Two conventions are supported:
#   1. Files matching `docker-stack.custom*.yml` at the repo root (alphabetical).
#   2. Any `*.yml` / `*.yaml` file inside a `custom/` directory (alphabetical).
# Each discovered file is validated with `docker compose -f <file> config -q`
# before the deployment proceeds. See `custom/README.md` for usage details.
# The auto-discovery can be disabled at runtime with `--no-custom`.
STACK_FILES=(
    "docker-stack.yml"
    "docker-stack.flowmaker.yml"
    "docker-stack.workers.yml"
    "docker-stack.monitoring.yml"
    "docker-stack.data.yml"
    "docker-stack.cdn.yml"
)

# Include premium workers only when not in community mode
if [ "$COMMUNITY_MODE" != "true" ]; then
    STACK_FILES+=("docker-stack.workers-premium.yml")
fi

# Add legacy workers if generated
if [ -f "docker-stack.workers-legacy.yml" ]; then
    STACK_FILES+=("docker-stack.workers-legacy.yml")
    echo -e "${BLUE}  Including legacy worker services (multi-version support)${NC}"
fi

# Add backup only for production
if [ "$ENV" = "prod" ]; then
    STACK_FILES+=("docker-stack.backup.yml")
    echo -e "${BLUE}  Including backup services (production only)${NC}"
else
    echo -e "${YELLOW}  Excluding backup services (${ENV} environment)${NC}"
fi

# Add demo simulators if requested
if [ "$DEPLOY_DEMO" = "true" ]; then
    if [ -f "docker-stack.demo.yml" ]; then
        STACK_FILES+=("docker-stack.demo.yml")
        echo -e "${BLUE}  Including demo simulators (--with-demo)${NC}"
    else
        echo -e "${YELLOW}  ⚠ docker-stack.demo.yml not found, skipping demo${NC}"
        DEPLOY_DEMO=false
    fi
fi

# Add ironstream services if requested
if [ "$DEPLOY_IRONSTREAM" = "true" ]; then
    if [ -f "docker-stack.ironstream.yml" ]; then
        STACK_FILES+=("docker-stack.ironstream.yml")
        echo -e "${BLUE}  Including IronStream services (--with-ironstream)${NC}"
    else
        echo -e "${YELLOW}  \u26a0 docker-stack.ironstream.yml not found, skipping${NC}"
        DEPLOY_IRONSTREAM=false
    fi
fi

# EE overlay (Logto + OAUTH override on uifusion-api). ee-gate.sh sets this
# flag automatically when the license entitles the enterprise edition. The
# custom auto-discovery block below is appended AFTER this overlay, so client
# `custom/` files keep the final say on uifusion-api overrides.
if [ "$WITH_EE_OVERLAY" = "true" ]; then
    if [ -f "docker-stack.ee.yml" ]; then
        STACK_FILES+=("docker-stack.ee.yml")
        echo -e "${BLUE}  Including EE overlay — Logto + OAUTH (--with-ee-overlay)${NC}"
    else
        echo -e "${RED}✗ --with-ee-overlay requested but docker-stack.ee.yml not present${NC}"
        echo -e "${YELLOW}  Pull the v2/ee-overlay branch or check out PR #2.${NC}"
        exit 1
    fi
fi

# Grafana Hub SSO wrapper. CE/EE-compatible (the Hub backend always signs
# its own JWT regardless of identity source). Appended after EE overlay so
# EE-only env can be referenced if needed later; before custom so client
# files retain final-word semantics.
if [ "$WITH_GRAFANA_SSO" = "true" ]; then
    if [ -f "docker-stack.grafana-wrapper.yml" ]; then
        STACK_FILES+=("docker-stack.grafana-wrapper.yml")
        echo -e "${BLUE}  Including Grafana SSO wrapper (--with-grafana-sso)${NC}"
    else
        echo -e "${RED}✗ --with-grafana-sso requested but docker-stack.grafana-wrapper.yml not present${NC}"
        exit 1
    fi

    # TLS_MODE-conditional CA trust for the JWKS fetch:
    #   - selfsigned → Grafana must trust the platform CA (skip-verify does NOT
    #     work in Grafana 13 for JWKS). Append the overlay that mounts it.
    #   - letsencrypt → public cert trusted out of the box; nothing to add.
    if [ "${TLS_MODE:-selfsigned}" = "selfsigned" ]; then
        if [ -f "docker-stack.grafana-wrapper-selfsigned.yml" ]; then
            STACK_FILES+=("docker-stack.grafana-wrapper-selfsigned.yml")
            echo -e "${BLUE}  Trusting platform CA in Grafana (TLS_MODE=selfsigned)${NC}"
            if [ ! -f "certs/${INDUSTREAM_DOMAIN}.crt" ]; then
                echo -e "${YELLOW}  ⚠ certs/${INDUSTREAM_DOMAIN}.crt not found — run scripts/generate/generate-certs.sh first, else Grafana SSO will fail with 'no keys found'${NC}"
            fi
        else
            echo -e "${RED}✗ TLS_MODE=selfsigned + --with-grafana-sso but docker-stack.grafana-wrapper-selfsigned.yml not present${NC}"
            exit 1
        fi
    else
        echo -e "${BLUE}  Grafana SSO: TLS_MODE=${TLS_MODE} → relying on publicly-trusted cert (no CA mount)${NC}"
    fi
fi

# =============================================================================
# Auto-discover custom stack files (client overrides / extensions)
# =============================================================================
# Convention 1: `docker-stack.custom*.yml` at the repo root.
# Convention 2: `*.yml` / `*.yaml` inside the `custom/` directory.
# Each discovered file is validated with `docker compose config -q` and any
# failure aborts the deployment. Disable with `--no-custom`.
if [ "$NO_CUSTOM" = "true" ]; then
    echo -e "${YELLOW}  Skipping custom stack auto-discovery (--no-custom)${NC}"
else
    CUSTOM_CANDIDATES=()

    # Convention 1: root-level docker-stack.custom*.yml (alphabetical, glob).
    # `shopt -s nullglob` ensures the loop is silent when no file matches.
    shopt -s nullglob
    for f in docker-stack.custom*.yml; do
        CUSTOM_CANDIDATES+=("$f")
    done
    shopt -u nullglob

    # Convention 2: any .yml / .yaml inside custom/ (alphabetical, recursive=no).
    if [ -d "custom" ]; then
        shopt -s nullglob
        for f in custom/*.yml custom/*.yaml; do
            CUSTOM_CANDIDATES+=("$f")
        done
        shopt -u nullglob
    fi

    # Sort alphabetically for deterministic ordering across machines.
    if [ ${#CUSTOM_CANDIDATES[@]} -gt 0 ]; then
        IFS=$'\n' CUSTOM_CANDIDATES=($(sort <<< "${CUSTOM_CANDIDATES[*]}"))
        unset IFS

        for custom_file in "${CUSTOM_CANDIDATES[@]}"; do
            # Lightweight YAML-only sanity check. We can't run a full
            # `docker compose config -q` here because:
            #   1) Stack files use `${ENV}-volume-name` for top-level volume
            #      keys; Compose does not expand variables in mapping keys
            #      until envsubst has run (later in this script).
            #   2) Override-only files (no image:/build:) fail standalone
            #      Compose validation, but they're valid as part of a merge.
            # The actual `docker compose config` after envsubst (line ~640)
            # is the real validator; a syntax error there aborts the deploy.
            if command -v python3 &>/dev/null; then
                if ! VALIDATION_OUTPUT=$(python3 -c "import yaml,sys; yaml.safe_load(open('$custom_file'))" 2>&1); then
                    echo ""
                    echo -e "${RED}\u2717 Invalid YAML in custom stack file: ${custom_file}${NC}"
                    echo -e "${RED}${VALIDATION_OUTPUT}${NC}"
                    echo -e "${RED}Deployment aborted. Fix the file or run with --no-custom.${NC}"
                    exit 1
                fi
            fi
            STACK_FILES+=("$custom_file")
            echo -e "${GREEN}  \u2713 Custom stack file detected: ${custom_file}${NC}"
        done
    fi
fi

# Build the -f arguments for docker-compose
COMPOSE_ARGS=""
for file in "${STACK_FILES[@]}"; do
    if [ -f "$file" ]; then
        COMPOSE_ARGS="$COMPOSE_ARGS -f $file"
        echo -e "${GREEN}  ✓ $file${NC}"
    else
        echo -e "${YELLOW}  ⚠ $file not found, skipping${NC}"
    fi
done

# Include external worker stack files
if [ -d "external-workers" ]; then
    EXTERNAL_COUNT=0
    for worker_dir in external-workers/*/; do
        stack_file="${worker_dir}docker-stack.external.yml"
        if [ -f "$stack_file" ]; then
            STACK_FILES+=("$stack_file")
            COMPOSE_ARGS="$COMPOSE_ARGS -f $stack_file"
            WORKER_NAME=$(basename "$worker_dir")
            echo -e "${GREEN}  + external: ${WORKER_NAME}${NC}"
            EXTERNAL_COUNT=$((EXTERNAL_COUNT + 1))
        fi
    done
    if [ "$EXTERNAL_COUNT" -gt 0 ]; then
        echo -e "${GREEN}  ✓ ${EXTERNAL_COUNT} external worker(s) included${NC}"
    fi
fi

# =============================================================================
# Generate UIFusion configuration
# =============================================================================
# We run this AFTER STACK_FILES is finalised so the generator can introspect
# the actual list of services that will be deployed and skip nav entries that
# point at services not present in this deployment.
echo ""
echo -e "${BLUE}Generating UIFusion configuration...${NC}"
if [ -f "scripts/generate/generate-uifusion-config.sh" ]; then
    UIFUSION_ARGS="--force --env $ENV"
    [ "$DEPLOY_IRONSTREAM" = "true" ] && UIFUSION_ARGS="$UIFUSION_ARGS --with-ironstream"
    UIFUSION_STACK_FILES="${STACK_FILES[*]}" \
        bash scripts/generate/generate-uifusion-config.sh $UIFUSION_ARGS
else
    echo -e "${YELLOW}⚠ UIFusion config generator not found, skipping${NC}"
fi

# =============================================================================
# Compose profiles — pick the backup jobs that match the deployment
# =============================================================================
# TIMESERIES_BACKEND drives which timeseries backup job is enabled
# (ts-influx vs ts-timescale). OFFSITE_ENABLED gates backup-offsite.
case "${TIMESERIES_BACKEND:-influx}" in
    influx|influxdb) TS_PROFILE="ts-influx" ;;
    timescale|timescaledb) TS_PROFILE="ts-timescale" ;;
    *)
        echo -e "${YELLOW}⚠ Unknown TIMESERIES_BACKEND='${TIMESERIES_BACKEND}', defaulting to influx${NC}"
        TS_PROFILE="ts-influx"
        ;;
esac
ACTIVE_PROFILES="${TS_PROFILE}"
if [ "${OFFSITE_ENABLED:-false}" = "true" ]; then
    ACTIVE_PROFILES="${ACTIVE_PROFILES},offsite"
fi
export COMPOSE_PROFILES="${ACTIVE_PROFILES}"
echo -e "${BLUE}Compose profiles: ${GREEN}${COMPOSE_PROFILES}${NC}"

# =============================================================================
# Pre-process stack files with envsubst (for ${ENV} in secrets/volumes/networks)
# =============================================================================
echo ""
echo -e "${BLUE}Pre-processing stack files with envsubst...${NC}"

TEMP_DIR=$(mktemp -d)
TEMP_COMPOSE_ARGS=""

for file in "${STACK_FILES[@]}"; do
    if [ -f "$file" ]; then
        temp_file="${TEMP_DIR}/${file}"
        mkdir -p "$(dirname "$temp_file")"
        envsubst < "$file" > "$temp_file"
        TEMP_COMPOSE_ARGS="$TEMP_COMPOSE_ARGS -f $temp_file"
        echo -e "${GREEN}  ✓ Processed: $file${NC}"
    fi
done

# =============================================================================
# Resolve variables and generate final stack file
# =============================================================================
echo ""
echo -e "${BLUE}Generating resolved stack file...${NC}"

RESOLVED_FILE="docker-stack-resolved-${ENV}.yml"
docker compose $TEMP_COMPOSE_ARGS config > "$RESOLVED_FILE"

# Fix paths - replace temp directory with project directory
echo -e "${BLUE}Fixing file paths...${NC}"
sed -i "s|${TEMP_DIR}|${PROJECT_DIR}|g" "$RESOLVED_FILE"

# Clean up temp files
rm -rf "$TEMP_DIR"

# Fix YAML for Swarm compatibility
echo -e "${BLUE}Fixing YAML for Swarm compatibility...${NC}"
if [ -f "scripts/utils/fix-swarm-yaml.py" ]; then
    python3 scripts/utils/fix-swarm-yaml.py "$RESOLVED_FILE"
fi

echo -e "${GREEN}✓ Variables resolved -> $RESOLVED_FILE${NC}"

# Exclude premium services if --exclude flag is provided
if [ -n "$EXCLUDE_SERVICES" ]; then
    echo ""
    echo -e "${BLUE}Excluding premium services (community mode)...${NC}"
    IFS=',' read -ra EXCLUDE_LIST <<< "$EXCLUDE_SERVICES"
    for svc in "${EXCLUDE_LIST[@]}"; do
        svc=$(echo "$svc" | xargs) # trim
        if [ -z "$svc" ]; then continue; fi
        python3 -c "
import yaml, sys
with open('$RESOLVED_FILE') as f:
    data = yaml.safe_load(f)
if 'services' in data and '$svc' in data['services']:
    del data['services']['$svc']
    print('  - removed: $svc')
with open('$RESOLVED_FILE', 'w') as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
"
    done
    echo -e "${GREEN}✓ Premium services excluded${NC}"
fi

# In community mode, route every BSL image through COMMUNITY_REGISTRY.
# Stack files already reference ${COMMUNITY_REGISTRY} / ${ENTERPRISE_REGISTRY}
# directly (per industream-cli/docs/REGISTRY-ARCHITECTURE.md), so no path
# rewriting is needed — the resolved file already points at the public GHCR
# location. We only sanity-check that the resolved file has no leftover
# enterprise references in stacks that should not be loaded.
if [ "$COMMUNITY_MODE" = "true" ]; then
    echo ""
    echo -e "${BLUE}Community mode — verifying registry routing...${NC}"
    ENTERPRISE_HOST="${ENTERPRISE_REGISTRY:-39t88114.c1.gra9.container-registry.ovh.net}"
    # workers-premium.yml is excluded earlier (line ~525). Ironstream is opt-in
    # via --with-ironstream and should never be combined with --community.
    if grep -q "${ENTERPRISE_HOST}/ironstream/" "$RESOLVED_FILE" 2>/dev/null; then
        echo -e "${RED}✗ Community mode cannot include IronStream services${NC}"
        echo -e "${RED}  Remove --with-ironstream or drop --community${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ BSL images route to COMMUNITY_REGISTRY=${COMMUNITY_REGISTRY:-ghcr.io/industream}${NC}"
fi

# =============================================================================
# Check Docker registry authentication
# =============================================================================
REGISTRY="${DOCKER_REGISTRY:-842775dh.c1.gra9.container-registry.ovh.net}"

# Check if credentials exist in docker config
REGISTRY_CREDS_EXIST=false
if [ -f "$HOME/.docker/config.json" ] && grep -q "$REGISTRY" "$HOME/.docker/config.json" 2>/dev/null; then
    REGISTRY_CREDS_EXIST=true
fi

if [ "$COMMUNITY_MODE" = "true" ]; then
    # Community mode pulls anonymously from COMMUNITY_REGISTRY (GHCR).
    # No login required; pull check happens implicitly in the main pull below.
    echo -e "${GREEN}✓ Community mode — anonymous pulls from ${COMMUNITY_REGISTRY:-ghcr.io/industream}${NC}"
elif [ "$REGISTRY_CREDS_EXIST" = "true" ]; then
    # Credentials exist — verify they actually work with a test pull
    echo -e "${BLUE}Verifying registry access to ${REGISTRY}...${NC}"
    # Pick a small known image to test (the UIFusion image is always needed)
    TEST_IMAGE="${REGISTRY}/uifusion/ui:${UIFUSION_VERSION:-latest}"
    if docker pull "$TEST_IMAGE" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Docker registry authenticated and accessible ($REGISTRY)${NC}"
    else
        echo -e "${RED}✗ Registry credentials found but pull failed${NC}"
        echo -e "${YELLOW}  Test image: ${TEST_IMAGE}${NC}"
        echo ""
        echo -e "${YELLOW}Possible causes:${NC}"
        echo "  - Credentials expired (re-login with: docker login ${REGISTRY})"
        echo "  - Image tag does not exist (check UIFUSION_VERSION in .env)"
        echo "  - Network issue (check connectivity)"
        echo ""
        if [ -t 0 ]; then
            read -p "$(echo -e "${YELLOW}Re-login now? [Y/n]: ${NC}")" relogin_choice
        fi
        relogin_choice="${relogin_choice:-Y}"
        if [[ "$relogin_choice" =~ ^[Yy]$ ]]; then
            docker login "$REGISTRY"
            if [ $? -ne 0 ]; then
                echo -e "${RED}✗ Registry login failed${NC}"
                if [ -t 0 ]; then
                    read -p "Continue deployment anyway? [y/N] " continue_choice
                fi
                if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                    exit 1
                fi
            else
                echo -e "${GREEN}✓ Registry login successful${NC}"
            fi
        else
            if [ -t 0 ]; then
                read -p "Continue deployment anyway? [y/N] " continue_choice
            fi
            if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    fi
else
    echo ""
    echo -e "${YELLOW}⚠ Not logged in to Docker registry: ${REGISTRY}${NC}"
    echo -e "${BLUE}Registry login is required to pull private images.${NC}"
    echo ""
    if [ -t 0 ]; then
        read -p "Do you want to log in now? [Y/n] " login_choice
    fi
    login_choice="${login_choice:-Y}"
    if [[ "$login_choice" =~ ^[Yy]$ ]]; then
        echo ""
        docker login "$REGISTRY"
        if [ $? -ne 0 ]; then
            echo -e "${RED}✗ Registry login failed${NC}"
            if [ -t 0 ]; then
                read -p "Continue deployment anyway? [y/N] " continue_choice
            fi
            if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                exit 1
            fi
        else
            echo -e "${GREEN}✓ Registry login successful${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ Skipping registry login. Image pulls may fail for private images.${NC}"
    fi
fi
echo ""

# =============================================================================
# Resource check
# =============================================================================
echo ""
if [ "$SKIP_MEMORY_CHECK" = true ]; then
    echo -e "${YELLOW}⚠ Memory check skipped (--skip-memory-check)${NC}"
else
    echo -e "${BLUE}Checking system resources...${NC}"

    # Calculate total memory reservations from the resolved stack file
    TOTAL_RESERVED_MB=$(python3 -c "
import yaml, sys
try:
    with open('$RESOLVED_FILE') as f:
        data = yaml.safe_load(f)
    total = 0
    for svc in data.get('services', {}).values():
        mem = svc.get('deploy', {}).get('resources', {}).get('reservations', {}).get('memory')
        if mem:
            mem = str(mem).strip().strip(chr(39)).strip(chr(34))
            if mem.endswith('G'):
                total += float(mem[:-1]) * 1024
            elif mem.endswith('M'):
                total += float(mem[:-1])
            elif mem.endswith('K'):
                total += float(mem[:-1]) / 1024
            else:
                total += float(mem) / 1024 / 1024
    print(int(total))
except Exception as e:
    print(0, file=sys.stderr)
    print(0)
" 2>/dev/null)

    # Get available system memory (total - ~512MB OS overhead)
    TOTAL_SYSTEM_MB=$(free -m | awk '/Mem:/ {print $2}')
    AVAILABLE_MB=$((TOTAL_SYSTEM_MB - 512))
    SYSTEM_CPUS=$(nproc)

    # Already reserved by running containers from other stacks
    # Note: Use docker inspect to get explicit memory limits (MemoryReservation or Memory).
    # docker stats shows host total RAM as "limit" for unlimited containers, which inflates the count.
    ALREADY_RESERVED_MB=$(docker inspect --format '{{.HostConfig.MemoryReservation}} {{.HostConfig.Memory}}' $(docker ps -q 2>/dev/null) 2>/dev/null | awk '{
        # Use MemoryReservation if set, otherwise Memory limit; skip if both are 0 (unlimited)
        val = ($1 > 0) ? $1 : $2
        if (val > 0) t += val / 1024 / 1024
    } END { printf "%d", t }')

    # Check if this is the same stack being redeployed (update) or a new one
    EXISTING_STACK_MB=0
    if docker stack ls --format "{{.Name}}" 2>/dev/null | grep -q "^${STACK_NAME}$"; then
        EXISTING_STACK_MB=$(docker inspect --format '{{.Name}} {{.HostConfig.MemoryReservation}} {{.HostConfig.Memory}}' $(docker ps -q 2>/dev/null) 2>/dev/null | grep "/${STACK_NAME}_" | awk '{
            val = ($2 > 0) ? $2 : $3
            if (val > 0) t += val / 1024 / 1024
        } END { printf "%d", t }')
    fi

    # Net new memory needed
    OTHER_STACKS_MB=$((ALREADY_RESERVED_MB - EXISTING_STACK_MB))
    NEEDED_MB=$((TOTAL_RESERVED_MB + OTHER_STACKS_MB))

    TOTAL_RESERVED_GB=$(echo "scale=1; ${TOTAL_RESERVED_MB} / 1024" | bc)
    AVAILABLE_GB=$(echo "scale=1; ${AVAILABLE_MB} / 1024" | bc)
    NEEDED_GB=$(echo "scale=1; ${NEEDED_MB} / 1024" | bc)

    echo -e "  System:     ${BOLD}${SYSTEM_CPUS} CPUs, ${TOTAL_SYSTEM_MB} MiB RAM${NC}"
    echo -e "  Available:  ${BOLD}${AVAILABLE_GB} GiB${NC} (after OS overhead)"
    if [ "$OTHER_STACKS_MB" -gt 0 ]; then
        OTHER_GB=$(echo "scale=1; ${OTHER_STACKS_MB} / 1024" | bc)
        echo -e "  Other stacks: ${BOLD}${OTHER_GB} GiB${NC} reserved"
    fi
    echo -e "  This stack: ${BOLD}${TOTAL_RESERVED_GB} GiB${NC} reserved"
    echo -e "  Total needed: ${BOLD}${NEEDED_GB} GiB${NC}"

    if [ "$NEEDED_MB" -gt "$AVAILABLE_MB" ]; then
        DEFICIT_GB=$(echo "scale=1; (${NEEDED_MB} - ${AVAILABLE_MB}) / 1024" | bc)
        RECOMMENDED_MB=$((NEEDED_MB + 1024))
        RECOMMENDED_GB=$(echo "scale=1; ${RECOMMENDED_MB} / 1024" | bc)
        echo ""
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  ⚠  LOW MEMORY: ${DEFICIT_GB} GiB short of recommended                    ║${NC}"
        echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${YELLOW}║  Recommended: ${RECOMMENDED_GB} GiB RAM for this configuration              ║${NC}"
        echo -e "${YELLOW}║  Some services may fail to start (pending state).           ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}Proceeding with deployment (use --skip-memory-check to hide this warning)...${NC}"
    else
        echo -e "${GREEN}✓ Sufficient resources available${NC}"
    fi
fi

# =============================================================================
# Pre-pull images
# =============================================================================
echo ""
echo -e "${BLUE}Checking container images...${NC}"

# Extract unique images from the resolved stack file
IMAGES=$(python3 -c "
import yaml, sys
with open('$RESOLVED_FILE') as f:
    data = yaml.safe_load(f)
seen = set()
for svc in data.get('services', {}).values():
    img = svc.get('image', '')
    if img and img not in seen:
        seen.add(img)
        print(img)
" 2>/dev/null | sort)

TOTAL_IMAGES=$(echo "$IMAGES" | wc -l)
AVAILABLE=0
MISSING_IMAGES=()

for img in $IMAGES; do
    if docker image inspect "$img" >/dev/null 2>&1; then
        AVAILABLE=$((AVAILABLE + 1))
    else
        MISSING_IMAGES+=("$img")
    fi
done

echo -e "${BLUE}  Images available locally: ${AVAILABLE}/${TOTAL_IMAGES}${NC}"

if [ ${#MISSING_IMAGES[@]} -gt 0 ]; then
    echo -e "${YELLOW}  ${#MISSING_IMAGES[@]} image(s) need to be pulled from registry${NC}"
    echo ""

    PULL_ERRORS=()
    PULL_OK=0
    PULL_INDEX=0

    for img in "${MISSING_IMAGES[@]}"; do
        PULL_INDEX=$((PULL_INDEX + 1))
        # Extract short name for display (last 2 path segments + tag)
        SHORT_IMG=$(echo "$img" | rev | cut -d'/' -f1-2 | rev)
        echo -ne "\r${BLUE}  Pulling [${PULL_INDEX}/${#MISSING_IMAGES[@]}] ${SHORT_IMG}...${NC}                    "

        if docker pull "$img" >/dev/null 2>&1; then
            PULL_OK=$((PULL_OK + 1))
        else
            PULL_ERRORS+=("$img")
        fi
    done
    echo ""

    # Retry failed pulls (network timeouts are common on first install)
    if [ ${#PULL_ERRORS[@]} -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}  ${#PULL_ERRORS[@]} image(s) failed — retrying...${NC}"
        RETRY_ERRORS=()
        for img in "${PULL_ERRORS[@]}"; do
            SHORT_IMG=$(echo "$img" | sed "s|.*${REGISTRY}/||")
            echo -ne "\r${BLUE}  Retrying ${SHORT_IMG}...${NC}                    "
            if docker pull "$img" >/dev/null 2>&1; then
                PULL_OK=$((PULL_OK + 1))
            else
                RETRY_ERRORS+=("$img")
            fi
        done
        echo ""
        PULL_ERRORS=("${RETRY_ERRORS[@]}")
    fi

    if [ ${#PULL_ERRORS[@]} -gt 0 ]; then
        echo ""
        echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  ⚠  ${#PULL_ERRORS[@]} image(s) failed to pull (after retry)                ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
        for err_img in "${PULL_ERRORS[@]}"; do
            echo -e "${RED}  ✗ ${err_img}${NC}"
        done
        echo ""
        echo -e "${YELLOW}Possible causes:${NC}"
        echo "  - Not logged in to the registry (run: docker login ${REGISTRY})"
        echo "  - Image tag does not exist (check versions in .env)"
        echo "  - Network issue (check connectivity to ${REGISTRY})"
        echo ""
        if [ -t 0 ]; then
            read -p "$(echo -e "${YELLOW}Continue deployment anyway? [y/N]: ${NC}")" CONTINUE_PULL
        fi
        if [[ ! "$CONTINUE_PULL" =~ ^[Yy]$ ]]; then
            echo -e "${RED}Deployment aborted.${NC}"
            exit 1
        fi
        echo -e "${YELLOW}Proceeding with missing images (affected services will stay pending)...${NC}"
    else
        echo -e "${GREEN}✓ All ${PULL_OK} image(s) pulled successfully${NC}"
    fi
else
    echo -e "${GREEN}✓ All images available locally${NC}"
fi

# =============================================================================
# Deploy stack
# =============================================================================
echo ""
echo -e "${BLUE}Deploying stack '${STACK_NAME}'...${NC}"
docker stack deploy -c "$RESOLVED_FILE" --with-registry-auth --prune --detach "$STACK_NAME"

# =============================================================================
# Wait for core services before workers can connect
# =============================================================================
echo ""
echo -e "${BLUE}Waiting for FlowMaker core services to be ready...${NC}"

wait_for_service() {
    local service_name="$1"
    local max_attempts="${2:-60}"
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        # Check if service has at least one running replica
        local running=$(docker service ls --filter "name=${STACK_NAME}_${service_name}" --format "{{.Replicas}}" 2>/dev/null | cut -d'/' -f1)
        local desired=$(docker service ls --filter "name=${STACK_NAME}_${service_name}" --format "{{.Replicas}}" 2>/dev/null | cut -d'/' -f2)

        if [ -n "$running" ] && [ "$running" -gt 0 ] && [ "$running" = "$desired" ]; then
            echo -e "${GREEN}  ✓ ${service_name} is ready (${running}/${desired})${NC}"
            return 0
        fi

        attempt=$((attempt + 1))
        echo -e "${YELLOW}  Waiting for ${service_name}... (${attempt}/${max_attempts})${NC}"
        sleep 2
    done

    echo -e "${YELLOW}  ⚠ ${service_name} not ready after ${max_attempts} attempts${NC}"
    return 1
}

# Wait for scheduler and logging service (critical for workers)
wait_for_service "flowmaker-scheduler" 60
wait_for_service "flowmaker-logging" 60

# Give services a moment to fully initialize their DNS entries
echo -e "${BLUE}Waiting for DNS propagation...${NC}"
sleep 5

# Force restart workers to ensure they connect properly
echo -e "${BLUE}Restarting workers to ensure proper connection...${NC}"
WORKER_PIDS=()
for worker in $(docker service ls --filter "name=${STACK_NAME}_worker-" --format "{{.Name}}"); do
    timeout 60 docker service update --force "$worker" >/dev/null 2>&1 &
    WORKER_PIDS+=($!)
done
# Wait with overall timeout (90s max)
WAIT_START=$SECONDS
while [ ${#WORKER_PIDS[@]} -gt 0 ] && [ $((SECONDS - WAIT_START)) -lt 90 ]; do
    NEW_PIDS=()
    for pid in "${WORKER_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            NEW_PIDS+=("$pid")
        fi
    done
    WORKER_PIDS=("${NEW_PIDS[@]}")
    [ ${#WORKER_PIDS[@]} -gt 0 ] && sleep 2
done
# Kill any remaining
for pid in "${WORKER_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
done
echo -e "${GREEN}✓ Workers restarted${NC}"

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ ${ENV^^} environment deployed successfully!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"

# =============================================================================
# EE: auto-register Logto OIDC apps from service labels (io.industream.logto.*)
# =============================================================================
# The label-driven seeder writes OIDC apps straight into logto-postgres (no
# Management API / M2M). It ships INSIDE the EE Hub-backend image
# (api-enterprise → /app/oidc-seeds/) — present in EE only, never in CE — so we
# extract it from the running container at deploy time. A vendored copy under
# scripts/setup/ takes precedence if present. Best-effort: waits briefly for
# Logto, never fails the deploy. (API resources + RBAC roles still come from
# seed-logto.sh, which needs a Management-API M2M app.)
if [ "$WITH_EE_OVERLAY" = "true" ]; then
    SEEDER="${SCRIPT_DIR}/setup/seed-logto-stack.sh"
    if [ ! -f "$SEEDER" ]; then
        # Not vendored → extract from the EE Hub-backend container to a temp file
        # (never write into the repo working tree).
        _hub_cid=$(docker ps -q \
            --filter "label=com.docker.swarm.service.name=${STACK_NAME}_uifusion-api" | head -1)
        if [ -n "$_hub_cid" ]; then
            SEEDER="$(mktemp -d)/seed-logto-stack.sh"
            docker cp "${_hub_cid}:/app/oidc-seeds/logto/seed-logto-stack.sh" "$SEEDER" 2>/dev/null \
                || SEEDER=""
        else
            SEEDER=""
        fi
    fi

    if [ -n "$SEEDER" ] && [ -f "$SEEDER" ]; then
        echo ""
        echo -e "${BLUE}EE: registering Logto OIDC apps from service labels...${NC}"
        # Best-effort Logto readiness wait (OIDC discovery endpoint, internal net).
        for _i in $(seq 1 30); do
            docker run --rm --network "${STACK_NAME}_${ENV}-platform" curlimages/curl:8.9.1 \
                -sf -o /dev/null --max-time 3 \
                "http://logto:3001/oidc/.well-known/openid-configuration" 2>/dev/null && break
            sleep 4
        done
        if SWARM_STACK="$STACK_NAME" bash "$SEEDER" --runtime swarm --stack "$STACK_NAME"; then
            echo -e "${GREEN}✓ Logto OIDC apps registered${NC}"
        else
            echo -e "${YELLOW}⚠ Logto app registration failed (non-fatal — re-run seed-logto-stack.sh manually)${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ seed-logto-stack.sh unavailable (no vendored copy + EE image lacks /app/oidc-seeds/) — Logto OIDC apps not auto-registered.${NC}"
    fi
fi

# =============================================================================
# Register Hub launchpad apps (CE + EE) — populates the menu AND the auth-bridge
# origin allowlist served at uifusion-api:3050/origins.
# =============================================================================
# The SharedWorker auth bridge only relays the Hub token to app origins that are
# in the allowlist, which the Hub-backend derives from its registered apps.
# Without this step the allowlist holds only the shell origin, so a sibling app
# served on its own subdomain — e.g. Grafana behind the grafana-hub-wrapper at
# dashboard.${INDUSTREAM_DOMAIN} (--with-grafana-sso) — is refused with
# "this application origin is not allowed to use Industream authentication" and
# SSO fails. Edition-agnostic: the launchpad + bridge exist in both CE and EE,
# and the seeder posts to the Hub-backend's container-local free-vend port 3051
# (no JWT). Prefers the vendored copy; falls back to extracting it from the
# Hub-backend image. Best-effort — never fails the deploy.
MENU_SEEDER="${SCRIPT_DIR}/setup/seed-menu-apps-stack.sh"
if [ ! -f "$MENU_SEEDER" ]; then
    _hub_cid=$(docker ps -q \
        --filter "label=com.docker.swarm.service.name=${STACK_NAME}_uifusion-api" | head -1)
    if [ -n "$_hub_cid" ]; then
        MENU_SEEDER="$(mktemp -d)/seed-menu-apps-stack.sh"
        docker cp "${_hub_cid}:/app/menu-seeds/seed-menu-apps-stack.sh" "$MENU_SEEDER" 2>/dev/null \
            || MENU_SEEDER=""
    else
        MENU_SEEDER=""
    fi
fi

if [ -n "$MENU_SEEDER" ] && [ -f "$MENU_SEEDER" ]; then
    echo ""
    echo -e "${BLUE}Registering Hub launchpad apps (menu + auth-bridge origin allowlist)...${NC}"
    # Brief readiness wait: the Hub-backend may still be rolling. The seeder
    # execs into the container and posts to localhost:3051, so wait until the
    # task is running, then let the internal free-vend port settle.
    for _i in $(seq 1 15); do
        _hub_cid=$(docker ps -q \
            --filter "label=com.docker.swarm.service.name=${STACK_NAME}_uifusion-api" | head -1)
        [ -n "$_hub_cid" ] && break
        sleep 2
    done
    [ -n "$_hub_cid" ] && sleep 3
    if bash "$MENU_SEEDER" --domain "$INDUSTREAM_DOMAIN" --runtime swarm --stack "$STACK_NAME"; then
        echo -e "${GREEN}✓ Hub launchpad apps registered${NC}"
    else
        echo -e "${YELLOW}⚠ Hub launchpad app registration failed (non-fatal — re-run seed-menu-apps-stack.sh manually)${NC}"
    fi
else
    echo -e "${YELLOW}⚠ seed-menu-apps-stack.sh unavailable (no vendored copy + Hub image lacks /app/menu-seeds/) — launchpad + Grafana SSO origins not registered.${NC}"
fi

# =============================================================================
# Display demo information if deployed
# =============================================================================
if [ "$DEPLOY_DEMO" = "true" ]; then
    echo ""
    echo -e "${GREEN}✓ Demo simulators deployed!${NC}"
    echo ""
    echo -e "${BLUE}Demo endpoints:${NC}"
    echo "  OPC-UA:    opc.tcp://${INDUSTREAM_SERVER_IP}:50000"
    echo "  MQTT:      ${INDUSTREAM_SERVER_IP}:1883 (WebSocket: 9001)"
    echo "  S7:        ${INDUSTREAM_SERVER_IP}:102"
    echo "  Modbus:    ${INDUSTREAM_SERVER_IP}:5020"
    echo ""
    echo -e "${BLUE}MQTT Topics:${NC}"
    echo "  industream/demo/eaf           # Electric Arc Furnace"
    echo "  industream/demo/blast_furnace # Blast Furnace"
    echo "  industream/demo/energy        # Energy Meters"
fi

# =============================================================================
# Display information
# =============================================================================
echo ""
echo -e "${BLUE}Environment URLs:${NC}"
echo "  Main portal:    https://${INDUSTREAM_DOMAIN}"
echo "  Keycloak:       https://${INDUSTREAM_DOMAIN}/auth"
echo "  Dashboard:      https://dashboard.${INDUSTREAM_DOMAIN}"
echo "  FlowMaker:      https://flowmaker.${INDUSTREAM_DOMAIN}"
echo "  DataCatalog:    https://datacatalog.${INDUSTREAM_DOMAIN}"
echo ""
echo -e "${BLUE}/etc/hosts (copy-paste on your workstation):${NC}"
SERVER_IP="${INDUSTREAM_SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
HOSTS_SUBDOMAINS="dashboard grafana flowmaker confighub scheduler logger datacatalog datacatalog-api datacatalog-ui databridge databridge-pg traefik influxdb timeseries prometheus alertmanager ntfy npm cdn minio s3 ironstream backups workers"
HOSTS_LINE="${SERVER_IP} ${INDUSTREAM_DOMAIN}"
for sub in $HOSTS_SUBDOMAINS; do
    HOSTS_LINE="${HOSTS_LINE} ${sub}.${INDUSTREAM_DOMAIN}"
done
echo ""
echo -e "  ${BOLD}${HOSTS_LINE}${NC}"
echo ""

# Show certificate info for self-signed mode
if [ "${TLS_MODE:-selfsigned}" = "selfsigned" ]; then
    CERT_FILE="certs/${INDUSTREAM_DOMAIN}.crt"
    if [ -f "$CERT_FILE" ]; then
        echo -e "${BLUE}Self-signed certificate (import in your browser to avoid warnings):${NC}"
        echo ""
        echo -e "  ${BOLD}scp ${USER}@${SERVER_IP}:$(pwd)/${CERT_FILE} ~/Downloads/${NC}"
        echo ""
        echo -e "  Then import ${BOLD}${INDUSTREAM_DOMAIN}.crt${NC}:"
        echo "    Chrome/Edge : Settings → Privacy → Security → Manage certificates → Authorities → Import"
        echo "    Firefox     : Settings → Privacy → Certificates → View Certificates → Authorities → Import"
        echo "    macOS       : double-click .crt → Keychain Access → Always Trust"
        echo "    Linux       : sudo cp ${INDUSTREAM_DOMAIN}.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates"
        echo ""
    else
        echo -e "${YELLOW}⚠ No certificate found at ${CERT_FILE}${NC}"
        echo -e "  Generate one with: ${BOLD}./scripts/generate/generate-certs.sh${NC}"
        echo ""
    fi
fi

# Show credentials (from secrets directory)
# By default, only the path is printed. Passwords are shown only when
# --show-credentials is passed (prevents secrets leaking into deploy logs,
# CI output, terminal scrollback, etc.).
SECRETS_DIR="$(pwd)/secrets/${ENV}"
if [ ! -d "$SECRETS_DIR" ]; then
    # Fallback to legacy flat layout
    SECRETS_DIR="$(pwd)/secrets"
fi

if [ -d "$SECRETS_DIR" ]; then
    if [ "$SHOW_CREDENTIALS" = "true" ]; then
        echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  ⚠  CREDENTIALS - KEEP THESE SAFE, DO NOT SHARE OR COMMIT!     ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${BLUE}PostgreSQL${NC}"
        echo -e "    User:     ${BOLD}${POSTGRES_ADMIN_USER:-postgres}${NC}"
        echo -e "    Password: ${BOLD}$(cat "$SECRETS_DIR/postgres_admin_password" 2>/dev/null || echo 'N/A')${NC}"
        echo ""
        echo -e "  ${BLUE}Hub Backend (JWT auth)${NC}"
        echo -e "    User:     ${BOLD}$(cat "$SECRETS_DIR/hub_backend_admin_user" 2>/dev/null || echo 'admin')${NC}"
        echo -e "    Password: ${BOLD}$(cat "$SECRETS_DIR/hub_backend_admin_password" 2>/dev/null || echo 'N/A')${NC}"
        echo ""
        echo -e "  ${BLUE}Grafana${NC}"
        echo -e "    User:     ${BOLD}${GRAFANA_ADMIN_USER:-admin}${NC}"
        echo -e "    Password: ${BOLD}$(cat "$SECRETS_DIR/grafana_admin_password" 2>/dev/null || echo 'N/A')${NC}"
        echo ""
        echo -e "  ${BLUE}InfluxDB${NC}"
        echo -e "    User:     ${BOLD}${INFLUX_ADMIN_USERNAME:-admin}${NC}"
        echo -e "    Password: ${BOLD}$(cat "$SECRETS_DIR/influx_admin_password" 2>/dev/null || echo 'N/A')${NC}"
        echo -e "    Token:    ${BOLD}$(cat "$SECRETS_DIR/influx_admin_token" 2>/dev/null || echo 'N/A')${NC}"
        echo ""
        echo -e "  ${BLUE}MinIO${NC}"
        echo -e "    User:     ${BOLD}$(cat "$SECRETS_DIR/minio_root_user" 2>/dev/null || echo 'admin')${NC}"
        echo -e "    Password: ${BOLD}$(cat "$SECRETS_DIR/minio_root_password" 2>/dev/null || echo 'N/A')${NC}"
        echo ""
        echo -e "  ${YELLOW}Secrets stored in: ${SECRETS_DIR}/${NC}"
        echo -e "  ${YELLOW}To regenerate: ./scripts/setup/create-secrets.sh --env ${ENV} --regenerate${NC}"
        echo ""
    else
        echo -e "${BLUE}Admin credentials${NC}"
        echo -e "  Saved at: ${BOLD}${SECRETS_DIR}/${NC} (chmod 600)"
        echo -e "  ${DIM}Re-run with --show-credentials to print them to stdout${NC}"
        echo -e "  ${DIM}Or read individual files, e.g.: cat ${SECRETS_DIR}/hub_backend_admin_password${NC}"
        echo ""
    fi
fi

# =============================================================================
# SEED CONFIGHUB - Environment variables & Scheduler
# =============================================================================
"$SCRIPT_DIR/setup/seed-confighub.sh" \
    --stack "$STACK_NAME" \
    --domain "$INDUSTREAM_DOMAIN"

echo ""
echo -e "${BLUE}Useful commands:${NC}"
echo "  docker stack services $STACK_NAME      # List services"
echo "  docker stack ps $STACK_NAME            # List tasks"
echo "  docker service logs ${STACK_NAME}_<service>  # View logs"
echo "  docker stack rm $STACK_NAME            # Remove stack"
if [ "$DEPLOY_DEMO" = "true" ]; then
    echo ""
    echo -e "${BLUE}Demo services:${NC}"
    echo "  docker service logs ${STACK_NAME}_industrial-simulator  # Simulator logs"
    echo "  docker service logs ${STACK_NAME}_mqtt-broker           # MQTT broker logs"
fi
echo ""
