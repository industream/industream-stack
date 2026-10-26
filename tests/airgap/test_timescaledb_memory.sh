#!/usr/bin/env bash
# TimescaleDB is the store every dashboard and report reads from. A fixed 1G
# limit left Postgres tuned for 1G (shared_buffers 256MB, max_connections 25)
# whatever the node, and timescaledb-tune only runs when the volume is created.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

sizer="scripts/setup/timescaledb-memory.sh"

fake_meminfo() {  # fake_meminfo <total_kib>
  local file; file="$(mktemp)"
  printf 'MemTotal:       %s kB\nMemFree:        1024 kB\n' "$1" > "$file"
  echo "$file"
}

assert_eq "$(NPROC=8 MEMINFO="$(fake_meminfo 16777216)" bash "$sizer")" "6400M 1600M 4.0 1600MB 4800MB" \
  "a 16 GiB / 8 CPU node gives TimescaleDB 40% of its RAM, half its CPUs, and Postgres caches sized from that limit"

assert_eq "$(NPROC=2 MEMINFO="$(fake_meminfo 2097152)" bash "$sizer")" "1024M 256M 2.0 256MB 768MB" \
  "a small node never goes below the previous 1024M/256M, 2 CPU defaults"

assert_eq "$(TIMESCALEDB_MEMORY_LIMIT=12G NPROC=8 MEMINFO="$(fake_meminfo 16777216)" bash "$sizer")" "12288M 3072M 4.0 3072MB 9216MB" \
  "a limit pinned in .env.<env> wins, and the Postgres caches follow it"

assert_eq "$(TIMESCALEDB_MEMORY_LIMIT=4096M TIMESCALEDB_MEMORY_RESERVATION=2G TIMESCALEDB_CPUS=3 NPROC=8 bash "$sizer")" \
  "4096M 2G 3 1024MB 3072MB" "a pinned reservation and CPU count are kept as is"

assert_fails env MEMINFO=/nonexistent bash "$sizer" "an unreadable meminfo is an error, not a silent 0M limit"
assert_fails env TIMESCALEDB_MEMORY_LIMIT=lots bash "$sizer" "an unparsable pinned limit is an error"

# Renders the file as `stack deploy` does, so a YAML or interpolation mistake fails here.
timescale_render() {  # timescale_render <limit> <shared_buffers> → "<limit bytes> <shared_buffers flag>"
  TIMESCALEDB_MEMORY_LIMIT="$1" TIMESCALEDB_SHARED_BUFFERS="$2" ENV=prod \
    docker stack config -c unified/base/timescale.yml -c unified/runtime/swarm/timescale.yml 2>/dev/null \
    | awk '/^  [a-z]/ {in_tsdb = ($1 == "timescaledb:")}
           in_tsdb && /memory:/ && !limit {gsub(/"/, "", $2); limit = $2}
           in_tsdb && /shared_buffers=/ {gsub(/[ "-]/, "", $0); flag = $0}
           END {print limit, flag}'
}
if docker stack config --help >/dev/null 2>&1; then
  assert_eq "$(timescale_render "" "")" "1073741824 shared_buffers=256MB" \
    "without the env, swarm keeps the former 1G limit and the tuned 256MB cache"
  assert_eq "$(timescale_render 6400M 1600MB)" "6710886400 shared_buffers=1600MB" \
    "the swarm TimescaleDB limit and Postgres cache come from the env"
else
  echo "  ⚠ docker stack config unavailable — swarm rendering not checked"
fi

deploy="$(cat unified/scripts/deploy.sh)"
assert_contains "$deploy" 'timescaledb-memory.sh' "the swarm deploy sizes TimescaleDB before stack deploy"
