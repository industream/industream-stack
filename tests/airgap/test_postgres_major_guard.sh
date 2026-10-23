#!/usr/bin/env bash
# A Postgres major bump on an existing volume (TimescaleDB pg17 → pg18) makes
# the new server refuse the old data directory and crash-loop. The guard must
# stop the deploy BEFORE the stack is touched and say what to do; a fresh
# volume or an unchanged major must go through untouched.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

GUARD=scripts/setup/check-postgres-major.sh
IMAGE="timescale/timescaledb:2.30.2-pg18"

# docker stub: STUB_VOLUME_EXISTS, STUB_DATA_MAJOR (empty = no PG_VERSION) and
# STUB_IMAGE_MAJOR drive the three facts the guard reads.
run_guard() {
  local stub_dir; stub_dir="$(mktemp -d)"
  cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "volume inspect") [[ "${STUB_VOLUME_EXISTS:-}" == 1 ]] || exit 1; echo '[]' ;;
  "image inspect")  printf 'PATH=/usr/bin\nPG_MAJOR=%s\n' "$STUB_IMAGE_MAJOR" ;;
  "run --rm")       [[ -n "${STUB_DATA_MAJOR:-}" ]] || exit 1; echo "$STUB_DATA_MAJOR" ;;
esac
exit 0
STUB
  chmod +x "$stub_dir/docker"
  PATH="$stub_dir:$PATH" bash "$GUARD" --volume prod-timescaledb-data --image "$IMAGE" 2>&1
}

# --- Major bump on existing data: refused, with the way out -------------------
set +e
out="$(STUB_VOLUME_EXISTS=1 STUB_DATA_MAJOR=17 STUB_IMAGE_MAJOR=18 run_guard)"; rc=$?
set -e
[[ $rc -ne 0 ]] || fail "a pg17 volume under a pg18 image must stop the deploy"
pass "a pg17 volume under a pg18 image stops the deploy"
assert_contains "$out" "prod-timescaledb-data" "the warning names the volume"
assert_contains "$out" "PostgreSQL 17" "the warning names the data's major"
assert_contains "$out" "PostgreSQL 18" "the warning names the image's major"
assert_contains "$out" "TIMESCALE_TIMESCALEDB_IMAGE=timescale/timescaledb:2.30.2-pg17" \
  "the warning gives the line that keeps the site on its current major"

# --- Nothing to protect: deploy goes on ---------------------------------------
STUB_VOLUME_EXISTS=0 STUB_IMAGE_MAJOR=18 run_guard >/dev/null || fail "a missing volume (fresh install) must pass"
pass "a fresh install (no volume yet) passes"

STUB_VOLUME_EXISTS=1 STUB_DATA_MAJOR='' STUB_IMAGE_MAJOR=18 run_guard >/dev/null || fail "an empty volume must pass"
pass "an existing but empty volume passes"

STUB_VOLUME_EXISTS=1 STUB_DATA_MAJOR=18 STUB_IMAGE_MAJOR=18 run_guard >/dev/null || fail "same major must pass"
pass "data and image on the same major pass"
