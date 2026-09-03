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
