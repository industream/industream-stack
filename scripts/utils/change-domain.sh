#!/bin/bash

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Change Domain Configuration                     ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════╝${NC}"
echo ""

# Get current domain
if [ -f .env ]; then
    CURRENT_DOMAIN=$(grep INDUSTREAM_DOMAIN .env | cut -d'=' -f2)
else
    CURRENT_DOMAIN="not set"
fi

echo -e "${BLUE}Current domain:${NC} ${YELLOW}${CURRENT_DOMAIN}${NC}"
echo ""
read -p "Enter new domain name: " NEW_DOMAIN

if [ -z "$NEW_DOMAIN" ]; then
    echo -e "${RED}Error: Domain cannot be empty${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}Will perform the following changes:${NC}"
echo "  1. Update INDUSTREAM_DOMAIN in .env"
echo "  2. Regenerate SSL certificates for ${NEW_DOMAIN}"
echo "  3. Regenerate UIFusion configuration"
echo "  4. Restart affected services"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Operation cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${BLUE}Step 1: Updating .env file...${NC}"
if [ -f .env ]; then
    sed -i.bak "s|INDUSTREAM_DOMAIN=.*|INDUSTREAM_DOMAIN=${NEW_DOMAIN}|" .env
    echo -e "${GREEN}✓ .env updated (backup saved as .env.bak)${NC}"
else
    echo -e "${YELLOW}Warning: .env not found, creating from .env.example${NC}"
    if [ -f .env.example ]; then
        cp .env.example .env
        sed -i "s|INDUSTREAM_DOMAIN=.*|INDUSTREAM_DOMAIN=${NEW_DOMAIN}|" .env
        echo -e "${GREEN}✓ .env created${NC}"
    else
        echo -e "${RED}Error: Neither .env nor .env.example found${NC}"
        exit 1
    fi
fi

echo ""
echo -e "${BLUE}Step 2: Regenerating SSL certificates...${NC}"
if [ -f scripts/generate/generate-certs.sh ]; then
    ./scripts/generate/generate-certs.sh
    echo -e "${GREEN}✓ Certificates regenerated${NC}"
else
    echo -e "${YELLOW}Warning: Certificate generation script not found${NC}"
fi

echo ""
echo -e "${BLUE}Step 3: Regenerating UIFusion configuration...${NC}"
if [ -f scripts/generate/generate-uifusion-config.sh ]; then
    ./scripts/generate/generate-uifusion-config.sh
    echo -e "${GREEN}✓ UIFusion configuration regenerated${NC}"
else
    echo -e "${YELLOW}Warning: UIFusion config generation script not found${NC}"
fi

echo ""
echo -e "${BLUE}Step 4: Restarting services...${NC}"
if command -v docker-compose &> /dev/null; then
    echo "Restarting Traefik and UIFusion..."
    docker-compose restart traefik uifusion 2>/dev/null || echo "Services not running or not found"
    echo -e "${GREEN}✓ Services restarted${NC}"
else
    echo -e "${YELLOW}Warning: docker-compose not found, please restart manually${NC}"
fi

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Domain change completed successfully!          ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}New domain:${NC} ${GREEN}${NEW_DOMAIN}${NC}"
echo ""
echo -e "${YELLOW}Important next steps:${NC}"
echo "  1. Update your DNS or /etc/hosts file:"
echo "     127.0.0.1  ${NEW_DOMAIN}"
echo ""
echo "  2. Trust the new certificate:"
echo "     ./scripts/utils/install-cert-trust.sh"
echo ""
echo "  3. Access your application at:"
echo "     https://${NEW_DOMAIN}"
echo ""
