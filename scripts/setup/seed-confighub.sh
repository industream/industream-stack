#!/bin/bash
# =============================================================================
# SEED CONFIGHUB - Set environment variables and scheduler after deployment
# =============================================================================
# Usage:
#   ./scripts/setup/seed-confighub.sh --stack industream-dev --domain dev.industream.platform.lan
#   ./scripts/setup/seed-confighub.sh --stack industream-prod --domain industream.platform.lan
# =============================================================================

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# Parse arguments
STACK_NAME=""
DOMAIN=""
MAX_WAIT=120

while [[ $# -gt 0 ]]; do
    case $1 in
        --stack) STACK_NAME="$2"; shift 2 ;;
        --domain) DOMAIN="$2"; shift 2 ;;
        --timeout) MAX_WAIT="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$STACK_NAME" ] || [ -z "$DOMAIN" ]; then
    echo -e "${RED}Usage: $0 --stack <stack-name> --domain <domain>${NC}"
    echo "  Example: $0 --stack industream-dev --domain dev.industream.platform.lan"
    exit 1
fi

# URLs derived from domain (aligned with fm CLI conventions)
CONFIGHUB_EXTERNAL_URL="https://confighub.${DOMAIN}"
CONFIGHUB_INTERNAL_URL="http://flowmaker-confighub:4000"
CDN_URL="https://cdn.${DOMAIN}"
DATACATALOG_URL="https://datacatalog.${DOMAIN}"
SCHEDULER_URL="https://scheduler.${DOMAIN}"
LOGGER_URL="https://logger.${DOMAIN}"

echo ""
echo -e "${BLUE}Seeding FlowMaker ConfigHub for ${BOLD}${STACK_NAME}${NC}${BLUE}...${NC}"
echo ""
echo -e "  environment/cdn          = ${CDN_URL}"
echo -e "  environment/confighub    = {\"url\": \"${CONFIGHUB_EXTERNAL_URL}\", \"internalUrl\": \"${CONFIGHUB_INTERNAL_URL}\"}"
echo -e "  environment/datacatalog  = {\"url\": \"${DATACATALOG_URL}\"}"
echo -e "  Scheduler 1              = ${SCHEDULER_URL} (logger: ${LOGGER_URL})"
echo ""

# Wait for ConfigHub container to be ready
CONFIGHUB_CONTAINER=""
ATTEMPTS=$((MAX_WAIT / 5))
for i in $(seq 1 "$ATTEMPTS"); do
    CONFIGHUB_CONTAINER=$(docker ps --format '{{.Names}}' | grep "${STACK_NAME}_flowmaker-confighub\." | head -1)
    if [ -n "$CONFIGHUB_CONTAINER" ]; then
        if docker exec "$CONFIGHUB_CONTAINER" wget -q --spider http://localhost:4000/ 2>/dev/null; then
            echo -e "  ${GREEN}✓ ConfigHub is ready${NC}"
            break
        fi
    fi
    echo -e "  ${YELLOW}Waiting for ConfigHub... (${i}/${ATTEMPTS})${NC}"
    sleep 5
done

if [ -z "$CONFIGHUB_CONTAINER" ]; then
    echo -e "  ${RED}✗ ConfigHub not found after ${MAX_WAIT}s${NC}"
    echo -e "  ${YELLOW}Run this script again once the stack is up:${NC}"
    echo -e "    ${BOLD}$0 --stack ${STACK_NAME} --domain ${DOMAIN}${NC}"
    exit 1
fi

# --- Seed environment variables ---
echo ""
echo -e "${BLUE}Setting environment variables...${NC}"

# Build JSON payload inside container (no jq dependency on host needed)
docker exec "$CONFIGHUB_CONTAINER" sh -c "
    DATACATALOG_JSON='{\"url\":\"${DATACATALOG_URL}\"}'
    CONFIGHUB_JSON='{\"url\":\"${CONFIGHUB_EXTERNAL_URL}\",\"internalUrl\":\"${CONFIGHUB_INTERNAL_URL}\"}'

    # Escape inner JSON for the payload (values must be JSON strings)
    DATACATALOG_ESCAPED=\$(echo \"\$DATACATALOG_JSON\" | sed 's/\"/\\\\\"/g')
    CONFIGHUB_ESCAPED=\$(echo \"\$CONFIGHUB_JSON\" | sed 's/\"/\\\\\"/g')

    PAYLOAD=\"{\\\"environment/cdn\\\":\\\"${CDN_URL}\\\",\\\"environment/confighub\\\":\\\"\${CONFIGHUB_ESCAPED}\\\",\\\"environment/datacatalog\\\":\\\"\${DATACATALOG_ESCAPED}\\\"}\"

    wget -q --post-data=\"\$PAYLOAD\" \
        --header='Content-Type: application/json' \
        -O /dev/null \
        'http://localhost:4000/environments'
" 2>/dev/null

if [ $? -eq 0 ]; then
    echo -e "  ${GREEN}✓ environment/cdn = ${CDN_URL}${NC}"
    echo -e "  ${GREEN}✓ environment/confighub set${NC}"
    echo -e "  ${GREEN}✓ environment/datacatalog set${NC}"
else
    echo -e "  ${RED}✗ Failed to seed environment variables${NC}"
fi

# --- Create scheduler ---
echo ""
echo -e "${BLUE}Creating scheduler...${NC}"

SCHEDULER_PAYLOAD="{\"name\":\"Scheduler 1\",\"url\":\"${SCHEDULER_URL}\",\"logServerUrl\":\"${LOGGER_URL}\",\"color\":\"lightskyblue\",\"isDefault\":true}"

HTTP_RESPONSE=$(docker exec "$CONFIGHUB_CONTAINER" wget -q \
    --post-data="$SCHEDULER_PAYLOAD" \
    --header='Content-Type: application/json' \
    -S -O /dev/null \
    'http://localhost:4000/schedulers' 2>&1 | grep "HTTP/" | tail -1 | awk '{print $2}')

case "$HTTP_RESPONSE" in
    201)
        echo -e "  ${GREEN}✓ Scheduler 1 created (${SCHEDULER_URL})${NC}"
        ;;
    409)
        echo -e "  ${YELLOW}Scheduler 1 already exists, updating...${NC}"
        docker exec "$CONFIGHUB_CONTAINER" wget -q \
            --method=PUT \
            --body-data="$SCHEDULER_PAYLOAD" \
            --header='Content-Type: application/json' \
            -O /dev/null \
            'http://localhost:4000/schedulers/Scheduler%201' 2>/dev/null \
            && echo -e "  ${GREEN}✓ Scheduler 1 updated${NC}" \
            || echo -e "  ${YELLOW}⚠ Failed to update scheduler${NC}"
        ;;
    *)
        echo -e "  ${RED}✗ Failed to create scheduler (HTTP ${HTTP_RESPONSE})${NC}"
        ;;
esac

echo ""
echo -e "${GREEN}ConfigHub seeding complete.${NC}"
echo ""
