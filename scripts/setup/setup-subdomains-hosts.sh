#!/bin/bash

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Setup Subdomains in /etc/hosts                  ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════╝${NC}"
echo ""

# Load environment variables
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

DOMAIN=${INDUSTREAM_DOMAIN:-industream.platform.lan}
IP=${HOST_IP:-127.0.0.1}

echo -e "${BLUE}Domain:${NC} ${GREEN}${DOMAIN}${NC}"
echo -e "${BLUE}IP Address:${NC} ${GREEN}${IP}${NC}"
echo ""

# Complete list of subdomains (all services from docker-stack*.yml)
SUBDOMAINS=(
    "${DOMAIN}"
    "dashboard.${DOMAIN}"
    "flowmaker.${DOMAIN}"
    "datacatalog.${DOMAIN}"
    "datacatalog-api.${DOMAIN}"
    "datacatalog-ui.${DOMAIN}"
    "timeseries.${DOMAIN}"
    "confighub.${DOMAIN}"
    "prometheus.${DOMAIN}"
    "alertmanager.${DOMAIN}"
    "workers.${DOMAIN}"
    "logs-flowmaker.${DOMAIN}"
    "esm.${DOMAIN}"
    "ntfy.${DOMAIN}"
    "backups.${DOMAIN}"
    "traefik.${DOMAIN}"
)

echo -e "${BLUE}Will add the following entries to /etc/hosts:${NC}"
echo ""
for subdomain in "${SUBDOMAINS[@]}"; do
    echo "  ${IP}  ${subdomain}"
done
echo ""

read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Operation cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${BLUE}Adding entries to /etc/hosts...${NC}"

# Remove old entries
for subdomain in "${SUBDOMAINS[@]}"; do
    sudo sed -i "/${subdomain}/d" /etc/hosts
done

# Add new entries
for subdomain in "${SUBDOMAINS[@]}"; do
    echo "${IP}  ${subdomain}" | sudo tee -a /etc/hosts > /dev/null
    echo -e "${GREEN}✓${NC} Added: ${IP}  ${subdomain}"
done

echo ""
echo -e "${GREEN}✓ /etc/hosts updated successfully!${NC}"
echo ""
echo -e "${BLUE}You can now access:${NC}"
echo "  Main Portal:       https://${DOMAIN}"
echo "  Dashboards:        https://dashboard.${DOMAIN}"
echo "  FlowMaker:         https://flowmaker.${DOMAIN}"
echo "  DataCatalog API:   https://datacatalog-api.${DOMAIN}"
echo "  DataCatalog UI:    https://datacatalog-ui.${DOMAIN}"
echo "  Timeseries:        https://timeseries.${DOMAIN}"
echo "  Traefik Dashboard: https://traefik.${DOMAIN}"
echo ""
