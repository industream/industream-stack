#!/bin/bash
# =============================================================================
# DEPLOY TRAEFIK SHARED INFRASTRUCTURE
# =============================================================================
# This script deploys the shared Traefik stack that handles routing for all
# environments (prod, dev, staging).
#
# Run this ONCE before deploying any environment-specific stacks.
# =============================================================================

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="traefik-shared"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."

# Change to project directory
cd "$PROJECT_DIR"

echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Traefik Shared Infrastructure - Deployment${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo ""

# Check if Swarm is initialized
if [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" != "active" ]; then
    echo -e "${RED}✗ Docker Swarm is not initialized${NC}"
    echo "Run: docker swarm init"
    exit 1
fi
echo -e "${GREEN}✓ Docker Swarm is active${NC}"

# Load environment variables (for server IP detection)
# Create .env from .env.example if it doesn't exist
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
        echo ""
        read -p "Press Enter to continue after reviewing .env, or Ctrl+C to abort... "
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
    echo "  ACME_EMAIL=${ACME_EMAIL:-not set}"
    echo ""
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
echo -e "${BLUE}Detecting server IP...${NC}"
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

echo ""
echo -e "${BLUE}Client DNS setup:${NC}"
echo "  Run ./scripts/generate/generate-client-setup.sh to create a client kit"
echo "  (hosts file + certificate + install scripts for USB deployment)"

# =============================================================================
# TLS Configuration (Let's Encrypt vs Self-signed)
# =============================================================================
echo ""
echo -e "${BLUE}TLS Mode: ${TLS_MODE:-selfsigned}${NC}"
if [ "${TLS_MODE}" = "letsencrypt" ]; then
    export TLS_CERTRESOLVER_CONFIG="certResolver: letsencrypt"
    echo -e "${GREEN}✓ Using Let's Encrypt certificates${NC}"
    echo "  Make sure ACME_EMAIL is set for certificate notifications"
else
    # Empty YAML object for self-signed (uses certificates defined in tls.certificates)
    export TLS_CERTRESOLVER_CONFIG="{}"
    echo -e "${GREEN}✓ Using self-signed certificates${NC}"
fi

# Generate Traefik dynamic config from template (if exists)
echo ""
echo -e "${BLUE}Generating Traefik dynamic configuration...${NC}"
if [ -f "traefik-dynamic/traefik-dynamic.yml.template" ]; then
    envsubst < traefik-dynamic/traefik-dynamic.yml.template > traefik-dynamic/traefik-dynamic.yml
    echo -e "${GREEN}✓ Traefik config generated${NC}"
else
    echo -e "${YELLOW}⚠ Template not found, using existing config${NC}"
fi

# Check stack file exists
if [ ! -f "docker-stack.traefik.yml" ]; then
    echo -e "${RED}✗ docker-stack.traefik.yml not found${NC}"
    exit 1
fi

# Check if stack is already deployed
EXISTING_STACK=$(docker stack ls --format '{{.Name}}' | grep "^${STACK_NAME}$" || true)
if [ -n "$EXISTING_STACK" ]; then
    echo ""
    echo -e "${YELLOW}⚠ Stack '$STACK_NAME' already exists${NC}"
    echo "  Updating the stack..."
fi

# Deploy stack
echo ""
echo -e "${BLUE}Deploying stack '$STACK_NAME'...${NC}"
docker stack deploy -c docker-stack.traefik.yml $STACK_NAME

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Traefik shared infrastructure deployed!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Network created: traefik-public${NC}"
echo "  This network will be used by all environment stacks."
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Deploy prod:    ./scripts/deploy-swarm.sh --env prod"
echo "  2. Deploy dev:     ./scripts/deploy-swarm.sh --env dev"
echo "  3. Deploy staging: ./scripts/deploy-swarm.sh --env staging"
echo ""
echo -e "${BLUE}Useful commands:${NC}"
echo "  docker stack services $STACK_NAME    # List Traefik services"
echo "  docker service logs ${STACK_NAME}_traefik  # View Traefik logs"
echo "  docker stack rm $STACK_NAME          # Remove Traefik stack"
echo ""
