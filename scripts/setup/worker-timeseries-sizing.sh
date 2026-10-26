#!/usr/bin/env bash
# Prints "<memory limit> <memory reservation> <cpus>" for the swarm worker-timeseries service.
#
# worker-timeseries writes every flow to DataBridge; bigger nodes carry bigger databases and more flows. The
# limit is 5% of this node's RAM, between 512M and 2G, half of it reserved; CPUs are a quarter of the node's,
# between 1 and 4. WORKER_TIMESERIES_MEMORY_LIMIT / _MEMORY_RESERVATION / WORKER_TIMESERIES_CPUS pinned in
# .env.<env> win. Reads the node it runs on: Industream swarms are single-node.
set -euo pipefail

to_mib() {  # to_mib <size with M or G suffix> → MiB
  case "$1" in
    *[0-9]G) echo $(( ${1%G} * 1024 )) ;;
    *[0-9]M) echo "${1%M}" ;;
    *) echo "✗ cannot parse WORKER_TIMESERIES_MEMORY_LIMIT '$1' (use e.g. 1024M or 1G)" >&2; return 1 ;;
  esac
}

if [[ -n "${WORKER_TIMESERIES_MEMORY_LIMIT:-}" ]]; then
  limit_mib="$(to_mib "$WORKER_TIMESERIES_MEMORY_LIMIT")"
else
  meminfo="${MEMINFO:-/proc/meminfo}"
  total_kib="$(awk '/^MemTotal:/ {print $2}' "$meminfo")"
  [[ "$total_kib" =~ ^[0-9]+$ ]] || { echo "✗ cannot read MemTotal from ${meminfo}" >&2; exit 1; }
  limit_mib=$(( total_kib / 1024 * 5 / 100 / 128 * 128 ))
  (( limit_mib < 512 )) && limit_mib=512
  (( limit_mib > 2048 )) && limit_mib=2048
fi

if [[ -n "${WORKER_TIMESERIES_CPUS:-}" ]]; then
  cpus="$WORKER_TIMESERIES_CPUS"
else
  quarter=$(( ${NPROC:-$(nproc)} / 4 ))
  (( quarter < 1 )) && quarter=1
  (( quarter > 4 )) && quarter=4
  cpus="${quarter}.0"
fi

echo "${limit_mib}M ${WORKER_TIMESERIES_MEMORY_RESERVATION:-$(( limit_mib / 2 ))M} ${cpus}"
