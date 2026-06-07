#!/usr/bin/env bash
# =============================================================================
# deploy.sh — the ONE assembler for the unified deploy tree.
# =============================================================================
# Builds the compose-file list from {edition, runtime, flags}, sources the single
# env sources, then dispatches: `docker compose up` (compose) or render →
# `docker stack deploy` (swarm). Same base/ + overlays for all 4 deploys.
#
#   ./deploy.sh --runtime swarm   --edition ee --env prod --bundle 1.0.1 --stack industream-prod
#   ./deploy.sh --runtime compose --edition ce --env dev  --bundle 1.0.1 --project fm-dev
#
# --bundle <ver> picks releases/bundle-platform-<ver>/ (the full-ref ${X_IMAGE}
# vars). Omit it when exactly one bundle exists (auto-selected).
#
# The CLI thin driver (industream-cli) calls this same logic. Plain Compose-Spec
# → the assembly is also reproducible by hand (BSL / CE no-CLI fallback).
#
# WIP: post-deploy seeders (Logto app/user + launchpad) wired in Phase 4.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # unified/
RUNTIME="" EDITION="ce" ENV="prod" STACK="" PROJECT="" COMMUNITY=false RENDER=false BUNDLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)   RUNTIME="$2"; shift 2 ;;
    --edition)   EDITION="$2"; shift 2 ;;
    --env)       ENV="$2"; shift 2 ;;
    --stack)     STACK="$2"; shift 2 ;;
    --project)   PROJECT="$2"; shift 2 ;;
    --community) COMMUNITY=true; shift ;;
    --bundle)    BUNDLE="$2"; shift 2 ;;
    --render)    RENDER=true; shift ;;
    -h|--help)   sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ "$RUNTIME" == swarm || "$RUNTIME" == compose ]] || { echo "✗ --runtime swarm|compose required" >&2; exit 1; }
[[ "$EDITION" == ce || "$EDITION" == ee ]]         || { echo "✗ --edition ce|ee required" >&2; exit 1; }
cd "$HERE"

# ---- BUNDLE: resolve the release bundle holding the full-ref ${X_IMAGE} vars -
# base/*.yml reference ${HUB_API_IMAGE}, ${WORKER_*_IMAGE}, … which live ONLY in
# a release bundle (scripts/render-bundles.sh renders them license-aware from
# versions.env + registries.env). --bundle <ver> selects one; with exactly one
# bundle present it auto-selects; otherwise --bundle is required.
if [[ -n "$BUNDLE" ]]; then
  BUNDLE_DIR="releases/bundle-platform-${BUNDLE}"
  [[ -d "$BUNDLE_DIR" ]] || { echo "✗ no bundle at ${BUNDLE_DIR} — run: scripts/render-bundles.sh ${BUNDLE}" >&2; exit 1; }
else
  mapfile -t _bundles < <(ls -d releases/bundle-platform-*/ 2>/dev/null)
  case ${#_bundles[@]} in
    1) BUNDLE_DIR="${_bundles[0]%/}" ;;
    0) echo "✗ no release bundle in releases/ — run: scripts/render-bundles.sh <version>" >&2; exit 1 ;;
    *) echo "✗ multiple bundles in releases/ — pass --bundle <version>" >&2; exit 1 ;;
  esac
fi

# ---- ENV: the single sources, in order (later wins) -------------------------
ENV_FILES=(--env-file registries.env --env-file versions.env --env-file auth.env --env-file "runtime.${RUNTIME}.env")
for bf in "$BUNDLE_DIR"/.env.*; do ENV_FILES+=(--env-file "$bf"); done
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

echo "▶ ${EDITION^^} / ${RUNTIME} / env=${ENV} / bundle=${BUNDLE_DIR##*/}"
echo "  files: ${FILES[*]//-f /}"

# ---- Render-only gate (validate the assembled config, deploy nothing) -------
if [[ "$RENDER" == true ]]; then
  if [[ "$RUNTIME" == compose ]]; then
    ENV=$ENV docker compose "${ENV_FILES[@]}" "${FILES[@]}" config
    exit $?
  fi
  # `docker compose config` can't render swarm overlays that use ${ENV} in
  # network-map KEYS (e.g. ${ENV}-platform) — those only interpolate at
  # `stack deploy` time. Validate each file is well-formed YAML instead.
  for f in "${FILES[@]}"; do [[ "$f" == -f ]] && continue
    python3 -c "import yaml; yaml.safe_load(open('$f'))" || { echo "✗ invalid YAML: $f" >&2; exit 1; }
  done
  echo "✓ ${#FILES[@]} swarm file refs are valid YAML (full validation = a live 'stack deploy')"
  exit 0
fi

# ---- Dispatch ---------------------------------------------------------------
if [[ "$RUNTIME" == compose ]]; then
  [[ -n "$PROJECT" ]] || { echo "✗ --project required for compose" >&2; exit 1; }
  exec docker compose -p "$PROJECT" "${ENV_FILES[@]}" "${FILES[@]}" up -d
else
  [[ -n "$STACK" ]] || { echo "✗ --stack required for swarm" >&2; exit 1; }
  # `docker stack deploy` interpolates ${VAR} from the PROCESS env (not
  # --env-file), and unlike `compose config` it handles ${ENV}-* network/secret
  # keys. Source the single env sources into the env, then deploy with -c.
  set -a; export ENV
  source registries.env; source versions.env; source auth.env; source "runtime.${RUNTIME}.env"
  for bf in "$BUNDLE_DIR"/.env.*; do source "$bf"; done
  [[ -f ".env.${ENV}" ]] && source ".env.${ENV}"
  set +a
  C_FILES=(); for f in "${FILES[@]}"; do [[ "$f" == -f ]] && C_FILES+=(-c) || C_FILES+=("$f"); done
  docker stack deploy --detach=false --with-registry-auth --prune "${C_FILES[@]}" "$STACK"
  # TODO(Phase 4): run seeders/ (Logto app+user, launchpad) for --edition ee.
fi
