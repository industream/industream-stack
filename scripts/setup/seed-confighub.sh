#!/bin/bash
# =============================================================================
# SEED CONFIGHUB - Set environment variables and scheduler after deployment
# =============================================================================
# Usage:
#   ./scripts/setup/seed-confighub.sh --domain <domain> --runtime swarm   --stack   industream-prod
#   ./scripts/setup/seed-confighub.sh --domain <domain> --runtime compose --project fm-dev
# (--stack implies --runtime swarm, --project implies --runtime compose, for back-compat.)
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
COMPOSE_PROJECT=""
RUNTIME="swarm"          # default; --stack/--project set it explicitly below
DOMAIN=""
MAX_WAIT=120

while [[ $# -gt 0 ]]; do
    case $1 in
        --runtime) RUNTIME="$2"; shift 2 ;;
        --stack)   STACK_NAME="$2"; RUNTIME="swarm"; shift 2 ;;
        --project) COMPOSE_PROJECT="$2"; RUNTIME="compose"; shift 2 ;;
        --domain)  DOMAIN="$2"; shift 2 ;;
        --timeout) MAX_WAIT="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}Usage: $0 --domain <domain> (--runtime swarm --stack <name> | --runtime compose --project <name>)${NC}"
    exit 1
fi
case "$RUNTIME" in
    swarm)   [ -z "$STACK_NAME" ]      && { echo -e "${RED}✗ --runtime swarm requires --stack <name>${NC}" >&2; exit 1; } ;;
    compose) [ -z "$COMPOSE_PROJECT" ] && { echo -e "${RED}✗ --runtime compose requires --project <name>${NC}" >&2; exit 1; } ;;
    *) echo -e "${RED}✗ Unknown --runtime '$RUNTIME' (expected: swarm|compose)${NC}" >&2; exit 1 ;;
esac

# URLs derived from domain (aligned with fm CLI conventions)
CONFIGHUB_EXTERNAL_URL="https://confighub.${DOMAIN}"
CONFIGHUB_INTERNAL_URL="http://flowmaker-confighub:4000"
CDN_URL="https://cdn.${DOMAIN}"
# The datacatalog ENV var flows consume is the DataCatalog *API* — served at the
# datacatalog-api.<domain> host on both runtimes (datacatalog.<domain> is the UI).
DATACATALOG_URL="https://datacatalog-api.${DOMAIN}"
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

# Helper: run a Node.js HTTP request inside the confighub container.
# Usage: confighub_request <method> <path> [json_body]
#
# SECURITY: all inputs (method, path, body) are passed via environment
# variables, NOT interpolated into the Node source. The Node script below is
# a STATIC string — no user-controlled value ever becomes code. The body,
# when provided, must already be a JSON string (we do NOT eval it).
confighub_request() {
    local method="$1"
    local path="$2"
    local body="$3"

    # Static Node script — never templated with user data.
    local node_script='
const http = require("http");
const method = process.env.CH_METHOD;
const path = process.env.CH_PATH;
const body = process.env.CH_BODY || "";
const options = {
    hostname: "localhost",
    port: 4000,
    path: path,
    method: method,
    headers: { "Content-Type": "application/json" }
};
const req = http.request(options, (res) => {
    res.on("data", () => {});
    res.on("end", () => { process.stdout.write(String(res.statusCode)); });
});
req.on("error", (e) => { process.stderr.write(e.message); process.exit(1); });
if (body.length > 0) { req.write(body); }
req.end();
'

    docker exec \
        -e CH_METHOD="$method" \
        -e CH_PATH="$path" \
        -e CH_BODY="$body" \
        "$CONFIGHUB_CONTAINER" node -e "$node_script" 2>/dev/null
}

# Wait for ConfigHub container to be ready
CONFIGHUB_CONTAINER=""
ATTEMPTS=$((MAX_WAIT / 5))
for i in $(seq 1 "$ATTEMPTS"); do
    # Resolve the confighub container by orchestrator label (swarm or compose).
    if [ "$RUNTIME" = swarm ]; then
        CONFIGHUB_CONTAINER=$(docker ps -q \
            --filter "label=com.docker.swarm.service.name=${STACK_NAME}_flowmaker-confighub" | head -1)
    else
        CONFIGHUB_CONTAINER=$(docker ps -q \
            --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
            --filter "label=com.docker.compose.service=flowmaker-confighub" | head -1)
    fi
    if [ -n "$CONFIGHUB_CONTAINER" ]; then
        HEALTH=$(confighub_request "GET" "/" 2>/dev/null || true)
        if [ -n "$HEALTH" ]; then
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
    if [ "$RUNTIME" = swarm ]; then
        echo -e "    ${BOLD}$0 --domain ${DOMAIN} --runtime swarm --stack ${STACK_NAME}${NC}"
    else
        echo -e "    ${BOLD}$0 --domain ${DOMAIN} --runtime compose --project ${COMPOSE_PROJECT}${NC}"
    fi
    exit 1
fi

# --- Seed environment variables ---
echo ""
echo -e "${BLUE}Setting environment variables...${NC}"

# Build the JSON payload via `node` inside the container so that URL values
# get properly JSON-escaped without shell-string interpolation into code.
# All URL values are passed via environment vars; the Node script below is
# static and never embeds user-controlled text.
ENV_BODY=$(docker exec \
    -e CDN_URL="$CDN_URL" \
    -e CONFIGHUB_EXTERNAL_URL="$CONFIGHUB_EXTERNAL_URL" \
    -e CONFIGHUB_INTERNAL_URL="$CONFIGHUB_INTERNAL_URL" \
    -e DATACATALOG_URL="$DATACATALOG_URL" \
    "$CONFIGHUB_CONTAINER" node -e '
const payload = {
    "environment/cdn": process.env.CDN_URL,
    "environment/confighub": JSON.stringify({
        url: process.env.CONFIGHUB_EXTERNAL_URL,
        internalUrl: process.env.CONFIGHUB_INTERNAL_URL
    }),
    "environment/datacatalog": JSON.stringify({
        url: process.env.DATACATALOG_URL
    })
};
process.stdout.write(JSON.stringify(payload));
')

HTTP_CODE=$(confighub_request "POST" "/environments" "$ENV_BODY")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "204" ]; then
    echo -e "  ${GREEN}✓ environment/cdn = ${CDN_URL}${NC}"
    echo -e "  ${GREEN}✓ environment/confighub set${NC}"
    echo -e "  ${GREEN}✓ environment/datacatalog set${NC}"
else
    echo -e "  ${RED}✗ Failed to seed environment variables (HTTP ${HTTP_CODE})${NC}"
fi

# --- Create scheduler ---
echo ""
echo -e "${BLUE}Creating scheduler...${NC}"

SCHED_BODY=$(docker exec \
    -e SCHEDULER_URL="$SCHEDULER_URL" \
    -e LOGGER_URL="$LOGGER_URL" \
    "$CONFIGHUB_CONTAINER" node -e '
const payload = {
    name: "Scheduler 1",
    url: process.env.SCHEDULER_URL,
    logServerUrl: process.env.LOGGER_URL,
    color: "lightskyblue",
    isDefault: true
};
process.stdout.write(JSON.stringify(payload));
')

HTTP_CODE=$(confighub_request "POST" "/schedulers" "$SCHED_BODY")

case "$HTTP_CODE" in
    201)
        echo -e "  ${GREEN}✓ Scheduler 1 created (${SCHEDULER_URL})${NC}"
        ;;
    409)
        echo -e "  ${YELLOW}Scheduler 1 already exists, updating...${NC}"
        HTTP_CODE=$(confighub_request "PUT" "/schedulers/Scheduler%201" "$SCHED_BODY")
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
            echo -e "  ${GREEN}✓ Scheduler 1 updated${NC}"
        else
            echo -e "  ${YELLOW}⚠ Failed to update scheduler (HTTP ${HTTP_CODE})${NC}"
        fi
        ;;
    *)
        echo -e "  ${RED}✗ Failed to create scheduler (HTTP ${HTTP_CODE})${NC}"
        ;;
esac

echo ""
echo -e "${GREEN}ConfigHub seeding complete.${NC}"
echo ""
