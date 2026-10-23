#!/usr/bin/env bash
# `check` lists the ${X_IMAGE} vars the scoped base needs. A var written with a
# default (${X_IMAGE:-image:tag}) is an optional override, not a requirement:
# reporting it missing makes every bundle look broken and buries the real gaps.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

out="$(./scripts/forge-bundle.sh check 1.0.2 --edition ee --groups "core monitoring timescale" 2>&1 || true)"

[[ "$out" != *"TIMESCALE_TIMESCALEDB_IMAGE"* ]] || fail "an override with a default is reported missing"
[[ "$out" != *"GRAFANA_IMAGE"$'\n'* && "$out" != *"- GRAFANA_IMAGE"* ]] || fail "GRAFANA_IMAGE (defaulted) is reported missing"
pass "image vars with a \${VAR:-default} are not required"

# A var with no default is still a hard requirement.
assert_contains "$out" "DATABRIDGE_API_ENTERPRISE_IMAGE" "a var without a default is still reported missing"
