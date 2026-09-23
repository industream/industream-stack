#!/usr/bin/env bash
# `check` proves every required image VARIABLE is present. It says nothing about
# whether the references resolve: a bundle naming an image that was never
# replicated to a reachable registry passes it, and fails later at `prepare`'s
# docker pull — or, worse, on site.
#
# That happened for real: datacatalog 1.13.1 existed only in the internal Harbor,
# absent from both GHCR and the customer hub, while `check` reported the bundle
# deployable.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

BUNDLE_KEY="pullable-fixture"
BUNDLE_DIR="releases/bundle-platform-${BUNDLE_KEY}"
cleanup() { rm -rf "${REPO_ROOT:?}/unified/$BUNDLE_DIR"; }
trap cleanup EXIT

mkdir -p "$BUNDLE_DIR"
cp releases/bundle-platform-1.0.1/.env.* "$BUNDLE_DIR/"

# A stub standing in for the registry: `manifest inspect` succeeds for every
# reference except the one named in $UNPULLABLE, so the test exercises the real
# refs of a real bundle without reaching any network.
with_manifest_stub() {  # with_manifest_stub <unpullable-substring> <cmd…>
  local stub_dir; stub_dir="$(mktemp -d)"
  UNPULLABLE="$1"; shift; export UNPULLABLE
  cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == manifest && "$2" == inspect ]]; then
  [[ -n "$UNPULLABLE" && "$3" == *"$UNPULLABLE"* ]] && exit 1
  echo '{}'; exit 0
fi
exit 0
STUB
  chmod +x "$stub_dir/docker"
  PATH="$stub_dir:$PATH" "$@"
}

# Every reference resolves → the bundle is shippable.
with_manifest_stub "" ./scripts/forge-bundle.sh check "$BUNDLE_KEY" --edition ce --pullable >/dev/null 2>&1 \
  || fail "--pullable must succeed when every reference resolves"
pass "--pullable accepts a bundle whose references all resolve"

# One reference does not resolve → refuse, and name it. Without --pullable the
# same bundle still passes, because that is the older, weaker question.
out="$(with_manifest_stub "datacatalog/api" ./scripts/forge-bundle.sh check "$BUNDLE_KEY" \
        --edition ce --pullable 2>&1)" && fail "--pullable must fail when a reference does not resolve"
pass "--pullable refuses a bundle naming an unreachable image"

assert_contains "$out" "datacatalog/api" \
  "the failure names the reference that could not be resolved"

with_manifest_stub "datacatalog/api" ./scripts/forge-bundle.sh check "$BUNDLE_KEY" --edition ce >/dev/null 2>&1 \
  || fail "without --pullable the variable-presence check must behave exactly as before"
pass "without --pullable the existing behaviour is unchanged"
