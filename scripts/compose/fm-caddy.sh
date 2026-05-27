#!/usr/bin/env bash
# =============================================================================
# fm-caddy.sh — local Caddy reverse proxy lifecycle
# Subcommands: rebuild, stop, delete, logs, ca
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

COMPOSE_ROOT="${COMPOSE_ROOT:-$(cd "$SCRIPT_DIR/../../../industream-flowmaker/deployment" && pwd)}"
INSTANCES_DIR="${FM_INSTANCES_DIR:-$COMPOSE_ROOT/instances}"
mkdir -p "$INSTANCES_DIR"

caddy_health_check() {
  local max_attempts="${1:-10}"
  local attempt=1

  while [[ $attempt -le $max_attempts ]]; do
    if docker compose -p caddy ps --format json 2>/dev/null | grep -q '"Health":"healthy"\|"State":"running"'; then
      return 0
    fi
    log_info "Waiting for Caddy to be healthy... ($attempt/$max_attempts)"
    sleep 2
    ((attempt++))
  done
  return 1
}

cmd_caddy_rebuild() {
  local networks=()
  local override_file="$COMPOSE_ROOT/docker-compose.infra.override.yml"
  local infra_file="$COMPOSE_ROOT/docker-compose.infra.yml"

  # Check if Caddy is currently running
  local caddy_was_running=false
  if docker compose -p caddy ps --quiet 2>/dev/null | grep -q .; then
    caddy_was_running=true
    log_info "Caddy is currently running, checking health..."
    if caddy_health_check 5; then
      log_success "Caddy is healthy"
    else
      log_warn "Caddy is running but may not be healthy"
    fi
  fi

  # Scan instances - single source of truth
  shopt -s nullglob
  for env_file in "$INSTANCES_DIR"/*/.env; do
    [[ -f "$env_file" ]] || continue
    local network
    network=$(grep -E '^FM_NETWORK=' "$env_file" 2>/dev/null | cut -d= -f2)
    [[ -n "$network" ]] && networks+=("$network")
  done
  shopt -u nullglob

  if [[ ${#networks[@]} -eq 0 ]]; then
    log_warn "No instances found. Creating empty override file."
    cat > "$override_file" <<EOF
# Auto-generated from ./instances/*/.env - do not edit
# Regenerate: ./fm caddy:rebuild
# No instances configured
services: {}
EOF
    return
  fi

  # Pre-create networks
  for net in "${networks[@]}"; do
    if docker network create "$net" 2>/dev/null; then
      log_info "Created network: $net"
    fi
  done

  # Build comma-separated network list for CADDY_INGRESS_NETWORKS
  local ingress_networks
  ingress_networks=$(printf '%s,' "${networks[@]}")
  ingress_networks="${ingress_networks%,}"

  # Generate override file
  {
    echo "# Auto-generated from ./instances/*/.env - do not edit"
    echo "# Regenerate: ./fm caddy:rebuild"
    echo "# Networks: ${networks[*]}"
    echo ""
    echo "services:"
    echo "  caddy:"
    echo "    environment:"
    echo "      - CADDY_INGRESS_NETWORKS=$ingress_networks"
    echo "    networks:"
    for net in "${networks[@]}"; do
      echo "      - $net"
    done
    echo ""
    echo "networks:"
    for net in "${networks[@]}"; do
      echo "  $net:"
      echo "    external: true"
    done
  } > "$override_file"

  log_success "Generated $override_file with ${#networks[@]} network(s)"

  # Start/restart Caddy
  if [[ -f "$infra_file" ]]; then
    log_info "Starting Caddy..."
    docker compose -p caddy -f "$infra_file" -f "$override_file" up -d

    log_info "Waiting for Caddy to be healthy..."
    if caddy_health_check 15; then
      log_success "Caddy is healthy"
    else
      log_error "Caddy health check failed"
      log_info "Check logs with: docker compose -p caddy logs"
      return 1
    fi
  fi
}

cmd_caddy_stop() {
  local infra_file="$COMPOSE_ROOT/docker-compose.infra.yml"
  local override_file="$COMPOSE_ROOT/docker-compose.infra.override.yml"

  log_info "Stopping Caddy..."
  if [[ -f "$override_file" ]]; then
    docker compose -p caddy -f "$infra_file" -f "$override_file" down
  else
    docker compose -p caddy -f "$infra_file" down
  fi
  log_success "Caddy stopped"
}

cmd_caddy_delete() {
  local infra_file="$COMPOSE_ROOT/docker-compose.infra.yml"
  local override_file="$COMPOSE_ROOT/docker-compose.infra.override.yml"
  local caddy_data="$COMPOSE_ROOT/volumes/caddy"

  echo -e "${RED}This will delete:${NC}"
  echo "  - Caddy container and volumes"
  echo "  - Caddy data directory: $caddy_data"
  echo "  - CA certificates (you'll need to re-trust after restart)"
  echo ""

  read -rp "$(echo -e "${RED}!${NC} Delete Caddy completely? [y/N]: ")" confirm
  [[ "$confirm" != "y" && "$confirm" != "Y" ]] && log_info "Aborted" && exit 0

  log_info "Stopping Caddy and removing volumes..."
  if [[ -f "$override_file" ]]; then
    docker compose -p caddy -f "$infra_file" -f "$override_file" down -v 2>/dev/null || true
  else
    docker compose -p caddy -f "$infra_file" down -v 2>/dev/null || true
  fi

  # Remove caddy data directory
  if [[ -d "$caddy_data" ]]; then
    rm -rf "$caddy_data"
    log_info "Removed $caddy_data"
  fi

  # Remove override file
  if [[ -f "$override_file" ]]; then
    rm -f "$override_file"
    log_info "Removed $override_file"
  fi

  log_success "Caddy completely deleted"
  echo ""
  echo "To restart Caddy, run:"
  echo "  ./fm caddy:rebuild"
}

cmd_caddy_logs() {
  local infra_file="$COMPOSE_ROOT/docker-compose.infra.yml"
  docker compose -p caddy -f "$infra_file" logs -f
}

cmd_caddy_ca() {
  local dest="${1:-$HOME/caddy-root-ca.crt}"
  local container

  # Get caddy container ID
  container=$(docker compose -p caddy ps -q caddy 2>/dev/null)

  if [[ -z "$container" ]]; then
    log_error "Caddy container not running"
    log_info "Start Caddy first: ./fm caddy:rebuild"
    exit 1
  fi

  # Extract CA directly from container (no sudo needed)
  if ! docker cp "$container:/data/caddy/pki/authorities/local/root.crt" "$dest" 2>/dev/null; then
    log_error "CA certificate not found in container"
    log_info "Caddy may not have generated certificates yet. Try accessing an HTTPS URL first."
    exit 1
  fi

  log_success "CA certificate copied to: $dest"
  echo ""
  echo -e "${YELLOW}=== Trust the CA ===${NC}"
  echo ""
  echo "Linux (Arch):"
  echo "  sudo trust anchor $dest"
  echo ""
  echo "Linux (Debian/Ubuntu):"
  echo "  sudo cp $dest /usr/local/share/ca-certificates/caddy-local.crt"
  echo "  sudo update-ca-certificates"
  echo ""
  echo "Linux (Fedora/RHEL):"
  echo "  sudo cp $dest /etc/pki/ca-trust/source/anchors/caddy-local.crt"
  echo "  sudo update-ca-trust"
  echo ""
  echo "macOS:"
  echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $dest"
  echo ""
  echo -e "${YELLOW}Firefox (uses own cert store):${NC}"
  echo "  Settings → Privacy & Security → Certificates → View Certificates"
  echo "  Authorities → Import → select $dest"
  echo "  Check 'Trust this CA to identify websites'"
  echo ""
}

main() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    rebuild) cmd_caddy_rebuild "$@" ;;
    stop)    cmd_caddy_stop "$@" ;;
    delete)  cmd_caddy_delete "$@" ;;
    logs)    cmd_caddy_logs "$@" ;;
    ca)      cmd_caddy_ca "$@" ;;
    ""|help|--help|-h)
      echo "Usage: fm-caddy.sh <rebuild|stop|delete|logs|ca> [args...]"
      ;;
    *)
      log_error "Unknown subcommand: $sub"
      echo "Usage: fm-caddy.sh <rebuild|stop|delete|logs|ca> [args...]"
      exit 1
      ;;
  esac
}

main "$@"
