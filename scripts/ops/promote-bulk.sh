#!/usr/bin/env bash
# =============================================================================
# promote-bulk.sh
#
# One-shot bulk promotion: walks every module in industream-cli/modules.json,
# lists all current tags on the staging Harbor (842775dh…) and copies them to
# their final destination:
#
#   - module.license == "bsl"           → ghcr.io/industream/<path>:<tag>
#   - module.license == "proprietary"   → 39t88114…/<path>:<tag>
#   - module.enterpriseVariant present  → 39t88114…/<enterpriseVariant>:<tag>
#                                          (in addition to the imagePattern
#                                           promotion)
#
# Idempotent: any tag that already has a manifest on the destination is
# skipped. Safe to re-run.
#
# Usage:
#   STAGING_USER=…   STAGING_PASS=… \
#   GHCR_USER=…      GHCR_PASS=…    \
#   ENTERPRISE_USER=… ENTERPRISE_PASS=… \
#   scripts/ops/promote-bulk.sh [flags]
#
# Flags:
#   --dry-run            Print the plan, don't copy anything.
#   --repo <substring>   Only process repos whose path contains <substring>
#                          (e.g. --repo flow-box-timer).
#   --include-dev        Include dev / pre-release tags
#                          (latest, *-dev*, *-alpha*, *-beta*, *-rc*).
#                          Default: skip.
#   --modules-json <p>   Path to modules.json (override).
#   -h, --help           Show help.
#
# Environment:
#   STAGING_REGISTRY     default: 842775dh.c1.gra9.container-registry.ovh.net
#   GHCR_REGISTRY        default: ghcr.io
#   GHCR_NAMESPACE       default: industream
#   ENTERPRISE_REGISTRY  default: 39t88114.c1.gra9.container-registry.ovh.net
#
#   STAGING_USER / STAGING_PASS         required (pull source).
#   GHCR_USER / GHCR_PASS               required when promoting bsl modules.
#                                       GHCR_USER is a bot name; GHCR_PASS is
#                                       a PAT with `write:packages`.
#   ENTERPRISE_USER / ENTERPRISE_PASS   required when promoting proprietary
#                                       modules or enterprise variants.
#
# Exit codes:
#   0  success (including dry-run)
#   1  one or more copies failed
#   2  pre-flight / argument error
# =============================================================================
set -euo pipefail

# --- Colours (suppressed when not a TTY) --------------------------------------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

# --- Config (overridable via env) ---------------------------------------------
STAGING_REGISTRY="${STAGING_REGISTRY:-842775dh.c1.gra9.container-registry.ovh.net}"
GHCR_REGISTRY="${GHCR_REGISTRY:-ghcr.io}"
GHCR_NAMESPACE="${GHCR_NAMESPACE:-industream}"
ENTERPRISE_REGISTRY="${ENTERPRISE_REGISTRY:-39t88114.c1.gra9.container-registry.ovh.net}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEFAULT_MODULES_JSON="${REPO_ROOT}/industream-cli/modules.json"

# --- Args ---------------------------------------------------------------------
DRY_RUN=false
INCLUDE_DEV=false
REPO_FILTER=""
MODULES_JSON="${DEFAULT_MODULES_JSON}"

print_help() {
  sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# --- Pre-flight ---------------------------------------------------------------
command -v crane >/dev/null || {
  echo "${RED}crane not found. Install:" >&2
  echo "  go install github.com/google/go-containerregistry/cmd/crane@latest${NC}" >&2
  exit 2
}
command -v jq >/dev/null || {
  echo "${RED}jq not found. apt-get install jq / brew install jq${NC}" >&2
  exit 2
}

if [[ ! -r "${MODULES_JSON}" ]]; then
  echo "${RED}modules.json not readable at ${MODULES_JSON}${NC}" >&2
  exit 2
fi

if [[ -z "${STAGING_USER:-}" || -z "${STAGING_PASS:-}" ]]; then
  echo "${RED}STAGING_USER and STAGING_PASS must be set${NC}" >&2
  exit 2
fi

# We can't know up-front whether ghcr or enterprise creds are needed (depends
# on what's in modules.json), so just check them lazily before each login.

# --- Tag filter ---------------------------------------------------------------
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

# --- Banner -------------------------------------------------------------------
echo "${BLUE}==================================================${NC}"
echo "${BLUE}  Industream bulk promotion${NC}"
echo "${BLUE}==================================================${NC}"
echo "Source         : ${STAGING_REGISTRY}/<path>"
echo "BSL  -> GHCR   : ${GHCR_REGISTRY}/${GHCR_NAMESPACE}/<path>"
echo "Prop -> Harbor : ${ENTERPRISE_REGISTRY}/<path>"
echo "modules.json   : ${MODULES_JSON}"
echo "Mode           : $([[ ${DRY_RUN} == true ]] && echo 'DRY-RUN' || echo 'LIVE')"
echo "Include dev    : ${INCLUDE_DEV}"
[[ -n "${REPO_FILTER}" ]] && echo "Filter         : ${REPO_FILTER}"
echo ""

# --- Auth (staging always; ghcr / enterprise only when needed) ----------------
echo "${STAGING_PASS}" \
  | crane auth login "${STAGING_REGISTRY}" -u "${STAGING_USER}" --password-stdin >/dev/null
echo "${GREEN}OK${NC}   authenticated to staging Harbor"

GHCR_AUTHED=false
ENT_AUTHED=false

ensure_ghcr_auth() {
  [[ "${GHCR_AUTHED}" == "true" ]] && return 0
  [[ "${DRY_RUN}" == "true" ]] && return 0
  if [[ -z "${GHCR_USER:-}" || -z "${GHCR_PASS:-}" ]]; then
    echo "${RED}GHCR_USER and GHCR_PASS must be set (need to push BSL modules)${NC}" >&2
    exit 2
  fi
  echo "${GHCR_PASS}" \
    | crane auth login "${GHCR_REGISTRY}" -u "${GHCR_USER}" --password-stdin >/dev/null
  echo "${GREEN}OK${NC}   authenticated to GHCR"
  GHCR_AUTHED=true
}

ensure_enterprise_auth() {
  [[ "${ENT_AUTHED}" == "true" ]] && return 0
  [[ "${DRY_RUN}" == "true" ]] && return 0
  if [[ -z "${ENTERPRISE_USER:-}" || -z "${ENTERPRISE_PASS:-}" ]]; then
    echo "${RED}ENTERPRISE_USER and ENTERPRISE_PASS must be set (need to push proprietary modules)${NC}" >&2
    exit 2
  fi
  echo "${ENTERPRISE_PASS}" \
    | crane auth login "${ENTERPRISE_REGISTRY}" -u "${ENTERPRISE_USER}" --password-stdin >/dev/null
  echo "${GREEN}OK${NC}   authenticated to enterprise Harbor"
  ENT_AUTHED=true
}

echo ""

# --- Build the promotion task list -------------------------------------------
# Emits TSV lines:  <src_path>\t<license>\t<destination_kind>\t<dst_path>
#   destination_kind = ghcr | enterprise
#   dst_path matches src_path 1:1 (no rename); kept for symmetry / future-proof.
#
# For dual-variant workers (enterpriseVariant present), we emit two rows: the
# imagePattern row (routed by license) and the enterpriseVariant row (always
# enterprise).
mapfile -t TASKS < <(
  jq -r '
    .modules
    | map(select(.imagePattern? != null and .imagePattern != ""))
    | map(. + {license: (.license // "bsl")})
    | map(
        [
          [
            .imagePattern,
            .license,
            (if .license == "bsl" then "ghcr" else "enterprise" end),
            .imagePattern
          ]
        ] +
        (if (.enterpriseVariant? // "") != "" then
          [[ .enterpriseVariant, "proprietary", "enterprise", .enterpriseVariant ]]
        else [] end)
      )
    | flatten(1)
    | unique_by(.[0] + "::" + .[2])
    | .[]
    | @tsv
  ' "${MODULES_JSON}"
)

if (( ${#TASKS[@]} == 0 )); then
  echo "${YELLOW}No promotable modules in ${MODULES_JSON}${NC}" >&2
  exit 0
fi

# --- Promotion loop -----------------------------------------------------------
TOTAL_REPOS=0
TOTAL_TAGS=0
COPIED=0
SKIPPED=0
FAILED=0
declare -a FAILURES=()

copy_tag() {
  # $1 src_ref, $2 dst_ref, $3 label (path:tag)
  local src="$1" dst="$2" label="$3"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY] COPIED ${label}: ${src} -> ${dst}"
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

for task in "${TASKS[@]}"; do
  IFS=$'\t' read -r src_path license dest_kind dst_path <<< "${task}"
  [[ -z "${src_path}" ]] && continue

  if [[ -n "${REPO_FILTER}" && "${src_path}" != *"${REPO_FILTER}"* ]]; then
    continue
  fi

  TOTAL_REPOS=$((TOTAL_REPOS + 1))

  case "${dest_kind}" in
    ghcr)
      dest_registry="${GHCR_REGISTRY}/${GHCR_NAMESPACE}"
      ensure_ghcr_auth
      ;;
    enterprise)
      dest_registry="${ENTERPRISE_REGISTRY}"
      ensure_enterprise_auth
      ;;
    *)
      echo "${RED}Unknown destination kind '${dest_kind}' for ${src_path}${NC}" >&2
      FAILED=$((FAILED + 1))
      FAILURES+=("${src_path}:* (bad dest kind)")
      continue
      ;;
  esac

  src_repo="${STAGING_REGISTRY}/${src_path}"
  dst_repo="${dest_registry}/${dst_path}"

  echo "${BLUE}>>> ${src_path} (${license}) -> ${dest_kind}${NC}"

  if ! tags=$(crane ls "${src_repo}" 2>/dev/null); then
    echo "  ${YELLOW}SKIP${NC} cannot list tags on source (repo missing?)"
    continue
  fi

  while IFS= read -r tag; do
    [[ -z "${tag}" ]] && continue
    TOTAL_TAGS=$((TOTAL_TAGS + 1))

    if [[ "${INCLUDE_DEV}" != "true" ]] && is_dev_tag "${tag}"; then
      echo "  SKIP ${tag} (dev/pre-release; pass --include-dev to mirror)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    src_ref="${src_repo}:${tag}"
    dst_ref="${dst_repo}:${tag}"

    if manifest_exists "${dst_ref}"; then
      echo "  ${GREEN}OK${NC}   ${tag} already on ${dest_kind}"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    if copy_tag "${src_ref}" "${dst_ref}" "${src_path}:${tag}"; then
      COPIED=$((COPIED + 1))
    else
      FAILED=$((FAILED + 1))
      FAILURES+=("${src_path}:${tag} -> ${dest_kind}")
    fi
  done <<< "${tags}"
done

# --- Summary ------------------------------------------------------------------
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
