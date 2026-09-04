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

# The bundle's own content must ARRIVE, not just survive alongside site state.
# scripts/backups/ is git-tracked tooling shipped in every bundle (git archive
# puts it in $bundle/tree/scripts/backups/) and is unrelated to $TARGET/backups/,
# the rollback-snapshot dir install.sh creates at the transfer root — an
# unanchored '--exclude=backups/' pattern used to conflate the two and drop
# this tooling from every install. A marker file here needs no MANIFEST.sha256
# regeneration, same as the asset fixtures above.
echo "backup-tooling-marker" > "$bundle/tree/scripts/backups/regression-marker.sh"

# Pre-existing site state that MUST survive an update. All five have already
# been clobbered on these hosts.
mkdir -p "$target/unified/custom" "$target/secrets/prod" "$target/unified/instances" "$target/.deploy-state"
echo "SITE_SECRET=keepme"   > "$target/unified/.env.prod"
echo "custom-overlay"       > "$target/unified/custom/site.yml"
echo "s3cret"               > "$target/secrets/prod/hub_backend_admin_password"
echo "instance-data"        > "$target/unified/instances/site.yml"
echo "deploy-state-data"    > "$target/.deploy-state/state.json"

# Pre-existing scripts/backups/ tooling on the target, so this run's
# pre-sync `tar` snapshot (taken because $target/unified already exists)
# actually has something under that name to snapshot — proving the snapshot
# itself doesn't drop it the same way the sync's rsync excludes used to.
mkdir -p "$target/scripts/backups"
echo "existing-backup-tool" > "$target/scripts/backups/existing-tool.sh"

with_docker_stub bash "$bundle/install.sh" --target "$target" --yes --no-deploy >/dev/null 2>&1 || true

assert_eq "$(cat "$target/unified/.env.prod")" "SITE_SECRET=keepme" ".env.<env> survives the sync"
assert_eq "$(cat "$target/unified/custom/site.yml")" "custom-overlay" "custom/ survives the sync"
assert_eq "$(cat "$target/secrets/prod/hub_backend_admin_password")" "s3cret" "secrets/ survive the sync"
assert_eq "$(cat "$target/unified/instances/site.yml")" "instance-data" "unified/instances/ survives the sync"
assert_eq "$(cat "$target/.deploy-state/state.json")" "deploy-state-data" ".deploy-state/ survives the sync"
[[ -f "$target/unified/scripts/deploy.sh" ]] || fail "the tree was not synced"
pass "the tree was synced"
assert_eq "$(cat "$target/scripts/backups/regression-marker.sh")" "backup-tooling-marker" \
  "scripts/backups/ tooling reaches the target, not just the rollback snapshot dir"
[[ -f "$target/AIRGAP_VERSION" ]] || fail "AIRGAP_VERSION not written"
pass "AIRGAP_VERSION written"
[[ -n "$(ls "$target/backups" 2>/dev/null)" ]] || fail "no rollback snapshot was taken"
pass "a rollback snapshot was taken"

# The snapshot tar's own --exclude had the identical unanchored-pattern bug
# as the rsync excludes above: an unanchored 'backups' also matches
# scripts/backups/ at depth, so a restore from an incident would hand back
# a tree with no backup tooling. Extract the tarball and prove the
# pre-existing scripts/backups/ file rode along.
snap="$(ls "$target"/backups/tree-*.tar.gz 2>/dev/null | head -1)"
[[ -n "$snap" ]] || fail "no rollback snapshot tarball found"
snap_extract="$(mktemp -d)"
tar xzf "$snap" -C "$snap_extract"
assert_eq "$(cat "$snap_extract/scripts/backups/existing-tool.sh")" "existing-backup-tool" \
  "the rollback snapshot keeps scripts/backups/ tooling too, not just \$TARGET/backups/"

# The other half of that same bug: an exclude that matches nothing not only
# fails to protect scripts/backups/, it also fails to exclude $TARGET/backups
# itself, so the snapshot tarball ends up containing the very directory it is
# being written into (and GNU tar aborts archiving a file that grows mid-read).
[[ ! -d "$snap_extract/backups" ]] || fail "the rollback snapshot must not contain \$TARGET/backups itself"
pass "the rollback snapshot excludes \$TARGET/backups itself"

# The regression with real teeth: the first run above created $target/backups,
# so a SECOND install/update into the same target is the case that actually
# broke — a dead tar --exclude archives $target/backups into itself and GNU
# tar aborts with "file changed as we read it", which install.sh (set -euo
# pipefail) turns into a hard failure of the whole install.
#
# GNU tar only hits that check reliably once there is enough tree content for
# the growing snapshot file's write to overlap the read of it — on the tiny
# tree this fixture builds by itself, the read can finish before the window
# opens. A production tree is easily big enough on its own; here 20MB of
# filler at the transfer root reproduces the same window on demand (this is
# a timing effect of the dead exclude, not a property of the filler content;
# measured reliable across repeated runs during development of this test).
head -c 20000000 /dev/urandom > "$target/top-level-filler.bin"

second_run_log="$(mktemp)"
set +e
with_docker_stub bash "$bundle/install.sh" --target "$target" --yes --no-deploy >"$second_run_log" 2>&1
second_run_status=$?
set -e
[[ "$second_run_status" -eq 0 ]] \
  || fail "a second install into the same target must exit 0 (got $second_run_status): $(cat "$second_run_log")"
pass "a second install into the same target succeeds"

# Assets must be seeded on EVERY run, not only the first: a bumped
# GRAFANA_DATABRIDGE_PLUGIN would otherwise send Grafana looking for a version
# it cannot reach, and the preinstall is boot-blocking.
# The swarm overlays pin `name: ${ENV}-<volume>`, so the real volume is
# `prod-grafana-data` — seeding `<stack>_grafana-data` would create an unused
# volume and leave Grafana unable to boot.
assert_contains "$(cat "$DOCKER_LOG")" "prod-grafana-data" "grafana plugins are seeded into the ENV-prefixed volume"
assert_contains "$(cat "$DOCKER_LOG")" "prod-cdn-server-storage" "CDN packages are seeded into the ENV-prefixed volume"
