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

die() { echo "✗ $*" >&2; exit 1; }

# Read one key from bundle.json, with a fallback for keys a bundle may not
# carry (the swarm stack name is a site property, not a build property).
json_get() {
  python3 -c "
import json,sys
d=json.load(open('$BUNDLE/bundle.json'))
print(d.get('$1', '''${2:-}'''))"
}

preflight() {
  command -v docker >/dev/null || die "docker is not installed"

  local runtime; runtime="$(json_get runtime)"
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
    local snap="$TARGET/backups/tree-$(date +%Y%m%d-%H%M%S).tar.gz"
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
  if [[ "$(json_get runtime)" == swarm ]]; then echo "$(json_get env)-$1"
  else echo "${PROJECT:-fm-$(json_get env)}_$1"; fi
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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)    TARGET="$2"; shift 2 ;;
      --yes)       ASSUME_YES=true; shift ;;
      --no-deploy) NO_DEPLOY=true; shift ;;
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
}

main "$@"
