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
  local need_kb dir
  need_kb="$(( $(json_get uncompressed_bytes 0) / 1024 + 2097152 ))"
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
    cat "$BUNDLE/images/$base" "$BUNDLE/images/$base".[0-9][0-9] 2>/dev/null \
      | zstd -dc | docker load
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) TARGET="$2"; shift 2 ;;
      --yes)    ASSUME_YES=true; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  preflight
  load_images
}

main "$@"
