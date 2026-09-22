#!/usr/bin/env bash
# install.sh must refuse to touch the tree or deploy when an image the bundle's
# deploy needs is neither shipped nor already loaded — the failure mode of a
# script-only (--skip-images) or differential (--against) bundle applied to a
# site whose inventory does not match. Today that surfaces as "No such image"
# tasks after the stack was already updated.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"
out="$(mktemp -d)"
bundle="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$out" --skip-images --skip-assets | tail -1)"
all_images="$(python3 -c "import json;print('\n'.join(json.load(open('$bundle/bundle.json'))['images']))")"
absent="$(tail -n 1 <<<"$all_images")"

# 1. One image missing on the site: stop before the tree is synced, name it.
present="$(mktemp)"; head -n -1 <<<"$all_images" > "$present"
target="$(mktemp -d)"; log="$(mktemp)"
status=0
DOCKER_STUB_IMAGES="$present" DEPLOY_TIMEOUT=1 \
  with_docker_stub bash "$bundle/install.sh" --target "$target" --yes > "$log" 2>&1 || status=$?
[[ "$status" -ne 0 ]] || fail "install.sh succeeded with an image missing from the site"
pass "install.sh fails when a required image is not loaded"
assert_contains "$(cat "$log")" "$absent" "the missing image is named"
[[ ! -d "$target/unified" ]] || fail "the tree was synced despite the missing image"
pass "the tree was not touched"
if grep -q 'stack deploy' "$DOCKER_LOG"; then fail "a deploy ran despite the missing image"; fi
pass "no deploy ran"

# 2. Every image present: the same bundle proceeds.
all_file="$(mktemp)"; printf '%s\n' "$all_images" > "$all_file"
target2="$(mktemp -d)"
DOCKER_STUB_IMAGES="$all_file" with_docker_stub bash "$bundle/install.sh" \
  --target "$target2" --yes --no-deploy >/dev/null 2>&1 \
  || fail "install.sh refused a bundle whose images are all loaded"
[[ -d "$target2/unified" ]] || fail "the tree was not synced"
pass "install.sh proceeds when every image is loaded"
