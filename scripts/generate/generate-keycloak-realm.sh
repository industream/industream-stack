#!/bin/bash

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Keycloak Realm Configuration Generator         ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════╝${NC}"
echo ""

# Load environment variables
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

DOMAIN=${INDUSTREAM_DOMAIN:-industream.platform.lan}

echo -e "${BLUE}Generating Keycloak realm configuration for domain: ${GREEN}${DOMAIN}${NC}"
echo ""

# Update the redirect URIs in the realm JSON using Python
python3 << EOF
import json
import sys

domain = "${DOMAIN}"

# Read the realm template/current realm
with open('keycloak-realms/industream-realm.json', 'r') as f:
    realm = json.load(f)

# Find uifusion client and update redirectUris with dynamic domain
updated = False
for client in realm.get('clients', []):
    if client.get('clientId') == 'uifusion':
        # Make redirectUris dynamic based on domain variable
        client['redirectUris'] = [
            f'https://dashboard.{domain}/login/generic_oauth',
            f'https://{domain}/*',
            '*'
        ]
        client['webOrigins'] = ['*']
        updated = True
        print(f"✓ Updated redirectUris for uifusion client")
        break

if not updated:
    print("ERROR: uifusion client not found in realm configuration", file=sys.stderr)
    sys.exit(1)

# Write back
with open('keycloak-realms/industream-realm.json', 'w') as f:
    json.dump(realm, f, indent=2)
EOF

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Keycloak realm configuration generated successfully!${NC}"
    echo ""
    echo -e "${BLUE}Configuration:${NC}"
    echo "  - Redirect URIs:"
    echo "    - https://dashboard.${DOMAIN}/login/generic_oauth"
    echo "    - https://${DOMAIN}/*"
    echo ""
    echo -e "${YELLOW}Note:${NC} Restart Keycloak container and reimport to apply changes:"
    echo "  docker-compose stop keycloak"
    echo "  docker-compose exec postgres psql -U postgres -c 'DROP DATABASE IF EXISTS keycloak;'"
    echo "  docker-compose exec postgres psql -U postgres -c 'CREATE DATABASE keycloak;'"
    echo "  docker-compose exec postgres psql -U postgres -d keycloak -c 'GRANT ALL ON SCHEMA public TO keycloak;'"
    echo "  docker-compose up -d keycloak"
    echo ""
else
    echo -e "${RED}✗ Failed to generate Keycloak realm configuration${NC}"
    exit 1
fi
