#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"
out="$(mktemp -d)"

# 1. A dirty tracked file must abort the build: what ships must be what was tested.
touch "$REPO_ROOT/unified/versions.env.dirtytest"
git -C "$REPO_ROOT" add -N unified/versions.env.dirtytest
assert_fails ./scripts/airgap.sh prepare --runtime swarm --edition ce --out "$out" \
  "prepare refuses a dirty working tree"
git -C "$REPO_ROOT" rm --cached -q unified/versions.env.dirtytest
rm -f "$REPO_ROOT/unified/versions.env.dirtytest"

# 2. On a clean tree it must produce the tree and the manifest.
bundle="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$out" --skip-images --skip-assets | tail -1)"
[[ -d "$bundle/tree" ]] || fail "tree/ missing"
pass "tree/ produced"
[[ -f "$bundle/tree/unified/scripts/deploy.sh" ]] || fail "deploy.sh missing from the tree"
pass "tree carries deploy.sh"
[[ -f "$bundle/bundle.json" ]] || fail "bundle.json missing"
pass "bundle.json produced"
assert_contains "$(cat "$bundle/bundle.json")" '"edition": "ce"' "bundle.json records the edition"
[[ -f "$bundle/MANIFEST.sha256" ]] || fail "MANIFEST.sha256 missing"
pass "manifest produced"

# 3. The resolved bundle .env.* must travel even when untracked — git archive
#    alone would deliver a stack whose images resolve to empty strings.
[[ -n "$(find "$bundle/tree/unified/releases" -name '.env.*' -print -quit)" ]] \
  || fail "bundle .env.* files missing from the tree"
pass "bundle .env.* travel with the tree"

# 4. A second `prepare` into the same --out must succeed even though the first
#    run's harvest_grafana_plugins left files owned by uid 472 (the Grafana
#    image's uid, never the host user) under $dest. Simulate that ownership
#    cheaply with a disposable container instead of a real Grafana run, which
#    keeps this test fast — a directory owned by 472, mode 755, reproduces the
#    exact "Permission denied" the host user hits, since 755 gives the owner
#    (472) write access but not "other" (the host user).
commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
stale_dest="$out/industream-airgap-${commit}-ce-swarm"
mkdir -p "$stale_dest/assets/grafana-plugins/some-plugin"
# shellcheck disable=SC1091
set -a; source "$REPO_ROOT/unified/versions.env"; set +a
docker run --rm -v "$stale_dest/assets/grafana-plugins:/plugins" "alpine:${ALPINE_VERSION}" sh -c \
  'echo x > /plugins/some-plugin/LICENSE && chown -R 472:0 /plugins/some-plugin'

# Confirms the fixture actually reproduces the bug: a plain host-side rm -rf
# cannot remove a 472-owned, mode-755 directory it does not own.
assert_fails rm -rf "$stale_dest/assets/grafana-plugins/some-plugin" \
  "sanity: a host-side rm cannot remove the 472-owned fixture"

#    The wipe fix runs a real container to remove the 472-owned leftover, so
#    this call uses the real docker daemon rather than with_docker_stub (whose
#    logging-only `docker` never actually touches the filesystem).
second_out="$(mktemp)"
./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$out" --skip-images --skip-assets > "$second_out" 2>&1
assert_contains "$(cat "$second_out")" "$stale_dest" \
  "a second prepare into the same --out succeeds despite 472-owned leftovers"
[[ ! -d "$stale_dest/assets/grafana-plugins/some-plugin" ]] \
  || fail "the 472-owned leftover from the previous run was not wiped"
pass "the 472-owned leftover from the previous run was wiped"
