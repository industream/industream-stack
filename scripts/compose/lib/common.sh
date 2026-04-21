#!/usr/bin/env bash
# =============================================================================
# common.sh — shared helpers for fm-* compose scripts
# =============================================================================
# Sourced by every fm-<topic>.sh sub-script. Provides:
#   - Color constants (with defaults, safe under `set -u`)
#   - log_* wrappers
#   - get_existing_* / prompt* helpers ported verbatim from the monolithic `fm`
#   - COMPOSE_ROOT and INSTANCES_DIR resolution
#
# The COMPOSE_ROOT override lets the scripts live in
# industream-stack/scripts/compose/ while still pointing at the compose files
# that currently live in industream-flowmaker/deployment/.
# =============================================================================

# Colors — keep defaults so `set -u` never blows up a sourcing script.
RED="${RED:-$'\033[0;31m'}"
GREEN="${GREEN:-$'\033[0;32m'}"
YELLOW="${YELLOW:-$'\033[1;33m'}"
BLUE="${BLUE:-$'\033[0;34m'}"
NC="${NC:-$'\033[0m'}"

log_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }

# -----------------------------------------------------------------------------
# Compose file root resolution
# -----------------------------------------------------------------------------
# SCRIPT_DIR is set by each sourcing script before this file is sourced.
# COMPOSE_ROOT points at the directory containing docker-compose.*.yml,
# .env.defaults, .env.template, docker-compose.infra*.yml, etc.
# Default: ../../../industream-flowmaker/deployment/ relative to scripts/compose/.
if [[ -z "${COMPOSE_ROOT:-}" ]]; then
  if [[ -n "${SCRIPT_DIR:-}" ]]; then
    COMPOSE_ROOT="$(cd "$SCRIPT_DIR/../../../industream-flowmaker/deployment" 2>/dev/null && pwd || true)"
  fi
fi
COMPOSE_ROOT="${COMPOSE_ROOT:-}"

# INSTANCES_DIR lives next to the compose files, unless caller overrides
# (handy for tests). Falls back gracefully if COMPOSE_ROOT is not yet set.
INSTANCES_DIR="${FM_INSTANCES_DIR:-${COMPOSE_ROOT:+$COMPOSE_ROOT/instances}}"

# -----------------------------------------------------------------------------
# Helpers (verbatim from fm, with INSTANCES_DIR / SCRIPT_DIR parameterized)
# -----------------------------------------------------------------------------

get_existing_networks() {
  local networks=()
  shopt -s nullglob
  for env_file in "$INSTANCES_DIR"/*/.env; do
    [[ -f "$env_file" ]] || continue
    local net
    net=$(grep -E '^FM_NETWORK=' "$env_file" 2>/dev/null | cut -d= -f2)
    [[ -n "$net" ]] && networks+=("$net")
  done
  shopt -u nullglob
  printf '%s\n' "${networks[@]}"
}

# Parse worker versions from docker-compose.workers.yml
# Extracts lines like: ${WORKER_TIMER_VERSION:-2.0.1}
# Outputs: WORKER_TIMER_VERSION=2.0.1
get_worker_versions() {
  local workers_file="$COMPOSE_ROOT/docker-compose.workers.yml"
  [[ ! -f "$workers_file" ]] && return

  grep -oE '\$\{[A-Z0-9_]+_VERSION:-[^}]+\}' "$workers_file" | \
    sed 's/\${//; s/:-/=/; s/}//' | \
    sort -u
}

get_existing_domains() {
  local domains=()
  shopt -s nullglob
  for env_file in "$INSTANCES_DIR"/*/.env; do
    [[ -f "$env_file" ]] || continue
    local domain
    domain=$(grep -E '^FM_DOMAIN=' "$env_file" 2>/dev/null | cut -d= -f2)
    [[ -n "$domain" ]] && domains+=("$domain")
  done
  shopt -u nullglob
  printf '%s\n' "${domains[@]}"
}

is_unique() {
  local value="$1"
  shift
  local existing=("$@")
  for item in "${existing[@]}"; do
    [[ "$item" == "$value" ]] && return 1
  done
  return 0
}

suggest_unique_name() {
  local base="$1"
  shift
  local existing=("$@")

  if is_unique "$base" "${existing[@]}"; then
    echo "$base"
    return
  fi

  local i=2
  while ! is_unique "${base}-${i}" "${existing[@]}"; do
    ((i++))
  done
  echo "${base}-${i}"
}

read_root_env() {
  local var="$1"
  local default="${2:-}"
  if [[ -f "$COMPOSE_ROOT/.env.defaults" ]]; then
    local value
    value=$(grep -E "^${var}=" "$COMPOSE_ROOT/.env.defaults" 2>/dev/null | cut -d= -f2)
    [[ -n "$value" ]] && echo "$value" && return
  fi
  echo "$default"
}

prompt() {
  local var_name="$1"
  local prompt_text="$2"
  local default="$3"
  local value

  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "${BLUE}?${NC} ${prompt_text} [${default}]: ")" value
    value="${value:-$default}"
  else
    read -rp "$(echo -e "${BLUE}?${NC} ${prompt_text}: ")" value
  fi
  echo "$value"
}

prompt_unique() {
  local var_name="$1"
  local prompt_text="$2"
  local default="$3"
  local -a existing=("${@:4}")
  local value

  while true; do
    value=$(prompt "$var_name" "$prompt_text" "$default")
    if is_unique "$value" "${existing[@]}"; then
      echo "$value"
      return
    fi
    log_warn "Value '$value' already exists. Please choose a unique value."
    default=$(suggest_unique_name "$value" "${existing[@]}")
  done
}

# Ensure the instances dir exists once COMPOSE_ROOT is known.
if [[ -n "$INSTANCES_DIR" ]]; then
  mkdir -p "$INSTANCES_DIR"
fi
