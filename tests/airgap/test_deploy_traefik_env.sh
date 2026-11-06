#!/usr/bin/env bash
# deploy-traefik.sh must read only the keys it uses from .env.
#
# Sourcing the whole .env made one unrelated line abort the Traefik deploy: an
# operator note such as `GROUPS=core flowmaker data` (unquoted) runs `flowmaker`
# as a command under `set -e`, so the shared router never came up.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

[[ ! -e .env ]] || fail ".env already exists in the repo root; refusing to overwrite it"
GENERATED="traefik-dynamic/traefik-dynamic.yml"
cleanup() { rm -f .env "$GENERATED" "${OUT:-}"; }
trap cleanup EXIT

cat > .env <<'ENV'
INDUSTREAM_DOMAIN=example.lan
TLS_MODE=selfsigned
TRAEFIK_AUTH_HTPASSWD='admin:$$apr1$$salt$$hash'
TRAEFIK_LOG_LEVEL=INFO
GROUPS=core flowmaker datacatalog
ENV

OUT="$(mktemp)"
# Not in $(…): with_docker_stub exports DOCKER_LOG, which a subshell would lose.
DOCKER_STUB_LOG_ENV="INDUSTREAM_DOMAIN TRAEFIK_LOG_LEVEL" \
  with_docker_stub ./scripts/deploy-traefik.sh >"$OUT" 2>&1 </dev/null \
  || fail "deploy-traefik.sh aborted on an unrelated .env line: $(cat "$OUT")"
pass "an unquoted unrelated line does not abort the deploy"

log="$(cat "$DOCKER_LOG")"
assert_contains "$log" "stack deploy -c docker-stack.traefik.yml" "the Traefik stack is deployed"
assert_contains "$log" "env INDUSTREAM_DOMAIN=example.lan" "the domain reaches the stack deploy"
assert_contains "$log" "env TRAEFIK_LOG_LEVEL=INFO" "stack variables still reach the stack deploy"
assert_contains "$(cat "$GENERATED")" 'admin:$$apr1$$salt$$hash' "the htpasswd reaches the dynamic config unchanged"
