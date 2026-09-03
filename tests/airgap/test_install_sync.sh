#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"
out="$(mktemp -d)"; target="$(mktemp -d)"
bundle="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$out" --skip-images --skip-assets | tail -1)"

# --skip-assets means the bundle carries no harvested asset directories at
# all, so seed_assets' own "source exists and is non-empty" guard would never
# fire without something under assets/ — fabricate the same kind of fixture
# content test_install_preflight.sh fabricates for --skip-images (fake image
# tarballs). Extra files here don't need a MANIFEST.sha256 regeneration:
# `sha256sum -c` only checks the files it was given, so files added after
# `prepare` that are absent from the manifest are simply not checked.
mkdir -p "$bundle/assets/grafana-plugins/industream-databridge-datasource" \
         "$bundle/assets/cdn-packages/cdn-server-storage" \
         "$bundle/assets/cdn-packages/cdn-cache-storage"
echo '{}' > "$bundle/assets/grafana-plugins/industream-databridge-datasource/plugin.json"
echo "pkg" > "$bundle/assets/cdn-packages/cdn-server-storage/some.tgz"
echo "pkg" > "$bundle/assets/cdn-packages/cdn-cache-storage/some.tgz"

# Pre-existing site state that MUST survive an update. All five have already
# been clobbered on these hosts.
mkdir -p "$target/unified/custom" "$target/secrets/prod" "$target/unified/instances" "$target/.deploy-state"
echo "SITE_SECRET=keepme"   > "$target/unified/.env.prod"
echo "custom-overlay"       > "$target/unified/custom/site.yml"
echo "s3cret"               > "$target/secrets/prod/hub_backend_admin_password"
echo "instance-data"        > "$target/unified/instances/site.yml"
echo "deploy-state-data"    > "$target/.deploy-state/state.json"

with_docker_stub bash "$bundle/install.sh" --target "$target" --yes --no-deploy >/dev/null 2>&1 || true

assert_eq "$(cat "$target/unified/.env.prod")" "SITE_SECRET=keepme" ".env.<env> survives the sync"
assert_eq "$(cat "$target/unified/custom/site.yml")" "custom-overlay" "custom/ survives the sync"
assert_eq "$(cat "$target/secrets/prod/hub_backend_admin_password")" "s3cret" "secrets/ survive the sync"
assert_eq "$(cat "$target/unified/instances/site.yml")" "instance-data" "unified/instances/ survives the sync"
assert_eq "$(cat "$target/.deploy-state/state.json")" "deploy-state-data" ".deploy-state/ survives the sync"
[[ -f "$target/unified/scripts/deploy.sh" ]] || fail "the tree was not synced"
pass "the tree was synced"
[[ -f "$target/AIRGAP_VERSION" ]] || fail "AIRGAP_VERSION not written"
pass "AIRGAP_VERSION written"
[[ -n "$(ls "$target/backups" 2>/dev/null)" ]] || fail "no rollback snapshot was taken"
pass "a rollback snapshot was taken"

# Assets must be seeded on EVERY run, not only the first: a bumped
# GRAFANA_DATABRIDGE_PLUGIN would otherwise send Grafana looking for a version
# it cannot reach, and the preinstall is boot-blocking.
# The swarm overlays pin `name: ${ENV}-<volume>`, so the real volume is
# `prod-grafana-data` — seeding `<stack>_grafana-data` would create an unused
# volume and leave Grafana unable to boot.
assert_contains "$(cat "$DOCKER_LOG")" "prod-grafana-data" "grafana plugins are seeded into the ENV-prefixed volume"
assert_contains "$(cat "$DOCKER_LOG")" "prod-cdn-server-storage" "CDN packages are seeded into the ENV-prefixed volume"
