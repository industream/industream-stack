#!/usr/bin/env bash
# Differential bundles: `diff --against` names what a site is missing, and
# `prepare --against` ships only that — while bundle.json keeps the FULL image
# list so verify (and install.sh's presence check) still reason about the
# whole deploy, never about the slice that travelled.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"
out="$(mktemp -d)"

full="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$out" --skip-images --skip-assets | tail -1)"
all_images="$(python3 -c "import json;print('\n'.join(json.load(open('$full/bundle.json'))['images']))")"
total="$(wc -l <<<"$all_images")"

# A site inventory = every image but the last two (the shape `docker image ls
# --format '{{.Repository}}:{{.Tag}}'` produces, plus a comment and a blank).
inventory="$out/site-images.txt"
{ echo "# exported from the site"; head -n -2 <<<"$all_images"; echo; } > "$inventory"
missing_expected="$(tail -n 2 <<<"$all_images")"

# 1. diff names exactly the two absent images and counts the rest as present.
diff_out="$(with_docker_stub ./scripts/airgap.sh diff --runtime swarm --edition ce --against "$inventory")"
while IFS= read -r img; do
  assert_contains "$diff_out" "+ $img" "diff lists $img as to-ship"
done <<<"$missing_expected"
assert_eq "$(grep -c '^+ ' <<<"$diff_out")" "2" "diff lists nothing else"
assert_contains "$diff_out" "2 image(s) to ship, $((total - 2)) already present" "diff summarises the delta"

# 2. A previous bundle's bundle.json is a valid reference: nothing to ship.
diff_same="$(with_docker_stub ./scripts/airgap.sh diff --runtime swarm --edition ce --against "$full")"
assert_contains "$diff_same" "0 image(s) to ship" "diff against the same bundle ships nothing"

# 3. diff without a reference, or with an unreadable one, must refuse.
assert_fails ./scripts/airgap.sh diff --runtime swarm --edition ce "diff requires --against"
assert_fails ./scripts/airgap.sh diff --runtime swarm --edition ce --against "$out/nope" "diff refuses a missing reference"

# 4. prepare --against saves only the delta, records both lists. A separate
#    --out: the bundle name is commit+edition+runtime, so the same --out would
#    overwrite the full bundle step 5 still reads.
prep_out="$(mktemp)"
with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$(mktemp -d)" --skip-assets --against "$inventory" > "$prep_out"
delta="$(tail -1 "$prep_out")"
saves="$(grep '^save ' "$DOCKER_LOG" | grep -v 'alpine:' || true)"
while IFS= read -r img; do
  assert_contains "$saves" "$img" "prepare --against saves $img"
done <<<"$missing_expected"
for img in $(head -n -2 <<<"$all_images"); do
  if grep -qF -- "$img" <<<"$saves"; then fail "prepare --against saved $img, which the site already has"; fi
done
pass "prepare --against saves none of the images the site already has"
python3 - "$delta/bundle.json" "$total" "$inventory" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); total = int(sys.argv[2])
assert len(d["images"]) == total, "images must stay the FULL list"
assert len(d["shipped_images"]) == 2, d["shipped_images"]
assert set(d["shipped_images"]) <= set(d["images"])
assert d["against"]["images"] == total - 2, d["against"]
assert d["against"]["ref"] == sys.argv[3].rsplit("/", 1)[-1], d["against"]
PY
pass "bundle.json keeps the full list and records the shipped slice and its reference"
[[ "$(ls "$delta/images" | grep -vc '^tooling')" -le 2 ]] || fail "more tarballs than groups touched by the delta"
pass "only the groups touched by the delta have a tarball"
with_docker_stub ./scripts/airgap.sh verify "$delta" >/dev/null || fail "a differential bundle does not verify"
pass "a differential bundle verifies"

# 5. A full bundle records shipped == images and no reference.
python3 - "$full/bundle.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["shipped_images"] == [] and d["against"] is None, (d["shipped_images"], d["against"])
PY
pass "a --skip-images bundle records an empty shipped list and no reference"

# 6. --against and --skip-images contradict each other.
assert_fails ./scripts/airgap.sh prepare --runtime swarm --edition ce --out "$out" \
  --skip-images --skip-assets --against "$inventory" "--against refuses --skip-images"
