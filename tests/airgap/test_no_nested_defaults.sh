#!/usr/bin/env bash
# `docker stack deploy` does not nest ${A:-x${B}}: it stops at the first "}",
# so a set A yields "value}" and an unset A keeps the literal "${B}" — both an
# invalid image reference that aborts the whole deploy. Put the default in
# versions.env (sourced before the bundle) and reference a bare ${A} instead.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

offenders="$(grep -nE '^[^#]*\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]*\$\{' \
  base/*.yml runtime/*/*.yml ./*.yml 2>/dev/null || true)"
[[ -z "$offenders" ]] || fail "nested \${A:-…\${B}} default in a compose file:
$offenders"
pass "no compose file uses a nested \${A:-…\${B}} default"

# The two overridable third-party images still default to their pinned tag.
images="$(with_docker_stub ./scripts/deploy.sh --runtime swarm --stack t --edition ee \
  --bundle 1.0.2 --env test --groups "core monitoring timescale" --list-images)"
assert_contains "$images" "grafana/grafana-oss:" "Grafana defaults to its versions.env tag"
assert_contains "$images" "timescale/timescaledb:" "TimescaleDB defaults to its versions.env tag"
