#!/usr/bin/env bash
# =============================================================================
# sync-community-mirror.sh
#
# Synchronise BSL 1.1 community images from the legacy premium Harbor to:
#   1. The legacy premium Harbor's `flowmaker.community/*` sub-project
#      (kept until the new Harbor is fully cut over — historical mirror).
#   2. The new community Harbor (`39t88114.c1.gra9.container-registry.ovh.net`),
#      structure flattened 1:1 (no `flowmaker.community/` prefix).
#
# Source of truth for the BSL repo list:
#   `industream-cli/modules.json`  (field: `license == "bsl"`)
# A baked-in fallback is used when modules.json is absent (e.g. the cli
# sub-repo is not checked out in CI).
#
# The script is idempotent: tags already present on BOTH destinations are
# skipped. It can be re-run any number of times safely.
#
# Usage:
#   PREMIUM_USER=...  PREMIUM_PASS=... \
#   COMMUNITY_USER=... COMMUNITY_PASS=... \
#   scripts/ops/sync-community-mirror.sh [flags]
#
# Flags:
#   --dry-run            Print what would be copied, don't copy.
#   --include-dev        Include dev / pre-release tags
#                          (latest, *-dev, *-alpha*, *-beta*, *-rc*).
#                          Default: skip them.
#   --repo <substring>   Restrict to repos whose path contains <substring>
#                          (e.g. --repo flow-box-timer).
#   --modules-json <p>   Path to industream-cli/modules.json (override).
#   -h, --help           Show this help and exit.
#
# Environment:
#   PREMIUM_REGISTRY     default: 842775dh.c1.gra9.container-registry.ovh.net
#   PREMIUM_LEGACY_PROJECT
#                        default: flowmaker.community
#                          (sub-project on premium Harbor used as legacy
#                           mirror destination)
#   COMMUNITY_REGISTRY   default: 39t88114.c1.gra9.container-registry.ovh.net
#
#   PREMIUM_USER / PREMIUM_PASS     required (source pull + legacy-mirror push)
#   COMMUNITY_USER / COMMUNITY_PASS required (new Harbor push)
#
# Exit codes:
#   0  success (including dry-run)
#   1  one or more copies failed
#   2  pre-flight / argument error
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------
# Colours (suppressed when stdout is not a terminal — keeps CI logs clean).
# --------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

# --------------------------------------------------------------------------
# Config (overridable via env).
# --------------------------------------------------------------------------
PREMIUM_REGISTRY="${PREMIUM_REGISTRY:-842775dh.c1.gra9.container-registry.ovh.net}"
PREMIUM_LEGACY_PROJECT="${PREMIUM_LEGACY_PROJECT:-flowmaker.community}"
COMMUNITY_REGISTRY="${COMMUNITY_REGISTRY:-39t88114.c1.gra9.container-registry.ovh.net}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEFAULT_MODULES_JSON="${REPO_ROOT}/industream-cli/modules.json"

# --------------------------------------------------------------------------
# Fallback BSL repo list (used when modules.json is absent).
# Mirrors the curated list from scripts/ops/clone-harbor-community.sh.
# Each entry is `<project>/<image>` on the source Harbor.
# --------------------------------------------------------------------------
FALLBACK_REPOS=(
  datacatalog/api
  datacatalog/ui
  flowmaker.boxes/flow-box-conditional-dataset-validator
  flowmaker.boxes/flow-box-data-logger
  flowmaker.boxes/flow-box-datacatalog-mapper
  flowmaker.boxes/flow-box-enqueue
  flowmaker.boxes/flow-box-equation-solver
  flowmaker.boxes/flow-box-http
  flowmaker.boxes/flow-box-influx-client
  flowmaker.boxes/flow-box-js-expression
  flowmaker.boxes/flow-box-minio-sink
  flowmaker.boxes/flow-box-modbus-tcp
  flowmaker.boxes/flow-box-mqtt-client
  flowmaker.boxes/flow-box-notification
  flowmaker.boxes/flow-box-postgres-client
  flowmaker.boxes/flow-box-test-data-generator
  flowmaker.boxes/flow-box-timer
  flowmaker.boxes/flow-box-timeseries-workers
  flowmaker.core/cdn-cache
  flowmaker.core/cdn-server
  flowmaker.core/flowmaker-confighub-v2
  flowmaker.core/flowmaker-front
  flowmaker.core/flowmaker-launcher
  flowmaker.core/flowmaker-logger
  flowmaker.infra/flowmaker-worker-manager
  timeseries/api
  uifusion/api
  uifusion/ui
)

# --------------------------------------------------------------------------
# Arg parsing.
# --------------------------------------------------------------------------
DRY_RUN=false
INCLUDE_DEV=false
REPO_FILTER=""
MODULES_JSON="${DEFAULT_MODULES_JSON}"

print_help() {
  # Lines 1..50 contain the comment-block help.
  sed -n '2,55p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=true; shift ;;
    --include-dev)   INCLUDE_DEV=true; shift ;;
    --repo)          REPO_FILTER="${2:-}"; shift 2 ;;
    --modules-json)  MODULES_JSON="${2:-}"; shift 2 ;;
    -h|--help)       print_help; exit 0 ;;
    *)               echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --------------------------------------------------------------------------
# Pre-flight checks.
# --------------------------------------------------------------------------
command -v crane >/dev/null || {
  echo "${RED}crane not found. Install via:" >&2
  echo "  go install github.com/google/go-containerregistry/cmd/crane@latest" >&2
  echo "  (or download a release: https://github.com/google/go-containerregistry/releases)${NC}" >&2
  exit 2
}

if [[ -z "${PREMIUM_USER:-}" || -z "${PREMIUM_PASS:-}" ]]; then
  echo "${RED}PREMIUM_USER and PREMIUM_PASS must be set${NC}" >&2
  exit 2
fi
if [[ "${DRY_RUN}" != "true" ]]; then
  if [[ -z "${COMMUNITY_USER:-}" || -z "${COMMUNITY_PASS:-}" ]]; then
    echo "${RED}COMMUNITY_USER and COMMUNITY_PASS must be set (or use --dry-run)${NC}" >&2
    exit 2
  fi
fi

# --------------------------------------------------------------------------
# Resolve the BSL repo list.
#
# Strategy:
#   - If modules.json exists AND jq is installed, parse it. Each module is
#     expected to expose `license` ("bsl"|"proprietary") and an `image` (or
#     fall back to its name) that maps to `<project>/<image>` on Harbor.
#   - Otherwise, use the baked-in FALLBACK_REPOS list.
# --------------------------------------------------------------------------
declare -a REPOS=()

load_repos_from_modules_json() {
  local path="$1"
  if ! command -v jq >/dev/null; then
    echo "${YELLOW}⚠ jq not installed — using fallback repo list${NC}" >&2
    return 1
  fi
  if [[ ! -r "${path}" ]]; then
    return 1
  fi
  # Expected schema (forward-compatible):
  #   { "modules": [
  #       { "license": "bsl", "harbor_path": "datacatalog/api", ... },
  #       { "license": "proprietary", ... }
  #   ] }
  # We tolerate either `harbor_path` (preferred) or `<project>/<image>`
  # derived from `project` + `image`. Lines emitted are repo paths.
  local out
  if ! out=$(jq -r '
      (.modules // [])
      | map(select(.license == "bsl"))
      | map(
          .harbor_path
          // ((.project // "") + "/" + (.image // .name // ""))
        )
      | map(select(. != "" and . != "/"))
      | unique
      | .[]
    ' "${path}" 2>/dev/null); then
    echo "${YELLOW}⚠ Failed to parse ${path} — using fallback${NC}" >&2
    return 1
  fi
  if [[ -z "${out}" ]]; then
    echo "${YELLOW}⚠ modules.json contained 0 BSL modules — using fallback${NC}" >&2
    return 1
  fi
  while IFS= read -r line; do
    [[ -n "${line}" ]] && REPOS+=("${line}")
  done <<< "${out}"
  return 0
}

if load_repos_from_modules_json "${MODULES_JSON}"; then
  REPOS_SOURCE="modules.json (${MODULES_JSON})"
else
  REPOS=("${FALLBACK_REPOS[@]}")
  REPOS_SOURCE="baked-in fallback list"
fi

# --------------------------------------------------------------------------
# Tag filter.
# --------------------------------------------------------------------------
is_dev_tag() {
  local tag="$1"
  case "${tag}" in
    latest)              return 0 ;;
    *-dev|*-dev.*)       return 0 ;;
    *-alpha*|*-beta*)    return 0 ;;
    *-rc*|*-rc.*)        return 0 ;;
    *) return 1 ;;
  esac
}

# --------------------------------------------------------------------------
# Banner.
# --------------------------------------------------------------------------
echo "${BLUE}==================================================${NC}"
echo "${BLUE}  Industream community-image sync${NC}"
echo "${BLUE}==================================================${NC}"
echo "Source         : ${PREMIUM_REGISTRY}/<project>/<image>"
echo "Legacy mirror  : ${PREMIUM_REGISTRY}/${PREMIUM_LEGACY_PROJECT}/<project>/<image>"
echo "New community  : ${COMMUNITY_REGISTRY}/<project>/<image>"
echo "Repo list      : ${REPOS_SOURCE} (${#REPOS[@]} repos)"
echo "Mode           : $([[ ${DRY_RUN} == true ]] && echo 'DRY-RUN' || echo 'LIVE')"
echo "Include dev    : ${INCLUDE_DEV}"
[[ -n "${REPO_FILTER}" ]] && echo "Filter         : ${REPO_FILTER}"
echo ""

# --------------------------------------------------------------------------
# Auth.
# --------------------------------------------------------------------------
echo "${PREMIUM_PASS}" \
  | crane auth login "${PREMIUM_REGISTRY}" -u "${PREMIUM_USER}" --password-stdin >/dev/null
echo "${GREEN}OK${NC}   authenticated to premium Harbor"

if [[ "${DRY_RUN}" != "true" ]]; then
  echo "${COMMUNITY_PASS}" \
    | crane auth login "${COMMUNITY_REGISTRY}" -u "${COMMUNITY_USER}" --password-stdin >/dev/null
  echo "${GREEN}OK${NC}   authenticated to community Harbor"
fi
echo ""

# --------------------------------------------------------------------------
# Sync loop.
# --------------------------------------------------------------------------
TOTAL_REPOS=0
TOTAL_TAGS=0
COPIED=0
SKIPPED=0
FAILED=0
declare -a FAILURES=()

copy_tag() {
  # $1 = src_ref, $2 = dst_ref, $3 = human-readable label
  local src="$1" dst="$2" label="$3"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY] would copy ${label}: ${src} -> ${dst}"
    return 0
  fi
  if crane copy --all-tags=false "${src}" "${dst}" >/dev/null 2>&1; then
    echo "    ${GREEN}COPIED${NC} ${label}"
    return 0
  fi
  echo "    ${RED}FAILED${NC} ${label}"
  return 1
}

manifest_exists() {
  crane manifest "$1" >/dev/null 2>&1
}

for repo in "${REPOS[@]}"; do
  if [[ -n "${REPO_FILTER}" && "${repo}" != *"${REPO_FILTER}"* ]]; then
    continue
  fi
  TOTAL_REPOS=$((TOTAL_REPOS + 1))

  src_repo="${PREMIUM_REGISTRY}/${repo}"
  legacy_repo="${PREMIUM_REGISTRY}/${PREMIUM_LEGACY_PROJECT}/${repo}"
  community_repo="${COMMUNITY_REGISTRY}/${repo}"

  echo "${BLUE}>>> ${repo}${NC}"

  if ! tags=$(crane ls "${src_repo}" 2>/dev/null); then
    echo "  ${YELLOW}SKIP${NC} cannot list tags on source (repo missing?)"
    continue
  fi

  while IFS= read -r tag; do
    [[ -z "${tag}" ]] && continue
    TOTAL_TAGS=$((TOTAL_TAGS + 1))

    if [[ "${INCLUDE_DEV}" != "true" ]] && is_dev_tag "${tag}"; then
      echo "  SKIP ${tag} (dev/pre-release, use --include-dev to mirror)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    src_ref="${src_repo}:${tag}"
    legacy_ref="${legacy_repo}:${tag}"
    community_ref="${community_repo}:${tag}"

    legacy_present=false
    community_present=false
    if manifest_exists "${legacy_ref}";    then legacy_present=true;    fi
    if manifest_exists "${community_ref}"; then community_present=true; fi

    if [[ "${legacy_present}" == "true" && "${community_present}" == "true" ]]; then
      echo "  OK   ${tag} already on both targets"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    echo "  >>> ${tag}"
    tag_failed=false

    if [[ "${legacy_present}" != "true" ]]; then
      if ! copy_tag "${src_ref}" "${legacy_ref}" "legacy-mirror"; then
        tag_failed=true
      fi
    else
      echo "    OK     legacy-mirror already has ${tag}"
    fi

    if [[ "${community_present}" != "true" ]]; then
      if ! copy_tag "${src_ref}" "${community_ref}" "community-new"; then
        tag_failed=true
      fi
    else
      echo "    OK     community-new already has ${tag}"
    fi

    if [[ "${tag_failed}" == "true" ]]; then
      FAILED=$((FAILED + 1))
      FAILURES+=("${repo}:${tag}")
    else
      COPIED=$((COPIED + 1))
    fi
  done <<< "${tags}"
done

# --------------------------------------------------------------------------
# Summary.
# --------------------------------------------------------------------------
echo ""
echo "${BLUE}==================================================${NC}"
echo "${BLUE}  Summary${NC}"
echo "${BLUE}==================================================${NC}"
echo "Repos processed : ${TOTAL_REPOS}"
echo "Tags seen       : ${TOTAL_TAGS}"
echo "${GREEN}Copied${NC}          : ${COPIED}"
echo "${YELLOW}Skipped${NC}         : ${SKIPPED}"
echo "${RED}Failed${NC}          : ${FAILED}"

if (( FAILED > 0 )); then
  echo ""
  echo "Failures:"
  printf '  %s\n' "${FAILURES[@]}"
  exit 1
fi
exit 0
