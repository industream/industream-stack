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
#
# --groups "<list>" (space- or comma-separated) restricts which gated tiles are
# seeded: a tile whose "gate" field is non-empty is only seeded when its gate is
# present in the list. Ungated tiles (empty gate) are always seeded. When
# --groups is omitted, everything is seeded (backward compatible).
# =============================================================================
set -euo pipefail

DOMAIN=""
RUNTIME="${RUNTIME:-compose}"
SWARM_STACK="${SWARM_STACK:-}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-}"
HUB_BACKEND_SERVICE="${HUB_BACKEND_SERVICE:-uifusion-api}"
HUB_INTERNAL_PORT="${HUB_INTERNAL_PORT:-3051}"
# NOTE: do NOT name this var GROUPS — bash treats $GROUPS as a special read-only
# array (the caller's supplementary group IDs), so a scalar assignment is lost.
GROUPS_ARG=""      # raw --groups value; empty = seed everything (no gate filter)
GROUPS_FILTER=0    # 1 once --groups is provided (even if empty list)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)  DOMAIN="$2"; shift 2 ;;
    --runtime) RUNTIME="$2"; shift 2 ;;
    --stack)   SWARM_STACK="$2"; shift 2 ;;
    --project) COMPOSE_PROJECT="$2"; shift 2 ;;
    --groups)  GROUPS_ARG="$2"; GROUPS_FILTER=1; shift 2 ;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Normalise the groups list: accept space- or comma-separated, collapse to a
# single space-delimited string padded with spaces for safe substring matching.
GROUPS_NORM=" $(printf '%s' "$GROUPS_ARG" | tr ',' ' ' | tr -s ' ') "

[ -z "$DOMAIN" ] && { echo "✗ --domain required (e.g. industream.platform.lan)" >&2; exit 1; }

# -----------------------------------------------------------------------------
# App catalog. One line per menu entry. Fields (pipe-separated):
#   id | name | desc | iconLetter | iconColor | gradient1 | gradient2 | subdomain | path | allowedRoles | gate
#
# The last TWO fields are OPTIONAL (existing 9-field lines leave them empty):
#   allowedRoles — comma-separated role list (e.g. "admin"). Empty = visible to
#                  all roles. The Hub backend filters /apps server-side: admins
#                  see every tile; non-admins only see tiles with no allowedRoles
#                  or whose allowedRoles intersect their own roles.
#   gate         — the deploy group that must be present for the tile to be
#                  seeded (matched against --groups). Empty = always seeded.
#
# Final URL = https://<subdomain>.${DOMAIN}<path>
# (path includes the leading "/" — typically "/" for UIs, "/swagger" or
#  "/openapi" for REST APIs to land on their Swagger UI)
#
# Add/remove entries here to evolve the menu. The first block is end-user /
# launcher entries (visible to everyone). The second block is ops/admin tiles
# (allowedRoles=admin) — internal services (Portainer, ConfigHub, Prometheus,
# Alertmanager, MinIO, InfluxDB) that admins get in their launchpad but regular
# users never see.
# -----------------------------------------------------------------------------
APPS=(
  # User-facing tiles — no roles, no gate (visible to everyone, always seeded).
  "flowmaker|FlowMaker|Design & monitor flows|FM|#0ea5e9|#0ea5e9|#06b6d4|flowmaker|/"
  "datacatalog|DataCatalog|Browse data assets|DC|#8b5cf6|#8b5cf6|#a78bfa|datacatalog-ui|/"
  "datacatalog-api|DataCatalog API|Catalog REST API|DA|#a855f7|#a855f7|#c084fc|datacatalog-api|/openapi"
  "grafana|Grafana|Visual dashboards|GR|#f46800|#f46800|#ff8c00|dashboard|/"
  "databridge|DataBridge|Time-series API|DB|#10b981|#10b981|#34d399|databridge|/swagger"

  # IronStream domain apps — user-facing, gated on the `ironstream` group.
  "material-catalog|Material Catalog|Manage materials & i18n|MC|#0d9488|#0d9488|#14b8a6|materialcatalog-ui|/||ironstream"
  "recipe-maker|Recipe Maker|Design & edit recipes|RM|#db2777|#db2777|#ec4899|recipemaker-ui|/||ironstream"
  "burden-descent|Burden Descent|Descent modeling|BD|#7c3aed|#7c3aed|#8b5cf6|burdendescent-ui|/||ironstream"
  "raceway|Raceway|Raceway monitoring|RW|#ea580c|#ea580c|#f97316|raceway-ui|/||ironstream"
  "filebrowser|Filebrowser|Browse & edit config files|FB|#475569|#475569|#64748b|filebrowser|/||ironstream"

  # Admin-only ops tiles — allowedRoles=admin, gated on their deploy group.
  "portainer|Portainer|Container & stack ops|PT|#13bef9|#13bef9|#0ea5e9|portainer|/|admin|portainer"
  "confighub|ConfigHub|Platform configuration|CH|#6366f1|#6366f1|#818cf8|confighub|/|admin|flowmaker"
  "prometheus|Prometheus|Metrics & queries|PR|#e6522c|#e6522c|#ff7043|prometheus|/|admin|monitoring"
  "alertmanager|Alertmanager|Alert routing|AM|#f59e0b|#f59e0b|#fbbf24|alertmanager|/|admin|monitoring"
  "minio|MinIO|Object storage console|MN|#c72e49|#c72e49|#ef4444|minio|/|admin|core"
  "influxdb|InfluxDB|Time-series store|IX|#22adf6|#22adf6|#7dd3fc|influxdb|/|admin|data"
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

for entry in "${APPS[@]}"; do
  # 11 fields; existing 9-field lines leave allowedRoles + gate empty.
  IFS='|' read -r id name desc iconLetter iconColor g1 g2 subdomain path allowedRoles gate <<< "$entry"
  [ -z "$path" ] && path="/"

  # Gate filter: skip a gated tile when --groups is provided and its gate is
  # absent from the list. Ungated tiles always pass.
  if [ "$GROUPS_FILTER" -eq 1 ] && [ -n "$gate" ] && [[ "$GROUPS_NORM" != *" $gate "* ]]; then
    echo "  - $id (skipped: gate '$gate' not in --groups)"
    continue
  fi

  url="https://${subdomain}.${DOMAIN}${path}"

  # Build the optional allowedRoles JSON fragment only when non-empty. The
  # backend createBody is .strict() and allowedRoles is optional, so we must
  # NOT emit an empty array or any unknown key.
  roles_json=""
  if [ -n "$allowedRoles" ]; then
    local_roles=""
    IFS=',' read -ra _roles <<< "$allowedRoles"
    for r in "${_roles[@]}"; do
      [ -z "$r" ] && continue
      [ -n "$local_roles" ] && local_roles="${local_roles},"
      local_roles="${local_roles}\"${r}\""
    done
    [ -n "$local_roles" ] && roles_json=",\"allowedRoles\":[${local_roles}]"
  fi

  # Build JSON inline (no jq needed in the container — host has the data).
  payload=$(printf '{"id":"%s","name":"%s","desc":"%s","icon":"%s","iconLetter":"%s","iconColor":"%s","gradient":["%s","%s"],"status":"online","urls":[{"frontend":"%s"}]%s}' \
    "$id" "$name" "$desc" "$iconLetter" "$iconLetter" "$iconColor" "$g1" "$g2" "$url" "$roles_json")
  upsert "$id" "$payload"
done

echo ""
echo "✓ Done. Menu apps live at https://${DOMAIN}/ (refresh the Hub UI to see them)."
