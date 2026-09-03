#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"
out="$(mktemp -d)"

# `with_docker_stub ... | tail -1` inside a single $(...) would run the stub
# setup (which exports $DOCKER_LOG) in a subshell, discarding the export before
# this script could read the log back — so capture stdout to a file instead
# and take the last line ourselves.
prepare_out="$(mktemp)"
with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$out" --skip-assets > "$prepare_out"
bundle="$(tail -1 "$prepare_out")"
log="$(cat "$DOCKER_LOG")"

# An image already present locally must not be pulled; the stub reports every
# `image inspect` as absent, so a pull per image is expected here.
assert_contains "$log" "pull " "absent images are pulled"
assert_contains "$log" "save " "images are saved"

# One tarball per group, not one per image.
(( $(ls "$bundle/images" | wc -l) < $(python3 -c "import json;print(len(json.load(open('$bundle/bundle.json'))['images']))") )) \
  || fail "images are not grouped"
pass "images are grouped into per-group tarballs"

# Splitting: a 5 MB file with a 1 MB cap must yield parts that concatenate back
# to the same bytes.
big="$out/big.bin"; head -c 5000000 /dev/urandom > "$big"
sum_before="$(sha256sum < "$big" | cut -d' ' -f1)"
./scripts/airgap.sh _split "$big" 1M
[[ -f "$big.00" ]] || fail "split produced no parts"
pass "split produced parts"
assert_eq "$(cat "$big".* | sha256sum | cut -d' ' -f1)" "$sum_before" "parts concatenate to the original"
[[ ! -f "$big" ]] || fail "the original was left behind, doubling the bundle size"
pass "the original is removed after splitting"

# A file under the cap must be left intact.
small="$out/small.bin"; head -c 1000 /dev/urandom > "$small"
./scripts/airgap.sh _split "$small" 1M
[[ -f "$small" && ! -f "$small.00" ]] || fail "a small file was split anyway"
pass "files under the cap are left intact"
