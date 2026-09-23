#!/usr/bin/env bash
# Prints "<limit> <reservation>" for the swarm InfluxDB service.
#
# InfluxDB's TSI index and page cache count against its cgroup limit, so a fixed
# 768M starves any site holding real history. The limit is sized at 40% of this
# node's RAM (the rest of the stack needs the remainder), never below the former
# 768M/256M defaults. INFLUXDB_MEMORY_LIMIT / INFLUXDB_MEMORY_RESERVATION pinned
# in .env.<env> win. Reads the node it runs on: Industream swarms are single-node.
set -euo pipefail

if [[ -n "${INFLUXDB_MEMORY_LIMIT:-}" ]]; then
  echo "${INFLUXDB_MEMORY_LIMIT} ${INFLUXDB_MEMORY_RESERVATION:-256M}"
  exit 0
fi

meminfo="${MEMINFO:-/proc/meminfo}"
total_kib="$(awk '/^MemTotal:/ {print $2}' "$meminfo")"
[[ "$total_kib" =~ ^[0-9]+$ ]] || { echo "✗ cannot read MemTotal from ${meminfo}" >&2; exit 1; }

limit_mib=$(( total_kib / 1024 * 40 / 100 / 256 * 256 ))
(( limit_mib < 768 )) && limit_mib=768
reservation_mib=$(( limit_mib / 4 ))
(( reservation_mib < 256 )) && reservation_mib=256
echo "${limit_mib}M ${INFLUXDB_MEMORY_RESERVATION:-${reservation_mib}M}"
