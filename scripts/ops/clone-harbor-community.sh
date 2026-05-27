#!/usr/bin/env bash
# =============================================================================
# Clone community images from the old Harbor (842775dh...) to the new
# Harbor (39t88114...). Uses `crane` (github.com/google/go-containerregistry)
# to copy registry-to-registry without pulling to the local filesystem,
# preserving digests + multi-arch + signatures.
#
# Usage:
#   SOURCE_USER=... SOURCE_PASS=... \
#   DEST_USER=... DEST_PASS=... \
#   ./scripts/ops/clone-harbor-community.sh [--dry-run] [--repo <pattern>]
#
# Environment:
#   SOURCE_REGISTRY   default: 842775dh.c1.gra9.container-registry.ovh.net
#   SOURCE_PROJECT    default: flowmaker.community
#   DEST_REGISTRY     default: 39t88114.c1.gra9.container-registry.ovh.net
#   DEST_PROJECT      default: community   (must exist on destination Harbor)
#   SOURCE_USER/SOURCE_PASS   required
#   DEST_USER/DEST_PASS       required
#
# Flags:
#   --dry-run            Print what would be copied, don't copy
#   --repo <substring>   Restrict to repos whose path contains <substring>
#                        (e.g. --repo flow-box-timer to copy a single worker)
#   --skip-existing      Skip tags that already exist on destination
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ---------- config ----------
SOURCE_REGISTRY="${SOURCE_REGISTRY:-842775dh.c1.gra9.container-registry.ovh.net}"
SOURCE_PROJECT="${SOURCE_PROJECT:-flowmaker.community}"
DEST_REGISTRY="${DEST_REGISTRY:-39t88114.c1.gra9.container-registry.ovh.net}"
# Destination = empty means mirror the source project structure 1:1 (i.e. each
# source sub-project becomes a top-level Harbor project on the destination).
# To flatten under a single project, set DEST_PROJECT=<name>.
DEST_PROJECT="${DEST_PROJECT:-}"

# BSL 1.1 community repos only — cross-referenced against industream-cli/modules.json
# (license == "bsl"). Premium repos like flow-box-opc-ua-client, flow-box-rtsp-client,
# flow-box-luminosity-box, monitoring/cadvisor, flowmaker.infra/backup-monitor
# are intentionally EXCLUDED.
REPOS=(
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

# ---------- args ----------
DRY_RUN=false
REPO_FILTER=""
SKIP_EXISTING=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=true; shift ;;
    --repo)          REPO_FILTER="$2"; shift 2 ;;
    --skip-existing) SKIP_EXISTING=true; shift ;;
    -h|--help)       sed -n '1,28p' "$0"; exit 0 ;;
    *)               echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ---------- pre-flight ----------
command -v crane >/dev/null || { echo -e "${RED}crane not found. Install from https://github.com/google/go-containerregistry/releases${NC}"; exit 2; }

if [[ -z "${SOURCE_USER:-}" || -z "${SOURCE_PASS:-}" ]]; then
  echo -e "${RED}SOURCE_USER and SOURCE_PASS must be set${NC}" >&2; exit 2
fi
if [[ -z "${DEST_USER:-}" || -z "${DEST_PASS:-}" ]] && [[ "$DRY_RUN" != "true" ]]; then
  echo -e "${RED}DEST_USER and DEST_PASS must be set (or use --dry-run)${NC}" >&2; exit 2
fi

echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Harbor community clone${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo "Source : ${SOURCE_REGISTRY}/${SOURCE_PROJECT}"
echo "Dest   : ${DEST_REGISTRY}/${DEST_PROJECT}"
echo "Mode   : $([[ $DRY_RUN == true ]] && echo 'DRY-RUN' || echo 'LIVE')"
[[ -n "$REPO_FILTER" ]] && echo "Filter : $REPO_FILTER"
echo ""

# ---------- auth ----------
echo "$SOURCE_PASS" | crane auth login "$SOURCE_REGISTRY" -u "$SOURCE_USER" --password-stdin >/dev/null
echo -e "${GREEN}✓ Authenticated to source${NC}"
if [[ "$DRY_RUN" != "true" ]]; then
  echo "$DEST_PASS" | crane auth login "$DEST_REGISTRY" -u "$DEST_USER" --password-stdin >/dev/null
  echo -e "${GREEN}✓ Authenticated to destination${NC}"
fi

# ---------- copy loop ----------
TOTAL_REPOS=0
TOTAL_TAGS=0
COPIED=0
SKIPPED=0
FAILED=0
declare -a FAILURES

for repo in "${REPOS[@]}"; do
  [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]] && continue
  TOTAL_REPOS=$((TOTAL_REPOS + 1))

  src_repo="${SOURCE_REGISTRY}/${SOURCE_PROJECT}/${repo}"
  # If DEST_PROJECT is empty, mirror the structure 1:1 (source sub-project
  # becomes a top-level project on dest). Else flatten under DEST_PROJECT.
  if [[ -z "$DEST_PROJECT" ]]; then
    dst_repo="${DEST_REGISTRY}/${repo}"
  else
    dst_repo="${DEST_REGISTRY}/${DEST_PROJECT}/${repo}"
  fi

  echo -e "${BLUE}▶ ${repo}${NC}"

  # List tags on source
  if ! tags=$(crane ls "$src_repo" 2>/dev/null); then
    echo -e "  ${YELLOW}⚠ Cannot list tags (repo may not exist on source) — skipping${NC}"
    continue
  fi
  tag_count=$(echo "$tags" | wc -l)
  echo "  tags: $tag_count"

  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    TOTAL_TAGS=$((TOTAL_TAGS + 1))

    if [[ "$SKIP_EXISTING" == "true" ]]; then
      if crane manifest "${dst_repo}:${tag}" >/dev/null 2>&1; then
        echo "  ${tag} → already on dest, skip"
        SKIPPED=$((SKIPPED + 1))
        continue
      fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  [DRY] would copy ${tag}"
      COPIED=$((COPIED + 1))
    else
      if crane copy --all-tags=false "${src_repo}:${tag}" "${dst_repo}:${tag}" 2>&1 | sed 's/^/    /'; then
        echo -e "  ${GREEN}✓${NC} ${tag}"
        COPIED=$((COPIED + 1))
      else
        echo -e "  ${RED}✗${NC} ${tag} — copy failed"
        FAILED=$((FAILED + 1))
        FAILURES+=("${repo}:${tag}")
      fi
    fi
  done <<< "$tags"
done

# ---------- summary ----------
echo ""
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Summary${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo "Repos processed : $TOTAL_REPOS"
echo "Tags total      : $TOTAL_TAGS"
echo -e "${GREEN}Copied${NC}          : $COPIED"
echo -e "${YELLOW}Skipped${NC}         : $SKIPPED"
echo -e "${RED}Failed${NC}          : $FAILED"
if (( FAILED > 0 )); then
  echo ""
  echo "Failures:"
  printf '  %s\n' "${FAILURES[@]}"
  exit 1
fi
