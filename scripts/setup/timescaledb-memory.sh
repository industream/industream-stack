#!/usr/bin/env bash
# Prints "<limit> <reservation> <cpus> <shared_buffers> <effective_cache_size>"
# for the swarm TimescaleDB service.
#
# TimescaleDB is the store every dashboard and report reads from. The limit is
# sized at 40% of this node's RAM, never below the former 1024M/256M, 2 CPU
# defaults; it gets half the node's CPUs. timescaledb-tune only runs when the
# volume is created, so the Postgres caches are derived from the limit here and
# passed on every deploy: shared_buffers 25%, effective_cache_size 75%.
# TIMESCALEDB_MEMORY_LIMIT / _RESERVATION / TIMESCALEDB_CPUS pinned in .env.<env>
# win. Reads the node it runs on: Industream swarms are single-node.
set -euo pipefail

to_mib() {  # to_mib <size with M or G suffix> → MiB
  case "$1" in
    *[0-9]G) echo $(( ${1%G} * 1024 )) ;;
    *[0-9]M) echo "${1%M}" ;;
    *) echo "✗ cannot parse TIMESCALEDB_MEMORY_LIMIT '$1' (use e.g. 4096M or 4G)" >&2; return 1 ;;
  esac
}

if [[ -n "${TIMESCALEDB_MEMORY_LIMIT:-}" ]]; then
  limit_mib="$(to_mib "$TIMESCALEDB_MEMORY_LIMIT")"
else
  meminfo="${MEMINFO:-/proc/meminfo}"
  total_kib="$(awk '/^MemTotal:/ {print $2}' "$meminfo")"
  [[ "$total_kib" =~ ^[0-9]+$ ]] || { echo "✗ cannot read MemTotal from ${meminfo}" >&2; exit 1; }
  limit_mib=$(( total_kib / 1024 * 40 / 100 / 256 * 256 ))
  (( limit_mib < 1024 )) && limit_mib=1024
fi

reservation_mib=$(( limit_mib / 4 ))
(( reservation_mib < 256 )) && reservation_mib=256

if [[ -n "${TIMESCALEDB_CPUS:-}" ]]; then
  cpus="$TIMESCALEDB_CPUS"
else
  half=$(( ${NPROC:-$(nproc)} / 2 ))
  (( half < 2 )) && half=2
  cpus="${half}.0"
fi

echo "${limit_mib}M ${TIMESCALEDB_MEMORY_RESERVATION:-${reservation_mib}M} ${cpus}" \
     "$(( limit_mib / 4 ))MB $(( limit_mib * 3 / 4 ))MB"
