#!/usr/bin/env bash
# The FlowMaker frontend's serving port appears in three unrelated files: the
# healthcheck, the Traefik loadbalancer label, and the Caddy upstream. Nothing
# ties them together, so a change to one leaves the others behind.
#
# That is how the core 2.2.2 upgrade broke on a real air-gapped update: the
# image went non-privileged (user nginx, listening on 8080) while all three
# still pointed at 80. nginx started, the healthcheck on :80 was refused, swarm
# stopped the task gracefully — exit 0, state "Complete", no error anywhere.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

health="$(grep -A20 'flowmaker-frontend:' base/flowmaker.yml \
  | grep -oE 'http://127\.0\.0\.1:[0-9]+/' | head -1 | sed -E 's|.*:([0-9]+)/|\1|')"
traefik="$(grep -oE 'flowmaker-frontend\.loadbalancer\.server\.port=[0-9]+' runtime/swarm/flowmaker.yml \
  | grep -oE '[0-9]+$' | head -1)"
caddy="$(grep -A14 'flowmaker-frontend:' runtime/compose/flowmaker.yml \
  | grep -oE 'upstreams [0-9]+' | grep -oE '[0-9]+' | head -1)"

[[ -n "$health" && -n "$traefik" && -n "$caddy" ]] \
  || fail "could not read all three ports (healthcheck=$health traefik=$traefik caddy=$caddy) — the file layout changed, fix this test rather than deleting it"
pass "the three frontend port references are readable"

assert_eq "$traefik" "$health" "the Traefik loadbalancer port matches the healthcheck port"
assert_eq "$caddy" "$health" "the Caddy upstream port matches the healthcheck port"

# The image itself is the authority. It is not always on the machine running the
# tests, so this is a warning rather than a failure — but when it IS present, a
# disagreement is the actual bug and must be loud.
set -a; source versions.env; set +a
img="ghcr.io/industream/flowmaker.core/flowmaker-front:${FLOWMAKER_FRONTEND_VERSION}"
if docker image inspect "$img" >/dev/null 2>&1; then
  exposed="$(docker image inspect "$img" --format '{{range $p, $_ := .Config.ExposedPorts}}{{$p}}{{end}}' | grep -oE '^[0-9]+')"
  assert_eq "$exposed" "$health" "the image's own exposed port matches what the compose files target"
else
  echo "  ⚠ $img not present locally — port agreement checked between files only" >&2
fi
