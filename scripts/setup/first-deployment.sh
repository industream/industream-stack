#!/bin/bash
set -e

# ══════════════════════════════════════════════════════════════════════════════
# Industream Platform - First Deployment Script
# ══════════════════════════════════════════════════════════════════════════════
# This script handles the complete first-time deployment of the Industream stack:
# - Checks prerequisites (Docker, docker-compose)
# - Initializes Docker Swarm if needed
# - Generates environment configuration
# - Creates Docker secrets
# - Deploys the stack
# - Optionally deploys demo simulators
# - Validates deployment and shows status
# ══════════════════════════════════════════════════════════════════════════════

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ENV="${ENV:-prod}"
STACK_NAME="industream-${ENV}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../.."
DEMO_DIR="$PROJECT_DIR/../industream-platform-demo"
DEPLOY_DEMO=false
cd "$PROJECT_DIR"

# ══════════════════════════════════════════════════════════════════════════════
# Helper Functions
# ══════════════════════════════════════════════════════════════════════════════

print_header() {
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
}

print_step() {
    echo -e "${CYAN}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BOLD}  $1${NC}"
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local answer

    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi

    read -r -p "$prompt" answer
    answer="${answer:-$default}"

    case "$answer" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# Deployment Type Selection
# ══════════════════════════════════════════════════════════════════════════════

select_deployment_type() {
    print_header "Deployment Type Selection"

    # Demo simulators only available for dev env (ingress ports would conflict)
    if [ "$ENV" != "dev" ]; then
        print_info "Environment: ${ENV} — deploying platform only"
        print_info "(Demo simulators are only available for the dev environment)"
        DEPLOY_DEMO=false
        return 0
    fi

    # Check if demo stack file exists
    if [ ! -f "docker-stack.demo.yml" ]; then
        print_info "docker-stack.demo.yml not found — deploying platform only"
        DEPLOY_DEMO=false
        return 0
    fi

    echo ""
    echo -e "${BOLD}What would you like to deploy?${NC}"
    echo ""
    echo "  1) Platform only   - Core platform (recommended)"
    echo "  2) Full with Demo  - Platform + simulators (OPC-UA, MQTT, S7, Modbus)"
    echo ""

    local choice
    read -r -p "Your choice [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1)
            DEPLOY_DEMO=false
            print_success "Will deploy: Dev platform only"
            ;;
        2)
            DEPLOY_DEMO=true
            print_success "Will deploy: Dev platform + Demo simulators"
            ;;
        *)
            print_warning "Invalid choice, defaulting to Platform only"
            DEPLOY_DEMO=false
            ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# Prerequisites Check & Auto-Install
# ══════════════════════════════════════════════════════════════════════════════

# Detect package manager (set once, used by all install functions)
detect_pkg_manager() {
    if command -v apt-get &> /dev/null; then
        echo "apt"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v pacman &> /dev/null; then
        echo "pacman"
    else
        echo ""
    fi
}

# Install a system package by name (handles per-distro differences)
install_package() {
    local pkg_apt="$1"
    local pkg_dnf="${2:-$1}"
    local pkg_pacman="${3:-$1}"
    local pkg_manager
    pkg_manager=$(detect_pkg_manager)

    case "$pkg_manager" in
        apt)
            sudo apt-get install -y "$pkg_apt"
            ;;
        dnf)
            sudo dnf install -y "$pkg_dnf"
            ;;
        pacman)
            sudo pacman -S --noconfirm "$pkg_pacman"
            ;;
        *)
            print_error "No supported package manager found (apt, dnf, pacman)"
            return 1
            ;;
    esac
}

# Install Docker Engine + Compose plugin from official Docker repo
install_docker() {
    local pkg_manager
    pkg_manager=$(detect_pkg_manager)

    print_step "Installing Docker Engine..."

    case "$pkg_manager" in
        apt)
            # Install prerequisites
            sudo apt-get update -y
            sudo apt-get install -y ca-certificates curl gnupg

            # Add Docker's official GPG key
            sudo install -m 0755 -d /etc/apt/keyrings
            if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                sudo chmod a+r /etc/apt/keyrings/docker.gpg
            fi

            # Set up the repository (works for Ubuntu and Debian)
            local distro
            distro=$(. /etc/os-release && echo "$ID")
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
                sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

            # Install Docker
            sudo apt-get update -y
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        dnf)
            sudo dnf install -y dnf-plugins-core
            sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        pacman)
            sudo pacman -S --noconfirm docker docker-compose docker-buildx
            ;;
        *)
            print_error "No supported package manager found"
            print_info "Install Docker manually: https://docs.docker.com/engine/install/"
            return 1
            ;;
    esac

    # Enable and start Docker
    sudo systemctl enable docker
    sudo systemctl start docker

    # Add current user to docker group (avoids needing sudo for docker commands)
    if ! groups | grep -q docker; then
        sudo usermod -aG docker "$USER"
        print_warning "User '$USER' added to docker group"
        print_warning "You may need to log out and back in for group changes to take effect"
        # Apply group in current shell via newgrp (will NOT affect parent shell)
        # We use sg instead to run the rest of the script with docker group
    fi

    print_success "Docker Engine installed"
}

check_prerequisites() {
    print_header "Checking Prerequisites"

    local need_install=false
    local missing_packages=()
    local pkg_manager
    pkg_manager=$(detect_pkg_manager)

    # ── Docker ──────────────────────────────────────────────────────────────
    print_step "Checking Docker..."
    if command -v docker &> /dev/null; then
        local docker_version=$(docker --version | cut -d' ' -f3 | tr -d ',')
        print_success "Docker installed (v$docker_version)"

        # Check Docker Compose (plugin)
        print_step "Checking Docker Compose..."
        if docker compose version &> /dev/null; then
            local compose_version=$(docker compose version --short 2>/dev/null || docker compose version | grep -oP '\d+\.\d+\.\d+')
            print_success "Docker Compose installed (v$compose_version)"
        else
            print_warning "Docker Compose plugin not found"
            need_install=true
        fi
    else
        print_warning "Docker is not installed"
        need_install=true
    fi

    # If Docker or Compose missing, offer to install
    if [ "$need_install" = true ]; then
        echo ""
        if [ -z "$pkg_manager" ]; then
            print_error "No supported package manager found (apt, dnf, pacman)"
            print_info "Install Docker manually: https://docs.docker.com/engine/install/"
            exit 1
        fi

        if ask_yes_no "Install Docker Engine + Compose automatically?" "y"; then
            install_docker
            # Verify installation
            if ! command -v docker &> /dev/null; then
                print_error "Docker installation failed"
                exit 1
            fi
            if ! docker compose version &> /dev/null; then
                print_error "Docker Compose installation failed"
                exit 1
            fi
            print_success "Docker + Compose ready"
        else
            print_error "Docker is required for deployment"
            exit 1
        fi
    fi

    # ── Docker daemon ───────────────────────────────────────────────────────
    print_step "Checking Docker daemon..."
    if docker info &> /dev/null; then
        print_success "Docker daemon is running"
    else
        print_warning "Docker daemon is not running"
        if ask_yes_no "Start Docker daemon now?" "y"; then
            sudo systemctl start docker
            sudo systemctl enable docker
            local retries=0
            while ! docker info &> /dev/null; do
                retries=$((retries + 1))
                if [ $retries -ge 15 ]; then
                    print_error "Failed to start Docker daemon (timeout after 15s)"
                    exit 1
                fi
                sleep 1
            done
            print_success "Docker daemon started"
        else
            print_error "Docker daemon is required"
            exit 1
        fi
    fi

    # ── Python 3 + PyYAML ──────────────────────────────────────────────────
    print_step "Checking Python 3..."
    if ! command -v python3 &> /dev/null; then
        print_warning "Python 3 not found"
        if ask_yes_no "Install Python 3 automatically?" "y"; then
            install_package "python3" "python3" "python"
        else
            print_error "Python 3 is required for Swarm YAML processing"
            exit 1
        fi
    fi
    local python_version=$(python3 --version 2>&1 | cut -d' ' -f2)
    print_success "Python 3 installed (v$python_version)"

    print_step "Checking PyYAML module..."
    if ! python3 -c "import yaml" &> /dev/null; then
        print_warning "PyYAML module not found"
        if ask_yes_no "Install PyYAML automatically?" "y"; then
            install_package "python3-yaml" "python3-pyyaml" "python-yaml"
        else
            print_error "PyYAML is required for Swarm YAML processing"
            exit 1
        fi
    fi
    print_success "PyYAML module installed"

    # ── OpenSSL ─────────────────────────────────────────────────────────────
    print_step "Checking OpenSSL..."
    if ! command -v openssl &> /dev/null; then
        print_warning "OpenSSL not found"
        if ask_yes_no "Install OpenSSL automatically?" "y"; then
            install_package "openssl" "openssl" "openssl"
        else
            print_error "OpenSSL is required for certificates and secret generation"
            exit 1
        fi
    fi
    print_success "OpenSSL installed"

    # ── envsubst (gettext) ──────────────────────────────────────────────────
    print_step "Checking envsubst..."
    if ! command -v envsubst &> /dev/null; then
        print_warning "envsubst not found"
        if ask_yes_no "Install envsubst (gettext) automatically?" "y"; then
            install_package "gettext-base" "gettext" "gettext"
        else
            print_error "envsubst is required for template processing"
            exit 1
        fi
    fi
    print_success "envsubst installed"

    # ── curl ────────────────────────────────────────────────────────────────
    print_step "Checking curl..."
    if ! command -v curl &> /dev/null; then
        print_warning "curl not found"
        if ask_yes_no "Install curl automatically?" "y"; then
            install_package "curl" "curl" "curl"
        else
            print_warning "curl missing — backup scripts and health checks may not work"
        fi
    fi
    if command -v curl &> /dev/null; then
        print_success "curl installed"
    fi

    echo ""
    print_success "All prerequisites satisfied"
}

# ══════════════════════════════════════════════════════════════════════════════
# Docker Swarm Initialization
# ══════════════════════════════════════════════════════════════════════════════

init_swarm() {
    print_header "Docker Swarm Initialization"

    print_step "Checking Swarm status..."
    local swarm_state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)

    if [ "$swarm_state" = "active" ]; then
        print_success "Docker Swarm is already initialized"
        local node_id=$(docker info --format '{{.Swarm.NodeID}}')
        print_info "Node ID: $node_id"
    else
        print_warning "Docker Swarm is not initialized"
        if ask_yes_no "Initialize Docker Swarm now?" "y"; then
            print_step "Initializing Swarm..."
            docker swarm init
            print_success "Docker Swarm initialized"
        else
            print_error "Docker Swarm is required for deployment"
            exit 1
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Environment Configuration
# ══════════════════════════════════════════════════════════════════════════════

generate_env() {
    print_header "Environment Configuration"

    if [ -f ".env" ]; then
        # Check if .env has actual generated passwords or just template placeholders
        if grep -q '^POSTGRES_ADMIN_PASSWORD=' .env 2>/dev/null; then
            print_warning ".env file already exists (with generated passwords)"
            if ask_yes_no "Keep existing .env file? (recommended)" "y"; then
                print_success "Keeping existing .env file"
                source .env
                print_info "Domain: ${INDUSTREAM_DOMAIN:-industream.platform.lan}"
                return 0
            fi
        else
            print_warning ".env exists but has no passwords — regenerating..."
        fi
    fi

    print_step "Generating .env file with secure passwords..."
    ./scripts/generate/generate-env.sh > .env
    chmod 600 .env
    print_success ".env file generated"

    # Load the domain for later use
    source .env
    print_info "Domain: ${INDUSTREAM_DOMAIN:-industream.platform.lan}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Docker Secrets Management
# ══════════════════════════════════════════════════════════════════════════════

create_secrets() {
    print_header "Docker Secrets Management"

    print_step "Creating secrets for ${ENV} environment..."
    "$PROJECT_DIR/scripts/setup/create-secrets.sh" --env "$ENV"

    print_success "All secrets configured"
}

# ══════════════════════════════════════════════════════════════════════════════
# Docker Registry Login
# ══════════════════════════════════════════════════════════════════════════════

check_registry_login() {
    print_header "Docker Registry Authentication"

    local registry="${DOCKER_REGISTRY:-842775dh.c1.gra9.container-registry.ovh.net}"

    print_step "Checking login to $registry..."

    if [ -f "$HOME/.docker/config.json" ] && grep -q "$registry" "$HOME/.docker/config.json" 2>/dev/null; then
        print_success "Already logged in to $registry"
        return 0
    fi

    # Auto-login if credentials were passed from install.sh
    if [ -n "${INDUSTREAM_REGISTRY_USER:-}" ] && [ -n "${INDUSTREAM_REGISTRY_PASSWORD:-}" ]; then
        print_step "Logging in with provided credentials..."
        if echo "$INDUSTREAM_REGISTRY_PASSWORD" | docker login "$registry" -u "$INDUSTREAM_REGISTRY_USER" --password-stdin &> /dev/null; then
            print_success "Registry login successful"
            return 0
        else
            print_error "Registry login failed with provided credentials"
        fi
    fi

    print_warning "Not logged in to Docker registry: $registry"
    echo ""
    echo -e "  ${BLUE}Registry login is required to pull private Industream images.${NC}"
    echo -e "  ${BLUE}You need the credentials provided by Industream.${NC}"
    echo ""
    read -p "  Do you want to log in now? [Y/n] " login_choice
    login_choice="${login_choice:-Y}"

    if [[ "$login_choice" =~ ^[Yy]$ ]]; then
        echo ""
        docker login "$registry"
        if [ $? -ne 0 ]; then
            print_error "Registry login failed"
            read -p "  Continue deployment anyway? [y/N] " continue_choice
            if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                exit 1
            fi
        else
            print_success "Registry login successful"
        fi
    else
        print_warning "Skipping registry login. Image pulls may fail for private images."
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Certificate Generation
# ══════════════════════════════════════════════════════════════════════════════

generate_certificates() {
    print_header "TLS Certificate Configuration"

    # Load environment variables
    source .env
    local domain="${INDUSTREAM_DOMAIN:-industream.platform.lan}"

    echo ""
    echo -e "  Domain: ${BOLD}${domain}${NC}"
    echo ""

    # Suggest TLS mode based on domain
    local suggested="selfsigned"
    if [[ ! "$domain" =~ \.(lan|local|test|localhost)$ ]]; then
        suggested="letsencrypt"
    fi

    echo -e "  ${BOLD}How should TLS certificates be managed?${NC}"
    echo ""
    if [ "$suggested" = "selfsigned" ]; then
        echo "    1) Self-signed certificate (recommended for .lan/.local domains)"
        echo "    2) Let's Encrypt (free, automatic - requires public domain + port 80)"
    else
        echo "    1) Self-signed certificate (for internal/private networks)"
        echo "    2) Let's Encrypt (recommended for public domains)"
    fi
    echo ""

    local tls_choice
    if [ "$suggested" = "selfsigned" ]; then
        read -r -p "  Your choice [1]: " tls_choice
        tls_choice="${tls_choice:-1}"
    else
        read -r -p "  Your choice [2]: " tls_choice
        tls_choice="${tls_choice:-2}"
    fi

    local tls_mode
    case "$tls_choice" in
        1) tls_mode="selfsigned" ;;
        2) tls_mode="letsencrypt" ;;
        *) tls_mode="$suggested" ;;
    esac

    # Update .env with the chosen TLS mode
    if grep -q "^TLS_MODE=" .env; then
        sed -i "s|^TLS_MODE=.*|TLS_MODE=${tls_mode}|" .env
    fi
    print_success "TLS mode: ${tls_mode}"

    # Let's Encrypt mode
    if [ "$tls_mode" = "letsencrypt" ]; then
        echo ""
        print_success "Let's Encrypt will handle certificates automatically"

        # Ask for ACME email if not set
        local current_email="${ACME_EMAIL:-admin@${domain}}"
        echo ""
        read -r -p "  ACME email for Let's Encrypt [$current_email]: " acme_email
        acme_email="${acme_email:-$current_email}"

        if grep -q "^ACME_EMAIL=" .env; then
            sed -i "s|^ACME_EMAIL=.*|ACME_EMAIL=${acme_email}|" .env
        fi
        print_info "ACME email: ${acme_email}"
        echo ""
        print_info "Make sure port 80 is accessible from the internet for ACME validation."
        return 0
    fi

    # Self-signed mode
    print_step "Self-signed certificate for ${domain}"

    # Check if certificate already exists
    if [ -f "certs/${domain}.crt" ] && [ -f "certs/${domain}.key" ]; then
        local expiry=$(openssl x509 -enddate -noout -in "certs/${domain}.crt" 2>/dev/null | cut -d= -f2)
        print_warning "Certificate already exists (expires: ${expiry})"
        if ! ask_yes_no "Regenerate certificate?" "n"; then
            print_success "Keeping existing certificate"
            return 0
        fi
    fi

    # Ask for validity period
    echo ""
    echo -e "  ${BOLD}How long should the certificate be valid?${NC}"
    echo ""
    echo "    1) 1 year"
    echo "    2) 2 years"
    echo "    3) 5 years (recommended)"
    echo "    4) 10 years"
    echo "    5) Custom"
    echo ""

    local choice
    read -r -p "  Your choice [3]: " choice
    choice="${choice:-3}"

    local cert_years
    case "$choice" in
        1) cert_years=1 ;;
        2) cert_years=2 ;;
        3) cert_years=5 ;;
        4) cert_years=10 ;;
        5)
            read -r -p "  Enter number of years: " cert_years
            if ! [[ "$cert_years" =~ ^[0-9]+$ ]] || [ "$cert_years" -lt 1 ]; then
                print_warning "Invalid input. Using default: 5 years"
                cert_years=5
            fi
            ;;
        *) cert_years=5 ;;
    esac

    print_step "Generating certificate valid for ${cert_years} years..."
    ./scripts/generate/generate-certs.sh --domain "$domain" --years "$cert_years" --force

    # Ask about trust installation
    echo ""
    if ask_yes_no "Install certificate in the system trust store? (avoids browser warnings on this machine)" "y"; then
        ./scripts/utils/install-cert-trust.sh 2>/dev/null || {
            print_warning "Auto-install failed. You can install manually later."
        }
    fi

    print_success "Certificate configured"
}

# ══════════════════════════════════════════════════════════════════════════════
# Traefik Shared Infrastructure
# ══════════════════════════════════════════════════════════════════════════════

deploy_traefik() {
    print_header "Traefik Shared Infrastructure"

    # Check if Traefik is already deployed
    if docker stack ls --format '{{.Name}}' 2>/dev/null | grep -q '^traefik-shared$'; then
        print_success "Traefik shared stack is already deployed"
        return 0
    fi

    print_step "Deploying Traefik (shared reverse proxy for all environments)..."
    ./scripts/deploy-traefik.sh

    print_success "Traefik shared infrastructure deployed"
}

# ══════════════════════════════════════════════════════════════════════════════
# Stack Deployment
# ══════════════════════════════════════════════════════════════════════════════

deploy_stack() {
    print_header "Platform Deployment"

    print_step "Running deploy-swarm.sh --env ${ENV}..."
    echo ""
    ./scripts/deploy-swarm.sh --env "$ENV"
}

deploy_demo() {
    if [ "$DEPLOY_DEMO" != "true" ]; then
        return 0
    fi

    print_header "Demo Simulators Deployment"

    if [ ! -d "$DEMO_DIR" ]; then
        print_warning "Demo directory not found: $DEMO_DIR"
        return 1
    fi

    print_step "Waiting for platform to be ready before deploying demo..."
    sleep 10

    print_step "Deploying demo simulators..."
    cd "$DEMO_DIR"

    # Check if docker-stack.demo.yml exists
    if [ -f "docker-stack.demo.yml" ]; then
        docker stack deploy -c docker-stack.demo.yml "${STACK_NAME}-demo"
        print_success "Demo simulators deployed"
    else
        print_warning "docker-stack.demo.yml not found, skipping demo deployment"
    fi

    cd "$PROJECT_DIR"
}

# ══════════════════════════════════════════════════════════════════════════════
# Deployment Validation
# ══════════════════════════════════════════════════════════════════════════════

wait_for_services() {
    print_header "Waiting for Services"

    local max_wait=180  # 3 minutes
    local interval=10
    local elapsed=0

    print_step "Waiting for platform services to start (max ${max_wait}s)..."

    while [ $elapsed -lt $max_wait ]; do
        local total=$(docker stack services "$STACK_NAME" --format '{{.Name}}' 2>/dev/null | wc -l)
        local running=$(docker stack services "$STACK_NAME" --format '{{.Replicas}}' 2>/dev/null | grep -c "1/1" || echo 0)

        echo -ne "\r  Platform services ready: $running/$total (${elapsed}s elapsed)    "

        if [ "$running" -eq "$total" ] && [ "$total" -gt 0 ]; then
            echo ""
            print_success "All $total platform services are running"
            break
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    if [ $elapsed -ge $max_wait ]; then
        echo ""
        print_warning "Timeout waiting for platform services. Some may still be starting."
    fi

    # Wait for demo services if deployed
    if [ "$DEPLOY_DEMO" = "true" ]; then
        echo ""
        print_step "Checking demo services..."
        local demo_total=$(docker stack services ${STACK_NAME}-demo --format '{{.Name}}' 2>/dev/null | wc -l)
        local demo_running=$(docker stack services ${STACK_NAME}-demo --format '{{.Replicas}}' 2>/dev/null | grep -c "1/1" || echo 0)
        print_info "Demo services: $demo_running/$demo_total ready"
    fi
}

show_status() {
    print_header "Deployment Status"

    # Platform services status
    print_step "Platform Services:"
    echo ""
    docker stack services "$STACK_NAME" --format "table {{.Name}}\t{{.Replicas}}\t{{.Image}}" | head -50

    # Check for failing platform services
    echo ""
    local failing=$(docker stack services "$STACK_NAME" --format '{{.Name}} {{.Replicas}}' | grep -v "1/1" | grep -v "NAME" || true)
    if [ -n "$failing" ]; then
        print_warning "Platform services not fully running:"
        echo "$failing" | while read line; do
            echo -e "  ${YELLOW}$line${NC}"
        done
    fi

    # Demo services status if deployed
    if [ "$DEPLOY_DEMO" = "true" ]; then
        echo ""
        print_step "Demo Services:"
        echo ""
        docker stack services ${STACK_NAME}-demo --format "table {{.Name}}\t{{.Replicas}}\t{{.Image}}" 2>/dev/null | head -20 || print_info "Demo services not yet available"
    fi
}

show_logs_summary() {
    print_header "Recent Logs (errors only)"

    local services=("traefik" "postgres" "uifusion-api" "grafana")

    for svc in "${services[@]}"; do
        local full_name="${STACK_NAME}_${svc}"
        local errors=$(docker service logs "$full_name" 2>&1 | grep -i "error\|fatal\|failed" | tail -3 || true)
        if [ -n "$errors" ]; then
            echo -e "${YELLOW}[$svc]${NC}"
            echo "$errors" | head -3
            echo ""
        fi
    done

    print_info "View full logs: docker service logs ${STACK_NAME}_<service>"
}

show_urls() {
    print_header "Stack URLs"

    source .env
    local domain="${INDUSTREAM_DOMAIN:-industream.platform.lan}"

    echo -e "${BOLD}Main Applications:${NC}"
    echo -e "  ${CYAN}Industream Portal${NC}   https://${domain}"
    echo -e "  ${CYAN}Grafana${NC}             https://grafana.${domain}"
    echo -e "  ${CYAN}FlowMaker${NC}           https://flowmaker.${domain}"
    echo -e "  ${CYAN}DataCatalog${NC}         https://datacatalog.${domain}"
    echo ""
    echo -e "${BOLD}Administration:${NC}"
    echo -e "  ${CYAN}Traefik Dashboard${NC}   https://traefik.${domain}"
    echo ""
    echo -e "${BOLD}Monitoring:${NC}"
    echo -e "  ${CYAN}Prometheus${NC}          https://prometheus.${domain}"
    echo -e "  ${CYAN}Alertmanager${NC}        https://alertmanager.${domain}"
    echo -e "  ${CYAN}Ntfy${NC}                https://ntfy.${domain}"
    echo ""
    echo -e "${BOLD}APIs:${NC}"
    echo -e "  ${CYAN}InfluxDB${NC}            https://influxdb.${domain}"
    echo -e "  ${CYAN}Timeseries API${NC}      https://timeseries.${domain}"
    echo ""

    # Show credentials
    print_header "Default Credentials"
    echo -e "${BOLD}Hub Backend (JWT auth) Admin:${NC}"
    echo -e "  User:     (see secrets/${ENV}/hub_backend_admin_user)"
    echo -e "  Password: (see secrets/${ENV}/hub_backend_admin_password)"
    echo ""
    echo -e "${BOLD}Grafana Admin:${NC}"
    echo -e "  User:     ${GRAFANA_ADMIN_USER:-admin}"
    echo -e "  Password: ${GRAFANA_ADMIN_PASSWORD:-<see .env file>}"
    echo ""
    echo -e "${BOLD}InfluxDB Admin:${NC}"
    echo -e "  User:     ${INFLUX_ADMIN_USERNAME:-admin}"
    echo -e "  Password: ${INFLUX_ADMIN_PASSWORD:-<see .env file>}"
    echo ""

    print_warning "Add '127.0.0.1 ${domain}' to /etc/hosts if testing locally"
    echo -e "  Run: ${CYAN}./scripts/setup/setup-subdomains-hosts.sh${NC}"
}

show_demo_info() {
    if [ "$DEPLOY_DEMO" != "true" ]; then
        return 0
    fi

    print_header "Demo Simulators Endpoints"

    echo -e "${BOLD}Industrial Protocol Simulators:${NC}"
    echo -e "  ${CYAN}OPC-UA Server${NC}       opc.tcp://localhost:50000"
    echo -e "  ${CYAN}MQTT Broker${NC}         localhost:1883 (MQTT) / localhost:9001 (WebSocket)"
    echo -e "  ${CYAN}Siemens S7 PLC${NC}      localhost:102"
    echo -e "  ${CYAN}Modbus TCP${NC}          localhost:5020"
    echo ""
    echo -e "${BOLD}Virtual RTSP Cameras:${NC}"
    echo -e "  ${CYAN}Factory Camera${NC}      rtsp://localhost:8554/stream"
    echo -e "  ${CYAN}Warehouse Camera${NC}    rtsp://localhost:8555/stream"
    echo ""
    echo -e "${BOLD}Demo Management:${NC}"
    echo "  docker stack services ${STACK_NAME}-demo    # List demo services"
    echo "  docker stack rm ${STACK_NAME}-demo          # Remove demo only"
    echo ""
}

show_useful_commands() {
    print_header "Useful Commands"

    echo -e "${BOLD}Stack Management:${NC}"
    echo "  docker stack services $STACK_NAME      # List services"
    echo "  docker stack ps $STACK_NAME            # List tasks"
    echo "  docker stack rm $STACK_NAME            # Remove stack"
    echo ""
    echo -e "${BOLD}Service Logs:${NC}"
    echo "  docker service logs ${STACK_NAME}_traefik -f"
    echo "  docker service logs ${STACK_NAME}_uifusion-api -f"
    echo "  docker service logs ${STACK_NAME}_grafana -f"
    echo ""
    echo -e "${BOLD}Restart a Service:${NC}"
    echo "  docker service update --force ${STACK_NAME}_<service>"
    echo ""
    echo -e "${BOLD}Scale a Service:${NC}"
    echo "  docker service scale ${STACK_NAME}_<service>=2"
    echo ""
    echo -e "${BOLD}Update Stack:${NC}"
    echo "  ./scripts/deploy-swarm.sh"
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════

main() {
    clear 2>/dev/null || true
    local username=$(whoami)

    echo ""
    echo -e "                                 ○     ○     ○     ${BLUE}●${NC}"
    echo -e "                                                   ${BLUE}│${NC}"
    echo -e "                                 ○     ${BLUE}●${NC}     ○     ${BLUE}●${NC}"
    echo -e "                                    ${BLUE}╱     ╲     ╱${NC}"
    echo -e "                                 ${BLUE}●${NC}     ○     ${BLUE}●${NC}     ○"
    echo -e "                                 ${BLUE}│${NC}"
    echo -e "                                 ${BLUE}●${NC}     ○     ○     ○"
    echo ""
    echo -e "  ${BOLD}██╗███╗   ██╗██████╗ ██╗   ██╗${NC}${BLUE}███████╗████████╗██████╗ ███████╗ █████╗ ███╗   ███╗${NC}"
    echo -e "  ${BOLD}██║████╗  ██║██╔══██╗██║   ██║${NC}${BLUE}██╔════╝╚══██╔══╝██╔══██╗██╔════╝██╔══██╗████╗ ████║${NC}"
    echo -e "  ${BOLD}██║██╔██╗ ██║██║  ██║██║   ██║${NC}${BLUE}███████╗   ██║   ██████╔╝█████╗  ███████║██╔████╔██║${NC}"
    echo -e "  ${BOLD}██║██║╚██╗██║██║  ██║██║   ██║${NC}${BLUE}╚════██║   ██║   ██╔══██╗██╔══╝  ██╔══██║██║╚██╔╝██║${NC}"
    echo -e "  ${BOLD}██║██║ ╚████║██████╔╝╚██████╔╝${NC}${BLUE}███████║   ██║   ██║  ██║███████╗██║  ██║██║ ╚═╝ ██║${NC}"
    echo -e "  ${BOLD}╚═╝╚═╝  ╚═══╝╚═════╝  ╚═════╝ ${NC}${BLUE}╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝${NC}"
    echo ""
    echo ""
    echo -e "  ${BOLD}Welcome ${GREEN}${username}${NC}${BOLD} to the Industream Platform installer!${NC}"
    echo ""
    echo -e "  ${CYAN}This wizard will guide you through the first deployment:${NC}"
    echo -e "    1. Check prerequisites (Docker, Python, OpenSSL...)"
    echo -e "    2. Initialize Docker Swarm"
    echo -e "    3. Configure your environment (.env)"
    echo -e "    4. Set up TLS certificates"
    echo -e "    5. Create Docker secrets"
    echo -e "    6. Deploy Traefik (shared reverse proxy)"
    echo -e "    7. Deploy the platform"
    echo ""
    echo -e "  ${YELLOW}Estimated time: 5-10 minutes${NC}"
    echo ""
    read -r -p "  Press Enter to start... "

    # Run all steps
    check_prerequisites
    init_swarm
    select_deployment_type
    generate_env
    check_registry_login
    create_secrets
    generate_certificates
    deploy_traefik
    deploy_stack
    deploy_demo
    wait_for_services
    show_status
    show_urls
    show_demo_info
    show_useful_commands

    print_header "Deployment Complete"
    print_success "Industream Platform is now running!"
    if [ "$DEPLOY_DEMO" = "true" ]; then
        print_info "Demo simulators are also deployed"
    fi
    echo ""
}

# Run main function
main "$@"
