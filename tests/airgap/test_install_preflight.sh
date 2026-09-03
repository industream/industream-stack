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

# --- success path: a valid bundle must actually load, both unsplit and split ---
# `cat "$base" "$base".NN` always fed `cat` one path guaranteed not to exist
# (the unsuffixed original for a split group; the ".NN" glob for an unsplit
# one), so `cat` exited 1 even though it streamed everything real — and under
# `pipefail`, that killed the script before any group finished. Build two
# fixture groups (one whole, one split) to prove the load actually completes.
#
# lib.sh's `docker` stub never reads its stdin before exiting, which is fine
# for every other test (nothing pipes real bytes into it) but here `docker
# load` is fed a real decompressed stream: once the stub exits without
# draining it, `zstd` gets SIGPIPE writing to a reader that already closed —
# a test-only artifact of the stub, not a bug in install.sh (a real `docker
# load` does read all of stdin). A local stub that also drains "load"'s
# stdin avoids it without touching the shared lib.sh helper.
with_docker_stub_draining() {
  local stub_dir; stub_dir="$(mktemp -d)"
  DOCKER_LOG="$(mktemp)"; export DOCKER_LOG
  cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
case "$1" in
  info)   echo "active" ;;
  image)  exit 1 ;;
  volume) echo "vol" ;;
  load)   cat >/dev/null ;;
esac
exit 0
STUB
  chmod +x "$stub_dir/docker"
  PATH="$stub_dir:$PATH" "$@"
}

out2="$(mktemp -d)"
prep2_out="$(mktemp)"
with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$out2" --skip-images --skip-assets > "$prep2_out"
bundle2="$(tail -1 "$prep2_out")"

fake_tar="$(mktemp)"; head -c 200000 /dev/urandom > "$fake_tar"
zstd -q -3 -f -o "$bundle2/images/core.tar.zst" "$fake_tar"          # unsplit group
zstd -q -3 -f -o "$fake_tar.zst" "$fake_tar"
split -d -a 2 -b 60000 "$fake_tar.zst" "$bundle2/images/workers.tar.zst."
rm -f "$bundle2/images/workers.tar.zst"                              # cmd_split removes the original
rm -f "$fake_tar" "$fake_tar.zst"

# bundle.json's uncompressed_bytes must stay small enough that the fixture
# "passes" the disk preflight on any machine running this test.
python3 - "$bundle2/bundle.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["uncompressed_bytes"] = 1024
json.dump(d, open(p, "w"))
PY
( cd "$bundle2" && find images -type f -print0 | xargs -0 sha256sum > PARTS.sha256 )
( cd "$bundle2" && find . -type f ! -name MANIFEST.sha256 -print0 | xargs -0 sha256sum > MANIFEST.sha256 )

install2_out="$(mktemp)"
install2_status=0
with_docker_stub_draining bash "$bundle2/install.sh" --target "$(mktemp -d)" --yes > "$install2_out" 2>&1 \
  || install2_status=$?
assert_eq "$install2_status" "0" "install.sh exits 0 on a valid bundle with images to load"
load_count="$(grep -c '^load' "$DOCKER_LOG" 2>/dev/null || true)"
assert_eq "$load_count" "2" "docker load ran once per group (unsplit and split)"

# --- clock preflight: exercise both the warning and the skip branches ---
# A stub `timedatectl` prepended on PATH (same host-safe pattern as
# with_docker_stub) drives the "not synchronised" warning without touching
# the real clock.
with_timedatectl_stub() {
  local synced="$1"; shift
  local td_dir; td_dir="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho %s\n' "$synced" > "$td_dir/timedatectl"
  chmod +x "$td_dir/timedatectl"
  PATH="$td_dir:$PATH" "$@"
}

clock_out="$(mktemp)"
with_docker_stub_draining with_timedatectl_stub no bash "$bundle2/install.sh" \
  --target "$(mktemp -d)" --yes > "$clock_out" 2>&1 || true
grep -q "NTP-synchronised" "$clock_out" \
  || fail "no warning printed when timedatectl reports NTPSynchronized=no"
pass "clock preflight warns when the clock is not NTP-synchronised"

clock_out2="$(mktemp)"
with_docker_stub_draining with_timedatectl_stub yes bash "$bundle2/install.sh" \
  --target "$(mktemp -d)" --yes > "$clock_out2" 2>&1 || true
if grep -q "NTP-synchronised" "$clock_out2"; then
  fail "a warning was printed even though timedatectl reports NTPSynchronized=yes"
fi
pass "clock preflight is silent when the clock is synchronised"

# `command -v timedatectl` absent must skip the check, not fail the install.
# Mirror every real PATH directory into one flat stub dir via symlinks,
# EXCLUDING timedatectl specifically — this hides only that one binary
# without disturbing anything else the script (or deploy.sh underneath it)
# needs to resolve.
without_timedatectl() {
  local mirror; mirror="$(mktemp -d)"
  local d f name
  IFS=: read -ra dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
      [[ -f "$f" && -x "$f" ]] || continue
      name="$(basename "$f")"
      [[ "$name" == timedatectl ]] && continue
      [[ -e "$mirror/$name" ]] || ln -s "$f" "$mirror/$name" 2>/dev/null || true
    done
  done
  PATH="$mirror" "$@"
}

clock_out3="$(mktemp)"
clock3_status=0
without_timedatectl with_docker_stub_draining bash "$bundle2/install.sh" \
  --target "$(mktemp -d)" --yes > "$clock_out3" 2>&1 || clock3_status=$?
assert_eq "$clock3_status" "0" "install.sh still succeeds when timedatectl is entirely absent"
if grep -q "NTP-synchronised" "$clock_out3"; then
  fail "a clock warning was printed even though timedatectl does not exist"
fi
pass "clock preflight silently skips when timedatectl is absent"
