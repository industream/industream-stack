#!/bin/bash
# =============================================================================
# INDUSTREAM PLATFORM - Unified Deployment Script
# =============================================================================
# Multi-environment deployment tool supporting prod, dev, and staging.
#
# Usage:
#   ./industream.sh              # Interactive mode
#   ./industream.sh deploy       # Deploy with environment selection
#   ./industream.sh status       # Show deployment status
#   ./industream.sh stop         # Stop services
#   ./industream.sh logs <svc>   # View service logs
#   ./industream.sh uninstall    # Uninstall environments
# =============================================================================

set -e

# =============================================================================
# Colors and Styling
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Icons
ICON_CHECK='✔'
ICON_CROSS='✖'
ICON_WARN='⚠'
ICON_ARROW='▶'
ICON_DOT='●'
ICON_CIRCLE='○'
ICON_GEAR='⚙'

TRAEFIK_STACK_NAME="traefik-shared"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$SCRIPT_DIR/../industream-platform-demo"

# Load base domain from .env
if [ -f "$SCRIPT_DIR/.env" ]; then
    INDUSTREAM_DOMAIN=$(grep -E '^INDUSTREAM_DOMAIN=' "$SCRIPT_DIR/.env" | cut -d= -f2-)
fi
INDUSTREAM_DOMAIN="${INDUSTREAM_DOMAIN:-industream.platform.lan}"

# =============================================================================
# UI Helper Functions
# =============================================================================

print_banner() {
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
    echo -e "          ${GRAY}Industrial Data Platform - Multi-Environment Deployment${NC}"
    echo ""
}

print_small_banner() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  ${ICON_GEAR}  ${WHITE}${BOLD}INDUSTREAM PLATFORM${NC} ${GRAY}- Multi-Environment Deployment Tool${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_section() {
    local title="$1"
    echo ""
    echo -e "${BLUE}┌─${NC} ${WHITE}${BOLD}$title${NC}"
    echo -e "${BLUE}│${NC}"
}

print_section_end() {
    echo -e "${BLUE}│${NC}"
}

print_step() {
    echo -e "${BLUE}│${NC}  ${CYAN}${ICON_ARROW}${NC} $1"
}

print_success() {
    echo -e "${BLUE}│${NC}  ${GREEN}${ICON_CHECK}${NC} $1"
}

print_warning() {
    echo -e "${BLUE}│${NC}  ${YELLOW}${ICON_WARN}${NC} $1"
}

print_error() {
    echo -e "${BLUE}│${NC}  ${RED}${ICON_CROSS}${NC} $1"
}

print_info() {
    echo -e "${BLUE}│${NC}    ${GRAY}$1${NC}"
}

print_item() {
    local status="$1"
    local text="$2"
    local icon

    case "$status" in
        ok)     icon="${GREEN}${ICON_DOT}${NC}" ;;
        warn)   icon="${YELLOW}${ICON_DOT}${NC}" ;;
        error)  icon="${RED}${ICON_DOT}${NC}" ;;
        none)   icon="${GRAY}${ICON_CIRCLE}${NC}" ;;
        *)      icon="${GRAY}${ICON_DOT}${NC}" ;;
    esac

    echo -e "${BLUE}│${NC}    $icon $text"
}

# =============================================================================
# Detection Functions
# =============================================================================

is_docker_installed() {
    command -v docker &> /dev/null
}

is_docker_running() {
    docker info &> /dev/null
}

is_swarm_active() {
    [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" = "active" ]
}

is_env_configured() {
    [ -f "$SCRIPT_DIR/.env" ]
}

# Auto-detect server IP (same logic as deploy-swarm.sh)
detect_server_ip() {
    local ip=""

    # Method 1: Get IP from default route interface
    local default_iface
    default_iface=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -1)
    if [ -n "$default_iface" ]; then
        ip=$(ip -4 addr show "$default_iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    fi

    # Method 2: Fallback to hostname -I
    if [ -z "$ip" ] || [ "$ip" = "127.0.0.1" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    # Method 3: Last resort - any non-docker, non-localhost IP
    if [ -z "$ip" ] || [ "$ip" = "127.0.0.1" ]; then
        ip=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | grep -v '^172\.1[7-9]\.' | grep -v '^172\.2[0-9]\.' | grep -v '^172\.3[0-1]\.' | head -1)
    fi

    echo "${ip:-127.0.0.1}"
}

# Interactive .env setup wizard
ensure_env_configured() {
    # Already configured - nothing to do
    if [ -f "$SCRIPT_DIR/.env" ]; then
        return 0
    fi

    # Check that .env.example exists
    if [ ! -f "$SCRIPT_DIR/.env.example" ]; then
        print_section "Configuration Error"
        print_error ".env.example not found in $SCRIPT_DIR"
        print_info "Cannot generate .env without a template."
        print_section_end
        exit 1
    fi

    print_section "Initial Configuration"
    print_warning "No .env file found - starting setup wizard"
    echo -e "${BLUE}│${NC}"

    # Copy template
    print_step "Copying .env.example → .env"
    cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
    print_success "Template copied"

    # Auto-detect server IP
    print_step "Detecting server IP..."
    local server_ip
    server_ip=$(detect_server_ip)
    print_success "Detected IP: ${WHITE}${BOLD}$server_ip${NC}"

    # Inject INDUSTREAM_SERVER_IP into .env (append if not present, replace if present)
    if grep -q '^INDUSTREAM_SERVER_IP=' "$SCRIPT_DIR/.env"; then
        sed -i "s|^INDUSTREAM_SERVER_IP=.*|INDUSTREAM_SERVER_IP=$server_ip|" "$SCRIPT_DIR/.env"
    else
        echo "" >> "$SCRIPT_DIR/.env"
        echo "# ============================================" >> "$SCRIPT_DIR/.env"
        echo "# Server IP (auto-detected)" >> "$SCRIPT_DIR/.env"
        echo "# ============================================" >> "$SCRIPT_DIR/.env"
        echo "INDUSTREAM_SERVER_IP=$server_ip" >> "$SCRIPT_DIR/.env"
    fi

    # Read key values from the freshly created .env
    local env_domain env_registry env_tls
    env_domain=$(grep -E '^INDUSTREAM_DOMAIN=' "$SCRIPT_DIR/.env" | cut -d= -f2-)
    env_registry=$(grep -E '^DOCKER_REGISTRY=' "$SCRIPT_DIR/.env" | cut -d= -f2-)
    env_tls=$(grep -E '^TLS_MODE=' "$SCRIPT_DIR/.env" | cut -d= -f2-)

    # Display summary
    echo -e "${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}  ${WHITE}${BOLD}Configuration Summary${NC}"
    echo -e "${BLUE}│${NC}    ${CYAN}INDUSTREAM_DOMAIN${NC}     ${WHITE}${env_domain:-industream.example.com}${NC}"
    echo -e "${BLUE}│${NC}    ${CYAN}INDUSTREAM_SERVER_IP${NC}  ${WHITE}${server_ip}${NC}"
    echo -e "${BLUE}│${NC}    ${CYAN}TLS_MODE${NC}              ${WHITE}${env_tls:-selfsigned}${NC} ${GRAY}(set in .env.prod)${NC}"
    echo -e "${BLUE}│${NC}    ${CYAN}DOCKER_REGISTRY${NC}       ${WHITE}${env_registry:-not set}${NC}"
    echo -e "${BLUE}│${NC}"

    # Ask user for confirmation
    while true; do
        echo -e "${BLUE}│${NC}  ${YELLOW}?${NC} Configuration OK? ${GRAY}[Y/n/e]${NC}"
        echo -e "${BLUE}│${NC}    ${GRAY}Y = continue, n = exit to edit manually, e = open in editor${NC}"
        read -p "    > " answer
        answer="${answer:-Y}"

        case "$answer" in
            [Yy]|[Yy]es)
                print_success "Configuration accepted"
                break
                ;;
            [Nn]|[Nn]o)
                print_warning "Edit .env manually, then re-run ./industream.sh"
                print_section_end
                exit 0
                ;;
            [Ee]|[Ee]dit)
                local editor="${EDITOR:-${VISUAL:-}}"
                if [ -z "$editor" ]; then
                    if command -v nano &>/dev/null; then
                        editor="nano"
                    elif command -v vi &>/dev/null; then
                        editor="vi"
                    else
                        print_error "No editor found. Set \$EDITOR and re-run."
                        continue
                    fi
                fi
                print_step "Opening .env in $editor..."
                $editor "$SCRIPT_DIR/.env"
                print_success "Editor closed"
                echo -e "${BLUE}│${NC}"

                # Re-read values after editing
                env_domain=$(grep -E '^INDUSTREAM_DOMAIN=' "$SCRIPT_DIR/.env" | cut -d= -f2-)
                server_ip=$(grep -E '^INDUSTREAM_SERVER_IP=' "$SCRIPT_DIR/.env" | cut -d= -f2-)
                env_registry=$(grep -E '^DOCKER_REGISTRY=' "$SCRIPT_DIR/.env" | cut -d= -f2-)
                env_tls=$(grep -E '^TLS_MODE=' "$SCRIPT_DIR/.env" | cut -d= -f2-)

                echo -e "${BLUE}│${NC}  ${WHITE}${BOLD}Updated Configuration${NC}"
                echo -e "${BLUE}│${NC}    ${CYAN}INDUSTREAM_DOMAIN${NC}     ${WHITE}${env_domain:-industream.example.com}${NC}"
                echo -e "${BLUE}│${NC}    ${CYAN}INDUSTREAM_SERVER_IP${NC}  ${WHITE}${server_ip:-not set}${NC}"
                echo -e "${BLUE}│${NC}    ${CYAN}TLS_MODE${NC}              ${WHITE}${env_tls:-selfsigned}${NC}"
                echo -e "${BLUE}│${NC}    ${CYAN}DOCKER_REGISTRY${NC}       ${WHITE}${env_registry:-not set}${NC}"
                echo -e "${BLUE}│${NC}"
                ;;
            *)
                print_warning "Invalid choice. Please enter Y, n, or e."
                ;;
        esac
    done

    print_section_end

    # Reload INDUSTREAM_DOMAIN from the potentially modified .env
    INDUSTREAM_DOMAIN=$(grep -E '^INDUSTREAM_DOMAIN=' "$SCRIPT_DIR/.env" | cut -d= -f2-)
    INDUSTREAM_DOMAIN="${INDUSTREAM_DOMAIN:-industream.platform.lan}"
}

is_traefik_deployed() {
    docker stack ls 2>/dev/null | grep -q "^${TRAEFIK_STACK_NAME}"
}

is_env_deployed() {
    local env_name="$1"
    docker stack ls 2>/dev/null | grep -q "^industream-${env_name}"
}

are_env_secrets_created() {
    local env_name="$1"
    local required_secrets=(
        "${env_name}_postgres_admin_password"
        "${env_name}_keycloak_admin_password"
        "${env_name}_influx_admin_token"
    )
    local existing_secrets=$(docker secret ls --format '{{.Name}}' 2>/dev/null)
    for secret in "${required_secrets[@]}"; do
        if ! echo "$existing_secrets" | grep -q "^${secret}$"; then
            return 1
        fi
    done
    return 0
}

is_demo_deployed() {
    local env_name="${1:-prod}"
    docker stack ls 2>/dev/null | grep -q "^industream-${env_name}-demo"
}

is_demo_available() {
    [ -d "$DEMO_DIR" ] && [ -f "$DEMO_DIR/docker-stack.demo.yml" ]
}

get_deployed_envs() {
    docker stack ls --format '{{.Name}}' 2>/dev/null | grep "^industream-" | grep -v "demo" | sed 's/industream-//' | sort
}

# =============================================================================
# Status Display
# =============================================================================

show_environment_status() {
    print_section "Environment Status"

    # Docker
    if is_docker_installed; then
        local docker_version=$(docker --version | cut -d' ' -f3 | tr -d ',')
        if is_docker_running; then
            print_item ok "Docker ${GRAY}v$docker_version${NC}"
        else
            print_item warn "Docker ${GRAY}v$docker_version (daemon stopped)${NC}"
        fi
    else
        print_item error "Docker ${GRAY}not installed${NC}"
    fi

    # Swarm
    if is_swarm_active; then
        local node_count=$(docker node ls --format '{{.ID}}' 2>/dev/null | wc -l)
        print_item ok "Docker Swarm ${GRAY}($node_count node(s))${NC}"
    else
        print_item warn "Docker Swarm ${GRAY}not initialized${NC}"
    fi

    # Environment file
    if is_env_configured; then
        print_item ok "Configuration ${GRAY}.env file${NC}"
    else
        print_item warn "Configuration ${GRAY}missing .env${NC}"
    fi

    # Traefik
    if is_traefik_deployed; then
        print_item ok "Traefik ${GRAY}shared infrastructure running${NC}"
    else
        print_item warn "Traefik ${GRAY}not deployed${NC}"
    fi

    print_section_end
}

show_deployment_status() {
    print_section "Deployment Status"

    local envs=("prod" "dev" "staging")

    for env in "${envs[@]}"; do
        if is_env_deployed "$env"; then
            local stack_name="industream-${env}"
            local total=$(docker stack services $stack_name --format '{{.Name}}' 2>/dev/null | wc -l)
            local running=$(docker stack services $stack_name --format '{{.Replicas}}' 2>/dev/null | grep -c "1/1" || echo 0)
            if [ "$running" -eq "$total" ]; then
                print_item ok "${env^^} ${GRAY}$running/$total services running${NC}"
            else
                print_item warn "${env^^} ${GRAY}$running/$total services running${NC}"
            fi

            # Check demo
            if is_demo_deployed "$env"; then
                print_info "  + Demo simulators running"
            fi
        else
            if are_env_secrets_created "$env"; then
                print_item none "${env^^} ${GRAY}ready (secrets exist)${NC}"
            else
                print_item none "${env^^} ${GRAY}not configured${NC}"
            fi
        fi
    done

    print_section_end
}

show_services() {
    local envs=$(get_deployed_envs)

    if [ -z "$envs" ]; then
        print_warning "No environments deployed"
        return
    fi

    for env in $envs; do
        local stack_name="industream-${env}"
        print_section "${env^^} Environment Services"
        echo -e "${BLUE}│${NC}"
        docker stack services $stack_name --format "table {{.Name}}\t{{.Replicas}}\t{{.Image}}" 2>/dev/null | \
            while IFS= read -r line; do
                echo -e "${BLUE}│${NC}    $line"
            done
        print_section_end
    done
}

show_urls() {
    local envs=$(get_deployed_envs)

    if [ -z "$envs" ]; then
        print_warning "No environments deployed"
        return
    fi

    for env in $envs; do
        source "$SCRIPT_DIR/.env" 2>/dev/null || true
        source "$SCRIPT_DIR/.env.${env}" 2>/dev/null || true
        local domain="${INDUSTREAM_DOMAIN:-industream.platform.lan}"

        print_section "${env^^} Environment URLs"
        echo -e "${BLUE}│${NC}"
        echo -e "${BLUE}│${NC}    ${WHITE}${BOLD}Main Applications${NC}"
        echo -e "${BLUE}│${NC}    ${CYAN}Portal${NC}        https://${domain}"
        echo -e "${BLUE}│${NC}    ${CYAN}Dashboard${NC}     https://dashboard.${domain}"
        echo -e "${BLUE}│${NC}    ${CYAN}FlowMaker${NC}     https://flowmaker.${domain}"
        echo -e "${BLUE}│${NC}    ${CYAN}DataCatalog${NC}   https://datacatalog.${domain}"
        echo -e "${BLUE}│${NC}"
        echo -e "${BLUE}│${NC}    ${WHITE}${BOLD}Administration${NC}"
        echo -e "${BLUE}│${NC}    ${CYAN}Keycloak${NC}      https://${domain}/auth"
        echo -e "${BLUE}│${NC}    ${CYAN}InfluxDB${NC}      https://${domain}/influxdb"
        print_section_end
    done
}

# =============================================================================
# Documentation Generation
# =============================================================================

generate_simulators_doc() {
    local env_name="$1"
    local template="$SCRIPT_DIR/SIMULATORS.md"
    local output="$SCRIPT_DIR/SIMULATORS-${env_name}.md"

    if [ ! -f "$template" ]; then
        print_warning "SIMULATORS.md template not found, skipping doc generation"
        return 0
    fi

    # Load variables from .env files
    local env_file="$SCRIPT_DIR/.env"
    local env_override="$SCRIPT_DIR/.env.${env_name}"

    # Read values (with defaults)
    local server_ip influxdb_version flowmaker_box_version domain
    if [ -f "$env_file" ]; then
        server_ip=$(grep -E '^INDUSTREAM_SERVER_IP=' "$env_file" | cut -d= -f2-)
        influxdb_version=$(grep -E '^INFLUXDB_VERSION=' "$env_file" | cut -d= -f2-)
        flowmaker_box_version=$(grep -E '^FLOWMAKER_BOX_VERSION=' "$env_file" | cut -d= -f2-)
    fi
    if [ -f "$env_override" ]; then
        domain=$(grep -E '^INDUSTREAM_DOMAIN=' "$env_override" | cut -d= -f2-)
    fi

    # Fallbacks
    server_ip="${server_ip:-$(detect_server_ip)}"
    influxdb_version="${influxdb_version:-2.7}"
    flowmaker_box_version="${flowmaker_box_version:-latest}"
    domain="${domain:-${INDUSTREAM_DOMAIN:-industream.platform.lan}}"

    # Generate resolved doc
    sed \
        -e "s|\${ENV}|${env_name}|g" \
        -e "s|\${INDUSTREAM_SERVER_IP}|${server_ip}|g" \
        -e "s|\${INFLUXDB_VERSION}|${influxdb_version}|g" \
        -e "s|\${FLOWMAKER_BOX_VERSION}|${flowmaker_box_version}|g" \
        -e "s|\${INDUSTREAM_DOMAIN}|${domain}|g" \
        "$template" > "$output"

    print_success "Generated ${CYAN}SIMULATORS-${env_name}.md${NC} with resolved values"
    print_info "Server IP: $server_ip | InfluxDB: $influxdb_version | Workers: $flowmaker_box_version"
}

# =============================================================================
# Actions
# =============================================================================

deploy_traefik() {
    print_section "Deploying Traefik Shared Infrastructure"

    if is_traefik_deployed; then
        print_warning "Traefik already deployed, updating..."
    fi

    print_step "Running deploy-traefik.sh..."
    "$SCRIPT_DIR/scripts/deploy-traefik.sh"

    print_success "Traefik deployed successfully"
    print_section_end
}

create_secrets_for_env() {
    local env_name="$1"

    if are_env_secrets_created "$env_name"; then
        print_info "Secrets for ${env_name} already exist"
        return 0
    fi

    print_step "Creating secrets for ${env_name}..."
    "$SCRIPT_DIR/scripts/setup/create-secrets.sh" --env "$env_name"
}

deploy_environment() {
    local env_name="$1"
    local with_demo="${2:-false}"

    print_section "Deploying ${env_name^^} Environment"

    # Check Traefik
    if ! is_traefik_deployed; then
        print_step "Traefik not deployed, deploying first..."
        deploy_traefik
    fi

    # Check secrets
    if ! are_env_secrets_created "$env_name"; then
        create_secrets_for_env "$env_name"
    fi

    # Deploy
    print_step "Deploying ${env_name} stack..."
    if [ "$with_demo" = "true" ]; then
        "$SCRIPT_DIR/scripts/deploy-swarm.sh" --env "$env_name" --with-demo
    else
        "$SCRIPT_DIR/scripts/deploy-swarm.sh" --env "$env_name"
    fi

    print_success "${env_name^^} environment deployed"

    # Generate resolved simulators doc when demo is included
    if [ "$with_demo" = "true" ]; then
        generate_simulators_doc "$env_name"
    fi

    print_section_end
}

stop_environment() {
    local env_name="$1"
    local stack_name="industream-${env_name}"
    local demo_stack_name="${stack_name}-demo"

    print_section "Stopping ${env_name^^} Environment"

    if is_demo_deployed "$env_name"; then
        print_step "Stopping demo simulators..."
        docker stack rm "$demo_stack_name"
        print_success "Demo stopped"
    fi

    if is_env_deployed "$env_name"; then
        print_step "Stopping ${env_name} stack..."
        docker stack rm "$stack_name"
        print_success "${env_name^^} stopped"
    else
        print_warning "${env_name^^} was not deployed"
    fi

    print_section_end
}

run_logs() {
    local service="$1"

    if [ -z "$service" ]; then
        print_section "Available Services"
        local envs=$(get_deployed_envs)
        for env in $envs; do
            print_info "${env^^}:"
            docker stack services "industream-${env}" --format "    {{.Name}}" 2>/dev/null
        done
        print_section_end
        echo ""
        echo "Usage: ./industream.sh logs <service-name>"
        exit 1
    fi

    docker service logs -f "$service"
}

# =============================================================================
# Interactive Menus
# =============================================================================

select_environments_menu() {
    local title="${1:-Select environments to deploy}"

    # All UI output goes to stderr so stdout only contains the result
    print_section "$title" >&2
    echo -e "${BLUE}│${NC}" >&2
    echo -e "${BLUE}│${NC}    ${WHITE}1)${NC} Production only ${GRAY}(${INDUSTREAM_DOMAIN})${NC}" >&2
    echo -e "${BLUE}│${NC}    ${WHITE}2)${NC} Production + Development ${GRAY}(+ dev.${INDUSTREAM_DOMAIN})${NC}" >&2
    echo -e "${BLUE}│${NC}    ${WHITE}3)${NC} Production + Staging ${GRAY}(+ staging.${INDUSTREAM_DOMAIN})${NC}" >&2
    echo -e "${BLUE}│${NC}    ${WHITE}4)${NC} All environments ${GRAY}(prod + dev + staging)${NC}" >&2
    echo -e "${BLUE}│${NC}    ${WHITE}5)${NC} Development only ${GRAY}(dev.${INDUSTREAM_DOMAIN})${NC}" >&2
    echo -e "${BLUE}│${NC}    ${WHITE}6)${NC} Staging only ${GRAY}(staging.${INDUSTREAM_DOMAIN})${NC}" >&2
    echo -e "${BLUE}│${NC}    ${WHITE}7)${NC} Custom selection" >&2
    echo -e "${BLUE}│${NC}    ${GRAY}0)${NC} Cancel" >&2
    print_section_end >&2

    echo "" >&2
    read -p "  Your choice [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1) echo "prod" ;;
        2) echo "prod dev" ;;
        3) echo "prod staging" ;;
        4) echo "prod dev staging" ;;
        5) echo "dev" ;;
        6) echo "staging" ;;
        7)
            echo "" >&2
            echo -e "  ${CYAN}Select environments (space-separated):${NC}" >&2
            echo -e "  ${GRAY}Available: prod dev staging${NC}" >&2
            read -p "  Environments: " custom_envs
            echo "$custom_envs"
            ;;
        0) echo "" ;;
        *) echo "" ;;
    esac
}

deploy_menu() {
    local with_demo=false

    # Ask for demo
    echo ""
    read -p "  Include demo simulators? [y/N]: " demo_answer
    if [[ "$demo_answer" =~ ^[Yy]$ ]]; then
        with_demo=true
    fi

    # Select environments (UI goes to stderr, result to stdout)
    local envs
    envs=$(select_environments_menu "Select environments to deploy")

    if [ -z "$envs" ]; then
        print_warning "No environment selected"
        return
    fi

    # Confirm
    echo ""
    echo -e "  ${CYAN}Will deploy:${NC} $envs"
    if [ "$with_demo" = "true" ]; then
        echo -e "  ${CYAN}With demo:${NC} yes"
    fi
    read -p "  Continue? [Y/n]: " confirm
    confirm="${confirm:-Y}"

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "Deployment cancelled"
        return
    fi

    # Deploy each environment
    for env in $envs; do
        deploy_environment "$env" "$with_demo"
    done

    echo ""
    echo -e "${GREEN}${BOLD}All selected environments deployed!${NC}"
    echo ""
}

stop_menu() {
    local deployed_envs=$(get_deployed_envs)

    if [ -z "$deployed_envs" ]; then
        print_warning "No environments deployed"
        return
    fi

    print_section "Select environments to stop"
    echo -e "${BLUE}│${NC}"
    local i=1
    for env in $deployed_envs; do
        echo -e "${BLUE}│${NC}    ${WHITE}$i)${NC} ${env^^}"
        ((i++))
    done
    echo -e "${BLUE}│${NC}    ${WHITE}a)${NC} All deployed environments"
    echo -e "${BLUE}│${NC}    ${WHITE}t)${NC} Stop Traefik (stops all routing!)"
    echo -e "${BLUE}│${NC}    ${GRAY}0)${NC} Cancel"
    print_section_end

    echo ""
    read -p "  Your choice: " choice

    case "$choice" in
        0|"") return ;;
        a|A)
            for env in $deployed_envs; do
                stop_environment "$env"
            done
            ;;
        t|T)
            echo ""
            echo -e "  ${RED}${BOLD}WARNING:${NC} This will stop Traefik and break routing for all environments!"
            read -p "  Are you sure? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                docker stack rm "$TRAEFIK_STACK_NAME"
                print_success "Traefik stopped"
            fi
            ;;
        [1-9]*)
            local env_array=($deployed_envs)
            local idx=$((choice - 1))
            if [ $idx -lt ${#env_array[@]} ]; then
                stop_environment "${env_array[$idx]}"
            else
                print_warning "Invalid choice"
            fi
            ;;
        *) print_warning "Invalid choice" ;;
    esac
}

uninstall_menu() {
    local deployed_envs=$(get_deployed_envs)

    print_section "Uninstall"
    echo -e "${BLUE}│${NC}"

    if [ -z "$deployed_envs" ]; then
        echo -e "${BLUE}│${NC}  ${YELLOW}No environments currently deployed${NC}"
        echo -e "${BLUE}│${NC}"
    fi

    echo -e "${BLUE}│${NC}    ${WHITE}1)${NC} Uninstall a specific environment"
    echo -e "${BLUE}│${NC}    ${WHITE}2)${NC} Uninstall everything ${GRAY}(all envs + Traefik)${NC}"
    echo -e "${BLUE}│${NC}    ${WHITE}3)${NC} Full cleanup ${GRAY}(everything + .env, secrets, certs)${NC}"
    echo -e "${BLUE}│${NC}    ${WHITE}d)${NC} Dry run ${GRAY}(preview what would be deleted)${NC}"
    echo -e "${BLUE}│${NC}    ${GRAY}0)${NC} Cancel"
    print_section_end

    echo ""
    read -p "  Your choice: " choice

    case "$choice" in
        1)
            echo ""
            echo -e "  ${CYAN}Available environments: prod dev staging${NC}"
            read -p "  Environment to uninstall: " env_name
            if [ -n "$env_name" ]; then
                "$SCRIPT_DIR/scripts/uninstall.sh" --env "$env_name"
            fi
            ;;
        2)
            "$SCRIPT_DIR/scripts/uninstall.sh" --all
            ;;
        3)
            "$SCRIPT_DIR/scripts/uninstall.sh" --all --delete-data
            ;;
        d|D)
            "$SCRIPT_DIR/scripts/uninstall.sh" --all --dry-run
            ;;
        0|"") return ;;
        *) print_warning "Invalid choice" ;;
    esac
}

show_menu() {
    local deployed_envs=$(get_deployed_envs)
    local has_traefik=$(is_traefik_deployed && echo "yes" || echo "no")

    echo ""
    echo -e "${BLUE}┌─${NC} ${WHITE}${BOLD}Actions${NC}"
    echo -e "${BLUE}│${NC}"

    if ! is_docker_installed; then
        echo -e "${BLUE}│${NC}  ${YELLOW}Docker is not installed${NC}"
        echo -e "${BLUE}│${NC}"
        echo -e "${BLUE}│${NC}    ${WHITE}1)${NC} Install Docker and start first deployment"
        echo -e "${BLUE}│${NC}    ${GRAY}0)${NC} Exit"
        print_section_end

        echo ""
        read -p "  Your choice [1]: " choice
        choice="${choice:-1}"

        case "$choice" in
            1) exec "$SCRIPT_DIR/scripts/setup/first-deployment.sh" ;;
            0) exit 0 ;;
            *) print_warning "Invalid choice" ;;
        esac
        return
    fi

    if ! is_docker_running; then
        echo -e "${BLUE}│${NC}  ${YELLOW}Docker daemon is not running${NC}"
        echo -e "${BLUE}│${NC}"
        echo -e "${BLUE}│${NC}    ${WHITE}1)${NC} Start Docker and run first deployment"
        echo -e "${BLUE}│${NC}    ${GRAY}0)${NC} Exit"
        print_section_end

        echo ""
        read -p "  Your choice [1]: " choice
        choice="${choice:-1}"

        case "$choice" in
            1) exec "$SCRIPT_DIR/scripts/setup/first-deployment.sh" ;;
            0) exit 0 ;;
            *) print_warning "Invalid choice" ;;
        esac
        return
    fi

    if ! is_swarm_active; then
        echo -e "${BLUE}│${NC}  ${YELLOW}Docker Swarm not initialized${NC}"
        echo -e "${BLUE}│${NC}"
        echo -e "${BLUE}│${NC}    ${WHITE}1)${NC} Initialize Swarm and start first deployment"
        echo -e "${BLUE}│${NC}    ${GRAY}0)${NC} Exit"
        print_section_end

        echo ""
        read -p "  Your choice [1]: " choice
        choice="${choice:-1}"

        case "$choice" in
            1) exec "$SCRIPT_DIR/scripts/setup/first-deployment.sh" ;;
            0) exit 0 ;;
            *) print_warning "Invalid choice" ;;
        esac
        return
    fi

    if [ -z "$deployed_envs" ]; then
        echo -e "${BLUE}│${NC}  ${CYAN}No environments deployed${NC}"
        echo -e "${BLUE}│${NC}"
        if [ "$has_traefik" = "yes" ]; then
            echo -e "${BLUE}│${NC}    ${WHITE}1)${NC} Deploy environment(s)"
        else
            echo -e "${BLUE}│${NC}    ${WHITE}1)${NC} Deploy Traefik + environment(s)"
        fi
        echo -e "${BLUE}│${NC}    ${WHITE}2)${NC} Run first deployment wizard"
        echo -e "${BLUE}│${NC}    ${GRAY}0)${NC} Exit"
        print_section_end

        echo ""
        read -p "  Your choice [1]: " choice
        choice="${choice:-1}"

        case "$choice" in
            1) deploy_menu ;;
            2) exec "$SCRIPT_DIR/scripts/setup/first-deployment.sh" ;;
            0) exit 0 ;;
            *) print_warning "Invalid choice" ;;
        esac
    else
        echo -e "${BLUE}│${NC}  ${GREEN}Deployed: ${deployed_envs}${NC}"
        echo -e "${BLUE}│${NC}"
        echo -e "${BLUE}│${NC}    ${WHITE}1)${NC} Deploy/update environment(s)"
        echo -e "${BLUE}│${NC}    ${WHITE}2)${NC} Show services"
        echo -e "${BLUE}│${NC}    ${WHITE}3)${NC} Show URLs"
        echo -e "${BLUE}│${NC}    ${WHITE}4)${NC} Stop environment(s)"
        echo -e "${BLUE}│${NC}    ${WHITE}5)${NC} View logs"
        echo -e "${BLUE}│${NC}    ${RED}6)${NC} Uninstall"
        echo -e "${BLUE}│${NC}    ${GRAY}0)${NC} Exit"
        print_section_end

        echo ""
        read -p "  Your choice [2]: " choice
        choice="${choice:-2}"

        case "$choice" in
            1) deploy_menu ;;
            2) show_services ;;
            3) show_urls ;;
            4) stop_menu ;;
            5)
                echo ""
                read -p "  Service name: " svc
                run_logs "$svc"
                ;;
            6) uninstall_menu ;;
            0) exit 0 ;;
            *) print_warning "Invalid choice" ;;
        esac
    fi
}

# =============================================================================
# Help
# =============================================================================

show_help() {
    print_small_banner

    echo -e "${WHITE}${BOLD}USAGE${NC}"
    echo "    ./industream.sh [COMMAND] [OPTIONS]"
    echo ""
    echo -e "${WHITE}${BOLD}COMMANDS${NC}"
    echo -e "    ${CYAN}(none)${NC}              Interactive mode with environment selection"
    echo -e "    ${CYAN}deploy${NC}              Deploy with environment selection menu"
    echo -e "    ${CYAN}deploy --env <env>${NC}  Deploy specific environment (prod|dev|staging)"
    echo -e "    ${CYAN}status${NC}              Show all deployment statuses"
    echo -e "    ${CYAN}services${NC}            List all running services"
    echo -e "    ${CYAN}urls${NC}                Show access URLs for all environments"
    echo -e "    ${CYAN}stop${NC}                Stop environments (interactive)"
    echo -e "    ${CYAN}stop --env <env>${NC}    Stop specific environment"
    echo -e "    ${CYAN}logs${NC} <service>      View service logs"
    echo -e "    ${CYAN}docs${NC}                Generate SIMULATORS-<env>.md with resolved values"
    echo -e "    ${CYAN}docs --env <env>${NC}   Generate for specific environment"
    echo -e "    ${CYAN}uninstall${NC}           Uninstall environments (interactive)"
    echo -e "    ${CYAN}uninstall --all${NC}     Uninstall everything"
    echo -e "    ${CYAN}uninstall --env <e>${NC} Uninstall specific environment"
    echo -e "    ${CYAN}help${NC}                Show this help"
    echo ""
    echo -e "${WHITE}${BOLD}OPTIONS${NC}"
    echo -e "    ${CYAN}--env <env>${NC}         Specify environment (prod, dev, staging)"
    echo -e "    ${CYAN}--with-demo${NC}         Include demo simulators"
    echo -e "    ${CYAN}--all${NC}               Target all environments (uninstall)"
    echo -e "    ${CYAN}--delete-data${NC}       Also remove .env, secrets/, certs/ (uninstall)"
    echo -e "    ${CYAN}--dry-run${NC}           Preview what would be deleted (uninstall)"
    echo -e "    ${CYAN}--force${NC}             Skip confirmation prompts (uninstall)"
    echo ""
    echo -e "${WHITE}${BOLD}ENVIRONMENTS${NC}"
    echo -e "    ${CYAN}prod${NC}     Production    ${GRAY}${INDUSTREAM_DOMAIN}${NC}"
    echo -e "    ${CYAN}dev${NC}      Development   ${GRAY}dev.${INDUSTREAM_DOMAIN}${NC}"
    echo -e "    ${CYAN}staging${NC}  Staging       ${GRAY}staging.${INDUSTREAM_DOMAIN}${NC}"
    echo ""
    echo -e "${WHITE}${BOLD}EXAMPLES${NC}"
    echo "    ./industream.sh                          # Interactive menu"
    echo "    ./industream.sh deploy                   # Deploy with selection"
    echo "    ./industream.sh deploy --env prod        # Deploy production only"
    echo "    ./industream.sh deploy --env dev --with-demo"
    echo "    ./industream.sh stop --env dev           # Stop dev environment"
    echo "    ./industream.sh docs                     # Regenerate simulator docs"
    echo "    ./industream.sh logs industream-prod_postgres"
    echo "    ./industream.sh uninstall --env dev"
    echo "    ./industream.sh uninstall --all --dry-run"
    echo "    ./industream.sh uninstall --all --delete-data"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    cd "$SCRIPT_DIR"

    # Ensure .env exists before any command (except help)
    local command="${1:-}"
    if [[ "$command" != "help" && "$command" != "--help" && "$command" != "-h" ]]; then
        ensure_env_configured
    fi

    shift 2>/dev/null || true

    case "$command" in
        "")
            print_banner
            show_environment_status
            show_deployment_status
            show_menu
            ;;
        deploy)
            print_small_banner

            local env=""
            local with_demo=false

            while [[ $# -gt 0 ]]; do
                case $1 in
                    --env) env="$2"; shift 2 ;;
                    --with-demo) with_demo=true; shift ;;
                    *) shift ;;
                esac
            done

            if [ -n "$env" ]; then
                deploy_environment "$env" "$with_demo"
            else
                deploy_menu
            fi
            ;;
        status)
            print_small_banner
            show_environment_status
            show_deployment_status
            ;;
        services)
            print_small_banner
            show_services
            ;;
        urls)
            print_small_banner
            show_urls
            ;;
        stop)
            print_small_banner

            local env=""
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --env) env="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done

            if [ -n "$env" ]; then
                stop_environment "$env"
            else
                stop_menu
            fi
            ;;
        uninstall)
            print_small_banner

            local env=""
            local delete_data=false
            local force=false
            local dry_run=false
            local all=false

            while [[ $# -gt 0 ]]; do
                case $1 in
                    --env) env="$2"; shift 2 ;;
                    --all) all=true; shift ;;
                    --delete-data) delete_data=true; shift ;;
                    --force) force=true; shift ;;
                    --dry-run) dry_run=true; shift ;;
                    *) shift ;;
                esac
            done

            local args=""
            if [ -n "$env" ]; then
                args="--env $env"
            elif [ "$all" = "true" ]; then
                args="--all"
            else
                uninstall_menu
                exit 0
            fi
            [ "$delete_data" = "true" ] && args="$args --delete-data"
            [ "$force" = "true" ] && args="$args --force"
            [ "$dry_run" = "true" ] && args="$args --dry-run"

            "$SCRIPT_DIR/scripts/uninstall.sh" $args
            ;;
        logs)
            run_logs "$1"
            ;;
        docs)
            print_small_banner

            local env=""
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --env) env="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done

            if [ -z "$env" ]; then
                # Generate for all deployed envs
                local deployed_envs
                deployed_envs=$(get_deployed_envs)
                if [ -z "$deployed_envs" ]; then
                    print_warning "No environments deployed. Specify one with --env <prod|dev|staging>"
                    exit 1
                fi
                print_section "Generating Simulator Documentation"
                for e in $deployed_envs; do
                    generate_simulators_doc "$e"
                done
                print_section_end
            else
                print_section "Generating Simulator Documentation"
                generate_simulators_doc "$env"
                print_section_end
            fi
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_small_banner
            print_error "Unknown command: $command"
            echo ""
            echo "Run './industream.sh help' for usage information"
            exit 1
            ;;
    esac
}

main "$@"
