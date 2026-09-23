#!/usr/bin/env bash
# =============================================================================
# seed-hub-languages-stack.sh — register the Hub UI languages on a deployment
# =============================================================================
# A fresh Hub knows only the languages that have been POSTed to it. Nothing seeds
# them, so every install shipped English-only until someone called the API by
# hand — which is exactly what happened on the Bernegger demo server (German was
# added manually, French was still missing).
#
# Same mechanism as seed-menu-apps-stack.sh: discover the hub-backend container
# and talk to the INTERNAL free-vend port (3051 — no JWT, container-local only,
# see internalApp in industream-hub-backend-enterprise/server.ts). The public
# POST /languages is admin-only; this path deliberately bypasses it the same way
# the launchpad tiles are seeded.
#
# Usage:
#   ./seed-hub-languages-stack.sh --runtime swarm   --stack industream-prod
#   ./seed-hub-languages-stack.sh --runtime compose --project fm-test-ee-lan
#
# Env overrides:
#   HUB_LANGUAGES         "<locale>:<name>,…"  (default: en:English,de:Deutsch,fr:Français)
#   HUB_BACKEND_SERVICE   default: uifusion-api
#   HUB_INTERNAL_PORT     default: 3051
#
# Idempotent: an already-registered locale answers 409 and is reported as "="
# rather than treated as a failure, so re-running a deploy is a no-op.
#
# NOTE: registering a language only makes it SELECTABLE. The translations
# themselves live in the Hub frontend (packages/industream-menu/i18n) and the
# language selector ships with it — until that lands, the UI stays English no
# matter what is seeded here.
# =============================================================================
set -euo pipefail

RUNTIME="${RUNTIME:-compose}"
SWARM_STACK="${SWARM_STACK:-}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-}"
HUB_BACKEND_SERVICE="${HUB_BACKEND_SERVICE:-uifusion-api}"
HUB_INTERNAL_PORT="${HUB_INTERNAL_PORT:-3051}"
# en first: it is the fallback locale the UI resolves against.
HUB_LANGUAGES="${HUB_LANGUAGES:-en:English,de:Deutsch,fr:Français}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)   RUNTIME="$2"; shift 2 ;;
    --stack)     SWARM_STACK="$2"; shift 2 ;;
    --project)   COMPOSE_PROJECT="$2"; shift 2 ;;
    --languages) HUB_LANGUAGES="$2"; shift 2 ;;
    *) echo "✗ Unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# -----------------------------------------------------------------------------
# Resolve hub-backend container (same discovery as seed-menu-apps-stack.sh).
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

echo "Seeding Hub languages via $HUB:$HUB_INTERNAL_PORT…"

# wget, not curl: the hub image is alpine and does not always ship curl — same
# reasoning as the menu seeder.
seed_one() {
  local locale="$1" name="$2" payload status
  payload=$(printf '{"locale":"%s","name":"%s"}' "$locale" "$name")
  status=$(docker exec -i "$HUB" sh -c \
    "wget --server-response -q -O /dev/null --header='Content-Type: application/json' \
      --post-data='$payload' http://localhost:${HUB_INTERNAL_PORT}/languages 2>&1 \
      | awk '/HTTP\//{print \$2; exit}'") || true
  case "$status" in
    201|200) echo "  + $locale ($name)" ;;
    409)     echo "  = $locale (already registered)" ;;
    *)       echo "  ! $locale failed: HTTP ${status:-no-response}" >&2 ;;
  esac
}

IFS=',' read -ra _entries <<< "$HUB_LANGUAGES"
for entry in "${_entries[@]}"; do
  entry="${entry#"${entry%%[![:space:]]*}"}"   # trim leading spaces
  [ -z "$entry" ] && continue
  locale="${entry%%:*}"
  name="${entry#*:}"
  if [ -z "$locale" ] || [ "$locale" = "$name" ]; then
    echo "  ! skipping malformed entry '$entry' (expected <locale>:<name>)" >&2
    continue
  fi
  seed_one "$locale" "$name"
done
