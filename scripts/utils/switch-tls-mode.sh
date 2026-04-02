#!/bin/bash
# Switch between Let's Encrypt (production) and self-signed (local) TLS modes

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STACK_FILE="$PROJECT_DIR/docker-stack.yml"
DYNAMIC_FILE="$PROJECT_DIR/traefik-dynamic/traefik-dynamic.yml"

show_usage() {
    echo -e "${BLUE}Usage:${NC} $0 [local|production]"
    echo ""
    echo "Modes:"
    echo "  local       - Use self-signed certificates (for .local domains)"
    echo "  production  - Use Let's Encrypt certificates (requires real domain)"
    echo ""
    echo "Example:"
    echo "  $0 local"
    echo "  $0 production"
}

switch_to_local() {
    echo -e "${YELLOW}Switching to LOCAL mode (self-signed certificates)...${NC}"

    # Replace certresolver with simple tls=true
    sed -i 's/\.tls\.certresolver=letsencrypt/.tls=true/g' "$STACK_FILE"

    # Update traefik-dynamic.yml - replace certResolver with empty tls
    sed -i 's/certResolver: letsencrypt/{}/g' "$DYNAMIC_FILE"

    # Comment out Let's Encrypt config
    sed -i 's/^    - --certificatesresolvers\.letsencrypt/    # - --certificatesresolvers.letsencrypt/g' "$STACK_FILE"

    # Comment out HTTP redirect
    sed -i 's/^    - --entrypoints\.web\.http\.redirections/    # - --entrypoints.web.http.redirections/g' "$STACK_FILE"

    echo -e "${GREEN}✓ Switched to LOCAL mode${NC}"
    echo ""
    echo -e "${YELLOW}Notes:${NC}"
    echo "  - Self-signed certificates will be used from ./certs/"
    echo "  - Make sure ./certs/ contains your .crt and .key files"
    echo "  - Add the certificate to your browser's trusted store"
}

switch_to_production() {
    echo -e "${YELLOW}Switching to PRODUCTION mode (Let's Encrypt)...${NC}"

    # Replace tls=true with certresolver
    sed -i 's/\.tls=true/.tls.certresolver=letsencrypt/g' "$STACK_FILE"

    # Update traefik-dynamic.yml
    sed -i 's/tls: {}/tls:\n        certResolver: letsencrypt/g' "$DYNAMIC_FILE"

    # Uncomment Let's Encrypt config
    sed -i 's/^    # - --certificatesresolvers\.letsencrypt/    - --certificatesresolvers.letsencrypt/g' "$STACK_FILE"

    # Uncomment HTTP redirect
    sed -i 's/^    # - --entrypoints\.web\.http\.redirections/    - --entrypoints.web.http.redirections/g' "$STACK_FILE"

    echo -e "${GREEN}✓ Switched to PRODUCTION mode${NC}"
    echo ""
    echo -e "${YELLOW}Requirements:${NC}"
    echo "  - Set INDUSTREAM_DOMAIN to a real domain (not .local) in .env"
    echo "  - Set ACME_EMAIL to a valid email address in .env"
    echo "  - Ensure port 80 is accessible from the internet (for HTTP challenge)"
}

case "${1:-}" in
    local)
        switch_to_local
        ;;
    production)
        switch_to_production
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
