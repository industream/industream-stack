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
# GROUP_SET = the base/<group>.yml set to assemble. Default = full platform; an
# instance footprint narrows it (e.g. a core-only or a workers-only instance, T3).
GROUP_SET="core flowmaker datacatalog workers data monitoring"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)   RUNTIME="$2"; shift 2 ;;
    --edition)   EDITION="$2"; shift 2 ;;
    --env)       ENV="$2"; shift 2 ;;
    --stack)     STACK="$2"; shift 2 ;;
    --project)   PROJECT="$2"; shift 2 ;;
    --community) COMMUNITY=true; shift ;;
    --bundle)    BUNDLE="$2"; shift 2 ;;
    --groups)    GROUP_SET="$2"; shift 2 ;;
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

# ---- FILES: neutral base + per-runtime overlays (group-selectable) ----------
FILES=()
for b in $GROUP_SET; do
  [[ -f "base/${b}.yml" ]] || { echo "✗ unknown group '${b}' (no base/${b}.yml)" >&2; exit 1; }
  FILES+=(-f "base/${b}.yml")
  [[ -f "runtime/${RUNTIME}/${b}.yml" ]] && FILES+=(-f "runtime/${RUNTIME}/${b}.yml")
done
# datacatalog increment-1 top-level overlay (until folded into runtime/<r>/) —
# only when the datacatalog group is in scope (else it merges onto a missing svc).
[[ -f "runtime.${RUNTIME}.yml" && " $GROUP_SET " == *" datacatalog "* ]] && FILES+=(-f "runtime.${RUNTIME}.yml")
# EE transform last (overrides win)
if [[ "$EDITION" == ee ]]; then
  FILES+=(-f "base/ee.yml")
  [[ -f "runtime/${RUNTIME}/ee.yml" ]] && FILES+=(-f "runtime/${RUNTIME}/ee.yml")
fi

echo "▶ ${EDITION^^} / ${RUNTIME} / env=${ENV} / bundle=${BUNDLE_DIR##*/} / groups=[${GROUP_SET}]"
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

# ---- EE post-deploy seeders -------------------------------------------------
# A greenfield EE deploy is loginnable WITHOUT the interactive Logto admin
# wizard: the EE hub image ships offline seeders (/app/oidc-seeds, /app/menu-seeds)
# that write straight to logto-postgres (direct-DB, no Management-API M2M) and to
# the Hub internal launchpad port. We extract + run them on the host, reusing the
# same admin identity as the CE native admin (HUB_BACKEND_ADMIN_*) so login is
# identical across editions. Best-effort and strictly NON-FATAL — a deploy never
# fails because seeding did. Requires python3 + argon2-cffi on the host (Argon2i).
seed_ee() {
  local hub_cid pg_cid i tmp domain admin_user admin_pass hub_filter pg_filter
  echo ""
  echo "▶ EE seeders (Logto app/roles/user + launchpad)…"
  if [[ "$RUNTIME" == swarm ]]; then
    hub_filter="com.docker.swarm.service.name=${STACK}_industream-hub-backend"
    pg_filter="com.docker.swarm.service.name=${STACK}_logto-postgres"
  else
    hub_filter="com.docker.compose.project=${PROJECT}"
    pg_filter="com.docker.compose.project=${PROJECT}"
  fi
  hub_cid="$(docker ps -q --filter "label=${hub_filter}" \
            $([[ "$RUNTIME" == compose ]] && echo --filter label=com.docker.compose.service=industream-hub-backend) \
            2>/dev/null | head -1)"
  [[ -z "$hub_cid" ]] && { echo "  ⚠ hub-backend container not found — skipping seeders" >&2; return 0; }

  # logto-postgres must accept connections (compose `up -d` returns before ready).
  for i in $(seq 1 30); do
    pg_cid="$(docker ps -q --filter "label=${pg_filter}" \
             $([[ "$RUNTIME" == compose ]] && echo --filter label=com.docker.compose.service=logto-postgres) \
             2>/dev/null | head -1)"
    [[ -n "$pg_cid" ]] && docker exec "$pg_cid" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 2
  done

  # Extract the seeders shipped in the EE image (absent on pre-2.1.3 images).
  tmp="$(mktemp -d)"
  docker cp "${hub_cid}:/app/oidc-seeds/logto/seed-logto.sh" "$tmp/seed-logto.sh" 2>/dev/null \
    || { echo "  ⚠ seeders absent from the hub image (pre-2.1.3) — run scripts/setup/ manually" >&2; rm -rf "$tmp"; return 0; }
  docker cp "${hub_cid}:/app/menu-seeds/seed-menu-apps-stack.sh" "$tmp/seed-menu.sh" 2>/dev/null || true

  local scope=(--runtime "$RUNTIME")
  [[ "$RUNTIME" == swarm ]] && scope+=(--stack "$STACK") || scope+=(--project "$PROJECT")
  domain="${INDUSTREAM_DOMAIN:-localhost}"
  admin_user="${HUB_BACKEND_ADMIN_USER:-admin}"; admin_pass="${HUB_BACKEND_ADMIN_PASSWORD:-admin}"

  # 1) Logto: OIDC app + roles + bootstrap user (Argon2i → needs python3 + argon2-cffi).
  if python3 -c 'import argon2' 2>/dev/null; then
    if bash "$tmp/seed-logto.sh" --client-id "${OIDC_CLIENT_ID:-industream-hub-app}" \
         --redirect "https://${domain}/" --user "$admin_user" --password "$admin_pass" \
         --email "admin@${domain}" --role admin "${scope[@]}" >/dev/null 2>&1; then
      echo "  ✓ Logto: app '${OIDC_CLIENT_ID:-industream-hub-app}' + roles + user '${admin_user}'"
    else echo "  ⚠ Logto seeding failed (non-fatal — see scripts/setup/seed-logto.sh)"; fi
  else
    echo "  ⚠ python3 argon2-cffi missing on host — Logto user bootstrap skipped"
  fi

  # 2) Launchpad menu apps + auth-bridge origin allowlist (internal port, no JWT).
  if [[ -f "$tmp/seed-menu.sh" ]]; then
    if HUB_BACKEND_SERVICE=industream-hub-backend bash "$tmp/seed-menu.sh" \
         --domain "$domain" "${scope[@]}" >/dev/null 2>&1; then
      echo "  ✓ launchpad menu apps + bridge origins seeded"
    else echo "  ⚠ launchpad seeding failed (non-fatal)"; fi
  fi
  rm -rf "$tmp"
}

# ---- Dispatch ---------------------------------------------------------------
if [[ "$RUNTIME" == compose ]]; then
  [[ -n "$PROJECT" ]] || { echo "✗ --project required for compose" >&2; exit 1; }
  docker compose -p "$PROJECT" "${ENV_FILES[@]}" "${FILES[@]}" up -d
  if [[ "$EDITION" == ee ]]; then
    # Source the env so seed_ee sees INDUSTREAM_DOMAIN / OIDC_CLIENT_ID / admin creds
    # (compose dispatch uses --env-file, which doesn't export into this process).
    set -a; export ENV
    source registries.env; source versions.env; source auth.env; source "runtime.${RUNTIME}.env"
    for bf in "$BUNDLE_DIR"/.env.*; do source "$bf"; done
    [[ -f ".env.${ENV}" ]] && source ".env.${ENV}"
    set +a
    seed_ee
  fi
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
  [[ "$EDITION" == ee ]] && seed_ee   # env already sourced above
fi
