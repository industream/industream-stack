#!/bin/bash
# =============================================================================
# Change the INDUSTREAM_DOMAIN for an existing Swarm deployment.
#
# This script is Swarm-exclusive. It regenerates TLS certs, UIFusion config,
# and Traefik dynamic config, then redeploys the affected stacks so the new
# domain takes effect.
# =============================================================================

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# =============================================================================
# Parse arguments
# =============================================================================
ENV="prod"
NEW_DOMAIN=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --env)
            ENV="$2"
            shift 2
            ;;
        --domain)
            NEW_DOMAIN="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--env <prod|dev|staging>] [--domain <new-domain>]"
            echo ""
            echo "Options:"
            echo "  --env <env>       Target environment (default: prod)"
            echo "  --domain <name>   New domain (skip interactive prompt)"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

if [[ ! "$ENV" =~ ^(prod|dev|staging)$ ]]; then
    echo -e "${RED}✗ Invalid environment: $ENV${NC}"
    exit 1
fi

cd "$PROJECT_DIR"

echo -e "${BLUE}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Change Domain Configuration (Swarm)             ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Target environment:${NC} ${YELLOW}${ENV}${NC}"
echo ""

# =============================================================================
# Pre-flight: Swarm must be active
# =============================================================================
if [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" != "active" ]; then
    echo -e "${RED}✗ Docker Swarm is not initialized on this node${NC}"
    echo "  This script only works on a Swarm-enabled host."
    exit 1
fi

# Get current domain
if [ -f .env ]; then
    CURRENT_DOMAIN=$(grep -E '^INDUSTREAM_DOMAIN=' .env | cut -d'=' -f2)
else
    CURRENT_DOMAIN="not set"
fi

echo -e "${BLUE}Current domain:${NC} ${YELLOW}${CURRENT_DOMAIN}${NC}"
echo ""

if [ -z "$NEW_DOMAIN" ]; then
    read -p "Enter new domain name: " NEW_DOMAIN
fi

if [ -z "$NEW_DOMAIN" ]; then
    echo -e "${RED}Error: Domain cannot be empty${NC}"
    exit 1
fi

# Basic domain sanity check (letters, digits, dots, hyphens)
if [[ ! "$NEW_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    echo -e "${RED}Error: Invalid domain name: $NEW_DOMAIN${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}Will perform the following changes:${NC}"
echo "  1. Update INDUSTREAM_DOMAIN in .env"
echo "  2. Regenerate SSL certificates for ${NEW_DOMAIN} (if TLS_MODE=selfsigned)"
echo "  3. Regenerate UIFusion configuration"
echo "  4. Regenerate Traefik dynamic configuration"
echo "  5. Redeploy traefik-shared and industream-${ENV} stacks"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Operation cancelled${NC}"
    exit 0
fi

# =============================================================================
# Step 1: Update .env
# =============================================================================
echo ""
echo -e "${BLUE}Step 1: Updating .env file...${NC}"
if [ -f .env ]; then
    sed -i.bak "s|^INDUSTREAM_DOMAIN=.*|INDUSTREAM_DOMAIN=${NEW_DOMAIN}|" .env
    echo -e "${GREEN}✓ .env updated (backup saved as .env.bak)${NC}"
else
    if [ -f .env.example ]; then
        echo -e "${YELLOW}Warning: .env not found, creating from .env.example${NC}"
        cp .env.example .env
        sed -i "s|^INDUSTREAM_DOMAIN=.*|INDUSTREAM_DOMAIN=${NEW_DOMAIN}|" .env
        echo -e "${GREEN}✓ .env created${NC}"
    else
        echo -e "${RED}Error: Neither .env nor .env.example found${NC}"
        exit 1
    fi
fi

# Re-read TLS_MODE from updated .env
TLS_MODE=$(grep -E '^TLS_MODE=' .env | cut -d'=' -f2 | tr -d '"' || true)
TLS_MODE="${TLS_MODE:-selfsigned}"

export INDUSTREAM_DOMAIN="$NEW_DOMAIN"

# =============================================================================
# Step 2: Regenerate SSL certificates (self-signed only)
# =============================================================================
echo ""
if [ "$TLS_MODE" = "selfsigned" ]; then
    echo -e "${BLUE}Step 2: Regenerating self-signed SSL certificates...${NC}"
    if [ -f "scripts/generate/generate-certs.sh" ]; then
        ./scripts/generate/generate-certs.sh
        echo -e "${GREEN}✓ Certificates regenerated${NC}"
    else
        echo -e "${RED}✗ scripts/generate/generate-certs.sh not found${NC}"
        exit 1
    fi
else
    echo -e "${BLUE}Step 2: TLS_MODE=${TLS_MODE} — skipping cert regeneration (handled by Traefik/ACME)${NC}"
fi

# =============================================================================
# Step 3: Regenerate UIFusion configuration
# =============================================================================
echo ""
echo -e "${BLUE}Step 3: Regenerating UIFusion configuration...${NC}"
if [ -f "scripts/generate/generate-uifusion-config.sh" ]; then
    ./scripts/generate/generate-uifusion-config.sh --force --env "$ENV"
    echo -e "${GREEN}✓ UIFusion configuration regenerated${NC}"
else
    echo -e "${RED}✗ scripts/generate/generate-uifusion-config.sh not found${NC}"
    exit 1
fi

# =============================================================================
# Step 4: Regenerate Traefik dynamic configuration
# =============================================================================
echo ""
echo -e "${BLUE}Step 4: Regenerating Traefik dynamic configuration...${NC}"
if [ -f "traefik-dynamic/traefik-dynamic.yml.template" ]; then
    if ! command -v envsubst &> /dev/null; then
        echo -e "${RED}✗ envsubst not found (install gettext)${NC}"
        exit 1
    fi
    envsubst < traefik-dynamic/traefik-dynamic.yml.template > traefik-dynamic/traefik-dynamic.yml
    echo -e "${GREEN}✓ Traefik dynamic config regenerated${NC}"
else
    echo -e "${YELLOW}⚠ traefik-dynamic/traefik-dynamic.yml.template not found, skipping${NC}"
fi

# =============================================================================
# Step 5: Redeploy stacks via Swarm
# =============================================================================
echo ""
echo -e "${BLUE}Step 5: Redeploying Swarm stacks...${NC}"

# Redeploy traefik-shared if present
if docker stack ls --format '{{.Name}}' | grep -q '^traefik-shared$'; then
    if [ -f "docker-stack.traefik.yml" ]; then
        echo -e "${BLUE}  Redeploying traefik-shared...${NC}"
        docker stack deploy -c docker-stack.traefik.yml --with-registry-auth --prune traefik-shared
        echo -e "${GREEN}  ✓ traefik-shared redeployed${NC}"
    elif [ -f "scripts/deploy-traefik.sh" ]; then
        echo -e "${BLUE}  Invoking scripts/deploy-traefik.sh...${NC}"
        bash scripts/deploy-traefik.sh
    else
        echo -e "${YELLOW}  ⚠ No traefik stack file or deploy script found; skipping Traefik redeploy${NC}"
    fi
else
    echo -e "${YELLOW}  ⚠ traefik-shared stack is not deployed; skipping${NC}"
fi

# Redeploy industream-<env>
STACK_NAME="industream-${ENV}"
if docker stack ls --format '{{.Name}}' | grep -q "^${STACK_NAME}$"; then
    if [ -f "scripts/deploy-swarm.sh" ]; then
        echo -e "${BLUE}  Invoking scripts/deploy-swarm.sh --env ${ENV}...${NC}"
        bash scripts/deploy-swarm.sh --env "$ENV"
        echo -e "${GREEN}  ✓ ${STACK_NAME} redeployed${NC}"
    else
        echo -e "${RED}  ✗ scripts/deploy-swarm.sh not found; cannot redeploy ${STACK_NAME}${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}  ⚠ ${STACK_NAME} stack is not deployed; run scripts/deploy-swarm.sh --env ${ENV} to deploy it${NC}"
fi

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Domain change completed successfully!          ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}New domain:${NC} ${GREEN}${NEW_DOMAIN}${NC}"
echo ""
echo -e "${YELLOW}Important next steps:${NC}"
echo "  1. Update your DNS (or /etc/hosts on the workstation):"
echo "     <SERVER_IP>  ${NEW_DOMAIN}"
echo "     <SERVER_IP>  *.${NEW_DOMAIN}"
echo ""
if [ "$TLS_MODE" = "selfsigned" ]; then
    echo "  2. Trust the new self-signed certificate:"
    echo "     ./scripts/utils/install-cert-trust.sh"
    echo ""
fi
echo "  3. Access your platform at:"
echo "     https://${NEW_DOMAIN}"
echo ""
