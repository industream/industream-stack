#!/usr/bin/env bash
# =============================================================================
# fm-sync.sh — confighub bootstrap (init) and version sync (sync)
#
# Note: the monolithic `fm` script defined cmd_sync and cmd_init twice each
# (lines 872/1168 and 1048/1344). Bash keeps the last definition, so only the
# second versions were ever executed. This file copies only those live versions
# verbatim; the earlier dead-code duplicates are discarded.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

COMPOSE_ROOT="${COMPOSE_ROOT:-$(cd "$SCRIPT_DIR/../../../industream-flowmaker/deployment" && pwd)}"
INSTANCES_DIR="${FM_INSTANCES_DIR:-$COMPOSE_ROOT/instances}"
mkdir -p "$INSTANCES_DIR"

cmd_sync() {
  local name="${1:-}"
  [[ -z "$name" ]] && log_error "Usage: fm sync <instance>" && exit 1

  local instance_dir="$INSTANCES_DIR/$name"
  [[ ! -d "$instance_dir" ]] && log_error "Instance '$name' not found" && exit 1
  [[ ! -f "$instance_dir/.env" ]] && log_error "No .env found for instance '$name'" && exit 1

  # Fetch versions.json via gh api
  log_info "Fetching versions from release-tracker..."
  local versions_json
  versions_json=$(gh api repos/industream/release-tracker/contents/versions.json --jq '.content' | base64 -d 2>/dev/null)
  if [[ -z "$versions_json" ]]; then
    log_error "Failed to fetch versions.json (is gh authenticated?)"
    exit 1
  fi

  local updated_at
  updated_at=$(echo "$versions_json" | jq -r '.lastUpdated')
  log_success "Fetched versions (last updated: $updated_at)"
  echo ""

  # Helper: extract version from versions.json by project key + image name
  get_version() {
    local key="$1" image="$2"
    echo "$versions_json" | jq -r --arg k "$key" --arg i "$image" \
      '.projects[] | select(.key == $k) | .components[] | select(.image == $i) | .version'
  }

  # Build the version map: ENV_VAR=version
  declare -A version_map

  # Core
  local v
  v=$(get_version "flowmaker.core" "flowmaker-runtime")
  [[ -n "$v" && "$v" != "null" ]] && version_map[CORE_VERSION]="$v"

  v=$(get_version "flowmaker.core" "flowmaker-front")
  [[ -n "$v" && "$v" != "null" ]] && version_map[FRONT_VERSION]="$v"

  # UIMaker (use uimaker-backend as source of truth)
  v=$(get_version "uimaker" "uimaker-backend")
  [[ -n "$v" && "$v" != "null" ]] && version_map[UIMAKER_VERSION]="$v"

  # DataCatalog
  v=$(get_version "datacatalog" "api")
  [[ -n "$v" && "$v" != "null" ]] && version_map[DATACATALOG_API_VERSION]="$v"

  v=$(get_version "datacatalog" "ui")
  [[ -n "$v" && "$v" != "null" ]] && version_map[DATACATALOG_UI_VERSION]="$v"

  # Workers: image "flow-box-<name>" -> WORKER_<NAME>_VERSION
  local image version var_name
  while IFS= read -r line; do
    image=$(echo "$line" | jq -r '.image')
    version=$(echo "$line" | jq -r '.version')
    [[ -z "$image" || "$image" == "null" ]] && continue

    # Convert flow-box-js-expression -> WORKER_JS_EXPRESSION_VERSION
    if [[ "$image" == flow-box-* ]]; then
      var_name=$(echo "${image#flow-box-}" | tr '[:lower:]-' '[:upper:]_')
      version_map["WORKER_${var_name}_VERSION"]="$version"
    fi
  done < <(echo "$versions_json" | jq -c '.projects[] | select(.key == "flowmaker.boxes") | .components[]')

  # Display what will change
  local env_file="$instance_dir/.env"
  local changes=()

  echo -e "${YELLOW}=== Version updates for instance '$name' ===${NC}"
  echo ""
  printf "  %-45s %-15s %-15s\n" "VARIABLE" "CURRENT" "NEW"
  printf "  %-45s %-15s %-15s\n" "--------" "-------" "---"

  local sorted_keys
  mapfile -t sorted_keys < <(printf '%s\n' "${!version_map[@]}" | sort)
  for var in "${sorted_keys[@]}"; do
    local new_ver="${version_map[$var]}"
    # Read current value (from active line or commented line)
    local current_ver
    current_ver=$(grep -E "^${var}=" "$env_file" 2>/dev/null | cut -d= -f2 | head -1 || true)
    [[ -z "$current_ver" ]] && current_ver=$(grep -E "^#\s*${var}=" "$env_file" 2>/dev/null | sed 's/^#\s*//' | cut -d= -f2 | head -1 || true)
    current_ver="${current_ver:--}"

    if [[ "$current_ver" != "$new_ver" ]]; then
      printf "  %-45s ${RED}%-15s${NC} ${GREEN}%-15s${NC}\n" "$var" "$current_ver" "$new_ver"
      changes+=("$var=$new_ver")
    else
      printf "  %-45s %-15s %-15s\n" "$var" "$current_ver" "(same)"
    fi
  done

  echo ""

  if [[ ${#changes[@]} -eq 0 ]]; then
    log_success "Instance '$name' is already up to date"
    return
  fi

   # Interactive per-item selection
  echo -e "  ${BLUE}a${NC} = apply all, ${BLUE}s${NC} = skip all, ${BLUE}n${NC} = skip one, or ${BLUE}y${NC}/Enter = apply:"
  echo ""

  local selected=()

  for change in "${changes[@]}"; do
    local var="${change%%=*}"
    local val="${change#*=}"
    local current
    current=$(grep -E "^${var}=" "$env_file" 2>/dev/null | cut -d= -f2 | head -1 || true)
    [[ -z "$current" ]] && current=$(grep -E "^#\s*${var}=" "$env_file" 2>/dev/null | sed 's/^#\s*//' | cut -d= -f2 | head -1 || true)

    local answer
    echo -en "  ${BLUE}?${NC} ${var} ${RED}${current:--}${NC} -> ${GREEN}${val}${NC} [y/n/a/s]: "
    read -r answer </dev/tty

    if [[ "$answer" == "a" ]]; then
      selected+=("$change")
      # Add all remaining changes
      local found=false
      for remaining in "${changes[@]}"; do
        [[ "$remaining" == "$change" ]] && found=true && continue
        $found && selected+=("$remaining")
      done
      break
    elif [[ "$answer" == "s" ]]; then
      break
    elif [[ "$answer" == "n" || "$answer" == "N" ]]; then
      continue
    else
      selected+=("$change")
    fi
  done

  echo ""

  if [[ ${#selected[@]} -eq 0 ]]; then
    log_info "No updates selected"
    return
  fi

  # Apply selected to instance .env
  for change in "${selected[@]}"; do
    local var="${change%%=*}"
    local val="${change#*=}"

    if grep -qE "^${var}=" "$env_file"; then
      sed -i "s|^${var}=.*|${var}=${val}|" "$env_file"
    elif grep -qE "^#\s*${var}=" "$env_file"; then
      sed -i "s|^#\s*${var}=.*|${var}=${val}|" "$env_file"
    else
      echo "${var}=${val}" >> "$env_file"
    fi
  done

  log_success "Updated ${#selected[@]} version(s) in $env_file"

  # Ask about .env.defaults
  echo ""
  read -rp "$(echo -e "${BLUE}?${NC} Also update .env.defaults? [y/N]: ")" update_defaults
  if [[ "$update_defaults" == "y" || "$update_defaults" == "Y" ]]; then
    local defaults_file="$COMPOSE_ROOT/.env.defaults"
    for change in "${selected[@]}"; do
      local var="${change%%=*}"
      local val="${change#*=}"

      if grep -qE "^${var}=" "$defaults_file"; then
        sed -i "s|^${var}=.*|${var}=${val}|" "$defaults_file"
      else
        echo "${var}=${val}" >> "$defaults_file"
      fi
    done
    log_success "Updated $defaults_file"
  fi
}

cmd_init() {
  local name="${1:-}"
  [[ -z "$name" ]] && log_error "Usage: fm init <instance>" && exit 1

  local instance_dir="$INSTANCES_DIR/$name"
  [[ ! -d "$instance_dir" ]] && log_error "Instance '$name' not found" && exit 1
  [[ ! -f "$instance_dir/.env" ]] && log_error "No .env found for instance '$name'" && exit 1

  # Read instance config
  local domain protocol
  domain=$(grep -E '^FM_DOMAIN=' "$instance_dir/.env" | cut -d= -f2)
  protocol=$(grep -E '^FM_PROTOCOL=' "$instance_dir/.env" | cut -d= -f2)
  protocol="${protocol:-https}"

  local confighub_url="${protocol}://confighub.${domain}"
  local cdn_url="${protocol}://cdn.${domain}"
  local datacatalog_url="${protocol}://datacatalog-api.${domain}"
  local scheduler_url="${protocol}://scheduler.${domain}"
  local logger_url="${protocol}://logger.${domain}"

  log_info "Initializing instance '$name' via $confighub_url"
  echo ""

  # --- Show what will be set ---
  echo -e "${YELLOW}=== Environment config ===${NC}"
  echo "  environment/cdn          = $cdn_url"
  echo "  environment/datacatalog  = {\"url\": \"$datacatalog_url\"}"
  echo ""
  echo -e "${YELLOW}=== Scheduler ===${NC}"
  echo "  Scheduler 1  url=$scheduler_url  logger=$logger_url"
  echo ""

  # --- Ask what to reset ---
  local do_env=false
  local do_sched=false

  read -rp "$(echo -e "${BLUE}?${NC} Reset environment config? [y/N]: ")" answer </dev/tty
  [[ "$answer" == "y" || "$answer" == "Y" ]] && do_env=true

  read -rp "$(echo -e "${BLUE}?${NC} Reset scheduler? [y/N]: ")" answer </dev/tty
  [[ "$answer" == "y" || "$answer" == "Y" ]] && do_sched=true

  if [[ "$do_env" == false && "$do_sched" == false ]]; then
    log_info "Nothing to do"
    return
  fi

  echo ""

  # --- Environment config ---
  if [[ "$do_env" == true ]]; then
    log_info "Setting environment variables..."
    local env_payload
    local datacatalog_json
    datacatalog_json=$(jq -n --arg url "$datacatalog_url" '{"url": $url}' | jq -c '.')
    env_payload=$(jq -n \
      --arg cdn "$cdn_url" \
      --arg datacatalog "$datacatalog_json" \
      '{"environment/cdn": $cdn, "environment/datacatalog": $datacatalog}')

    if curl -sf -X POST "${confighub_url}/environments" \
      -H "Content-Type: application/json" \
      -d "$env_payload" > /dev/null; then
      log_success "environment/cdn = $cdn_url"
      log_success "environment/datacatalog = {\"url\": \"$datacatalog_url\"}"
    else
      log_error "Failed to set environment config"
    fi
    echo ""
  fi

  # --- Scheduler ---
  if [[ "$do_sched" == true ]]; then
    log_info "Creating scheduler..."
    local scheduler_payload
    local pastel_colors=(
      "lightsalmon" "lightpink" "lightskyblue" "lightgreen"
      "peachpuff" "plum" "khaki" "thistle"
      "paleturquoise" "sandybrown" "lightcoral" "mediumaquamarine"
    )
    local random_color="${pastel_colors[$((RANDOM % ${#pastel_colors[@]}))]}"

    scheduler_payload=$(jq -n \
      --arg name "Scheduler 1" \
      --arg url "$scheduler_url" \
      --arg logUrl "$logger_url" \
      --arg color "$random_color" \
      '{
        "name": $name,
        "url": $url,
        "logServerUrl": $logUrl,
        "color": $color,
        "isDefault": true
      }')

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${confighub_url}/schedulers" \
      -H "Content-Type: application/json" \
      -d "$scheduler_payload")

    if [[ "$http_code" == "201" ]]; then
      log_success "Scheduler created: $scheduler_url"
    elif [[ "$http_code" == "409" ]]; then
      log_warn "Scheduler 'Scheduler 1' already exists, updating..."
      if curl -sf -X PUT "${confighub_url}/schedulers/Scheduler%201" \
        -H "Content-Type: application/json" \
        -d "$scheduler_payload" > /dev/null; then
        log_success "Scheduler updated: $scheduler_url"
      else
        log_error "Failed to update scheduler"
      fi
    else
      log_error "Failed to create scheduler (HTTP $http_code)"
    fi
    echo ""
  fi

  log_success "Instance '$name' initialized"
}

main() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    init) cmd_init "$@" ;;
    sync) cmd_sync "$@" ;;
    ""|help|--help|-h)
      echo "Usage: fm-sync.sh <init|sync> <instance>"
      ;;
    *)
      log_error "Unknown subcommand: $sub"
      echo "Usage: fm-sync.sh <init|sync> <instance>"
      exit 1
      ;;
  esac
}

main "$@"
