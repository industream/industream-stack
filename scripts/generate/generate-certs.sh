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

# Default values
DOMAIN=""
AUTO_TRUST=false
FORCE_REGEN=false
CERT_YEARS=5

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --trust)
            AUTO_TRUST=true
            shift
            ;;
        --force)
            FORCE_REGEN=true
            shift
            ;;
        --years)
            CERT_YEARS="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --domain <domain>   Domain for certificate (default: from .env or industream.platform.lan)"
            echo "  --trust             Automatically install to system trust store"
            echo "  --force             Regenerate even if certificate exists"
            echo "  --years <n>         Certificate validity in years (default: 5)"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Interactive mode"
            echo "  $0 --domain dev.industream.platform.lan --trust --force"
            echo "  $0 --trust                           # Auto-install trust"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Load domain from .env if not specified
if [ -z "$DOMAIN" ]; then
    if [ -f ".env" ]; then
        DOMAIN=$(grep -E "^INDUSTREAM_DOMAIN=" .env | cut -d'=' -f2)
    fi
    DOMAIN="${DOMAIN:-industream.platform.lan}"
fi

# =============================================================================
# FUNCTIONS (defined early for use in certificate existence check)
# =============================================================================

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
        certutil -A -n "$DOMAIN" -t "CT,c,c" -i "certs/${DOMAIN}.crt" -d sql:"$NSSDB_DIR"
        echo -e "${GREEN}✓ Certificate installed to Chromium${NC}"
    else
        echo -e "${YELLOW}Note: Install nss/libnss3-tools for Chromium support${NC}"
    fi
}

# Function to install certificate to system trust store
install_certificate_trust() {
    echo -e "${BLUE}Installing certificate to system trust store...${NC}"

    if [ -f /etc/os-release ]; then
        . /etc/os-release

        # Try trust anchor first (works on most modern Linux distros)
        if command -v trust &> /dev/null; then
            echo -e "${BLUE}Using 'trust anchor' command...${NC}"
            sudo trust anchor "certs/${DOMAIN}.crt"
            echo -e "${GREEN}✓ Certificate installed in system trust store${NC}"
            install_chromium_nss
        else
            # Fallback to traditional methods
            case "$ID" in
                ubuntu|debian|linuxmint)
                    echo -e "${BLUE}Installing certificate for Debian/Ubuntu...${NC}"
                    sudo cp "certs/${DOMAIN}.crt" "/usr/local/share/ca-certificates/${DOMAIN}.crt"
                    sudo update-ca-certificates
                    echo -e "${GREEN}✓ Certificate installed in system trust store${NC}"
                    install_chromium_nss
                    ;;
                fedora|rhel|centos)
                    echo -e "${BLUE}Installing certificate for Fedora/RHEL/CentOS...${NC}"
                    sudo cp "certs/${DOMAIN}.crt" "/etc/pki/ca-trust/source/anchors/${DOMAIN}.crt"
                    sudo update-ca-trust
                    echo -e "${GREEN}✓ Certificate installed in system trust store${NC}"
                    install_chromium_nss
                    ;;
                arch|manjaro)
                    echo -e "${BLUE}Installing certificate for Arch Linux...${NC}"
                    sudo trust anchor "certs/${DOMAIN}.crt"
                    echo -e "${GREEN}✓ Certificate installed in system trust store${NC}"
                    install_chromium_nss
                    ;;
                *)
                    echo -e "${YELLOW}Unknown distribution. Please install manually:${NC}"
                    echo "  - Chrome/Edge: Import certs/${DOMAIN}.crt to 'Trusted Root Certification Authorities'"
                    echo "  - Firefox: Import in Settings > Privacy & Security > Certificates > View Certificates"
                    ;;
            esac
        fi
    elif [ "$(uname)" == "Darwin" ]; then
        echo -e "${BLUE}Installing certificate for macOS...${NC}"
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "certs/${DOMAIN}.crt"
        echo -e "${GREEN}✓ Certificate installed in system trust store${NC}"
    fi

    echo ""
    echo -e "${YELLOW}Note:${NC} You may need to restart your browser for the changes to take effect."
}

# =============================================================================
# MAIN SCRIPT
# =============================================================================

echo -e "${BLUE}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Self-Signed Certificate Generator              ║${NC}"
echo -e "${BLUE}║   for ${DOMAIN}${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════╝${NC}"
echo ""

# Create certs directory if it doesn't exist
mkdir -p certs

# Check if certificates already exist
if [ -f "certs/${DOMAIN}.crt" ] && [ -f "certs/${DOMAIN}.key" ]; then
    if [ "$FORCE_REGEN" = true ]; then
        echo -e "${YELLOW}Forcing regeneration of certificates...${NC}"
    elif [ "$AUTO_TRUST" = true ]; then
        # Auto mode with existing certs: just install trust
        echo -e "${GREEN}Certificates already exist in certs/${DOMAIN}.*${NC}"
        echo -e "${BLUE}Installing to trust store...${NC}"
        install_certificate_trust
        echo ""
        echo -e "${GREEN}Certificate trust installation complete!${NC}"
        exit 0
    else
        # Interactive mode: ask user
        echo -e "${YELLOW}Certificates already exist in certs/${DOMAIN}.*${NC}"
        echo ""
        read -p "Do you want to regenerate them? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}Keeping existing certificates${NC}"
            exit 0
        fi
    fi
fi

# Ask for validity period only in interactive mode
if [ "$AUTO_TRUST" = false ] && [ "$FORCE_REGEN" = false ]; then
    echo -e "${BLUE}Certificate validity period:${NC}"
    read -p "How many years should the certificate be valid? [$CERT_YEARS]: " INPUT_YEARS
    CERT_YEARS=${INPUT_YEARS:-$CERT_YEARS}
fi

# Validate input is a positive number
if ! [[ "$CERT_YEARS" =~ ^[0-9]+$ ]] || [ "$CERT_YEARS" -lt 1 ]; then
    echo -e "${YELLOW}Invalid input. Using default: 5 years${NC}"
    CERT_YEARS=5
fi

CERT_DAYS=$((CERT_YEARS * 365))

echo ""
echo -e "${BLUE}Generating self-signed certificate for ${DOMAIN}...${NC}"
echo -e "${BLUE}Validity: ${CERT_YEARS} years (${CERT_DAYS} days)${NC}"
echo ""

# Generate self-signed certificate
openssl req -x509 -nodes -days $CERT_DAYS -newkey rsa:2048 \
    -keyout "certs/${DOMAIN}.key" \
    -out "certs/${DOMAIN}.crt" \
    -subj "/C=FR/ST=France/L=Paris/O=Industream/OU=IT/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN},DNS:localhost,DNS:*.localhost"

# Set appropriate permissions
chmod 644 "certs/${DOMAIN}.crt"
chmod 600 "certs/${DOMAIN}.key"

echo ""
echo -e "${GREEN}✓ Certificate generated successfully!${NC}"
echo ""
echo -e "${BLUE}Certificate details:${NC}"
echo "  Location: certs/${DOMAIN}.crt"
echo "  Key:      certs/${DOMAIN}.key"
echo "  Domain:   ${DOMAIN} (+ *.${DOMAIN})"
echo "  Validity: ${CERT_YEARS} years (${CERT_DAYS} days)"
echo ""
echo -e "${YELLOW}Important:${NC}"
echo "1. Add to your /etc/hosts:"
echo "   127.0.0.1  ${DOMAIN}"
echo ""
echo "2. Trust the certificate in your system:"
echo ""

# Install trust automatically or ask
if [ "$AUTO_TRUST" = true ]; then
    install_certificate_trust
else
    read -p "Do you want to install the certificate in the system trust store? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        install_certificate_trust
    else
        echo ""
        echo "You can install it later with:"
        echo "  ./scripts/utils/install-cert-trust.sh"
        echo ""
        echo "Or manually:"
        echo "  - Linux: sudo trust anchor certs/${DOMAIN}.crt"
        echo "  - macOS: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain certs/${DOMAIN}.crt"
        echo "  - Or import manually in your browser settings"
    fi
fi

echo ""
echo -e "${GREEN}Certificate generation complete!${NC}"
