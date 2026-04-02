#!/bin/bash

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../.."
cd "$PROJECT_DIR"

# Load domain from .env
if [ -f ".env" ]; then
    DOMAIN=$(grep -E "^INDUSTREAM_DOMAIN=" .env | cut -d'=' -f2)
fi
DOMAIN="${DOMAIN:-industream.platform.lan}"
CERT_FILE="certs/${DOMAIN}.crt"

echo -e "${BLUE}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Install ${DOMAIN} Certificate${NC}"
echo -e "${BLUE}║   to System Trust Store                           ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════╝${NC}"
echo ""

# Check if certificate exists
if [ ! -f "$CERT_FILE" ]; then
    echo -e "${RED}✗ Certificate not found at ${CERT_FILE}${NC}"
    echo "  Please generate it first with: ./scripts/generate/generate-certs.sh"
    exit 1
fi

echo -e "${BLUE}Installing certificate to system trust store...${NC}"
echo ""

# Function to install to Chromium NSS database
install_chromium_nss() {
    if command -v certutil &> /dev/null; then
        echo -e "${BLUE}Installing to Chromium NSS database...${NC}"
        NSSDB_DIR="$HOME/.pki/nssdb"
        mkdir -p "$NSSDB_DIR"
        if [ ! -f "$NSSDB_DIR/cert9.db" ]; then
            certutil -N --empty-password -d sql:"$NSSDB_DIR"
        fi
        # Remove existing cert if present
        certutil -D -n "$DOMAIN" -d sql:"$NSSDB_DIR" 2>/dev/null || true
        certutil -A -n "$DOMAIN" -t "CT,c,c" -i "$CERT_FILE" -d sql:"$NSSDB_DIR"
        echo -e "${GREEN}✓ Certificate installed to Chromium${NC}"
    else
        echo -e "${YELLOW}Note: Install nss/libnss3-tools for Chromium support${NC}"
    fi
}

# Detect OS and install accordingly
if [ -f /etc/os-release ]; then
    . /etc/os-release

    # Try trust anchor first (works on most modern Linux distros)
    if command -v trust &> /dev/null; then
        echo -e "${BLUE}Detected: $PRETTY_NAME${NC}"
        echo -e "${BLUE}Using 'trust anchor' command...${NC}"
        sudo trust anchor "$CERT_FILE"
        echo -e "${GREEN}✓ Certificate installed to system trust store${NC}"
        install_chromium_nss
    else
        # Fallback to traditional methods
        case "$ID" in
            ubuntu|debian|linuxmint)
                echo -e "${BLUE}Detected: Debian/Ubuntu${NC}"
                sudo cp "$CERT_FILE" "/usr/local/share/ca-certificates/${DOMAIN}.crt"
                sudo update-ca-certificates
                echo -e "${GREEN}✓ Certificate installed successfully${NC}"
                install_chromium_nss
                ;;
            fedora|rhel|centos)
                echo -e "${BLUE}Detected: Fedora/RHEL/CentOS${NC}"
                sudo cp "$CERT_FILE" "/etc/pki/ca-trust/source/anchors/${DOMAIN}.crt"
                sudo update-ca-trust
                echo -e "${GREEN}✓ Certificate installed successfully${NC}"
                install_chromium_nss
                ;;
            *)
                echo -e "${YELLOW}Unknown Linux distribution: $ID${NC}"
                echo "Please install manually:"
                echo "  sudo cp $CERT_FILE /usr/local/share/ca-certificates/"
                echo "  sudo update-ca-certificates"
                exit 1
                ;;
        esac
    fi
elif [ "$(uname)" == "Darwin" ]; then
    echo -e "${BLUE}Detected: macOS${NC}"
    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CERT_FILE"
    echo -e "${GREEN}✓ Certificate installed successfully${NC}"
else
    echo -e "${RED}✗ Unsupported operating system${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}Important:${NC}"
echo "  - System trust store updated"
echo "  - You may need to restart your browser"
echo "  - Chrome/Chromium should recognize the certificate automatically"
echo "  - Firefox uses its own certificate store and may still require manual import"
echo ""
echo -e "${BLUE}Firefox manual import:${NC}"
echo "  1. Open Firefox"
echo "  2. Go to Settings > Privacy & Security > Certificates > View Certificates"
echo "  3. Click 'Import' on the 'Authorities' tab"
echo "  4. Select: $(pwd)/$CERT_FILE"
echo "  5. Check 'Trust this CA to identify websites'"
echo ""
echo -e "${GREEN}Installation complete!${NC}"
