#!/bin/bash
# =============================================================================
# INDUSTREAM PLATFORM - One-Line Installer
# =============================================================================
# Usage: curl -fsSL https://install.industream.io | bash -s
#
# This script:
#   1. Asks for registry credentials
#   2. Checks prerequisites (git, curl)
#   3. Clones the deployment repository
#   4. Logs into the Docker registry
#   5. Launches the interactive installer (industream.sh)
# =============================================================================

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

REPO_URL="https://github.com/industream/industream-swarm.git"
INSTALL_DIR="${INDUSTREAM_DIR:-$HOME/industream-platform}"
REGISTRY="842775dh.c1.gra9.container-registry.ovh.net"

echo ""
echo -e "${BLUE}${BOLD}Industream Platform Installer${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# =============================================================================
# Step 1: Collect registry credentials upfront
# =============================================================================
echo -e "${BLUE}Docker registry credentials${NC}"
echo -e "${BLUE}Registry: ${BOLD}${REGISTRY}${NC}"
echo ""
read -p "  Username: " REGISTRY_USER < /dev/tty
read -s -p "  Password: " REGISTRY_PASSWORD < /dev/tty
echo ""
echo ""

if [ -z "$REGISTRY_USER" ] || [ -z "$REGISTRY_PASSWORD" ]; then
    echo -e "${RED}Username and password are required${NC}"
    exit 1
fi

# =============================================================================
# Step 2: Check prerequisites
# =============================================================================
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Missing: $1${NC}"
        echo "Install it first: $2"
        exit 1
    fi
}

check_command git "sudo apt install git -y"
check_command curl "sudo apt install curl -y"
echo -e "${GREEN}Prerequisites OK${NC}"

# =============================================================================
# Step 3: Clone or update repository
# =============================================================================
if [ -d "$INSTALL_DIR/.git" ]; then
    echo -e "${YELLOW}Existing installation found at ${INSTALL_DIR}${NC}"
    echo -e "${BLUE}Updating...${NC}"
    git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || true
else
    echo -e "${BLUE}Cloning to ${INSTALL_DIR}...${NC}"
    git clone "$REPO_URL" "$INSTALL_DIR"
fi
echo -e "${GREEN}Repository ready${NC}"

# =============================================================================
# Step 4: Make scripts executable
# =============================================================================
chmod +x "$INSTALL_DIR/industream.sh"
find "$INSTALL_DIR/scripts" -name "*.sh" -exec chmod +x {} \;

# =============================================================================
# Step 5: Docker login (deferred until Docker is available)
# =============================================================================
# Save credentials for industream.sh / first-deployment.sh to use
export INDUSTREAM_REGISTRY="$REGISTRY"
export INDUSTREAM_REGISTRY_USER="$REGISTRY_USER"
export INDUSTREAM_REGISTRY_PASSWORD="$REGISTRY_PASSWORD"

# If Docker is already running, login now
if command -v docker &> /dev/null && docker info &> /dev/null; then
    echo -e "${BLUE}Logging into Docker registry...${NC}"
    if echo "$REGISTRY_PASSWORD" | docker login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin &> /dev/null; then
        echo -e "${GREEN}Docker registry: authenticated${NC}"
    else
        echo -e "${RED}Docker login failed — check your credentials${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}Docker not yet available — registry login will happen during deployment${NC}"
fi

echo ""
echo -e "${GREEN}${BOLD}Installation ready!${NC}"
echo ""

# =============================================================================
# Step 6: Launch interactive installer
# =============================================================================
cd "$INSTALL_DIR"
exec ./industream.sh
