#!/usr/bin/env bash
# =============================================================================
# seed-menu-apps-stack.sh — seed the Hub menu apps for a running deployment
# =============================================================================
# Companion to seed-menu-apps.sh (which targets a hardcoded localhost dev
# HUB_BACKEND_URL). This one:
#   - discovers the running hub-backend container in a stack (swarm or compose)
#   - posts via the INTERNAL free-vend port (3051 — no JWT required, container-
#     local only, see internalApp in industream-hub-backend-enterprise/server.ts)
#   - constructs every URL as https://<subdomain>.<DOMAIN>/ — DOMAIN is a single
#     CLI flag, subdomain is per-app and fixed in the APPS table below
#
# Adding a new app = add one line to APPS. Removing = delete the line + DELETE
# /apps/<id> manually if you want to clean it from LMDB.
#
# Usage:
#   ./seed-menu-apps-stack.sh --domain industream.platform.lan \
#                              --runtime swarm --stack industream-prod
#   ./seed-menu-apps-stack.sh --domain test.flowmaker.lan \
#                              --runtime compose --project fm-test-ee-lan
#
# Env override: HUB_BACKEND_SERVICE (default: uifusion-api), HUB_INTERNAL_PORT
# (default: 3051).
# =============================================================================
set -euo pipefail

DOMAIN=""
RUNTIME="${RUNTIME:-compose}"
SWARM_STACK="${SWARM_STACK:-}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-}"
HUB_BACKEND_SERVICE="${HUB_BACKEND_SERVICE:-uifusion-api}"
HUB_INTERNAL_PORT="${HUB_INTERNAL_PORT:-3051}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)  DOMAIN="$2"; shift 2 ;;
    --runtime) RUNTIME="$2"; shift 2 ;;
    --stack)   SWARM_STACK="$2"; shift 2 ;;
    --project) COMPOSE_PROJECT="$2"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[ -z "$DOMAIN" ] && { echo "✗ --domain required (e.g. industream.platform.lan)" >&2; exit 1; }

# -----------------------------------------------------------------------------
# App catalog. One line per menu entry. Fields (pipe-separated):
#   id | name | desc | iconLetter | iconColor | gradient1 | gradient2 | subdomain | path
#
# Final URL = https://<subdomain>.${DOMAIN}<path>
# (path includes the leading "/" — typically "/" for UIs, "/swagger" or
#  "/openapi" for REST APIs to land on their Swagger UI)
#
# Add/remove entries here to evolve the menu. End-user / launcher entries
# only — internal services (confighub, logger, scheduler) live in the stack
# but are NOT user-facing, keep them out.
# -----------------------------------------------------------------------------
APPS=(
  "flowmaker|FlowMaker|Design & monitor flows|FM|#0ea5e9|#0ea5e9|#06b6d4|flowmaker|/"
  "datacatalog|DataCatalog|Browse data assets|DC|#8b5cf6|#8b5cf6|#a78bfa|datacatalog-ui|/"
  "datacatalog-api|DataCatalog API|Catalog REST API|DA|#a855f7|#a855f7|#c084fc|datacatalog-api|/openapi"
  "grafana|Grafana|Visual dashboards|GR|#f46800|#f46800|#ff8c00|dashboard|/"
  "databridge|DataBridge|Time-series API|DB|#10b981|#10b981|#34d399|databridge|/swagger"
)

# -----------------------------------------------------------------------------
# Resolve hub-backend container.
# -----------------------------------------------------------------------------
case "$RUNTIME" in
  swarm)
    [ -z "$SWARM_STACK" ] && { echo "✗ --runtime swarm requires --stack <name>" >&2; exit 1; }
    HUB=$(docker ps \
      --filter "label=com.docker.swarm.service.name=${SWARM_STACK}_${HUB_BACKEND_SERVICE}" \
      --format '{{.ID}}' | head -1)
    ;;
  compose)
    [ -z "$COMPOSE_PROJECT" ] && { echo "✗ --runtime compose requires --project <name>" >&2; exit 1; }
    HUB=$(docker ps \
      --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
      --filter "label=com.docker.compose.service=${HUB_BACKEND_SERVICE}" \
      --format '{{.ID}}' | head -1)
    ;;
  *) echo "✗ Unknown --runtime '$RUNTIME' (expected: compose|swarm)" >&2; exit 1 ;;
esac

if [ -z "$HUB" ]; then
  echo "✗ No running '$HUB_BACKEND_SERVICE' container found" >&2
  exit 1
fi

echo "Seeding Hub menu apps via $HUB:$HUB_INTERNAL_PORT (domain=$DOMAIN)…"
echo ""

# -----------------------------------------------------------------------------
# Build payload then POST (201) / PUT (200) for upsert semantics. Uses wget
# inside the container — alpine ships it, curl is not always present.
# -----------------------------------------------------------------------------
upsert() {
  local id="$1" payload="$2"
  local post_status put_status
  post_status=$(docker exec -i "$HUB" sh -c "wget --server-response -q -O /dev/null --header='Content-Type: application/json' --post-data='$payload' http://localhost:${HUB_INTERNAL_PORT}/apps 2>&1 | awk '/HTTP\\//{print \$2; exit}'")
  if [ "$post_status" = "201" ]; then
    echo "  + $id (created)"
    return
  fi
  if [ "$post_status" = "409" ]; then
    put_status=$(docker exec -i "$HUB" sh -c "wget --server-response -q -O /dev/null --method=PUT --header='Content-Type: application/json' --body-data='$payload' http://localhost:${HUB_INTERNAL_PORT}/apps/$id 2>&1 | awk '/HTTP\\//{print \$2; exit}'")
    if [ "$put_status" = "200" ]; then
      echo "  ~ $id (updated)"
      return
    fi
    echo "  ! $id: POST=409, PUT=$put_status" >&2
    return
  fi
  echo "  ! $id failed: POST=$post_status" >&2
}

ADDED=0
UPDATED=0
for entry in "${APPS[@]}"; do
  IFS='|' read -r id name desc iconLetter iconColor g1 g2 subdomain path <<< "$entry"
  [ -z "$path" ] && path="/"
  url="https://${subdomain}.${DOMAIN}${path}"
  # Build JSON inline (no jq needed in the container — host has the data).
  payload=$(printf '{"id":"%s","name":"%s","desc":"%s","icon":"%s","iconLetter":"%s","iconColor":"%s","gradient":["%s","%s"],"status":"online","urls":[{"frontend":"%s"}]}' \
    "$id" "$name" "$desc" "$iconLetter" "$iconLetter" "$iconColor" "$g1" "$g2" "$url")
  upsert "$id" "$payload"
done

echo ""
echo "✓ Done. Menu apps live at https://${DOMAIN}/ (refresh the Hub UI to see them)."
