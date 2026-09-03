#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"
out="$(mktemp -d)"
bundle="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$out" --skip-images --skip-assets | tail -1)"

with_docker_stub ./scripts/airgap.sh verify "$bundle" >/dev/null \
  || fail "a freshly built bundle does not verify"
pass "a fresh bundle verifies"

# Corrupting a file must be caught by the manifest.
echo tampered >> "$bundle/tree/unified/versions.env"
assert_fails ./scripts/airgap.sh verify "$bundle" "a tampered file fails verification"
git -C "$REPO_ROOT" show HEAD:unified/versions.env > "$bundle/tree/unified/versions.env"

# Dropping an image from the manifest must be caught by replaying the list
# against the bundle's OWN tree — this is what catches a group added between
# build and departure. The checksum step only detects transport corruption
# (bytes changed since the manifest was written); it is not the mechanism
# this assertion is meant to exercise, so bundle.json's own recorded hash is
# refreshed after editing it below — otherwise the checksum check would
# reject the bundle first and the image-set replay would never actually run,
# making this assertion pass for the wrong reason.
dropped="$(python3 - "$bundle/bundle.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); print(d["images"].pop()); json.dump(d, open(p, "w"))
PY
)"
( cd "$bundle" && sha256sum bundle.json | sed 's#  bundle.json#  ./bundle.json#' \
    > /tmp/bundle_json.sha256.$$
  grep -v ' \./bundle\.json$' MANIFEST.sha256 > MANIFEST.sha256.tmp.$$
  cat /tmp/bundle_json.sha256.$$ >> MANIFEST.sha256.tmp.$$
  mv MANIFEST.sha256.tmp.$$ MANIFEST.sha256
  rm -f /tmp/bundle_json.sha256.$$ )

assert_fails ./scripts/airgap.sh verify "$bundle" "a missing image fails verification"
out2="$(./scripts/airgap.sh verify "$bundle" 2>&1 >/dev/null || true)"
assert_contains "$out2" "$dropped" "the missing image is named in the replay failure"

# bundle.json is unsigned data of unproven provenance — MANIFEST.sha256 is a
# plain checksum, not a signature, and (as above) its own line is trivial to
# refresh after editing bundle.json. A field value containing shell
# metacharacters must never be evaluated as shell code while verify reads it.
marker="/tmp/airgap-verify-injection-marker-$$"
rm -f "$marker"
python3 - "$bundle/bundle.json" "$marker" <<PY
import json, sys
p, marker = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["groups"] = 'x"; touch ' + marker + '; echo "'
json.dump(d, open(p, "w"))
PY
( cd "$bundle" && sha256sum bundle.json | sed 's#  bundle.json#  ./bundle.json#' \
    > /tmp/bundle_json.sha256.$$
  grep -v ' \./bundle\.json$' MANIFEST.sha256 > MANIFEST.sha256.tmp.$$
  cat /tmp/bundle_json.sha256.$$ >> MANIFEST.sha256.tmp.$$
  mv MANIFEST.sha256.tmp.$$ MANIFEST.sha256
  rm -f /tmp/bundle_json.sha256.$$ )

./scripts/airgap.sh verify "$bundle" >/dev/null 2>&1 || true
[[ ! -f "$marker" ]] || fail "a crafted bundle.json field executed shell code during verify"
rm -f "$marker"
pass "a crafted bundle.json field is never evaluated as shell code"
