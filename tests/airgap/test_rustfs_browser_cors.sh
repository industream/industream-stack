#!/usr/bin/env bash
# RustFS, unlike MinIO, answers no CORS header by default: a browser upload from a FlowMaker box form
# to s3.<domain> was refused. The server now allows the FlowMaker origin.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

minio_env() {  # minio_env → the RUSTFS_CORS_ALLOWED_ORIGINS value rendered for the minio service
  INDUSTREAM_DOMAIN=site.example ENV=prod RUSTFS_VERSION=1.0.1 CDN_SERVER_IMAGE=x CDN_CACHE_IMAGE=x \
  HUB_API_IMAGE=x HUB_UI_IMAGE=x MINIO_ROOT_USER_SECRET_NAME=u MINIO_ROOT_PASSWORD_SECRET_NAME=p \
    docker stack config -c unified/base/core.yml 2>/dev/null \
    | awk '/^  [a-z]/ {in_minio = ($1 == "minio:")} in_minio && /RUSTFS_CORS_ALLOWED_ORIGINS/ {print $2; exit}'
}
if docker stack config --help >/dev/null 2>&1; then
  assert_eq "$(minio_env)" "https://flowmaker.site.example" "RustFS allows the swarm FlowMaker origin"
else
  echo "  ⚠ docker stack config unavailable — rendering not checked"
fi

compose_env() {  # compose_env <VAR> → its value on the minio service once the compose overlay is merged
  ( cd unified && FM_DOMAIN=fm.example INDUSTREAM_DOMAIN=site.example ENV=dev RUSTFS_VERSION=1.0.1 \
      CDN_SERVER_IMAGE=x CDN_CACHE_IMAGE=x HUB_API_IMAGE=x HUB_UI_IMAGE=x \
      MINIO_ROOT_USER_SECRET_NAME=u MINIO_ROOT_PASSWORD_SECRET_NAME=p \
      docker compose -f base/core.yml -f runtime/compose/core.yml config 2>/dev/null ) \
    | awk -v var="$1:" '/^  [a-z]/ {in_minio = ($1 == "minio:")} in_minio && $1 == var {print $2; exit}'
}
if docker compose version >/dev/null 2>&1; then
  assert_eq "$(compose_env RUSTFS_CORS_ALLOWED_ORIGINS)" "https://frontend.fm.example" \
    "compose mode allows the compose FlowMaker origin"
  assert_eq "$(compose_env RUSTFS_ACCESS_KEY_FILE)" "/run/secrets/u" "the compose overlay keeps the base credentials"
else
  echo "  ⚠ docker compose unavailable — rendering not checked"
fi
