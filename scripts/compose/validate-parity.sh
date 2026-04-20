#!/usr/bin/env bash
# =============================================================================
# validate-parity.sh
# -----------------------------------------------------------------------------
# Audit parity between the Swarm source of truth (industream-stack/docker-stack.*.yml)
# and the Compose tree (industream-flowmaker/deployment/docker-compose.*.yml).
#
# WHY this exists
#   We explicitly do NOT auto-generate the compose override from the swarm
#   stacks — see `industream-cli/docs/INTEGRATION-PLAN.md` section 3
#   ("Compose vs Swarm stack files — mergeable or not?"): a mechanical
#   translation is only ~70% reliable because of secrets, Traefik labels,
#   and network driver differences. Instead we keep two parallel trees and
#   run this script in CI to guarantee they do not drift on the fields that
#   MUST stay in sync.
#
# What this script checks, for each service that appears in BOTH trees:
#   1. Image tag       (`image: repo:tag`) must match byte-for-byte.
#   2. Healthcheck     (`healthcheck.test` + `healthcheck.interval`) must match.
#   3. Env var keys    (names only — values are allowed to differ).
#   4. Container ports (the right-hand side of `host:container`; host may vary).
#
# What this script does NOT do:
#   - Resolve `${VAR}` interpolation. A mismatch like `postgres:${POSTGRES_VERSION}`
#     vs `postgres:18-alpine` will be flagged; that is intentional — pin both
#     sides explicitly or align the default.
#   - Follow `extends:` or `include:` directives.
#   - Validate Traefik labels, secrets, networks, or `deploy.*` — those ARE
#     expected to diverge by design (see §3 matrix).
#
# Usage:
#   ./scripts/compose/validate-parity.sh            # human-readable, exit 1 on mismatch
#   ./scripts/compose/validate-parity.sh --json     # machine-readable output for CI
#   ./scripts/compose/validate-parity.sh --fix      # print the manual sync hints
#
# Env vars:
#   COMPOSE_ROOT  Path to the compose deployment dir.
#                 Default: <repo-parent>/industream-flowmaker/deployment
#   SWARM_ROOT    Path to the swarm stack dir.
#                 Default: the repo that contains this script.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# Repo root = parent of scripts/compose
SWARM_ROOT_DEFAULT="${SCRIPT_DIR%/scripts/compose}"
SWARM_ROOT="${SWARM_ROOT:-$SWARM_ROOT_DEFAULT}"
COMPOSE_ROOT="${COMPOSE_ROOT:-${SWARM_ROOT}/../industream-flowmaker/deployment}"

# Canonical service list — only these are audited. Names use the canonical
# Swarm service id where it differs from the Compose id; the name map below
# resolves compose aliases.
CANONICAL_SERVICES=(
  "postgres"
  "keycloak"
  "redis"
  "uifusion"
  "flowmaker-scheduler"
  "flowmaker-launcher"
  "flowmaker-confighub-v2"
  "flowmaker-logger"
  "flowmaker-front"
  "datacatalog-api"
  "datacatalog-ui"
  "databridge-api"
)

# Compose service name aliases -> canonical name.
# Compose uses `flowmaker-confighub` for the v2 image, `flowmaker-logging`,
# `flowmaker-frontend` — map them so the parity check lines up.
declare -A COMPOSE_ALIAS=(
  ["flowmaker-confighub"]="flowmaker-confighub-v2"
  ["flowmaker-logging"]="flowmaker-logger"
  ["flowmaker-frontend"]="flowmaker-front"
  ["databridge"]="databridge-api"
)

# -----------------------------------------------------------------------------
# CLI flags
# -----------------------------------------------------------------------------
OUTPUT_MODE="human"   # human | json
SHOW_FIX_HINTS=0

for arg in "$@"; do
  case "$arg" in
    --json) OUTPUT_MODE="json" ;;
    --fix)  SHOW_FIX_HINTS=1 ;;
    -h|--help)
      sed -n '2,40p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

# -----------------------------------------------------------------------------
# YAML reader: prefer yq (mikefarah), fall back to python3+PyYAML.
# Exposes: yaml_get <file> <expression>
#   The expression is yq/go-style: '.services.postgres.image'
# -----------------------------------------------------------------------------
YAML_BACKEND=""
if command -v yq >/dev/null 2>&1; then
  yq_version="$(yq --version 2>&1 || true)"
  case "$yq_version" in
    *mikefarah*|*"version v"*|*"version 4"*) YAML_BACKEND="yq" ;;
    *) YAML_BACKEND="" ;;
  esac
fi

if [[ -z "$YAML_BACKEND" ]] && command -v python3 >/dev/null 2>&1; then
  if python3 -c "import yaml" >/dev/null 2>&1; then
    YAML_BACKEND="python"
  fi
fi

if [[ -z "$YAML_BACKEND" ]]; then
  echo "ERROR: need either mikefarah 'yq' (>= 4) or python3 with PyYAML installed." >&2
  echo "Install:  sudo pacman -S yq   OR   pip install --user pyyaml" >&2
  exit 2
fi

yaml_get() {
  local file="$1" expr="$2"
  if [[ "$YAML_BACKEND" == "yq" ]]; then
    yq eval "$expr // \"\"" "$file" 2>/dev/null || true
  else
    python3 - "$file" "$expr" <<'PY'
import sys, yaml
path = sys.argv[1]
expr = sys.argv[2].lstrip('.')
with open(path, 'r', encoding='utf-8') as fh:
    try:
        doc = yaml.safe_load(fh) or {}
    except yaml.YAMLError as exc:
        sys.stderr.write(f"yaml parse error in {path}: {exc}\n")
        sys.exit(0)

def walk(node, segments):
    for seg in segments:
        if node is None:
            return None
        # array index: [0]
        if seg.startswith('[') and seg.endswith(']'):
            try:
                idx = int(seg[1:-1])
            except ValueError:
                return None
            if isinstance(node, list) and -len(node) <= idx < len(node):
                node = node[idx]
            else:
                return None
        elif isinstance(node, dict):
            node = node.get(seg)
        else:
            return None
    return node

# Very small subset of yq syntax: dot-separated keys, optional [idx].
segments = []
buf = ''
i = 0
while i < len(expr):
    c = expr[i]
    if c == '.':
        if buf:
            segments.append(buf); buf = ''
    elif c == '[':
        if buf:
            segments.append(buf); buf = ''
        end = expr.index(']', i)
        segments.append(expr[i:end+1])
        i = end
    else:
        buf += c
    i += 1
if buf:
    segments.append(buf)

val = walk(doc, segments)
if val is None:
    print('')
elif isinstance(val, (dict, list)):
    # emit as compact JSON so callers can parse deterministic output
    import json
    print(json.dumps(val, sort_keys=True))
else:
    print(val)
PY
  fi
}

# List service names in a YAML file (top-level `services:` mapping keys).
yaml_list_services() {
  local file="$1"
  if [[ "$YAML_BACKEND" == "yq" ]]; then
    yq eval '.services | keys | .[]' "$file" 2>/dev/null || true
  else
    python3 - "$file" <<'PY'
import sys, yaml
with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    try:
        doc = yaml.safe_load(fh) or {}
    except yaml.YAMLError:
        sys.exit(0)
for name in (doc.get('services') or {}).keys():
    print(name)
PY
  fi
}

# -----------------------------------------------------------------------------
# Index builder: walk every stack/compose file, record the first occurrence of
# each service along with its source file.
# -----------------------------------------------------------------------------
declare -A SWARM_FILE_OF
declare -A COMPOSE_FILE_OF

index_tree() {
  local root="$1" glob_prefix="$2"
  local -n outmap="$3"
  shopt -s nullglob
  local file svc
  for file in "$root"/"${glob_prefix}"*.yml "$root"/"${glob_prefix}"*.yaml; do
    [[ -f "$file" ]] || continue
    while IFS= read -r svc; do
      [[ -z "$svc" ]] && continue
      # First file wins — the base files (docker-stack.yml / docker-compose.yml)
      # sort before the suffixed variants, which is what we want.
      if [[ -z "${outmap[$svc]:-}" ]]; then
        outmap[$svc]="$file"
      fi
    done < <(yaml_list_services "$file")
  done
  shopt -u nullglob
}

if [[ ! -d "$SWARM_ROOT" ]]; then
  echo "ERROR: SWARM_ROOT not found: $SWARM_ROOT" >&2
  exit 2
fi
if [[ ! -d "$COMPOSE_ROOT" ]]; then
  echo "ERROR: COMPOSE_ROOT not found: $COMPOSE_ROOT (set COMPOSE_ROOT=... to override)" >&2
  exit 2
fi

index_tree "$SWARM_ROOT"   "docker-stack."   SWARM_FILE_OF
index_tree "$COMPOSE_ROOT" "docker-compose." COMPOSE_FILE_OF

# Resolve compose aliases so the comparison keys align.
for alias in "${!COMPOSE_ALIAS[@]}"; do
  canonical="${COMPOSE_ALIAS[$alias]}"
  if [[ -n "${COMPOSE_FILE_OF[$alias]:-}" && -z "${COMPOSE_FILE_OF[$canonical]:-}" ]]; then
    COMPOSE_FILE_OF[$canonical]="${COMPOSE_FILE_OF[$alias]}"
    # Remember the on-disk name so yaml_get can find it.
    COMPOSE_FILE_OF["__alias_of_${canonical}"]="$alias"
  fi
done

# -----------------------------------------------------------------------------
# Comparators
# -----------------------------------------------------------------------------
MISMATCHES=()
OK_COUNT=0
CHECKED_COUNT=0

# Each result row is tab-separated: status\tservice\tfield\tswarm\tcompose.
# Tab is chosen because healthcheck commands often contain "|" but never a real tab.
RESULTS=()
RESULT_SEP=$'\t'

emit_result() {
  local status="$1" svc="$2" field="$3" sv="$4" cv="$5"
  RESULTS+=("${status}${RESULT_SEP}${svc}${RESULT_SEP}${field}${RESULT_SEP}${sv}${RESULT_SEP}${cv}")
  if [[ "$status" == "MISMATCH" ]]; then
    MISMATCHES+=("${svc}:${field}")
  else
    OK_COUNT=$((OK_COUNT + 1))
  fi
}

# Compose service may be registered under an alias; return the on-disk name.
compose_key() {
  local svc="$1"
  echo "${COMPOSE_FILE_OF[__alias_of_${svc}]:-$svc}"
}

compare_image() {
  local svc="$1" sfile="$2" cfile="$3" ckey
  ckey="$(compose_key "$svc")"
  local sval cval
  sval="$(yaml_get "$sfile" ".services.${svc}.image")"
  cval="$(yaml_get "$cfile" ".services.${ckey}.image")"
  if [[ -z "$sval" || -z "$cval" ]]; then
    # If either side omits the image key, skip — we can't compare inherited images.
    return
  fi
  if [[ "$sval" == "$cval" ]]; then
    emit_result "OK" "$svc" "image" "$sval" "$cval"
  else
    emit_result "MISMATCH" "$svc" "image" "$sval" "$cval"
  fi
}

compare_healthcheck() {
  local svc="$1" sfile="$2" cfile="$3" ckey
  ckey="$(compose_key "$svc")"
  local s_test c_test s_int c_int
  s_test="$(yaml_get "$sfile" ".services.${svc}.healthcheck.test")"
  c_test="$(yaml_get "$cfile" ".services.${ckey}.healthcheck.test")"
  s_int="$(yaml_get "$sfile" ".services.${svc}.healthcheck.interval")"
  c_int="$(yaml_get "$cfile" ".services.${ckey}.healthcheck.interval")"

  # If neither side declares a healthcheck, nothing to check.
  if [[ -z "$s_test" && -z "$c_test" ]]; then
    return
  fi

  # Normalise whitespace/newlines for comparison.
  local s_test_norm c_test_norm
  s_test_norm="$(printf '%s' "$s_test" | tr -s '[:space:]' ' ')"
  c_test_norm="$(printf '%s' "$c_test" | tr -s '[:space:]' ' ')"

  if [[ "$s_test_norm" == "$c_test_norm" ]]; then
    emit_result "OK" "$svc" "healthcheck.test" "$s_test_norm" "$c_test_norm"
  else
    emit_result "MISMATCH" "$svc" "healthcheck.test" "$s_test_norm" "$c_test_norm"
  fi

  if [[ -n "$s_int" && -n "$c_int" ]]; then
    if [[ "$s_int" == "$c_int" ]]; then
      emit_result "OK" "$svc" "healthcheck.interval" "$s_int" "$c_int"
    else
      emit_result "MISMATCH" "$svc" "healthcheck.interval" "$s_int" "$c_int"
    fi
  fi
}

# Collect env var KEYS (names) from a service's `environment` block, which
# can be either a list ("KEY=val" or "KEY") or a map ({KEY: val}).
env_keys() {
  local file="$1" svc="$2"
  if [[ "$YAML_BACKEND" == "yq" ]]; then
    # Try list form first; fall back to map.
    local keys
    keys="$(yq eval "
      .services.\"${svc}\".environment |
        (select(tag == \"!!seq\") | .[] | sub(\"=.*\",\"\")),
        (select(tag == \"!!map\") | keys | .[])
    " "$file" 2>/dev/null | sort -u | grep -v '^null$' || true)"
    printf '%s\n' "$keys"
  else
    python3 - "$file" "$svc" <<'PY'
import sys, yaml
path, svc = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as fh:
    try:
        doc = yaml.safe_load(fh) or {}
    except yaml.YAMLError:
        sys.exit(0)
env = ((doc.get('services') or {}).get(svc) or {}).get('environment')
keys = []
if isinstance(env, list):
    for item in env:
        if isinstance(item, str):
            keys.append(item.split('=', 1)[0])
elif isinstance(env, dict):
    keys = list(env.keys())
for k in sorted(set(keys)):
    print(k)
PY
  fi
}

compare_env_keys() {
  local svc="$1" sfile="$2" cfile="$3" ckey
  ckey="$(compose_key "$svc")"
  local s_keys c_keys
  s_keys="$(env_keys "$sfile" "$svc" | sort -u)"
  c_keys="$(env_keys "$cfile" "$ckey" | sort -u)"

  if [[ -z "$s_keys" && -z "$c_keys" ]]; then
    return
  fi

  # Intersection diff: keys present in ONE side but not the other.
  local only_swarm only_compose
  only_swarm="$(comm -23 <(printf '%s\n' "$s_keys") <(printf '%s\n' "$c_keys"))"
  only_compose="$(comm -13 <(printf '%s\n' "$s_keys") <(printf '%s\n' "$c_keys"))"

  if [[ -z "$only_swarm" && -z "$only_compose" ]]; then
    emit_result "OK" "$svc" "env.keys" "(aligned)" "(aligned)"
  else
    local sv_summary cv_summary
    sv_summary="only-in-swarm: $(printf '%s' "$only_swarm" | tr '\n' ',' | sed 's/,$//')"
    cv_summary="only-in-compose: $(printf '%s' "$only_compose" | tr '\n' ',' | sed 's/,$//')"
    emit_result "MISMATCH" "$svc" "env.keys" "$sv_summary" "$cv_summary"
  fi
}

# Extract container-side ports from a `ports:` list.
#   "8080:80"         -> 80
#   "127.0.0.1:80:80" -> 80
#   "9000"            -> 9000
#   { target: 80, published: 8080 } -> 80
container_ports() {
  local file="$1" svc="$2"
  if [[ "$YAML_BACKEND" == "yq" ]]; then
    yq eval "
      .services.\"${svc}\".ports[] |
        (select(tag == \"!!str\") | sub(\".*:\",\"\")),
        (select(tag == \"!!map\") | .target)
    " "$file" 2>/dev/null | grep -v '^null$' | sort -un || true
  else
    python3 - "$file" "$svc" <<'PY'
import sys, yaml
path, svc = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as fh:
    try:
        doc = yaml.safe_load(fh) or {}
    except yaml.YAMLError:
        sys.exit(0)
ports = ((doc.get('services') or {}).get(svc) or {}).get('ports') or []
out = []
for p in ports:
    if isinstance(p, str):
        # strip any "host:" prefixes, keep only the rightmost :N
        parts = p.split(':')
        tail = parts[-1].split('/')[0]
        out.append(tail)
    elif isinstance(p, dict):
        t = p.get('target')
        if t is not None:
            out.append(str(t))
for v in sorted(set(out), key=lambda x: int(x) if x.isdigit() else 0):
    print(v)
PY
  fi
}

compare_ports() {
  local svc="$1" sfile="$2" cfile="$3" ckey
  ckey="$(compose_key "$svc")"
  local s_ports c_ports
  s_ports="$(container_ports "$sfile" "$svc")"
  c_ports="$(container_ports "$cfile" "$ckey")"
  if [[ -z "$s_ports" && -z "$c_ports" ]]; then
    return
  fi
  if [[ "$s_ports" == "$c_ports" ]]; then
    emit_result "OK" "$svc" "ports.container" "$s_ports" "$c_ports"
  else
    local sv cv
    sv="$(printf '%s' "$s_ports" | tr '\n' ',' | sed 's/,$//')"
    cv="$(printf '%s' "$c_ports" | tr '\n' ',' | sed 's/,$//')"
    emit_result "MISMATCH" "$svc" "ports.container" "$sv" "$cv"
  fi
}

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------
for svc in "${CANONICAL_SERVICES[@]}"; do
  sfile="${SWARM_FILE_OF[$svc]:-}"
  cfile="${COMPOSE_FILE_OF[$svc]:-}"

  if [[ -z "$sfile" || -z "$cfile" ]]; then
    # Service missing on one side → informational only, never a hard fail.
    continue
  fi

  CHECKED_COUNT=$((CHECKED_COUNT + 1))
  compare_image       "$svc" "$sfile" "$cfile"
  compare_healthcheck "$svc" "$sfile" "$cfile"
  compare_env_keys    "$svc" "$sfile" "$cfile"
  compare_ports       "$svc" "$sfile" "$cfile"
done

# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------
mismatch_count="${#MISMATCHES[@]}"

json_escape() {
  # Escape backslashes first, then double quotes, then control chars that break JSON.
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g'
}

if [[ "$OUTPUT_MODE" == "json" ]]; then
  # Emit newline-delimited JSON objects — easy to parse in CI with `jq -s`.
  printf '{"summary":{"checked":%d,"ok":%d,"mismatches":%d}}\n' \
    "$CHECKED_COUNT" "$OK_COUNT" "$mismatch_count"
  for row in "${RESULTS[@]}"; do
    IFS="$RESULT_SEP" read -r status svc field sv cv <<<"$row"
    printf '{"status":"%s","service":"%s","field":"%s","swarm":"%s","compose":"%s"}\n' \
      "$(json_escape "$status")" "$(json_escape "$svc")" "$(json_escape "$field")" \
      "$(json_escape "$sv")" "$(json_escape "$cv")"
  done
else
  echo "swarm root   : $SWARM_ROOT"
  echo "compose root : $COMPOSE_ROOT"
  echo "yaml backend : $YAML_BACKEND"
  echo
  for row in "${RESULTS[@]}"; do
    IFS="$RESULT_SEP" read -r status svc field sv cv <<<"$row"
    if [[ "$status" == "OK" ]]; then
      printf '[OK]       %-25s %-22s\n' "$svc" "$field"
    else
      printf '[MISMATCH] %-25s %-22s\n             swarm  : %s\n             compose: %s\n' \
        "$svc" "$field" "$sv" "$cv"
    fi
  done
  echo
  echo "----------------------------------------------------------------"
  echo "$CHECKED_COUNT services checked, $mismatch_count mismatches"
  echo "----------------------------------------------------------------"

  if (( SHOW_FIX_HINTS == 1 )) && (( mismatch_count > 0 )); then
    echo
    echo "This script will NOT auto-sync (see docs/INTEGRATION-PLAN.md §3)."
    echo "Manual steps to realign each mismatch:"
    for entry in "${MISMATCHES[@]}"; do
      svc="${entry%%:*}"
      field="${entry#*:}"
      sfile="${SWARM_FILE_OF[$svc]:-?}"
      cfile="${COMPOSE_FILE_OF[$svc]:-?}"
      case "$field" in
        image)
          echo "  - ${svc}.image : align the tag in"
          echo "      swarm   -> $sfile"
          echo "      compose -> $cfile"
          ;;
        healthcheck.*)
          echo "  - ${svc}.${field} : copy the healthcheck block from the swarm file into the compose file"
          echo "      swarm   -> $sfile"
          echo "      compose -> $cfile"
          ;;
        env.keys)
          echo "  - ${svc}.environment : reconcile env var KEYS (values may differ)"
          echo "      swarm   -> $sfile"
          echo "      compose -> $cfile"
          ;;
        ports.container)
          echo "  - ${svc}.ports : container-side port must match (host binding may vary)"
          echo "      swarm   -> $sfile"
          echo "      compose -> $cfile"
          ;;
      esac
    done
  fi
fi

exit $(( mismatch_count > 0 ? 1 : 0 ))
