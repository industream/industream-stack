#!/usr/bin/env bash
# =============================================================================
# forge-bundle.sh — materialize a release bundle from the Forge API.
# =============================================================================
# Ports deployment-v2's `fm --bundle-interactive` Forge flow into the unified
# tree, WITHOUT changing how deploy.sh consumes bundles: Forge is just a
# *source* that drops .env.* files into releases/bundle-platform-<key>/, exactly
# like render-bundles.sh does from the local sources. deploy.sh --bundle <key>
# then deploys it unchanged.
#
# The Forge contract mirrors David's fm (feat/deployment-v2):
#   GET  {FORGE}public/bundles/exports
#   GET  {FORGE}public/bundles/{exportKey}/versions/{version}/export   (a .zip)
#
#   ./forge-bundle.sh list                         # machine-readable export list
#   ./forge-bundle.sh list --json                  # raw normalized JSON
#   ./forge-bundle.sh fetch <exportKey> <version>  # download → releases/bundle-platform-forge-…/
#   ./forge-bundle.sh fetch <exportKey> <version> --name 1.0.1   # into bundle-platform-1.0.1/
#   ./forge-bundle.sh import <bundle.zip> [--name <key>]   # OFFLINE: materialize from a local zip
#   ./forge-bundle.sh check <bundle-key|dir>       # verify a bundle satisfies base/*.yml image vars
#   ./forge-bundle.sh interactive                  # menu; prints the resolved bundle key
#
# On `fetch`/`interactive` the RESOLVED BUNDLE KEY (e.g. forge-flowmaker-ce-2.1.0)
# is printed as the LAST stdout line so deploy.sh can capture it:
#   BUNDLE="$(scripts/forge-bundle.sh fetch "$k" "$v")"
#   ./deploy.sh --runtime swarm --bundle "$BUNDLE" …
#
# Config:
#   RELEASE_FORGE_URL   override the default Forge base URL.
#   FORGE_INSECURE=1    skip TLS verification (curl -k). Secure-by-default OFF;
#                       opt-in ONLY for a Forge behind an internal/self-signed
#                       cert whose CA is not installed on the host. Prefer
#                       installing the internal CA over setting this in prod.
# All progress/prompt output goes to STDERR so stdout stays clean for capture.
# =============================================================================
set -euo pipefail

DEFAULT_RELEASE_FORGE_URL="https://forge-api.forge.industream.dev/"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # unified/
RELEASES_DIR="$HERE/releases"

# TLS mode for every Forge curl. Empty by default (verify); -k only when opted in.
CURL_TLS_OPTS=()
case "${FORGE_INSECURE:-}" in 1|true|yes) CURL_TLS_OPTS=(-k) ;; esac

# ---- logging (stderr; keeps stdout clean for the printed bundle key) --------
if [[ -t 2 ]]; then
  _C_RED=$'\033[0;31m'; _C_GRN=$'\033[0;32m'; _C_YLW=$'\033[1;33m'; _C_BLU=$'\033[0;34m'; _C_NC=$'\033[0m'
else
  _C_RED=""; _C_GRN=""; _C_YLW=""; _C_BLU=""; _C_NC=""
fi
log_info()    { echo "${_C_BLU}▶${_C_NC} $*" >&2; }
log_success() { echo "${_C_GRN}✓${_C_NC} $*" >&2; }
log_warn()    { echo "${_C_YLW}⚠${_C_NC} $*" >&2; }
log_error()   { echo "${_C_RED}✗${_C_NC} $*" >&2; }

get_release_forge_url() {
  local url="${RELEASE_FORGE_URL:-$DEFAULT_RELEASE_FORGE_URL}"
  # strip surrounding quotes a config file may carry, ensure trailing slash
  url="${url%\"}"; url="${url#\"}"; url="${url%\'}"; url="${url#\'}"
  [[ "$url" != */ ]] && url="$url/"
  echo "$url"
}

require() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { log_error "'$c' is required for this command"; missing=1; }
  done
  [[ "$missing" -eq 0 ]]
}

# ---- bundle-key sanitizer: a Forge export/version → a filesystem-safe key ----
# Only [A-Za-z0-9._-] survive; everything else collapses to '-'. Keeps the
# bundle dir name predictable and shell-safe (deploy.sh globs bundle-platform-*).
sanitize_key() {
  local raw="$1"
  raw="${raw//[^A-Za-z0-9._-]/-}"
  # squeeze repeats and trim leading/trailing separators
  raw="$(printf '%s' "$raw" | sed -E 's/-+/-/g; s/^[-.]+//; s/[-.]+$//')"
  echo "$raw"
}

fetch_forge_exports_json() {
  local forge_url; forge_url="$(get_release_forge_url)"
  require curl jq || return 1
  curl -fsSL "${CURL_TLS_OPTS[@]}" "${forge_url}public/bundles/exports" || {
    log_error "failed to fetch Forge exports from ${forge_url}public/bundles/exports"
    [[ ${#CURL_TLS_OPTS[@]} -eq 0 ]] && log_warn "if this is a TLS/cert error, retry with FORGE_INSECURE=1 (internal/self-signed Forge)"
    return 1
  }
}

# Normalize the exports payload (array | {exports:[…]} | {data:[…]}) to a flat array.
normalize_exports_json() {
  jq -c '
    if type == "array" then .
    elif .exports then .exports
    elif .data then .data
    else []
    end'
}

# ---- list: machine-readable export/version table ----------------------------
cmd_list() {
  local as_json=false
  [[ "${1:-}" == "--json" ]] && as_json=true
  local raw; raw="$(fetch_forge_exports_json)" || return 1
  local norm; norm="$(printf '%s' "$raw" | normalize_exports_json)"

  if [[ "$as_json" == true ]]; then
    printf '%s\n' "$norm"
    return
  fi

  # TSV: exportKey  projectKey  version  (one row per available version)
  printf '%s' "$norm" | jq -r '
    .[]
    | { exportKey: (.exportKey // .key // .id // ""),
        projectKey: ((.projectKey // (.project | if type=="object" then .key else . end) // .key) // ""),
        versions: ((.versions // .bundleVersions // .availableVersions // []) ) }
    | . as $e
    | ($e.versions[]?
        | (if type=="string" then . else (.versionNumber // .version // .name // .key // "") end)) as $v
    | select($e.exportKey != "" and $v != "")
    | [$e.exportKey, ($e.projectKey // $e.exportKey), $v] | @tsv'
}

# ---- shared: copy the .env.* out of an extracted archive into a bundle dir ---
# Finds .env.* anywhere under $extract_dir, wipes the destination's prior .env.*
# (so a re-import never leaves stale image refs), copies, and returns the count
# via stdout. Used by both `fetch` (Forge download) and `import` (local zip).
install_env_files_from_dir() {
  local extract_dir="$1" dest_dir="$2"
  shopt -s globstar nullglob
  local -a env_files=("$extract_dir"/**/.env.*)
  shopt -u globstar nullglob
  [[ ${#env_files[@]} -eq 0 ]] && { log_error "no .env.* files found in the bundle archive"; return 1; }

  mkdir -p "$dest_dir"
  shopt -s nullglob; local f; for f in "$dest_dir"/.env.*; do rm -f "$f"; done; shopt -u nullglob

  local copied=0
  for f in "${env_files[@]}"; do cp "$f" "$dest_dir/$(basename "$f")"; copied=$((copied + 1)); done
  log_success "copied ${copied} env file(s) → releases/$(basename "$dest_dir")/"
}

# ---- download + extract a bundle into releases/bundle-platform-<key>/ --------
cmd_fetch() {
  local export_key="" version="" name="" print_key=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)     name="$2"; shift 2 ;;
      --name=*)   name="${1#--name=}"; shift ;;
      --quiet)    print_key=false; shift ;;
      -*)         log_error "unknown option: $1"; return 1 ;;
      *)          if [[ -z "$export_key" ]]; then export_key="$1"; elif [[ -z "$version" ]]; then version="$1"; else log_error "unexpected arg: $1"; return 1; fi; shift ;;
    esac
  done
  [[ -z "$export_key" || -z "$version" ]] && { log_error "usage: forge-bundle.sh fetch <exportKey> <version> [--name <key>]"; return 1; }
  require curl unzip || return 1

  # Bundle key: caller-provided --name (→ bundle-platform-<name>) else a
  # deterministic forge-<exportKey>-<version> (gitignored via bundle-platform-forge-*).
  local key
  if [[ -n "$name" ]]; then key="$(sanitize_key "$name")"; else key="forge-$(sanitize_key "${export_key}-${version}")"; fi
  local dest_dir="$RELEASES_DIR/bundle-platform-${key}"

  local forge_url; forge_url="$(get_release_forge_url)"
  local tmp_dir; tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN
  local zip="$tmp_dir/bundle.zip" extract="$tmp_dir/x"; mkdir -p "$extract"

  local url="${forge_url}public/bundles/${export_key}/versions/${version}/export"
  log_info "downloading Forge bundle: ${export_key}@${version}"
  curl -fsSL "${CURL_TLS_OPTS[@]}" "$url" -o "$zip" || {
    log_error "download failed: $url"
    [[ ${#CURL_TLS_OPTS[@]} -eq 0 ]] && log_warn "if this is a TLS/cert error, retry with FORGE_INSECURE=1 (internal/self-signed Forge)"
    return 1
  }
  unzip -q "$zip" -d "$extract" || { log_error "failed to extract bundle archive"; return 1; }

  install_env_files_from_dir "$extract" "$dest_dir" || return 1

  # Provenance breadcrumb (matches David's # Forge … metadata), non-.env so it's
  # never sourced as an env-file by deploy.sh's .env.* glob.
  printf 'source=forge\nexportKey=%s\nversion=%s\nforgeUrl=%s\n' "$export_key" "$version" "$forge_url" > "$dest_dir/FORGE_SOURCE"

  # LAST stdout line = the bundle key deploy.sh should pass to --bundle.
  [[ "$print_key" == true ]] && echo "$key"
}

# ---- import a bundle from a LOCAL zip (offline / air-gapped) -----------------
# Same materialization as `fetch`, but the archive comes from disk instead of
# Forge — for when the box can't reach forge-api (VPN down, air-gapped site):
# download the .zip on a machine that CAN, copy it over, then `import` it.
cmd_import() {
  local zip_path="" name="" print_key=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)   name="$2"; shift 2 ;;
      --name=*) name="${1#--name=}"; shift ;;
      --quiet)  print_key=false; shift ;;
      -*)       log_error "unknown option: $1"; return 1 ;;
      *)        if [[ -z "$zip_path" ]]; then zip_path="$1"; else log_error "unexpected arg: $1"; return 1; fi; shift ;;
    esac
  done
  [[ -z "$zip_path" ]] && { log_error "usage: forge-bundle.sh import <bundle.zip> [--name <key>]"; return 1; }
  [[ -f "$zip_path" ]] || { log_error "zip not found: $zip_path"; return 1; }
  require unzip || return 1

  # Default key = the zip's basename (sans .zip), sanitized. --name overrides.
  local key
  if [[ -n "$name" ]]; then key="$(sanitize_key "$name")"; else key="$(sanitize_key "$(basename "${zip_path%.zip}")")"; fi
  [[ -n "$key" ]] || { log_error "could not derive a bundle key from '$zip_path' — pass --name <key>"; return 1; }
  local dest_dir="$RELEASES_DIR/bundle-platform-${key}"

  local tmp_dir; tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN
  local extract="$tmp_dir/x"; mkdir -p "$extract"

  log_info "importing local bundle: $zip_path"
  unzip -q "$zip_path" -d "$extract" || { log_error "failed to extract $zip_path"; return 1; }
  install_env_files_from_dir "$extract" "$dest_dir" || return 1
  printf 'source=import\nzip=%s\n' "$(readlink -f "$zip_path")" > "$dest_dir/FORGE_SOURCE"

  [[ "$print_key" == true ]] && echo "$key"
}

# ---- check: does a materialized bundle satisfy unified base/*.yml? -----------
# Cross-checks the ${X_IMAGE} vars a bundle PROVIDES against those the assembled
# base/*.yml REQUIRE, so a var-name/coverage mismatch is caught BEFORE a live
# deploy (a swarm --render only validates YAML, it does NOT expand vars, so it
# passes even when image refs would resolve EMPTY). Exit 0 = all required vars
# present; exit 2 = one or more missing.
cmd_check() {
  # A bundle only covers the groups/edition it was SCOPED for: a CE
  # `flowmaker-community` Forge bundle ships no data/monitoring/EE images and is
  # NOT broken for lacking them — you deploy it with a narrowed group set. So
  # `required` is computed ONLY from the base/*.yml deploy.sh would actually
  # assemble for --edition/--groups (same mapping as deploy.sh), not all of base/.
  local target="" edition="ce"
  local groups="core flowmaker datacatalog workers data monitoring"   # deploy.sh default
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --edition)   edition="$2"; shift 2 ;;
      --edition=*) edition="${1#--edition=}"; shift ;;
      --groups)    groups="$2"; shift 2 ;;
      --groups=*)  groups="${1#--groups=}"; shift ;;
      -*)          log_error "unknown option: $1"; return 1 ;;
      *)           if [[ -z "$target" ]]; then target="$1"; else log_error "unexpected arg: $1"; return 1; fi; shift ;;
    esac
  done
  [[ -z "$target" ]] && { log_error "usage: forge-bundle.sh check <bundle-key|bundle-dir> [--edition ce|ee] [--groups \"core flowmaker …\"]"; return 1; }
  [[ "$edition" == ce || "$edition" == ee ]] || { log_error "--edition must be ce|ee"; return 1; }

  # Accept a full path, a bundle-platform-<key> name, or a bare key.
  local dir
  if [[ -d "$target" ]]; then dir="$target"
  elif [[ -d "$RELEASES_DIR/$target" ]]; then dir="$RELEASES_DIR/$target"
  elif [[ -d "$RELEASES_DIR/bundle-platform-$target" ]]; then dir="$RELEASES_DIR/bundle-platform-$target"
  else log_error "bundle not found: $target"; return 1; fi
  shopt -s nullglob; local -a bfiles=("$dir"/.env.*); shopt -u nullglob
  [[ ${#bfiles[@]} -eq 0 ]] && { log_error "no .env.* in $dir"; return 1; }

  local base_dir="$HERE/base"
  # Assemble the SCOPED base file set (mirrors deploy.sh): base/<group>.yml per
  # selected group, plus base/ee.yml when --edition ee (the EE transform adds
  # HUB_API_ENTERPRISE_IMAGE etc.). An unknown group is a hard error.
  local -a base_files=() g
  for g in $groups; do
    [[ -f "$base_dir/${g}.yml" ]] || { log_error "unknown group '$g' (no base/${g}.yml)"; return 1; }
    base_files+=("$base_dir/${g}.yml")
  done
  [[ "$edition" == ee && -f "$base_dir/ee.yml" ]] && base_files+=("$base_dir/ee.yml")

  local provided required missing
  # A var counts as PROVIDED if the bundle carries it OR one of the baseline env
  # sources deploy.sh ALSO sources defines it. deploy.sh sources, in order,
  # registries.env + versions.env BEFORE the bundle's .env.* (see deploy.sh env
  # order), so a full-ref ${X_IMAGE} living there (e.g. CADVISOR_IMAGE — a
  # third-party infra image a product bundle never exports) is resolved at deploy
  # time and must NOT be reported missing. Checking the bundle alone yielded a
  # false "missing CADVISOR_IMAGE" that blocked nothing at deploy but looked fatal.
  local -a baseline_env=("$HERE/registries.env" "$HERE/versions.env")
  provided="$(grep -hoE '^[A-Z0-9_]+_IMAGE' "${bfiles[@]}" "${baseline_env[@]}" 2>/dev/null | sort -u)"
  required="$(grep -rhoE '\$\{[A-Z0-9_]+_IMAGE' "${base_files[@]}" 2>/dev/null | tr -d '${' | sort -u)"
  missing="$(comm -23 <(printf '%s\n' "$required") <(printf '%s\n' "$provided"))"

  echo "▶ checking bundle: $(basename "$dir")  [edition=${edition}, groups: ${groups}]" >&2
  echo "  provided image vars (bundle + versions.env/registries.env): $(printf '%s' "$provided" | grep -c .)   required by scoped base: $(printf '%s' "$required" | grep -c .)" >&2
  if [[ -n "$missing" ]]; then
    log_error "REQUIRED by the scoped base but MISSING from the bundle (would deploy EMPTY image refs):"
    printf '    - %s\n' $missing >&2
    log_warn "if these belong to groups this bundle doesn't cover, narrow --groups/--edition to its scope"
    return 2
  fi
  log_success "all required image vars are present — bundle is deployable for [edition=${edition}, groups: ${groups}]"
}

# ---- interactive selection (menu) → fetch → print key -----------------------
cmd_interactive() {
  local raw; raw="$(fetch_forge_exports_json)" || return 1
  local norm; norm="$(printf '%s' "$raw" | normalize_exports_json)"

  local -a rows=()
  mapfile -t rows < <(printf '%s' "$norm" | jq -r '
    .[]
    | [ (.exportKey // .key // .id // ""),
        ((.projectKey // (.project | if type=="object" then .key else . end) // .key) // ""),
        (.name // .bundleName // .displayName // .label // .projectName // "") ]
    | select(.[0] != "") | @tsv')
  [[ ${#rows[@]} -eq 0 ]] && { log_error "no Forge bundle exports available"; return 1; }

  echo "${_C_YLW}=== Select Forge Project ===${_C_NC}" >&2; echo "" >&2
  local i=1 row ek pk nm
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r ek pk nm <<< "$row"
    [[ -z "$pk" ]] && pk="$ek"; [[ -z "$nm" ]] && nm="$pk"
    printf "  %d) %s (%s)\n" "$i" "$nm" "$pk" >&2; ((i++))
  done
  echo "" >&2
  local choice; read -rp "${_C_BLU}?${_C_NC} Select project [1]: " choice; choice="${choice:-1}"
  [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#rows[@]} ]] || { log_error "invalid project choice"; return 1; }
  IFS=$'\t' read -r ek pk nm <<< "${rows[$((choice-1))]}"

  local -a versions=()
  # -V (version sort) not -C: bundle 1.0.10 must outrank 1.0.9 (lexical would flip it).
  mapfile -t versions < <(printf '%s' "$norm" | jq -r --arg k "$ek" '
    .[] | select((.exportKey // .key // .id // "") == $k)
    | (.versions // .bundleVersions // .availableVersions // [])[]?
    | if type=="string" then . else (.versionNumber // .version // .name // .key // "") end
    | select(. != "")' | sort -Vr)
  [[ ${#versions[@]} -eq 0 ]] && { log_error "no versions for selected project"; return 1; }

  echo "" >&2; echo "${_C_YLW}=== Select Forge Version ===${_C_NC}" >&2; echo "" >&2
  i=1; local v; for v in "${versions[@]}"; do printf "  %d) %s\n" "$i" "$v" >&2; ((i++)); done
  echo "" >&2
  read -rp "${_C_BLU}?${_C_NC} Select version [1]: " choice; choice="${choice:-1}"
  [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#versions[@]} ]] || { log_error "invalid version choice"; return 1; }
  v="${versions[$((choice-1))]}"

  cmd_fetch "$ek" "$v"
}

usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  list)        shift; cmd_list "$@" ;;
  fetch)       shift; cmd_fetch "$@" ;;
  import)      shift; cmd_import "$@" ;;
  check)       shift; cmd_check "$@" ;;
  interactive) shift; cmd_interactive "$@" ;;
  -h|--help|help|"") usage ;;
  *) log_error "unknown command: $1"; usage; exit 1 ;;
esac
