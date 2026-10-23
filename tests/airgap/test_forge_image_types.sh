#!/usr/bin/env bash
# The Forge tags every image COMMUNITY or ENTERPRISE and ships that in the
# export's manifest.json. Forge puts an enterprise image in the CE-named slot
# (HUB_API_IMAGE, CONFIGHUB_IMAGE), while the EE overlay reads its own
# variables (HUB_API_ENTERPRISE_IMAGE, CONFIGHUB_IMAGE_EE). The import must
# bridge the two, or an EE deploy of a Forge bundle resolves empty images.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

KEY="forge-test-image-types"
DIR="releases/bundle-platform-${KEY}"
work="$(mktemp -d)"
cleanup() { rm -rf "${REPO_ROOT:?}/unified/$DIR" "$work"; }
trap cleanup EXIT

EE_HUB="39t.example/uifusion/api-enterprise:2.4.2"
EE_CONFIGHUB="39t.example/flowmaker.core/flowmaker-enterprise-confighub-v2:2.2.4"
EE_DATABRIDGE="39t.example/timeseries/api-enterprise:2.6.1"
CE_UI="ghcr.io/industream/uifusion/ui:2.4.2"

# A Forge export: one folder holding the .env.* files and the manifest.
make_zip() {
  local name="$1" with_manifest="$2" extra_line="${3:-}"
  local root="$work/$name/bundle-flowmaker-enterprise-2.2.4"
  mkdir -p "$root"
  printf 'HUB_UI_IMAGE="%s"\nHUB_API_IMAGE="%s"\nCONFIGHUB_IMAGE="%s"\nDATABRIDGE_API_IMAGE="%s"\n%s' \
    "$CE_UI" "$EE_HUB" "$EE_CONFIGHUB" "$EE_DATABRIDGE" "$extra_line" > "$root/.env.industream_flowmaker-enterprise"
  if [[ "$with_manifest" == true ]]; then
    cat > "$root/manifest.json" <<EOF
{"formatVersion":1,"images":[
 {"variable":"HUB_UI_IMAGE","reference":"$CE_UI","imageType":"COMMUNITY","envFile":".env.industream_flowmaker-enterprise"},
 {"variable":"HUB_API_IMAGE","reference":"$EE_HUB","imageType":"ENTERPRISE","envFile":".env.industream_flowmaker-enterprise"},
 {"variable":"CONFIGHUB_IMAGE","reference":"$EE_CONFIGHUB","imageType":"ENTERPRISE","envFile":".env.industream_flowmaker-enterprise"},
 {"variable":"DATABRIDGE_API_IMAGE","reference":"$EE_DATABRIDGE","imageType":"ENTERPRISE","envFile":".env.industream_flowmaker-enterprise"}
]}
EOF
  fi
  (cd "$work/$name" && zip -qr "../$name.zip" .)
  echo "$work/$name.zip"
}

provided() { { cat "$DIR"/.env.* 2>/dev/null || true; } | { grep -E "^$1=" || true; } | tail -1 | cut -d= -f2- | tr -d '"'; }

# --- Enterprise images reach the EE variables --------------------------------
./scripts/forge-bundle.sh import "$(make_zip typed true)" --name "$KEY" --quiet >/dev/null 2>&1
assert_eq "$(provided HUB_API_ENTERPRISE_IMAGE)" "$EE_HUB" "an ENTERPRISE HUB_API_IMAGE also provides HUB_API_ENTERPRISE_IMAGE"
assert_eq "$(provided CONFIGHUB_IMAGE_EE)" "$EE_CONFIGHUB" "an ENTERPRISE CONFIGHUB_IMAGE also provides CONFIGHUB_IMAGE_EE"
assert_eq "$(provided DATABRIDGE_API_ENTERPRISE_IMAGE)" "$EE_DATABRIDGE" "an ENTERPRISE DATABRIDGE_API_IMAGE also provides DATABRIDGE_API_ENTERPRISE_IMAGE"
assert_eq "$(provided HUB_API_IMAGE)" "$EE_HUB" "the Forge variable itself is kept as shipped"

# --- The EE check no longer reports them missing -----------------------------
check_out="$(./scripts/forge-bundle.sh check "$KEY" --edition ee 2>&1 || true)"
[[ "$check_out" != *"HUB_API_ENTERPRISE_IMAGE"* ]] || fail "check --edition ee still reports HUB_API_ENTERPRISE_IMAGE missing"
[[ "$check_out" != *"CONFIGHUB_IMAGE_EE"* ]] || fail "check --edition ee still reports CONFIGHUB_IMAGE_EE missing"
pass "check --edition ee accepts the aliased EE variables"
rm -rf "${REPO_ROOT:?}/unified/$DIR"

# --- An explicit EE variable in the bundle wins ------------------------------
EXPLICIT="39t.example/uifusion/api-enterprise:9.9.9"
./scripts/forge-bundle.sh import "$(make_zip explicit true "HUB_API_ENTERPRISE_IMAGE=\"$EXPLICIT\"
")" --name "$KEY" --quiet >/dev/null 2>&1
assert_eq "$(provided HUB_API_ENTERPRISE_IMAGE)" "$EXPLICIT" "a HUB_API_ENTERPRISE_IMAGE shipped by the bundle is not overridden"
rm -rf "${REPO_ROOT:?}/unified/$DIR"

# --- No manifest: behaviour unchanged ----------------------------------------
./scripts/forge-bundle.sh import "$(make_zip untyped false)" --name "$KEY" --quiet >/dev/null 2>&1
assert_eq "$(provided HUB_API_ENTERPRISE_IMAGE)" "" "without a manifest no EE variable is invented"
