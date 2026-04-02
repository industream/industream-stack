#!/bin/bash
# =============================================================================
# GENERATE CLIENT SETUP KIT
# =============================================================================
# Generates a ready-to-deploy client kit for air-gapped environments.
# Output: client-setup/ directory containing:
#   - hosts           Static hosts file entries for all subdomains
#   - *.crt           Self-signed TLS certificate
#   - install-windows.bat   Windows installer (hosts + cert)
#   - install-linux.sh      Linux installer (hosts + cert)
#   - README.txt            Instructions for IT / operators
#
# Usage: ./scripts/generate/generate-client-setup.sh
# =============================================================================

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../.."
OUTPUT_DIR="$PROJECT_DIR/client-setup"

echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Generate Client Setup Kit${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo ""

# Load environment variables
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
else
    echo -e "${RED}Error: .env file not found at $PROJECT_DIR/.env${NC}"
    echo "Run deploy-traefik.sh first or create .env from .env.example"
    exit 1
fi

DOMAIN="${INDUSTREAM_DOMAIN:-industream.platform.lan}"
SERVER_IP="${INDUSTREAM_SERVER_IP:-}"

if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}Error: INDUSTREAM_SERVER_IP is not set in .env${NC}"
    echo "Set the server IP address before generating the client kit."
    exit 1
fi

echo -e "${BLUE}Domain:${NC}    ${GREEN}${DOMAIN}${NC}"
echo -e "${BLUE}Server IP:${NC} ${GREEN}${SERVER_IP}${NC}"
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
    "etcd.${DOMAIN}"
    "prometheus.${DOMAIN}"
    "alertmanager.${DOMAIN}"
    "workers.${DOMAIN}"
    "logs-flowmaker.${DOMAIN}"
    "uimaker-flowmaker.${DOMAIN}"
    "uimaker-flowmaker-view.${DOMAIN}"
    "uimaker-flowmaker-api.${DOMAIN}"
    "esm.${DOMAIN}"
    "ntfy.${DOMAIN}"
    "backups.${DOMAIN}"
    "traefik.${DOMAIN}"
)

# Prepare output directory
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# ─────────────────────────────────────────────
# 1. Generate hosts file
# ─────────────────────────────────────────────
echo -e "${BLUE}Generating hosts file...${NC}"
HOSTS_FILE="$OUTPUT_DIR/hosts"

cat > "$HOSTS_FILE" <<EOF
# =============================================================================
# Industream Platform - Static DNS Entries
# =============================================================================
# Server IP: ${SERVER_IP}
# Domain:    ${DOMAIN}
# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# =============================================================================

EOF

for subdomain in "${SUBDOMAINS[@]}"; do
    echo "${SERVER_IP}  ${subdomain}" >> "$HOSTS_FILE"
done

echo -e "${GREEN}✓ hosts file created (${#SUBDOMAINS[@]} entries)${NC}"

# ─────────────────────────────────────────────
# 2. Copy self-signed certificate
# ─────────────────────────────────────────────
echo -e "${BLUE}Copying certificate...${NC}"
CERT_FILE="$PROJECT_DIR/certs/${DOMAIN}.crt"

if [ -f "$CERT_FILE" ]; then
    cp "$CERT_FILE" "$OUTPUT_DIR/${DOMAIN}.crt"
    echo -e "${GREEN}✓ Certificate copied: ${DOMAIN}.crt${NC}"
else
    echo -e "${YELLOW}⚠ Certificate not found at $CERT_FILE${NC}"
    echo -e "${YELLOW}  Run ./scripts/generate/generate-certs.sh first${NC}"
    echo -e "${YELLOW}  Continuing without certificate...${NC}"
fi

# ─────────────────────────────────────────────
# 3. Generate Windows install script
# ─────────────────────────────────────────────
echo -e "${BLUE}Generating Windows installer...${NC}"

# Use printf to write the batch file with Windows line endings (CRLF)
WIN_FILE="$OUTPUT_DIR/install-windows.bat"
{
    printf '@echo off\r\n'
    printf 'REM =============================================================================\r\n'
    printf 'REM Industream Platform - Client Setup (Windows)\r\n'
    printf 'REM =============================================================================\r\n'
    printf 'REM This script must be run as Administrator.\r\n'
    printf 'REM It appends DNS entries to the hosts file and imports the TLS certificate.\r\n'
    printf 'REM =============================================================================\r\n'
    printf '\r\n'
    printf 'echo.\r\n'
    printf 'echo ══════════════════════════════════════════════════\r\n'
    printf 'echo    Industream Platform - Client Setup\r\n'
    printf 'echo ══════════════════════════════════════════════════\r\n'
    printf 'echo.\r\n'
    printf '\r\n'
    printf 'REM Check for admin privileges\r\n'
    printf 'net session >nul 2>&1\r\n'
    printf 'if %%errorlevel%% neq 0 (\r\n'
    printf '    echo ERROR: This script requires Administrator privileges.\r\n'
    printf '    echo Right-click the script and select "Run as administrator".\r\n'
    printf '    pause\r\n'
    printf '    exit /b 1\r\n'
    printf ')\r\n'
    printf '\r\n'
    printf 'set "HOSTS_FILE=%%WINDIR%%\\System32\\drivers\\etc\\hosts"\r\n'
    printf 'set "SCRIPT_DIR=%%~dp0"\r\n'
    printf '\r\n'
    printf 'REM ── Step 1: Update hosts file ──\r\n'
    printf 'echo.\r\n'
    printf 'echo [1/2] Updating hosts file...\r\n'
    printf '\r\n'
    printf 'REM Remove old Industream entries\r\n'
    printf 'findstr /v /i "%s" "%%HOSTS_FILE%%" > "%%TEMP%%\\hosts.tmp"\r\n' "${DOMAIN}"
    printf 'copy /y "%%TEMP%%\\hosts.tmp" "%%HOSTS_FILE%%" >nul\r\n'
    printf 'del "%%TEMP%%\\hosts.tmp"\r\n'
    printf '\r\n'
    printf 'REM Append new entries from hosts file\r\n'
    printf 'echo. >> "%%HOSTS_FILE%%"\r\n'
    printf 'type "%%SCRIPT_DIR%%hosts" >> "%%HOSTS_FILE%%"\r\n'
    printf 'echo [OK] Hosts file updated.\r\n'
    printf '\r\n'
    printf 'REM ── Step 2: Import TLS certificate ──\r\n'
    printf 'echo.\r\n'
    printf 'echo [2/2] Importing TLS certificate...\r\n'
    printf '\r\n'
    printf 'if exist "%%SCRIPT_DIR%%%s.crt" (\r\n' "${DOMAIN}"
    printf '    certutil -addstore -f "Root" "%%SCRIPT_DIR%%%s.crt"\r\n' "${DOMAIN}"
    printf '    if %%errorlevel%% equ 0 (\r\n'
    printf '        echo [OK] Certificate imported to Trusted Root store.\r\n'
    printf '    ) else (\r\n'
    printf '        echo [WARN] Certificate import failed. You may need to import it manually.\r\n'
    printf '    )\r\n'
    printf ') else (\r\n'
    printf '    echo [SKIP] No certificate file found.\r\n'
    printf ')\r\n'
    printf '\r\n'
    printf 'echo.\r\n'
    printf 'echo ══════════════════════════════════════════════════\r\n'
    printf 'echo    Setup complete!\r\n'
    printf 'echo ══════════════════════════════════════════════════\r\n'
    printf 'echo.\r\n'
    printf 'echo You can now access: https://%s\r\n' "${DOMAIN}"
    printf 'echo.\r\n'
    printf 'pause\r\n'
} > "$WIN_FILE"

echo -e "${GREEN}✓ install-windows.bat created${NC}"

# ─────────────────────────────────────────────
# 4. Generate Linux install script
# ─────────────────────────────────────────────
echo -e "${BLUE}Generating Linux installer...${NC}"

cat > "$OUTPUT_DIR/install-linux.sh" <<'OUTER_EOF'
#!/bin/bash
# =============================================================================
# Industream Platform - Client Setup (Linux)
# =============================================================================
# This script must be run as root (or with sudo).
# It appends DNS entries to /etc/hosts and installs the TLS certificate.
# =============================================================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Industream Platform - Client Setup${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo ""

# Check for root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root.${NC}"
    echo "Usage: sudo ./install-linux.sh"
    exit 1
fi

OUTER_EOF

# Inject the domain as a variable (not expanded at write time by the heredoc above)
cat >> "$OUTPUT_DIR/install-linux.sh" <<EOF
DOMAIN="${DOMAIN}"
EOF

cat >> "$OUTPUT_DIR/install-linux.sh" <<'OUTER_EOF'

# ── Step 1: Update /etc/hosts ──
echo -e "${BLUE}[1/2] Updating /etc/hosts...${NC}"

# Remove old Industream entries
sed -i "/${DOMAIN}/d" /etc/hosts

# Append new entries
cat "$SCRIPT_DIR/hosts" >> /etc/hosts

echo -e "${GREEN}[OK] /etc/hosts updated.${NC}"

# ── Step 2: Install TLS certificate ──
echo ""
echo -e "${BLUE}[2/2] Installing TLS certificate...${NC}"

CERT_FILE="$SCRIPT_DIR/${DOMAIN}.crt"

if [ -f "$CERT_FILE" ]; then
    # Detect distro and install accordingly
    if [ -d /usr/local/share/ca-certificates ]; then
        # Debian/Ubuntu
        cp "$CERT_FILE" "/usr/local/share/ca-certificates/${DOMAIN}.crt"
        update-ca-certificates
        echo -e "${GREEN}[OK] Certificate installed (Debian/Ubuntu).${NC}"
    elif [ -d /etc/pki/ca-trust/source/anchors ]; then
        # RHEL/CentOS/Fedora
        cp "$CERT_FILE" "/etc/pki/ca-trust/source/anchors/${DOMAIN}.crt"
        update-ca-trust
        echo -e "${GREEN}[OK] Certificate installed (RHEL/Fedora).${NC}"
    elif [ -d /etc/ca-certificates/trust-source/anchors ]; then
        # Arch Linux
        cp "$CERT_FILE" "/etc/ca-certificates/trust-source/anchors/${DOMAIN}.crt"
        trust extract-compat
        echo -e "${GREEN}[OK] Certificate installed (Arch Linux).${NC}"
    else
        echo -e "${YELLOW}[WARN] Could not detect certificate store.${NC}"
        echo "Please install the certificate manually: $CERT_FILE"
    fi
else
    echo -e "${YELLOW}[SKIP] No certificate file found.${NC}"
fi

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   Setup complete!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo "You can now access: https://${DOMAIN}"
echo ""
OUTER_EOF

chmod +x "$OUTPUT_DIR/install-linux.sh"
echo -e "${GREEN}✓ install-linux.sh created${NC}"

# ─────────────────────────────────────────────
# 5. Generate README
# ─────────────────────────────────────────────
echo -e "${BLUE}Generating README...${NC}"

cat > "$OUTPUT_DIR/README.txt" <<EOF
=============================================================================
  INDUSTREAM PLATFORM - CLIENT SETUP KIT
=============================================================================

  Server IP: ${SERVER_IP}
  Domain:    ${DOMAIN}
  Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

=============================================================================

This kit configures a client machine to access the Industream platform
on an air-gapped (offline) network.

It performs two actions:
  1. Adds DNS entries to the system hosts file (so *.${DOMAIN} resolves)
  2. Installs the self-signed TLS certificate (so browsers trust HTTPS)


WINDOWS
-------
  1. Copy this folder to the client machine (e.g. via USB stick)
  2. Right-click "install-windows.bat" -> "Run as administrator"
  3. Open https://${DOMAIN} in your browser


LINUX
-----
  1. Copy this folder to the client machine
  2. Run: sudo ./install-linux.sh
  3. Open https://${DOMAIN} in your browser


MANUAL SETUP
------------
If the scripts don't work on your system:

  1. Append the contents of the "hosts" file to:
     - Windows: C:\\Windows\\System32\\drivers\\etc\\hosts
     - Linux/Mac: /etc/hosts

  2. Import "${DOMAIN}.crt" as a trusted root certificate:
     - Windows: certutil -addstore -f "Root" "${DOMAIN}.crt"
     - Linux (Debian/Ubuntu):
         sudo cp ${DOMAIN}.crt /usr/local/share/ca-certificates/
         sudo update-ca-certificates
     - Linux (RHEL/Fedora):
         sudo cp ${DOMAIN}.crt /etc/pki/ca-trust/source/anchors/
         sudo update-ca-trust
     - macOS:
         sudo security add-trusted-cert -d -r trustRoot \\
           -k /Library/Keychains/System.keychain ${DOMAIN}.crt


FILES IN THIS KIT
-----------------
  hosts                  DNS entries for all ${DOMAIN} subdomains
  ${DOMAIN}.crt    Self-signed TLS certificate
  install-windows.bat    Automated installer for Windows
  install-linux.sh       Automated installer for Linux
  README.txt             This file

=============================================================================
EOF

echo -e "${GREEN}✓ README.txt created${NC}"

# ─────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Client setup kit generated!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Output directory:${NC} $OUTPUT_DIR"
echo ""
echo "Contents:"
ls -la "$OUTPUT_DIR"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Copy the client-setup/ folder to a USB stick"
echo "  2. On each client machine, run the appropriate installer"
echo ""
