#!/bin/bash
# =============================================================================
# TIMESERIES BACKUP DISPATCHER
# =============================================================================
# Branches on TIMESERIES_BACKEND={influx,timescale} and invokes the matching
# native backup script. Lets the same swarm-cronjob service handle either
# backend without redeploying the stack file.
#
# Why a dispatcher rather than two parallel cron jobs?
#   • TimescaleDB ships as a Postgres extension — there is at most ONE
#     timeseries backend deployed per environment, never both.
#   • Switching from Influx to Timescale only requires flipping the env var
#     in .env, not editing docker-stack.backup.yml.
# =============================================================================

set -uo pipefail

BACKEND="${TIMESERIES_BACKEND:-influx}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

case "$BACKEND" in
    influx|influxdb)
        log "TIMESERIES_BACKEND=influx → delegating to backup-influxdb.sh"
        exec bash "${SCRIPT_DIR}/backup-influxdb.sh" "$@"
        ;;
    timescale|timescaledb)
        log "TIMESERIES_BACKEND=timescale → delegating to backup-timescaledb.sh"
        exec bash "${SCRIPT_DIR}/backup-timescaledb.sh" "$@"
        ;;
    none|"")
        log "TIMESERIES_BACKEND=none — skipping timeseries backup."
        exit 0
        ;;
    *)
        log "ERROR: unknown TIMESERIES_BACKEND='${BACKEND}'. Expected: influx|timescale|none."
        exit 1
        ;;
esac
