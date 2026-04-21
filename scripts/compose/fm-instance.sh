#!/usr/bin/env bash
# =============================================================================
# fm-instance.sh — instance lifecycle (create, up, down, ps, logs, list, delete)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

COMPOSE_ROOT="${COMPOSE_ROOT:-$(cd "$SCRIPT_DIR/../../../industream-flowmaker/deployment" && pwd)}"
INSTANCES_DIR="${FM_INSTANCES_DIR:-$COMPOSE_ROOT/instances}"
mkdir -p "$INSTANCES_DIR"

cmd_create() {
  local name="${1:-}"

  if [[ -z "$name" ]]; then
    name=$(prompt "name" "Instance name" "")
    [[ -z "$name" ]] && log_error "Instance name is required" && exit 1
  fi

  local instance_dir="$INSTANCES_DIR/$name"

  if [[ -d "$instance_dir" ]]; then
    log_error "Instance '$name' already exists at $instance_dir"
    exit 1
  fi

  log_info "Creating instance: $name"
  echo ""

  # Get existing values for uniqueness checks
  mapfile -t existing_networks < <(get_existing_networks)
  mapfile -t existing_domains < <(get_existing_domains)

  # Suggest defaults
  local default_network
  default_network=$(suggest_unique_name "${name}-net" "${existing_networks[@]}")
  local default_domain
  default_domain=$(suggest_unique_name "${name}.flowmaker.localhost" "${existing_domains[@]}")

  # Read from root .env for version defaults
  local default_registry
  default_registry=$(read_root_env "DOCKER_REGISTRY" "")
  local default_core_version
  default_core_version=$(read_root_env "CORE_VERSION" "latest")
  local default_front_version
  default_front_version=$(read_root_env "FRONT_VERSION" "latest")
  local default_uimaker_version
  default_uimaker_version=$(read_root_env "UIMAKER_VERSION" "latest")
  local default_protocol
  default_protocol=$(read_root_env "FM_PROTOCOL" "https")

  echo -e "${YELLOW}=== Instance Configuration ===${NC}"
  echo ""

  # Required unique values
  local fm_network
  fm_network=$(prompt_unique "FM_NETWORK" "Docker network name" "$default_network" "${existing_networks[@]}")

  local fm_domain
  fm_domain=$(prompt_unique "FM_DOMAIN" "Domain (e.g., dev.flowmaker.localhost)" "$default_domain" "${existing_domains[@]}")

  # Protocol
  local fm_protocol
  fm_protocol=$(prompt "FM_PROTOCOL" "Protocol (http/https)" "$default_protocol")

  echo ""
  echo -e "${YELLOW}=== Version Configuration (leave empty to use root .env) ===${NC}"
  echo ""

  local docker_registry
  docker_registry=$(prompt "DOCKER_REGISTRY" "Docker registry" "$default_registry")

  local core_version
  core_version=$(prompt "CORE_VERSION" "Core version" "$default_core_version")

  local front_version
  front_version=$(prompt "FRONT_VERSION" "Frontend version" "$default_front_version")

  local uimaker_version
  uimaker_version=$(prompt "UIMAKER_VERSION" "UIMaker version" "$default_uimaker_version")

  echo ""

  # Create directory structure with correct permissions
  mkdir -p "$instance_dir/volumes/etcd-data"
  mkdir -p "$instance_dir/volumes/confighub-v2-data"
  mkdir -p "$instance_dir/volumes/uimaker-backend/projects"
  mkdir -p "$instance_dir/volumes/uimaker-backend/storage"
  mkdir -p "$instance_dir/volumes/uimaker-backend/resources"
  mkdir -p "$instance_dir/volumes/datacatalog-pgdata"

  # Write .env file from template
  local template_file="$COMPOSE_ROOT/.env.template"
  if [[ ! -f "$template_file" ]]; then
    log_error "Template file not found: $template_file"
    exit 1
  fi

  # Replace simple placeholders
  sed -e "s|{{FM_INSTANCE}}|$name|g" \
      -e "s|{{FM_NETWORK}}|$fm_network|g" \
      -e "s|{{FM_DOMAIN}}|$fm_domain|g" \
      -e "s|{{FM_UID}}|$(id -u)|g" \
      -e "s|{{FM_GID}}|$(id -g)|g" \
      -e "s|{{FM_PROTOCOL}}|$fm_protocol|g" \
      -e "s|{{DOCKER_REGISTRY}}|$docker_registry|g" \
      -e "s|{{CORE_VERSION}}|$core_version|g" \
      -e "s|{{FRONT_VERSION}}|$front_version|g" \
      -e "s|{{UIMAKER_VERSION}}|$uimaker_version|g" \
      -e "/{{WORKER_VERSIONS}}/d" \
      "$template_file" > "$instance_dir/.env"

  # Append worker versions from docker-compose.workers.yml
  while IFS= read -r line; do
    [[ -n "$line" ]] && echo "# $line" >> "$instance_dir/.env"
  done < <(get_worker_versions)

  # Write docker-compose.override.yml template
  cat > "$instance_dir/docker-compose.override.yml" <<'EOF'
# Instance-specific compose overrides
# Uncomment and modify sections as needed

# services:
#   # Example: Override worker image completely
#   worker-timer:
#     image: ${DOCKER_REGISTRY}/flowmaker.boxes/flow-box-timer:custom-tag
#
#   # Example: Add environment variables to a service
#   flowmaker-scheduler:
#     environment:
#       - FM_DEBUG=true
#       - FM_LOG_LEVEL=debug
#
#   # Example: Add extra volumes to a service
#   flowmaker-frontend:
#     volumes:
#       - ./instances/my-instance/custom-config:/app/config:ro
#
#   # Example: Override command
#   worker-http-client:
#     command: ["node", "--inspect=0.0.0.0:9230", "/usr/app/index.js"]
EOF

  log_success "Created instance at $instance_dir"
  log_success "Environment file: $instance_dir/.env"
  log_success "Override template: $instance_dir/docker-compose.override.yml"

  echo ""
  log_info "Rebuilding Caddy configuration..."
  "$SCRIPT_DIR/fm-caddy.sh" rebuild

  echo ""
  echo -e "${GREEN}Instance '$name' is ready!${NC}"
  echo ""
  echo "Start with:"
  echo "  ./fm up $name                        # Core services only"
  echo "  ./fm up $name --workers              # Core + workers"
  echo "  ./fm up $name --workers --uimaker    # Core + workers + UIMaker"
}

cmd_up() {
  local name="${1:-}"
  [[ -z "$name" ]] && log_error "Usage: fm up <instance> [--workers] [--uimaker]" && exit 1

  local instance_dir="$INSTANCES_DIR/$name"
  [[ ! -d "$instance_dir" ]] && log_error "Instance '$name' not found" && exit 1

  shift
  local with_workers=false
  local with_uimaker=false
  local profiles=()

  local no_pull=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workers) with_workers=true ;;
      --uimaker) with_uimaker=true; profiles+=(--profile uimaker) ;;
      --local) no_pull=true ;;
      *) log_warn "Unknown option: $1" ;;
    esac
    shift
  done

  local env_files=(--env-file "$COMPOSE_ROOT/.env.defaults" --env-file "$instance_dir/.env")
  local compose_files=(
    -f "$COMPOSE_ROOT/docker-compose.yml"
    -f "$COMPOSE_ROOT/docker-compose.datacatalog.yml"
  )

  # Add workers compose if requested
  [[ "$with_workers" == true ]] && compose_files+=(-f "$COMPOSE_ROOT/docker-compose.workers.yml")

  # Add instance override if exists
  [[ -f "$instance_dir/docker-compose.override.yml" ]] && \
    compose_files+=(-f "$instance_dir/docker-compose.override.yml")

  log_info "Starting instance: $name"

  # Start all services together
  local pull_policy=()
  [[ "$no_pull" == true ]] && pull_policy=(--pull never)

  docker compose -p "fm-$name" "${env_files[@]}" "${compose_files[@]}" "${profiles[@]}" up -d "${pull_policy[@]}"

  # Get domain and protocol from instance .env
  local domain protocol
  domain=$(grep -E '^FM_DOMAIN=' "$instance_dir/.env" 2>/dev/null | cut -d= -f2)
  protocol=$(grep -E '^FM_PROTOCOL=' "$instance_dir/.env" 2>/dev/null | cut -d= -f2)
  protocol="${protocol:-https}"

  log_success "Instance '$name' is running"
  echo ""
  echo -e "${YELLOW}Available services:${NC}"
  echo "  Frontend:   ${protocol}://frontend.${domain}"
  echo "  ConfigHub:  ${protocol}://confighub.${domain}"
  echo "  Logger:     ${protocol}://logger.${domain}"
  echo "  etcd:       ${protocol}://etcd.${domain}"
  echo "  DataCatalog API: ${protocol}://datacatalog-api.${domain}"
  echo "  DataCatalog UI:  ${protocol}://datacatalog-ui.${domain}"
  if [[ "$with_uimaker" == true ]]; then
    echo "  UIMaker:    ${protocol}://uimaker.${domain}"
    echo "  UIMaker RO: ${protocol}://uimaker-ro.${domain}"
    echo "  UIMaker API:${protocol}://uimaker-api.${domain}"
  fi
}

cmd_down() {
  local name="${1:-}"
  [[ -z "$name" ]] && log_error "Usage: fm down <instance>" && exit 1

  local instance_dir="$INSTANCES_DIR/$name"
  [[ ! -d "$instance_dir" ]] && log_error "Instance '$name' not found" && exit 1

  local env_files=(--env-file "$COMPOSE_ROOT/.env.defaults" --env-file "$instance_dir/.env")
  local compose_files=(
    -f "$COMPOSE_ROOT/docker-compose.yml"
    -f "$COMPOSE_ROOT/docker-compose.datacatalog.yml"
    -f "$COMPOSE_ROOT/docker-compose.workers.yml"
  )

  # Add instance override if exists
  [[ -f "$instance_dir/docker-compose.override.yml" ]] && \
    compose_files+=(-f "$instance_dir/docker-compose.override.yml")

  log_info "Stopping instance: $name"

  # Stop all services together
  docker compose -p "fm-$name" "${env_files[@]}" "${compose_files[@]}" --profile uimaker down

  log_success "Instance '$name' stopped"
}

cmd_logs() {
  local name="${1:-}"
  [[ -z "$name" ]] && log_error "Usage: fm logs <instance> [service]" && exit 1

  local instance_dir="$INSTANCES_DIR/$name"
  [[ ! -d "$instance_dir" ]] && log_error "Instance '$name' not found" && exit 1

  shift
  local service="${1:-}"

  local env_files=(--env-file "$COMPOSE_ROOT/.env.defaults" --env-file "$instance_dir/.env")
  local compose_files=(
    -f "$COMPOSE_ROOT/docker-compose.yml"
    -f "$COMPOSE_ROOT/docker-compose.datacatalog.yml"
    -f "$COMPOSE_ROOT/docker-compose.workers.yml"
  )

  if [[ -n "$service" ]]; then
    docker compose -p "fm-$name" "${env_files[@]}" "${compose_files[@]}" logs -f "$service"
  else
    docker compose -p "fm-$name" "${env_files[@]}" "${compose_files[@]}" logs -f
  fi
}

cmd_ps() {
  local name="${1:-}"
  [[ -z "$name" ]] && log_error "Usage: fm ps <instance>" && exit 1

  local instance_dir="$INSTANCES_DIR/$name"
  [[ ! -d "$instance_dir" ]] && log_error "Instance '$name' not found" && exit 1

  # Get network name
  local network
  network=$(grep -E '^FM_NETWORK=' "$instance_dir/.env" 2>/dev/null | cut -d= -f2)

  echo -e "${YELLOW}Containers for instance '$name':${NC}"
  echo ""

  printf "%-12s %-30s %-10s %-15s %s\n" "CONTAINER ID" "SERVICE" "STATE" "IP" "STATUS"
  printf "%-12s %-30s %-10s %-15s %s\n" "------------" "-------" "-----" "--" "------"

  docker ps -a \
    --filter "label=com.docker.compose.project=fm-$name" \
    --format "{{.ID}}\t{{.Label \"com.docker.compose.service\"}}\t{{.State}}\t{{.Status}}" | \
    sort -t$'\t' -k2 | \
    while IFS=$'\t' read -r id service state status; do
      # Get IP address for the instance network
      local ip
      ip=$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" "$id" 2>/dev/null)
      [[ -z "$ip" ]] && ip="-"
      printf "%-12s %-30s %-10s %-15s %s\n" "$id" "$service" "$state" "$ip" "$status"
    done
}

cmd_list() {
  echo -e "${YELLOW}Instances:${NC}"
  echo ""

  if [[ ! -d "$INSTANCES_DIR" ]] || [[ -z "$(ls -A "$INSTANCES_DIR" 2>/dev/null)" ]]; then
    log_info "No instances found. Create one with: ./fm create <name>"
    return
  fi

  printf "%-15s %-25s %-20s %-10s\n" "NAME" "DOMAIN" "NETWORK" "STATUS"
  printf "%-15s %-25s %-20s %-10s\n" "----" "------" "-------" "------"

  for instance_dir in "$INSTANCES_DIR"/*/; do
    [[ ! -d "$instance_dir" ]] && continue

    local name
    name=$(basename "$instance_dir")
    local env_file="$instance_dir/.env"

    if [[ -f "$env_file" ]]; then
      local domain network
      domain=$(grep -E '^FM_DOMAIN=' "$env_file" 2>/dev/null | cut -d= -f2)
      network=$(grep -E '^FM_NETWORK=' "$env_file" 2>/dev/null | cut -d= -f2)

      # Check if running
      local status="stopped"
      if docker compose -p "fm-$name" ps --quiet 2>/dev/null | grep -q .; then
        status="${GREEN}running${NC}"
      fi

      printf "%-15s %-25s %-20s " "$name" "$domain" "$network"
      echo -e "$status"
    else
      printf "%-15s %-25s %-20s %-10s\n" "$name" "-" "-" "no .env"
    fi
  done
}

cmd_delete() {
  local name="${1:-}"
  [[ -z "$name" ]] && log_error "Usage: fm delete <instance>" && exit 1

  local instance_dir="$INSTANCES_DIR/$name"
  [[ ! -d "$instance_dir" ]] && log_error "Instance '$name' not found" && exit 1

  echo -e "${RED}This will delete:${NC}"
  echo "  - Instance directory: $instance_dir"
  echo "  - All volumes in: $instance_dir/volumes/"
  echo "  - Docker network for this instance"
  echo "  - Docker volumes prefixed with fm-$name"
  echo ""

  read -rp "$(echo -e "${RED}!${NC} Delete instance '$name' and ALL its data? [y/N]: ")" confirm
  [[ "$confirm" != "y" && "$confirm" != "Y" ]] && log_info "Aborted" && exit 0

  # Get network name before stopping
  local network
  network=$(grep -E '^FM_NETWORK=' "$instance_dir/.env" 2>/dev/null | cut -d= -f2)

  # Stop and remove all containers for this project
  log_info "Stopping instance and removing Docker resources..."

  # Force remove all containers with this project name
  local containers
  containers=$(docker ps -aq --filter "label=com.docker.compose.project=fm-$name" 2>/dev/null)
  if [[ -n "$containers" ]]; then
    echo "$containers" | xargs -r docker rm -f 2>/dev/null || true
    log_info "Removed containers"
  fi

  # Remove any volumes with this project prefix
  local volumes
  volumes=$(docker volume ls -q --filter "name=fm-${name}_" 2>/dev/null)
  if [[ -n "$volumes" ]]; then
    echo "$volumes" | xargs -r docker volume rm 2>/dev/null || true
    log_info "Removed Docker volumes"
  fi

  # Remove network if exists
  if [[ -n "$network" ]]; then
    docker network rm "$network" 2>/dev/null && log_info "Removed network: $network" || true
  fi

  # Remove instance directory
  rm -rf "$instance_dir"
  log_success "Removed $instance_dir"

  # Rebuild Caddy config
  log_info "Rebuilding Caddy configuration..."
  "$SCRIPT_DIR/fm-caddy.sh" rebuild

  log_success "Instance '$name' completely deleted"
}

main() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    create) cmd_create "$@" ;;
    up)     cmd_up "$@" ;;
    down)   cmd_down "$@" ;;
    ps)     cmd_ps "$@" ;;
    logs)   cmd_logs "$@" ;;
    list)   cmd_list "$@" ;;
    delete) cmd_delete "$@" ;;
    ""|help|--help|-h)
      echo "Usage: fm-instance.sh <create|up|down|ps|logs|list|delete> [args...]"
      ;;
    *)
      log_error "Unknown subcommand: $sub"
      echo "Usage: fm-instance.sh <create|up|down|ps|logs|list|delete> [args...]"
      exit 1
      ;;
  esac
}

main "$@"
