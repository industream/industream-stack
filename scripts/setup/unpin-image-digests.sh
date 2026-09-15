#!/usr/bin/env bash
# Strips registry digests from a swarm stack's service specs.
#
# A service first deployed with internet carries `image:tag@sha256:…`. Images
# loaded from an offline bundle have different digests — docker save/load does
# not preserve the original — and `--resolve-image never` forbids re-resolving,
# so the task is rejected forever with "No such image: …@sha256:…".
#
# `stack deploy` only rewrites a service whose definition changed, so a service
# whose image version did not move between bundles keeps its old pinned spec.
# On a real site that left exactly the unchanged three (logto, grafana, minio)
# down while the other 42 came up.
#
# Idempotent: a service already free of a digest is left alone, so this can run
# on every deploy without restarting anything for nothing.
set -euo pipefail

STACK="${1:?usage: unpin-image-digests.sh <stack>}"

info() { printf '  ▶ %s\n' "$1"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; }

command -v docker >/dev/null || { echo "  ⚠ docker not found — skipping" >&2; exit 0; }

mapfile -t services < <(docker service ls --filter "label=com.docker.stack.namespace=${STACK}" \
  --format '{{.Name}}' 2>/dev/null)
(( ${#services[@]} > 0 )) || { info "no services in '${STACK}' yet — nothing to unpin"; exit 0; }

unpinned=0
for svc in "${services[@]}"; do
  image="$(docker service inspect "$svc" \
    --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null)" || continue
  [[ "$image" == *@sha256:* ]] || continue

  bare="${image%@sha256:*}"
  info "unpinning ${svc}: ${bare}"
  # --no-resolve-image is the point: resolving against the registry is what wrote
  # the digest in the first place, and on an offline site it cannot succeed.
  docker service update --no-resolve-image --image "$bare" "$svc" >/dev/null 2>&1 \
    || { echo "  ⚠ could not unpin $svc" >&2; continue; }
  unpinned=$((unpinned + 1))
done

if (( unpinned == 0 )); then
  ok "no service carries a registry digest"
else
  ok "${unpinned} service(s) unpinned from a registry digest"
fi
