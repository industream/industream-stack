#!/usr/bin/env bash
# =============================================================================
# fm-hosts.sh — print /etc/hosts entries for every known instance
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

COMPOSE_ROOT="${COMPOSE_ROOT:-$(cd "$SCRIPT_DIR/../../../industream-flowmaker/deployment" && pwd)}"
INSTANCES_DIR="${FM_INSTANCES_DIR:-$COMPOSE_ROOT/instances}"
mkdir -p "$INSTANCES_DIR"

get_local_ips() {
  local ips=("127.0.0.1")

  # Get IPs from ip command (Linux), excluding docker/virtual bridges
  if command -v ip &>/dev/null; then
    while IFS= read -r line; do
      local iface ip
      iface=$(echo "$line" | awk '{print $1}')
      ip=$(echo "$line" | awk '{print $2}')

      # Skip docker bridges, veth, and virtual interfaces
      [[ "$iface" =~ ^(br-|docker|veth|virbr) ]] && continue
      [[ -n "$ip" && "$ip" != "127.0.0.1" ]] && ips+=("$ip")
    done < <(ip -4 addr show | awk '/inet / {gsub(/\/.*/, "", $2); print $NF, $2}' | grep -v '^lo ')
  # Fallback to hostname -I
  elif command -v hostname &>/dev/null; then
    while IFS= read -r ip; do
      [[ -n "$ip" && "$ip" != "127.0.0.1" ]] && ips+=("$ip")
    done < <(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.')
  fi

  printf '%s\n' "${ips[@]}"
}

select_ip() {
  local -a ips
  mapfile -t ips < <(get_local_ips)

  # Only one IP, use it
  if [[ ${#ips[@]} -eq 1 ]]; then
    echo "${ips[0]}"
    return
  fi

  # Multiple IPs, prompt user
  log_info "Multiple IPs detected:" >&2
  echo "" >&2

  local i=1
  for ip in "${ips[@]}"; do
    # Try to get interface name for this IP
    local iface=""
    if command -v ip &>/dev/null; then
      iface=$(ip -4 addr show | grep -B2 "$ip" | grep -oP '^\d+:\s+\K[^:]+' | tail -1)
      [[ -n "$iface" ]] && iface=" ($iface)"
    fi
    echo "  $i) $ip$iface" >&2
    ((i++))
  done

  echo "" >&2
  local choice
  read -rp "$(echo -e "${BLUE}?${NC} Select IP [1]: ")" choice >&2
  choice="${choice:-1}"

  # Validate choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#ips[@]} ]]; then
    echo "${ips[$((choice-1))]}"
  else
    log_warn "Invalid choice, using 127.0.0.1" >&2
    echo "127.0.0.1"
  fi
}

cmd_hosts() {
  if [[ ! -d "$INSTANCES_DIR" ]] || [[ -z "$(ls -A "$INSTANCES_DIR" 2>/dev/null)" ]]; then
    log_info "No instances found. Create one with: ./fm create <name>" >&2
    return
  fi

  # Select IP address
  local ip
  ip=$(select_ip)

  echo "# FlowMaker hosts - add to /etc/hosts"
  echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# IP: $ip"
  echo ""

  for env_file in "$INSTANCES_DIR"/*/.env; do
    [[ -f "$env_file" ]] || continue

    local domain
    domain=$(grep -E '^FM_DOMAIN=' "$env_file" 2>/dev/null | cut -d= -f2)
    [[ -z "$domain" ]] && continue

    local instance
    instance=$(basename "$(dirname "$env_file")")

    echo "# Instance: $instance"
    echo "$ip frontend.$domain confighub.$domain logger.$domain etcd.$domain cdn.$domain"
    echo "$ip datacatalog-api.$domain datacatalog-ui.$domain"
    echo "$ip uimaker.$domain uimaker-ro.$domain uimaker-api.$domain"
    echo ""
  done
}

main() {
  local sub="${1:-hosts}"
  case "$sub" in
    hosts|"") cmd_hosts ;;
    help|--help|-h)
      echo "Usage: fm-hosts.sh"
      ;;
    *)
      log_error "Unknown subcommand: $sub"
      echo "Usage: fm-hosts.sh"
      exit 1
      ;;
  esac
}

main "$@"
