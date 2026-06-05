#!/usr/bin/env bash
# =============================================================================
# deploy.sh — the ONE assembler for the unified deploy tree.
# =============================================================================
# Builds the compose-file list from {edition, runtime, flags}, sources the single
# env sources, then dispatches: `docker compose up` (compose) or render →
# `docker stack deploy` (swarm). Same base/ + overlays for all 4 deploys.
#
#   ./deploy.sh --runtime swarm   --edition ee --env prod   --stack industream-prod
#   ./deploy.sh --runtime compose --edition ce --env dev     --project fm-dev
#
# The CLI thin driver (industream-cli) calls this same logic. Plain Compose-Spec
# → the assembly is also reproducible by hand (BSL / CE no-CLI fallback).
#
# WIP: post-deploy seeders (Logto app/user + launchpad) wired in Phase 4.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # unified/
RUNTIME="" EDITION="ce" ENV="prod" STACK="" PROJECT="" COMMUNITY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)   RUNTIME="$2"; shift 2 ;;
    --edition)   EDITION="$2"; shift 2 ;;
    --env)       ENV="$2"; shift 2 ;;
    --stack)     STACK="$2"; shift 2 ;;
    --project)   PROJECT="$2"; shift 2 ;;
    --community) COMMUNITY=true; shift ;;
    -h|--help)   sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ "$RUNTIME" == swarm || "$RUNTIME" == compose ]] || { echo "✗ --runtime swarm|compose required" >&2; exit 1; }
[[ "$EDITION" == ce || "$EDITION" == ee ]]         || { echo "✗ --edition ce|ee required" >&2; exit 1; }
cd "$HERE"

# ---- ENV: the single sources, in order (later wins) -------------------------
ENV_FILES=(--env-file registries.env --env-file versions.env --env-file auth.env --env-file "runtime.${RUNTIME}.env")
[[ -f ".env.${ENV}" ]] && ENV_FILES+=(--env-file ".env.${ENV}")

# ---- FILES: neutral base + per-runtime overlays -----------------------------
FILES=()
for b in core flowmaker datacatalog workers data monitoring; do
  FILES+=(-f "base/${b}.yml")
  [[ -f "runtime/${RUNTIME}/${b}.yml" ]] && FILES+=(-f "runtime/${RUNTIME}/${b}.yml")
done
# datacatalog increment-1 top-level overlay (until folded into runtime/<r>/)
[[ -f "runtime.${RUNTIME}.yml" ]] && FILES+=(-f "runtime.${RUNTIME}.yml")
# EE transform last (overrides win)
if [[ "$EDITION" == ee ]]; then
  FILES+=(-f "base/ee.yml")
  [[ -f "runtime/${RUNTIME}/ee.yml" ]] && FILES+=(-f "runtime/${RUNTIME}/ee.yml")
fi

echo "▶ ${EDITION^^} / ${RUNTIME} / env=${ENV}"
echo "  files: ${FILES[*]//-f /}"

# ---- Dispatch ---------------------------------------------------------------
if [[ "$RUNTIME" == compose ]]; then
  [[ -n "$PROJECT" ]] || { echo "✗ --project required for compose" >&2; exit 1; }
  exec docker compose -p "$PROJECT" "${ENV_FILES[@]}" "${FILES[@]}" up -d
else
  [[ -n "$STACK" ]] || { echo "✗ --stack required for swarm" >&2; exit 1; }
  # stack deploy can't read --env-file → render an interpolated file via compose
  # config, then deploy it (deploy: keys are preserved by `compose config`).
  RESOLVED="$(mktemp --suffix=.yml)"
  ENV=$ENV docker compose "${ENV_FILES[@]}" "${FILES[@]}" config > "$RESOLVED"
  echo "  resolved → $RESOLVED"
  docker stack deploy --detach=false --with-registry-auth --prune -c "$RESOLVED" "$STACK"
  # TODO(Phase 4): run seeders/ (Logto app+user, launchpad) for --edition ee.
fi
