#!/usr/bin/env bash
# A service first deployed ONLINE carries a registry digest in its spec. Loading
# images from a bundle gives them different digests (docker save/load does not
# preserve the original), and --resolve-image never forbids re-resolving — so the
# task is rejected forever with "No such image: …@sha256:…".
#
# `stack deploy` only rewrites a service whose definition changed. A service whose
# image version did NOT change between bundles keeps its old, digest-pinned spec —
# which is why exactly the unchanged ones (logto, grafana, minio) stayed down on a
# real site while the other 42 came up.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

# Records `service update` calls so the test asserts on what would actually be
# issued, and answers `service inspect` with a digest-pinned image.
with_digest_stub() {  # with_digest_stub <cmd…>
  local stub_dir; stub_dir="$(mktemp -d)"
  cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
case "$1 $2" in
  "service ls")     echo "teststack_logto" ;;
  "service inspect") echo "ghcr.io/logto-io/logto:1.40.1@sha256:deadbeef" ;;
  "info")           echo "active" ;;
esac
exit 0
STUB
  chmod +x "$stub_dir/docker"
  PATH="$stub_dir:$PATH" "$@"
}

DOCKER_LOG="$(mktemp)"; export DOCKER_LOG
with_digest_stub bash "$REPO_ROOT/scripts/setup/unpin-image-digests.sh" teststack >/dev/null 2>&1 \
  || fail "the script must succeed over a stack with a digest-pinned service"
pass "the script runs over a stack"

assert_contains "$(cat "$DOCKER_LOG")" "service update --no-resolve-image" \
  "the update is issued with --no-resolve-image — resolving is what pinned the digest"

assert_contains "$(cat "$DOCKER_LOG")" "ghcr.io/logto-io/logto:1.40.1" \
  "the image is re-set to the bare tag"

[[ "$(cat "$DOCKER_LOG")" != *"1.40.1@sha256"* ]] \
  || fail "the digest must be stripped, not carried over"
pass "the digest is stripped from the new image reference"

# A service with no digest is already correct. Re-issuing an update would restart
# it for nothing, on every single deploy.
: > "$DOCKER_LOG"
stub_dir="$(mktemp -d)"
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
case "$1 $2" in
  "service ls")      echo "teststack_logto" ;;
  "service inspect") echo "ghcr.io/logto-io/logto:1.40.1" ;;
esac
exit 0
STUB
chmod +x "$stub_dir/docker"
PATH="$stub_dir:$PATH" bash "$REPO_ROOT/scripts/setup/unpin-image-digests.sh" teststack >/dev/null 2>&1 || true
[[ "$(cat "$DOCKER_LOG")" != *"service update"* ]] \
  || fail "a service with no digest must be left alone"
pass "a service already free of a digest is left alone"
rm -rf "$stub_dir"
