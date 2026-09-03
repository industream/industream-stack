#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

# --bundle is REQUIRED: two directories match releases/bundle-platform-*/ on
# this branch, so deploy.sh's auto-select exits 1 before any flag is read.
BUNDLE_ARGS=(--bundle 1.0.1 --env test)

# A stack deploy needs an env file; use the dummy test env shipped in the tree.
# DEPLOY_TIMEOUT=1 bounds the convergence-poll loop (the docker stub returns no
# services, so it would otherwise spin for the default 600s before giving up).
run_deploy() {
  DEPLOY_TIMEOUT=1 with_docker_stub ./scripts/deploy.sh --runtime swarm --edition ce \
    "${BUNDLE_ARGS[@]}" --stack airgap-test "$@" >/dev/null 2>&1 || true
}

run_deploy --airgap
log="$(cat "$DOCKER_LOG")"
if grep -qE '^pull ' <<<"$log"; then fail "--airgap still pulled images"; fi
pass "--airgap emits no pull"
assert_contains "$log" "--resolve-image never" "--airgap passes --resolve-image never"
if grep -q -- "--with-registry-auth" <<<"$log"; then fail "--airgap kept --with-registry-auth"; fi
pass "--airgap drops --with-registry-auth"

# Without the flag, the pre-pull must still happen — this guards the online path.
run_deploy
assert_contains "$(cat "$DOCKER_LOG")" "pull " "online deploy still pre-pulls"
