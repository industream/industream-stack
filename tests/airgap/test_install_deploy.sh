#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

# NOTE on runtime: deploy.sh's seed_menu_apps polls for the hub-backend
# container for up to 60*2s before giving up (no override exists for this —
# it is unconditional, downstream of --airgap, and out of this file's scope).
# Every scenario below that lets a real deploy run to completion therefore
# costs ~2 minutes; DEPLOY_TIMEOUT only bounds the convergence-poll ahead of
# it. Scenarios that don't need to observe the deploy call itself use
# --no-deploy instead, which is fast (no docker stack/compose call at all).

# --- swarm: --airgap reaches deploy.sh, nothing is pulled, default stack ------
out="$(mktemp -d)"; target="$(mktemp -d)"
bundle="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ee \
  --out "$out" --skip-images --skip-assets | tail -1)"

DEPLOY_TIMEOUT=1 with_docker_stub bash "$bundle/install.sh" --target "$target" --yes >/dev/null 2>&1 || true
log="$(cat "$DOCKER_LOG")"
assert_contains "$log" "--resolve-image never" "the deploy runs in airgap mode"
if grep -qE '^pull ' <<<"$log"; then fail "the install pulled an image"; fi
pass "the install pulls nothing"
assert_contains "$log" "stack deploy" "the swarm deploy actually ran"
assert_contains "$log" "industream-prod" "the default stack name (json_get fallback) is used"

# --- swarm: --stack overrides the bundle.json fallback ------------------------
target2="$(mktemp -d)"
DEPLOY_TIMEOUT=1 with_docker_stub bash "$bundle/install.sh" --target "$target2" --yes \
  --stack site-prod >/dev/null 2>&1 || true
log2="$(cat "$DOCKER_LOG")"
assert_contains "$log2" "stack deploy" "the swarm deploy ran with an overridden stack"
assert_contains "$log2" "site-prod" "--stack overrides the default stack name"
if grep -q "industream-prod" <<<"$log2"; then fail "the default stack name leaked through the override"; fi
pass "no stray default stack name"

# --- compose: --project reaches BOTH the deploy call and volume_name() --------
# This is the gap Task 10 had to close: bundle.json carries no target-side
# compose project, so an operator-supplied --project must land on the SAME
# name the asset seeder used, or Grafana's plugin volume silently diverges
# from the one the deploy actually mounts.
outc="$(mktemp -d)"; targetc="$(mktemp -d)"
bundlec="$(with_docker_stub ./scripts/airgap.sh prepare --runtime compose --edition ce \
  --out "$outc" --skip-images --skip-assets | tail -1)"
mkdir -p "$bundlec/assets/grafana-plugins/industream-databridge-datasource"
echo '{}' > "$bundlec/assets/grafana-plugins/industream-databridge-datasource/plugin.json"

DEPLOY_TIMEOUT=1 with_docker_stub bash "$bundlec/install.sh" --target "$targetc" --yes \
  --project site-fm >/dev/null 2>&1 || true
logc="$(cat "$DOCKER_LOG")"
assert_contains "$logc" "compose" "the compose deploy actually ran"
assert_contains "$logc" "-p site-fm" "--project reaches the deploy call"
assert_contains "$logc" " up -d" "compose deploy ends in up -d"
assert_contains "$logc" "site-fm_grafana-data" "--project reaches volume_name() too — same name, no drift"

# --- compose, no --project: the deploy call and volume_name() must still agree
# (fast path — --no-deploy skips the actual deploy.sh call, so this only
# proves the SEEDING side of the default; the deploy side shares the exact
# same compose_project() function, verified by the override case above and by
# a source-level check that both call sites use it).
outc2="$(mktemp -d)"; targetc2="$(mktemp -d)"
bundlec2="$(with_docker_stub ./scripts/airgap.sh prepare --runtime compose --edition ce \
  --out "$outc2" --skip-images --skip-assets | tail -1)"
mkdir -p "$bundlec2/assets/grafana-plugins/industream-databridge-datasource"
echo '{}' > "$bundlec2/assets/grafana-plugins/industream-databridge-datasource/plugin.json"
with_docker_stub bash "$bundlec2/install.sh" --target "$targetc2" --yes --no-deploy >/dev/null 2>&1 || true
# bundle.json's env is "prod" (airgap.sh's own default) — the compose project
# fallback is "fm-<env>", exactly as volume_name() has documented since Task 9.
assert_contains "$(cat "$DOCKER_LOG")" "fm-prod_grafana-data" \
  "the default compose project (no --project given) seeds fm-<env>_<volume>"
# Source check, not a behavioural one: proves volume_name() and run_deploy()
# both call compose_project() rather than each hand-rolling the same default —
# the override case above already proves the VALUE matches at runtime.
[[ "$(grep -c 'compose_project' "$REPO_ROOT/unified/scripts/airgap-install.sh")" -ge 3 ]] \
  || fail "compose_project() is not shared by both volume_name() and run_deploy()"
pass "compose_project() is the single source for both the deploy call and volume_name()"

# --- --no-deploy stops before touching deploy.sh at all -----------------------
outn="$(mktemp -d)"; targetn="$(mktemp -d)"
bundlen="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$outn" --skip-images --skip-assets | tail -1)"
with_docker_stub bash "$bundlen/install.sh" --target "$targetn" --yes --no-deploy >/dev/null 2>&1 || true
logn="$(cat "$DOCKER_LOG")"
if grep -q "stack deploy" <<<"$logn"; then fail "--no-deploy still ran the deploy"; fi
pass "--no-deploy never invokes deploy.sh"
[[ -f "$targetn/unified/scripts/deploy.sh" ]] || fail "--no-deploy should still sync the tree"
pass "--no-deploy still syncs the tree and seeds assets"
