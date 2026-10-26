#!/usr/bin/env bash
# worker-timeseries writes every flow to DataBridge. At 0.25 CPU / 128 MiB, one 4000-tag OPC UA flow at
# 1 msg/s throttled it constantly and made it miss scheduler heartbeats, so the OPC box dropped values.
# Bigger nodes carry bigger databases and more flows, so the worker is sized from the node like the stores.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

sizer="scripts/setup/worker-timeseries-sizing.sh"

fake_meminfo() {  # fake_meminfo <total_kib>
  local file; file="$(mktemp)"
  printf 'MemTotal:       %s kB\nMemFree:        1024 kB\n' "$1" > "$file"
  echo "$file"
}

assert_eq "$(NPROC=8 MEMINFO="$(fake_meminfo 33554432)" bash "$sizer")" "1536M 768M 2.0" \
  "a 32 GiB / 8 CPU node gives the worker 5% of its RAM, half of it reserved, and a quarter of its CPUs"

assert_eq "$(NPROC=4 MEMINFO="$(fake_meminfo 8388608)" bash "$sizer")" "512M 256M 1.0" \
  "a small node never goes below 512M and one CPU"

assert_eq "$(NPROC=64 MEMINFO="$(fake_meminfo 268435456)" bash "$sizer")" "2048M 1024M 4.0" \
  "a very large node is capped at 2G and four CPUs"

assert_eq "$(WORKER_TIMESERIES_MEMORY_LIMIT=3072M WORKER_TIMESERIES_CPUS=3 NPROC=8 bash "$sizer")" "3072M 1536M 3" \
  "values pinned in .env.<env> win"

assert_fails env MEMINFO=/nonexistent bash "$sizer" "an unreadable meminfo is an error, not a silent 0M limit"

worker_render() {  # worker_render <limit> <cpus> → "<memory limit bytes> <cpu limit nano> <volume target>"
  WORKER_TIMESERIES_MEMORY_LIMIT="$1" WORKER_TIMESERIES_CPUS="$2" ENV=prod \
    docker stack config -c unified/base/workers.yml -c unified/runtime/swarm/workers.yml 2>/dev/null \
    | awk '/^  [a-z]/ {in_worker = ($1 == "worker-timeseries:")}
           in_worker && /memory:/ && !memory {gsub(/"/, "", $2); memory = $2}
           in_worker && /cpus:/ && !cpus {gsub(/"/, "", $2); cpus = $2}
           in_worker && /target: \/usr\/app\/data/ {target = $2}
           END {print memory, cpus, target}'
}
if docker stack config --help >/dev/null 2>&1; then
  assert_eq "$(worker_render "" "")" "536870912 1.0 /usr/app/data" \
    "without the env, swarm gives the worker 512M, one CPU and a persistent data volume"
  assert_eq "$(worker_render 1536M 2.0)" "1610612736 2.0 /usr/app/data" "the swarm worker limits come from the env"
else
  echo "  ⚠ docker stack config unavailable — swarm rendering not checked"
fi

deploy="$(cat unified/scripts/deploy.sh)"
assert_contains "$deploy" 'worker-timeseries-sizing.sh' "the swarm deploy sizes worker-timeseries before stack deploy"
