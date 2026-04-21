#!/usr/bin/env bash
# =============================================================================
# fm-worker.sh — worker tooling (launch-worker, cdn-reset)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

COMPOSE_ROOT="${COMPOSE_ROOT:-$(cd "$SCRIPT_DIR/../../../industream-flowmaker/deployment" && pwd)}"
INSTANCES_DIR="${FM_INSTANCES_DIR:-$COMPOSE_ROOT/instances}"
mkdir -p "$INSTANCES_DIR"

cmd_cdn_reset() {
  local name="${1:-}"
  local target="${2:-all}"

  [[ -z "$name" ]] && log_error "Usage: fm cdn-reset <instance> [worker-name|all]" && exit 1

  local instance_dir="$INSTANCES_DIR/$name"
  [[ ! -d "$instance_dir" ]] && log_error "Instance '$name' not found" && exit 1

  local project="fm-$name"
  local containers

  if [[ "$target" == "all" ]]; then
    # Find all worker containers (service name starts with "worker-")
    local all_containers
    all_containers=$(docker ps -q --filter "label=com.docker.compose.project=$project" 2>/dev/null)
    containers=""
    for cid in $all_containers; do
      local svc
      svc=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$cid" 2>/dev/null)
      [[ "$svc" == worker-* ]] && containers="$containers $cid"
    done
    containers=$(echo "$containers" | xargs)
  else
    containers=$(docker ps -q --filter "label=com.docker.compose.project=$project" --filter "label=com.docker.compose.service=$target" 2>/dev/null)
  fi

  if [[ -z "$containers" ]]; then
    log_error "No running workers found"
    exit 1
  fi

  for container in $containers; do
    local service
    service=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$container" 2>/dev/null)
    docker exec "$container" rm -f /cdn-runtime/.seeded 2>/dev/null || true
    log_success "Reset: $service"
  done

  echo ""
  log_info "Restart workers to re-seed: ./fm down $name && ./fm up $name --workers"
}

cmd_launch_worker() {
  local name="${1:-}"
  [[ -z "$name" ]] && log_error "Usage: fm launch-worker <instance> [--id <worker-id>] [--port <zmq-port>] [--flowmaker-workers-path=<path>] <worker-name> [process-command...]" && exit 1
  shift

  local instance_dir="$INSTANCES_DIR/$name"
  [[ ! -d "$instance_dir" ]] && log_error "Instance '$name' not found" && exit 1
  [[ ! -f "$instance_dir/.env" ]] && log_error "No .env found for instance '$name'" && exit 1

  # Parse options
  local worker_id=""
  local zmq_port=""
  local flowmaker_workers_path=""
  local positional_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) worker_id="$2"; shift 2 ;;
      --port) zmq_port="$2"; shift 2 ;;
      --flowmaker-workers-path=*) flowmaker_workers_path="${1#--flowmaker-workers-path=}"; shift ;;
      --flowmaker-workers-path) flowmaker_workers_path="$2"; shift 2 ;;
      --) shift; positional_args+=("$@"); break ;;
      -*) log_error "Unknown option: $1"; exit 1 ;;
      *) positional_args+=("$1"); shift ;;
    esac
  done

  # Resolve flowmaker-workers-path from deployment/.env if not provided via flag
  if [[ -z "$flowmaker_workers_path" && -f "$COMPOSE_ROOT/.env" ]]; then
    flowmaker_workers_path=$(grep -E '^FLOWMAKER_WORKERS_PATH=' "$COMPOSE_ROOT/.env" 2>/dev/null | cut -d= -f2)
  fi
  if [[ -z "$flowmaker_workers_path" ]]; then
    log_error "FLOWMAKER_WORKERS_PATH not set."
    echo "  Add the following to $COMPOSE_ROOT/.env:"
    echo ""
    echo "  FLOWMAKER_WORKERS_PATH=/path/to/worker-cli"
    echo "  LAUNCH_WORKER_DEFAULT_PROCESS=npx tsx src/index.ts"
    echo ""
    exit 1
  fi

  # Validate positional args: <worker-name> [process-command...]
  [[ ${#positional_args[@]} -lt 1 ]] && log_error "Usage: fm launch-worker <instance> [options] <worker-name> [process-command...]" && exit 1

  local worker_name="${positional_args[0]}"
  local process_cmd=()

  if [[ ${#positional_args[@]} -gt 1 ]]; then
    process_cmd=("${positional_args[@]:1}")
  else
    # Read default process from deployment/.env
    local default_process=""
    [[ -f "$COMPOSE_ROOT/.env" ]] && default_process=$(grep -E '^LAUNCH_WORKER_DEFAULT_PROCESS=' "$COMPOSE_ROOT/.env" 2>/dev/null | cut -d= -f2)
    if [[ -z "$default_process" ]]; then
      log_error "No process specified and LAUNCH_WORKER_DEFAULT_PROCESS not set."
      echo "  Add the following to $COMPOSE_ROOT/.env:"
      echo ""
      echo "  LAUNCH_WORKER_DEFAULT_PROCESS=npx tsx src/index.ts"
      echo ""
      exit 1
    fi
    read -ra process_cmd <<< "$default_process"
  fi

  # Hint about missing .env entries for ease of use
  local env_hints=()
  if [[ -f "$COMPOSE_ROOT/.env" ]]; then
    grep -qE '^FLOWMAKER_WORKERS_PATH=' "$COMPOSE_ROOT/.env" 2>/dev/null || env_hints+=("FLOWMAKER_WORKERS_PATH=$flowmaker_workers_path")
    grep -qE '^LAUNCH_WORKER_DEFAULT_PROCESS=' "$COMPOSE_ROOT/.env" 2>/dev/null || env_hints+=("LAUNCH_WORKER_DEFAULT_PROCESS=${process_cmd[*]}")
  else
    env_hints+=("FLOWMAKER_WORKERS_PATH=$flowmaker_workers_path")
    env_hints+=("LAUNCH_WORKER_DEFAULT_PROCESS=${process_cmd[*]}")
  fi
  if [[ ${#env_hints[@]} -gt 0 ]]; then
    log_warn "Consider adding to $COMPOSE_ROOT/.env:"
    printf '  %s\n' "${env_hints[@]}"
    echo ""
  fi

  local worker_dir="$flowmaker_workers_path/workers/$worker_name"
  [[ ! -d "$worker_dir" ]] && log_error "Worker directory not found: $worker_dir" && exit 1

  # Read instance config
  local network
  network=$(grep -E '^FM_NETWORK=' "$instance_dir/.env" | cut -d= -f2)
  [[ -z "$network" ]] && log_error "FM_NETWORK not set in instance .env" && exit 1

  local project="fm-$name"

  # Generate worker ID if not provided
  if [[ -z "$worker_id" ]]; then
    worker_id="worker-local-$(head -c 4 /dev/urandom | xxd -p)"
  fi

  # Resolve container IPs by inspecting the Docker network
  log_info "Resolving service IPs on network '$network'..."

  resolve_container_ip() {
    local service="$1"
    local container="${project}-${service}-1"
    local ip
    ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" "$container" 2>/dev/null)
    [[ -z "$ip" ]] && log_error "Could not resolve IP for $container" && return 1
    echo "$ip"
  }

  local scheduler_ip logging_ip datacatalog_ip cdn_ip gateway_ip

  scheduler_ip=$(resolve_container_ip "flowmaker-scheduler") || exit 1
  logging_ip=$(resolve_container_ip "flowmaker-logging") || exit 1
  datacatalog_ip=$(resolve_container_ip "datacatalog-api") || exit 1

  # CDN is optional — some setups may not have it
  cdn_ip=$(resolve_container_ip "cdn-server" 2>/dev/null) || cdn_ip=""

  # Get gateway IP (= host IP as seen from containers)
  gateway_ip=$(docker network inspect "$network" --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
  [[ -z "$gateway_ip" ]] && log_error "Could not determine gateway IP for network '$network'" && exit 1

  # Find a free ZMQ port starting from 5570
  if [[ -z "$zmq_port" ]]; then
    zmq_port=5570
    while ss -tlnH "sport = :$zmq_port" 2>/dev/null | grep -q .; do
      ((zmq_port++))
      [[ $zmq_port -gt 5600 ]] && log_error "No free port found in range 5570-5600" && exit 1
    done
  fi

  log_success "Resolved service addresses:"
  echo "  Scheduler:    $scheduler_ip:3120"
  echo "  Logging:      $logging_ip:3000"
  echo "  DataCatalog:  $datacatalog_ip:8080"
  [[ -n "$cdn_ip" ]] && echo "  CDN:          $cdn_ip:4873"
  echo "  Gateway (host): $gateway_ip"
  echo ""
  echo "  Worker ID:    $worker_id"
  echo "  ZMQ bind:     tcp://*:$zmq_port"
  echo "  ZMQ adv:      tcp://$gateway_ip:$zmq_port"
  echo ""

  # Build env vars
  local app_config_dir="$worker_dir/frontend/dist/"
  local env_vars=(
    "FM_WORKER_ID=$worker_id"
    "FM_RUNTIME_HTTP_ADDRESS=http://$scheduler_ip:3120"
    "FM_ROUTER_TRANSPORT_ADDRESS=tcp://*:$zmq_port"
    "FM_WORKER_TRANSPORT_ADV_ADDRESS=tcp://$gateway_ip:$zmq_port"
    "FM_WORKER_LOG_SOCKET_IO_ENDPOINT=http://$logging_ip:3000"
    "FM_DATACATALOG_URL=http://$datacatalog_ip:8080"
    "FM_WORKER_APP_CONFIG=$app_config_dir"
  )
  [[ -n "$cdn_ip" ]] && env_vars+=("FM_CDN_REGISTRY_URL=http://$cdn_ip:4873")

  # Offer to rebuild frontend config
  local frontend_dir="$worker_dir/frontend"
  if [[ -d "$frontend_dir" ]]; then
    local rebuild=""
    read -rp "$(echo -e "${BLUE}?${NC} Rebuild frontend config for '$worker_name'? [y/N]: ")" rebuild
    if [[ "$rebuild" =~ ^[Yy]$ ]]; then
      log_info "Building frontend in $frontend_dir..."
      (cd "$frontend_dir" && npm run build) || { log_error "Frontend build failed"; exit 1; }
      log_success "Frontend build complete"
      echo ""
    fi
  fi

  log_info "Launching: ${process_cmd[*]} (in $worker_dir)"
  echo ""

  cd "$worker_dir"
  exec env "${env_vars[@]}" "${process_cmd[@]}"
}

main() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    launch-worker) cmd_launch_worker "$@" ;;
    cdn-reset)     cmd_cdn_reset "$@" ;;
    ""|help|--help|-h)
      echo "Usage: fm-worker.sh <launch-worker|cdn-reset> [args...]"
      ;;
    *)
      log_error "Unknown subcommand: $sub"
      echo "Usage: fm-worker.sh <launch-worker|cdn-reset> [args...]"
      exit 1
      ;;
  esac
}

main "$@"
