#!/usr/bin/env bash
# =============================================================================
# install.sh — install or update the platform from an offline bundle.
# =============================================================================
# Same script for a first install and for an update; the only difference is
# what is already on the machine. Run it from inside the unpacked bundle.
#
# There is deliberately NO teardown option: deploy.sh's teardown flag removes
# caddy_data, hence the CA, hence every workstation that trusted the cert.
# =============================================================================
set -euo pipefail
BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${TARGET:-$HOME/industream-platform}"
ASSUME_YES=false
NO_DEPLOY=false
# Deploy-call overrides — empty means "take it from bundle.json". PROJECT is
# also read by volume_name() (below) so an operator-supplied --project lands
# on the SAME compose project the deploy itself uses; guessing two different
# values here is exactly how a volume gets seeded under a name nothing reads.
RUNTIME_OPT="" EDITION_OPT="" ENV_OPT="" GROUPS_OPT="" STACK_OPT="" PROJECT=""

die() { echo "✗ $*" >&2; exit 1; }

# Read one key from bundle.json, with a fallback for keys a bundle may not
# carry (the swarm stack name is a site property, not a build property).
json_get() {
  python3 -c "
import json,sys
d=json.load(open('$BUNDLE/bundle.json'))
print(d.get('$1', '''${2:-}'''))"
}

# Bundle values as they will actually be used, i.e. an operator override if
# one was given, else whatever the bundle was built with. Used by BOTH the
# deploy call and the asset seeder below, so the two can never disagree.
resolved_runtime() { [[ -n "$RUNTIME_OPT" ]] && echo "$RUNTIME_OPT" || json_get runtime; }
resolved_edition() { [[ -n "$EDITION_OPT" ]] && echo "$EDITION_OPT" || json_get edition; }
resolved_env()     { [[ -n "$ENV_OPT" ]]     && echo "$ENV_OPT"     || json_get env; }
resolved_groups()  { [[ -n "$GROUPS_OPT" ]]  && echo "$GROUPS_OPT"  || json_get groups; }

# Compose has no fixed volume-naming convention the way the swarm overlays do
# (deploy.sh treats --project as an arbitrary value unrelated to --env) — this
# is the ONE place that default gets decided, so volume_name() and run_deploy()
# stay in agreement by construction rather than by two matching literals.
compose_project() { echo "${PROJECT:-fm-$(resolved_env)}"; }

preflight() {
  command -v docker >/dev/null || die "docker is not installed"

  local runtime; runtime="$(resolved_runtime)"
  if [[ "$runtime" == swarm ]]; then
    [[ "$(docker info -f '{{.Swarm.LocalNodeState}}' 2>/dev/null)" == active ]] \
      || die "this node is not in an active swarm — run 'docker swarm init' first"
  fi

  # Docker 29 stores images under /var/lib/containerd, NOT /var/lib/docker.
  # Checking only the latter is how a machine froze mid-install with 22GB
  # landing on a 20GB root.
  #
  # bundle.json is untrusted data (MANIFEST.sha256 is a checksum, not a
  # signature) — validate uncompressed_bytes is a plain non-negative integer
  # BEFORE any arithmetic use of it, so a crafted value dies cleanly here
  # instead of ever being handed to bash arithmetic unchecked.
  local raw_bytes; raw_bytes="$(json_get uncompressed_bytes 0)"
  [[ "$raw_bytes" =~ ^[0-9]+$ ]] || die "bundle.json has a malformed uncompressed_bytes value"
  local need_kb dir
  need_kb="$(( raw_bytes / 1024 + 2097152 ))"
  for dir in /var/lib/containerd /var/lib/docker; do
    [[ -d "$dir" ]] || continue
    local free_kb; free_kb="$(df -Pk "$dir" | awk 'NR==2{print $4}')"
    (( free_kb >= need_kb )) \
      || die "not enough free space on $dir: $((free_kb/1024))MB free, $((need_kb/1024))MB needed"
  done

  # A wrong clock breaks proxy TLS and Hub JWT with errors that never mention
  # time — the most expensive class of failure to diagnose on site.
  if command -v timedatectl >/dev/null; then
    timedatectl show -p NTPSynchronized --value | grep -q yes \
      || echo "⚠ clock is not NTP-synchronised — TLS and JWT failures will look like anything but a clock problem" >&2
  fi

  echo "▶ verifying the bundle"
  bash "$BUNDLE/tree/unified/scripts/airgap.sh" verify "$BUNDLE" || exit 1
}

load_images() {
  local base
  # Parts are streamed straight into docker load: never reassembled, so the
  # bundle is never duplicated on a disk that may not have room for it.
  for base in $(ls "$BUNDLE/images" 2>/dev/null | sed 's/\.[0-9][0-9]$//' | sort -u); do
    echo "▶ loading $base"
    # An unsplit group has only "$base"; a split group has only "$base".NN
    # (cmd_split removes the unsuffixed original). Feeding `cat` a path that
    # is guaranteed not to exist either way makes it exit 1 even though it
    # streamed everything real — which pipefail then turns into a script
    # abort. Build the real file list first instead.
    local files=() part
    [[ -e "$BUNDLE/images/$base" ]] && files+=("$BUNDLE/images/$base")
    for part in "$BUNDLE/images/$base".[0-9][0-9]; do
      [[ -e "$part" ]] && files+=("$part")
    done
    (( ${#files[@]} > 0 )) || die "no readable part found for $base"
    cat "${files[@]}" | zstd -dc | docker load
  done
}

# Never `git reset --hard`, never a bare `cp -r`: both have already destroyed
# untracked site state on these hosts. rsync with hard exclusions, after a
# snapshot that makes the previous tree recoverable.
sync_tree() {
  mkdir -p "$TARGET/backups"
  if [[ -d "$TARGET/unified" ]]; then
    local snap; snap="$TARGET/backups/tree-$(date +%Y%m%d-%H%M%S).tar.gz"
    echo "▶ snapshotting the current tree → $snap"
    tar czf "$snap" -C "$TARGET" --exclude=backups .
  fi
  echo "▶ syncing the tree"
  rsync -a --delete \
    --exclude='.env.*' \
    --exclude='secrets/' \
    --exclude='unified/custom/' \
    --exclude='unified/instances/' \
    --exclude='.deploy-state/' \
    --exclude='backups/' \
    "$BUNDLE/tree/" "$TARGET/"
  # The checkout is knowingly detached from origin: offline it will never take
  # another `git pull`, so record what it actually holds.
  printf 'commit=%s\nbundle=%s\ninstalled=%s\n' \
    "$(json_get commit)" "$(basename "$BUNDLE")" "$(date -Is)" > "$TARGET/AIRGAP_VERSION"
}

# Seeded on EVERY deploy, not only the first. GF_PLUGINS_PREINSTALL_SYNC is
# boot-blocking, so a plugin version bump with no reachable registry would stop
# Grafana from starting at all.
# Volume names differ per runtime, and NOT the way the `<stack>_<volume>`
# default would suggest: the swarm overlays pin an explicit
# `name: ${ENV}-<volume>` (runtime/swarm/monitoring.yml, core.yml), so the
# real volume is `prod-grafana-data`. Compose declares no name, so it gets the
# `<project>_<volume>` default. Seeding the wrong name silently creates an
# unused volume and leaves Grafana unable to boot.
volume_name() {
  if [[ "$(resolved_runtime)" == swarm ]]; then echo "$(resolved_env)-$1"
  else echo "$(compose_project)_$1"; fi
}

seed_assets() {
  seed_volume() {
    local vol="$1" src="$2" sub="${3:-}"
    [[ -d "$src" && -n "$(ls -A "$src")" ]] || return 0
    docker volume create "$vol" >/dev/null
    docker run --rm -v "$vol:/dest" -v "$src:/src:ro" alpine \
      sh -c "mkdir -p /dest/$sub && cp -a /src/. /dest/$sub"
  }
  echo "▶ seeding runtime assets"
  seed_volume "$(volume_name grafana-data)"       "$BUNDLE/assets/grafana-plugins"                 "plugins"
  seed_volume "$(volume_name cdn-server-storage)" "$BUNDLE/assets/cdn-packages/cdn-server-storage"
  seed_volume "$(volume_name cdn-cache-storage)"  "$BUNDLE/assets/cdn-packages/cdn-cache-storage"
}

# Closes the loop: replay the SAME deploy.sh that assembled the bundle's image
# set (airgap.sh's --list-images / verify), so what gets deployed never drifts
# from what was checked. --bundle is always taken from bundle.json and never
# overridden here — it selects the release dir carrying the full-ref
# ${X_IMAGE} vars (releases/bundle-platform-<ver>/), and the synced tree can
# carry more than one such dir (e.g. a leftover Forge bundle), at which point
# deploy.sh's auto-select refuses to guess and --bundle stops being optional.
run_deploy() {
  local runtime edition env_val groups bundle_ver
  runtime="$(resolved_runtime)"
  edition="$(resolved_edition)"
  env_val="$(resolved_env)"
  groups="$(resolved_groups)"
  bundle_ver="$(json_get bundle)"
  local args=(--runtime "$runtime" --edition "$edition" --env "$env_val" --airgap)
  [[ -n "$bundle_ver" ]] && args+=(--bundle "$bundle_ver")
  [[ -n "$groups" ]] && args+=(--groups "$groups")
  # deploy.sh requires --stack for swarm and --project for compose; compose_project()
  # is the SAME function volume_name() uses above, so the asset volumes and the
  # deploy always land under the same project name.
  if [[ "$runtime" == swarm ]]; then
    args+=(--stack "${STACK_OPT:-$(json_get stack industream-prod)}")
  else
    args+=(--project "$(compose_project)")
  fi
  echo "▶ deploying (--airgap)"
  ( cd "$TARGET/unified" && ./scripts/deploy.sh "${args[@]}" )
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)    TARGET="$2"; shift 2 ;;
      --yes)       ASSUME_YES=true; shift ;;
      --no-deploy) NO_DEPLOY=true; shift ;;
      --runtime)   RUNTIME_OPT="$2"; shift 2 ;;
      --edition)   EDITION_OPT="$2"; shift 2 ;;
      --env)       ENV_OPT="$2"; shift 2 ;;
      --groups)    GROUPS_OPT="$2"; shift 2 ;;
      --stack)     STACK_OPT="$2"; shift 2 ;;
      --project)   PROJECT="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  preflight
  load_images
  sync_tree
  seed_assets
  if [[ "$NO_DEPLOY" == true ]]; then
    echo "▶ --no-deploy: tree synced and assets seeded, deploy skipped"
  else
    run_deploy
  fi
}

main "$@"
