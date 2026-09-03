#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"
out="$(mktemp -d)"; target="$(mktemp -d)"
bundle="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$out" --skip-images --skip-assets | tail -1)"

# Disk space is checked on /var/lib/containerd as well as /var/lib/docker:
# Docker 29 stores images in the former (22GB vs 4KB measured), and checking
# only the latter is how a machine froze mid-install.
assert_contains "$(grep -c 'containerd' "$REPO_ROOT/unified/scripts/airgap-install.sh")" "" ""
grep -q '/var/lib/containerd' "$REPO_ROOT/unified/scripts/airgap-install.sh" \
  || fail "the disk preflight ignores /var/lib/containerd"
pass "disk preflight covers containerd"

# Clock drift breaks proxy TLS and Hub JWT with errors that never mention time.
grep -q 'clock\|chrony\|timedatectl' "$REPO_ROOT/unified/scripts/airgap-install.sh" \
  || fail "no clock preflight"
pass "clock preflight present"

# install.sh must never offer a teardown: deploy.sh --down destroys caddy_data,
# hence the CA, hence every workstation that trusted the certificate.
if grep -q -- '--down' "$REPO_ROOT/unified/scripts/airgap-install.sh"; then
  fail "install.sh exposes --down"
fi
pass "install.sh exposes no --down"

# A bundle that does not verify must stop before Docker is touched.
# `with_docker_stub ... | tail -1` — or wrapping it in $(...) at all — would
# run the stub setup (which exports $DOCKER_LOG) in a subshell, discarding the
# export before this script could read the log back; capture to a file with
# plain redirection instead, as test_prepare_images.sh does.
echo tampered >> "$bundle/tree/unified/versions.env"
install_out="$(mktemp)"
with_docker_stub bash "$bundle/install.sh" --target "$target" --yes > "$install_out" 2>&1 || true
out_log="$(cat "$install_out")"
assert_contains "$out_log" "manifest mismatch" "install stops on a bad manifest"
if grep -q "load" "$DOCKER_LOG" 2>/dev/null; then fail "install loaded images despite a bad manifest"; fi
pass "no image was loaded after a failed verification"
