#!/bin/bash
# =============================================================================
# INDUSTREAM PLATFORM - One-Line Installer
# =============================================================================
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/industream/industream-swarm/main/install.sh)
# =============================================================================

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

REPO_URL="https://github.com/industream/industream-swarm.git"
INSTALL_DIR="${INDUSTREAM_DIR:-$HOME/industream-platform}"
REGISTRY="842775dh.c1.gra9.container-registry.ovh.net"

# =============================================================================
# Bolt - The Industream install companion
# =============================================================================
bolt_say() {
    local message="$1"
    echo -e "${CYAN}  ⚙ Bolt:${NC} ${DIM}\"$message\"${NC}"
}

print_bolt_intro() {
    echo ""
    echo -e "${CYAN}        ┌───────┐${NC}"
    echo -e "${CYAN}        │ ◉   ◉ │${NC}"
    echo -e "${CYAN}        │  ───  │${NC}"
    echo -e "${CYAN}     ┌──┤       ├──┐${NC}"
    echo -e "${CYAN}     │  └───┬───┘  │${NC}"
    echo -e "${CYAN}     ◯      │      ◯${NC}"
    echo -e "${CYAN}     │   ┌──┴──┐   │${NC}"
    echo -e "${CYAN}     └───┤     ├───┘${NC}"
    echo -e "${CYAN}         │     │${NC}"
    echo -e "${CYAN}         ┴─┐ ┌─┴${NC}"
    echo -e "${CYAN}           │ │${NC}"
    echo -e "${CYAN}          ─┘ └─${NC}"
    echo ""
    echo -e "${BOLD}  Hey! I'm ${CYAN}Bolt${NC}${BOLD}, your install companion.${NC}"
    echo -e "${DIM}  I'll walk you through the Industream Platform setup.${NC}"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_bolt_success() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${GREEN}        ┌───────┐${NC}"
    echo -e "${GREEN}        │ ★   ★ │${NC}"
    echo -e "${GREEN}        │  ◡◡◡  │${NC}"
    echo -e "${GREEN}     ┌──┤       ├──┐${NC}"
    echo -e "${GREEN}     │  └───┬───┘  │${NC}"
    echo -e "${GREEN}    \\◯/     │    \\◯/${NC}"
    echo -e "${GREEN}     │   ┌──┴──┐   │${NC}"
    echo -e "${GREEN}     └───┤     ├───┘${NC}"
    echo -e "${GREEN}         │     │${NC}"
    echo -e "${GREEN}         ┴─┐ ┌─┴${NC}"
    echo -e "${GREEN}           │ │${NC}"
    echo -e "${GREEN}          ─┘ └─${NC}"
    echo ""
    echo -e "${GREEN}${BOLD}  Congratulations! Welcome to Industream! 🏭${NC}"
    echo ""
    echo -e "${DIM}  Your platform is being deployed.${NC}"
    echo -e "${DIM}  Bolt out. Beep boop.${NC}"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# =============================================================================
# Start
# =============================================================================
print_bolt_intro

# =============================================================================
# Step 1: Collect registry credentials
# =============================================================================
bolt_say "First things first — I need your registry credentials."
echo ""
echo -e "${BLUE}  Registry: ${BOLD}${REGISTRY}${NC}"
echo ""
printf "  Username: "
read REGISTRY_USER
printf "  Password: "
stty -echo 2>/dev/null
read REGISTRY_PASSWORD
stty echo 2>/dev/null
echo ""
echo ""

if [ -z "$REGISTRY_USER" ] || [ -z "$REGISTRY_PASSWORD" ]; then
    bolt_say "No credentials? I can't work like this."
    echo -e "${RED}  Username and password are required${NC}"
    exit 1
fi
bolt_say "Got it. I'll keep those safe."
echo ""

# =============================================================================
# Step 2: Check prerequisites
# =============================================================================
bolt_say "Checking your toolbox..."

check_command() {
    if ! command -v "$1" &> /dev/null; then
        bolt_say "Hmm, you're missing $1. That's a problem."
        echo -e "${RED}  Install it first: $2${NC}"
        exit 1
    fi
}

check_command git "sudo apt install git -y"
check_command curl "sudo apt install curl -y"
echo -e "${GREEN}  ✓ Prerequisites OK${NC}"
echo ""

# =============================================================================
# Step 3: Clone or update repository
# =============================================================================
bolt_say "Grabbing the latest deployment files..."

if [ -d "$INSTALL_DIR/.git" ]; then
    echo -e "${YELLOW}  Existing installation found — updating...${NC}"
    git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || true
else
    git clone --quiet "$REPO_URL" "$INSTALL_DIR"
fi
echo -e "${GREEN}  ✓ Repository ready${NC}"
echo ""

# =============================================================================
# Step 4: Make scripts executable
# =============================================================================
chmod +x "$INSTALL_DIR/industream.sh"
find "$INSTALL_DIR/scripts" -name "*.sh" -exec chmod +x {} \;

# =============================================================================
# Step 5: Docker login
# =============================================================================
export INDUSTREAM_REGISTRY="$REGISTRY"
export INDUSTREAM_REGISTRY_USER="$REGISTRY_USER"
export INDUSTREAM_REGISTRY_PASSWORD="$REGISTRY_PASSWORD"

if command -v docker &> /dev/null && docker info &> /dev/null; then
    bolt_say "Docker is here. Logging into the registry..."
    if echo "$REGISTRY_PASSWORD" | docker login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin &> /dev/null; then
        echo -e "${GREEN}  ✓ Registry: authenticated${NC}"
    else
        bolt_say "Login failed. Double-check those credentials."
        exit 1
    fi
else
    bolt_say "Docker isn't installed yet — I'll handle the login during deployment."
fi
echo ""

# =============================================================================
# Step 6: Launch installer
# =============================================================================
print_bolt_success

cd "$INSTALL_DIR"
exec ./industream.sh
