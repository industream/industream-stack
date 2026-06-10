#!/usr/bin/env bash
# Pre-create the shared overlay network every group stack attaches to, and the
# external secrets, BEFORE deploying the per-group stacks in Portainer.
set -euo pipefail
ENV="${1:-prod}"
docker network inspect "${ENV}-platform" >/dev/null 2>&1 \
  || docker network create -d overlay --attachable "${ENV}-platform"
echo "✓ network ${ENV}-platform ready"
echo "→ now run create-secrets.sh (external prod_* secrets), then add each"
echo "  subfolder here as a Portainer Git stack (Repository → Compose path = <group>/docker-compose.yml)."
