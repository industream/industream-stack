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

# A tree path this bundle (the "old" version) ships but a later bundle will
# NOT ship — e.g. a group overlay retired between releases. Setup for the
# stale-prune regression below: added directly to the bundle's tree, same as
# the marker file above, so it needs no MANIFEST.sha256 regeneration either.
mkdir -p "$bundle/tree/unified/base"
echo "legacy-overlay" > "$bundle/tree/unified/base/legacy-group.yml"

# Pre-existing site state that MUST survive an update. All five have already
# been clobbered on these hosts.
mkdir -p "$target/unified/custom" "$target/secrets/prod" "$target/unified/instances" "$target/.deploy-state"
echo "SITE_SECRET=keepme"   > "$target/unified/.env.prod"
echo "custom-overlay"       > "$target/unified/custom/site.yml"
echo "s3cret"               > "$target/secrets/prod/hub_backend_admin_password"
echo "instance-data"        > "$target/unified/instances/site.yml"
echo "deploy-state-data"    > "$target/.deploy-state/state.json"

# A site-local file at a path NOBODY ever put on the exclude list — unlike
# the paths above, which are all named in sync_tree's --exclude flags. Under
# the old blocklist design (rsync --delete plus a hand-maintained exclude
# list) this file sits on the target, is absent from the bundle's tree, and
# matches no exclude pattern, so --delete removes it — exactly the class of
# bug that deleted unified/base/certs/ on a real site before certs/ was
# added to the list. Under the allowlist design this file was never shipped
# by any bundle, so it can never be a stale-prune candidate either: it is
# structurally safe rather than safe-by-having-been-remembered.
mkdir -p "$target/unified/base"
echo "operator-local-config" > "$target/unified/base/some-operator-file.conf"

# Site-local TLS material: gitignored (`certs/` in .gitignore), so `git
# archive` never puts it in the bundle's tree, and runtime/swarm/monitoring.yml
# bind-mounts base/certs/${INDUSTREAM_DOMAIN}.crt straight into Grafana — a
# real air-gapped site lost this directory entirely on update, and Grafana
# then refused to start ("bind source path does not exist"). Real key/cert
# content, not a placeholder, so a byte-for-byte compare actually proves
# something.
mkdir -p "$target/unified/base/certs"
echo "FAKE-CERT-CONTENT" > "$target/unified/base/certs/site.example.crt"
echo "FAKE-KEY-CONTENT"  > "$target/unified/base/certs/site.example.key"

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
assert_eq "$(cat "$target/unified/base/certs/site.example.crt")" "FAKE-CERT-CONTENT" \
  "unified/base/certs/ (site TLS material) survives the sync"
assert_eq "$(cat "$target/unified/base/certs/site.example.key")" "FAKE-KEY-CONTENT" \
  "unified/base/certs/ key file survives the sync"
assert_eq "$(cat "$target/unified/base/some-operator-file.conf")" "operator-local-config" \
  "a site-local file at a path nobody excludes survives an update (this is the assertion the cert-loss bug would have failed)"
assert_eq "$(cat "$target/unified/base/legacy-group.yml")" "legacy-overlay" \
  "a bundle-shipped file arrives on install (setup for the stale-prune regression below)"
[[ -f "$target/unified/scripts/deploy.sh" ]] || fail "the tree was not synced"
pass "the tree was synced"
assert_eq "$(cat "$target/scripts/backups/regression-marker.sh")" "backup-tooling-marker" \
  "scripts/backups/ tooling reaches the target, not just the rollback snapshot dir"
[[ -f "$target/AIRGAP_VERSION" ]] || fail "AIRGAP_VERSION not written"
pass "AIRGAP_VERSION written"
[[ -f "$target/AIRGAP_TREE_MANIFEST" ]] || fail "AIRGAP_TREE_MANIFEST not written"
pass "AIRGAP_TREE_MANIFEST written"
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

# Simulate the next bundle in the series dropping the group overlay it used
# to ship (e.g. a group retired between releases). AIRGAP_TREE_MANIFEST from
# the first run above still lists it, so this second install is the real
# test of allowlist-based pruning: the file must be removed, even though
# nothing on the exclude list ever named it — leaving it would mean
# deploy.sh's `-f base/*.yml` glob keeps picking up a config that no longer
# corresponds to any deployed group.
rm -f "$bundle/tree/unified/base/legacy-group.yml"

# The trap one level below the allowlist: a bundle's tree DOES carry paths the
# rsync excludes — `prepare` resolves unified/.env.<env> into it, and a real
# bundle also carries unified/custom/README.md and unified/instances/.gitignore.
# Recording those in the manifest as "delivered" would make the very next
# bundle that stops shipping one (built for a different --env, say) delete the
# SITE's file at that path — the same data loss, one level down. Dropping
# .env.prod from this second bundle is exactly that scenario; the site's own
# .env.prod, asserted below, must not move.
[[ -e "$bundle/tree/unified/.env.prod" ]] \
  || fail "fixture assumption broken: the bundle's tree should carry unified/.env.prod (an rsync-excluded path)"
rm -f "$bundle/tree/unified/.env.prod"

second_run_log="$(mktemp)"
set +e
with_docker_stub bash "$bundle/install.sh" --target "$target" --yes --no-deploy >"$second_run_log" 2>&1
second_run_status=$?
set -e
[[ "$second_run_status" -eq 0 ]] \
  || fail "a second install into the same target must exit 0 (got $second_run_status): $(cat "$second_run_log")"
pass "a second install into the same target succeeds"

# The file the first bundle shipped and the second no longer does must be
# gone — the manifest diff (previous set minus current set) is what now
# stands in for rsync --delete's blanket removal.
[[ ! -e "$target/unified/base/legacy-group.yml" ]] \
  || fail "a file the previous bundle shipped and this one no longer ships must be pruned from the target"
pass "a file dropped between successive bundles is pruned from the target"

# The unexcluded site-local file must still be untouched on this SECOND run
# too, now that AIRGAP_TREE_MANIFEST actually exists and the real
# allowlist-diff logic ran (the first run above only proved the "no manifest
# yet" safety fallback). It was never in any bundle's manifest, so it is
# never a candidate for removal, proving the property structurally rather
# than by the transitional skip.
assert_eq "$(cat "$target/unified/base/some-operator-file.conf")" "operator-local-config" \
  "the unexcluded site-local file also survives a second update, once real manifest-diff pruning is active"

# An rsync-excluded path the previous bundle carried but never copied must not
# be a prune candidate: the file on the target is the SITE's, not the bundle's.
assert_eq "$(cat "$target/unified/.env.prod")" "SITE_SECRET=keepme" \
  "the site's .env survives a bundle that stops shipping that env's file (excluded paths are never prune candidates)"

# Assets must be seeded on EVERY run, not only the first: a bumped
# GRAFANA_DATABRIDGE_PLUGIN would otherwise send Grafana looking for a version
# it cannot reach, and the preinstall is boot-blocking.
# The swarm overlays pin `name: ${ENV}-<volume>`, so the real volume is
# `prod-grafana-data` — seeding `<stack>_grafana-data` would create an unused
# volume and leave Grafana unable to boot.
assert_contains "$(cat "$DOCKER_LOG")" "prod-grafana-data" "grafana plugins are seeded into the ENV-prefixed volume"
assert_contains "$(cat "$DOCKER_LOG")" "prod-cdn-server-storage" "CDN packages are seeded into the ENV-prefixed volume"
