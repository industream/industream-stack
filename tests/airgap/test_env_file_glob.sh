#!/usr/bin/env bash
# The bundle env chain must load the group env files and nothing else.
#
# deploy.sh feeds `--env-file` from a glob over the bundle directory. A stray
# file that happens to match — an editor swap file, a `.orig` left by a merge, a
# `.bak` an operator made before editing a version — is loaded like a real group
# file, and because the chain is last-one-wins it SILENTLY overrides the image
# versions that get deployed. That is how a site was nearly deployed with the
# very version an operator had just replaced.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

BUNDLE_DIR="releases/bundle-platform-1.0.1"
BUNDLE_ARGS=(--bundle 1.0.1 --env test)
SENTINEL="sentinel.invalid/must-not-be-loaded:9.9.9"

# Every name below sorts AFTER `.env.core`, so under a last-one-wins chain each
# would win if it were loaded at all.
STRAYS=(
  "$BUNDLE_DIR/.env.core.bak"
  "$BUNDLE_DIR/.env.core.orig"
  "$BUNDLE_DIR/.env.core.swp"
  "$BUNDLE_DIR/.env.core~"
)

cleanup() { rm -f "${STRAYS[@]}"; }
trap cleanup EXIT

for stray in "${STRAYS[@]}"; do
  printf 'HUB_UI_IMAGE=%s\n' "$SENTINEL" > "$stray"
done

images="$(with_docker_stub ./scripts/deploy.sh --runtime swarm --stack test-glob \
  --edition ce "${BUNDLE_ARGS[@]}" --list-images)"

if grep -q 'sentinel.invalid' <<<"$images"; then
  fail "a stray file matching .env.* overrode the bundle env"
fi
pass "stray .bak/.orig/.swp/~ files do not enter the env chain"

# The real group files must still be loaded — a fix that narrowed the glob too
# far would pass the assertion above while deploying nothing.
assert_contains "$images" "ghcr.io/industream/uifusion/ui:" "the real .env.core is still loaded"
assert_contains "$images" "postgres:" "the other group env files are still loaded"

cleanup
trap - EXIT

# Without the strays the list must be identical: the guard changes nothing when
# the directory is clean.
clean="$(with_docker_stub ./scripts/deploy.sh --runtime swarm --stack test-glob-clean \
  --edition ce "${BUNDLE_ARGS[@]}" --list-images)"
assert_eq "$images" "$clean" "the image list is the same with and without strays"
