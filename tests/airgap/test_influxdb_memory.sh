#!/usr/bin/env bash
# InfluxDB's index and page cache count against its cgroup limit. A fixed 768M
# starved a site holding real history (slow Grafana, high load with no
# acquisition), while the same stack was fine on a node with little data.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

sizer="scripts/setup/influxdb-memory.sh"

fake_meminfo() {  # fake_meminfo <total_kib>
  local file; file="$(mktemp)"
  printf 'MemTotal:       %s kB\nMemFree:        1024 kB\n' "$1" > "$file"
  echo "$file"
}

assert_eq "$(MEMINFO="$(fake_meminfo 16777216)" bash "$sizer")" "6400M 1600M" \
  "a 16 GiB node gives InfluxDB 40% of its RAM and reserves a quarter of that"

assert_eq "$(MEMINFO="$(fake_meminfo 1048576)" bash "$sizer")" "768M 256M" \
  "a small node never goes below the previous 768M/256M defaults"

assert_eq "$(INFLUXDB_MEMORY_LIMIT=12G MEMINFO="$(fake_meminfo 16777216)" bash "$sizer")" "12G 256M" \
  "a limit pinned in .env.<env> wins over the RAM-based size"

assert_eq "$(INFLUXDB_MEMORY_LIMIT=12G INFLUXDB_MEMORY_RESERVATION=4G bash "$sizer")" "12G 4G" \
  "a pinned reservation is kept as is"

assert_eq "$(INFLUXDB_RAM_PERCENT=20 MEMINFO="$(fake_meminfo 16777216)" bash "$sizer")" "3072M 768M" \
  "next to TimescaleDB, InfluxDB gets the smaller share the deploy passes"

assert_fails env MEMINFO=/nonexistent bash "$sizer" "an unreadable meminfo is an error, not a silent 0M limit"

# Renders the file as `stack deploy` does: a bare ${VAR} inside a flow mapping
# `{ … }` is a YAML syntax error, so a text match alone is not enough.
influx_memory() {  # influx_memory <limit env value> → "<limit bytes> <reservation bytes>"
  INFLUXDB_MEMORY_LIMIT="$1" ENV=prod docker stack config -c unified/runtime/swarm/data.yml \
    | awk '/^  [a-z]/ {in_influx = ($1 == "influxdb:")}
           in_influx && /memory:/ {gsub(/"/, "", $2); printf "%s%s", separator, $2; separator = " "}'
}
if docker stack config --help >/dev/null 2>&1; then
  assert_eq "$(influx_memory "")" "805306368 268435456" "without the env, swarm keeps the former 768M/256M"
  assert_eq "$(influx_memory 6400M)" "6710886400 268435456" "the swarm InfluxDB limit comes from the env"
else
  echo "  ⚠ docker stack config unavailable — swarm rendering not checked"
fi

deploy="$(cat unified/scripts/deploy.sh)"
assert_contains "$deploy" 'influxdb-memory.sh' "the swarm deploy sizes InfluxDB before stack deploy"
