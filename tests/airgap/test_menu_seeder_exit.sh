#!/usr/bin/env bash
# A rejected tile only ever reached stderr — which deploy.sh discards — and the
# seeder still exited 0. A run where the Hub backend refused every single tile
# was therefore indistinguishable from one that worked, and the deploy printed
# "✓ Hub menu apps seeded" over an empty launchpad.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEEDER="$REPO_ROOT/scripts/setup/seed-menu-apps-stack.sh"

# The seeder resolves a container with `docker ps`, then reads an HTTP status
# out of `docker exec … wget`. Feeding that status is all a stub needs to do.
run_with_status() {  # run_with_status <http-status> -> exit code
  local status="$1" stub_dir
  stub_dir="$(mktemp -d)"
  cat > "$stub_dir/docker" <<STUB
#!/usr/bin/env bash
case "\$1" in
  ps)   echo "deadbeefcafe" ;;
  exec) echo "${status}" ;;
esac
exit 0
STUB
  chmod +x "$stub_dir/docker"
  PATH="$stub_dir:$PATH" bash "$SEEDER" \
    --domain example.test --runtime swarm --stack teststack >/dev/null 2>&1
  echo $?
}

assert_eq "$(run_with_status 201)" "0" "every tile created → exit 0"
assert_eq "$(run_with_status 500)" "1" "a rejected tile → non-zero exit, not a silent success"

# 409 means the tile exists; the seeder then PUTs. The stub answers 409 to both
# calls, so the PUT does not return 200 either — that is a failure as well.
assert_eq "$(run_with_status 409)" "1" "a PUT that does not return 200 → non-zero exit"

# The failure must name itself, not just set a code: the operator reads the log.
stub_dir="$(mktemp -d)"
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  ps)   echo "deadbeefcafe" ;;
  exec) echo "500" ;;
esac
exit 0
STUB
chmod +x "$stub_dir/docker"
out="$(PATH="$stub_dir:$PATH" bash "$SEEDER" --domain example.test --runtime swarm --stack teststack 2>&1 || true)"
assert_contains "$out" "rejected" "the failure says how many tiles were rejected"
[[ "$out" != *"✓ Done."* ]] || fail "a failed run must not print the success line"
pass "a failed run prints no success line"
