#!/bin/bash
# =============================================================================
# TIMESCALEDB BACKUP
# =============================================================================
# TimescaleDB is a Postgres extension, so backups are logical pg_dump dumps
# of the timeseries database with the timescaledb extension preserved.
# For very large hypertables, consider pg_dump --jobs and parallel restore
# at recovery time. Compressed chunks are dumped as-is.
#
# Expected env:
#   TIMESCALE_HOST       — service hostname (default: timescaledb)
#   TIMESCALE_PORT       — default 5432
#   TIMESCALE_USER       — admin user (default: postgres)
#   TIMESCALE_DB         — database name (default: industream_timeseries)
#   PGPASSWORD_FILE      — path to Docker secret with the password
# =============================================================================

set -uo pipefail

BACKUP_DIR="${BACKUP_DIR:-/backups/timeseries}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
TIMESCALE_HOST="${TIMESCALE_HOST:-timescaledb}"
TIMESCALE_PORT="${TIMESCALE_PORT:-5432}"
TIMESCALE_USER="${TIMESCALE_USER:-postgres}"
TIMESCALE_DB="${TIMESCALE_DB:-industream_timeseries}"
PGPASSWORD_FILE="${PGPASSWORD_FILE:-/run/secrets/timescale_admin_password}"

NTFY_URL="${NTFY_URL:-http://ntfy:80}"
NTFY_TOPIC="${NTFY_TOPIC:-industream-backups}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

notify() {
    local title="$1" body="$2" priority="${3:-default}" tags="${4:-}"
    if [ -n "$NTFY_URL" ] && [ -n "$NTFY_TOPIC" ]; then
        wget -qO- --post-data="$body" \
            --header="Title: ${title}" \
            --header="Priority: ${priority}" \
            --header="Tags: ${tags}" \
            "${NTFY_URL}/${NTFY_TOPIC}" >/dev/null || true
    fi
}

if [ -f "$PGPASSWORD_FILE" ]; then
    export PGPASSWORD
    PGPASSWORD="$(cat "$PGPASSWORD_FILE")"
else
    log_error "Password secret not found at $PGPASSWORD_FILE"
    notify "TimescaleDB Backup FAILED" "missing password secret" urgent "rotating_light,backup"
    exit 1
fi

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
DATE_DIR="$(date '+%Y/%m/%d')"
OUT_DIR="${BACKUP_DIR}/${DATE_DIR}"
mkdir -p "$OUT_DIR"
OUT_FILE="${OUT_DIR}/${TIMESCALE_DB}_${TIMESTAMP}.dump"

log "Backing up TimescaleDB ${TIMESCALE_DB}@${TIMESCALE_HOST}:${TIMESCALE_PORT}"
START=$(date +%s)

if pg_dump \
        --host="$TIMESCALE_HOST" \
        --port="$TIMESCALE_PORT" \
        --username="$TIMESCALE_USER" \
        --format=custom \
        --compress=9 \
        --no-owner \
        --no-acl \
        --file="$OUT_FILE" \
        "$TIMESCALE_DB"; then
    DURATION=$(( $(date +%s) - START ))
    SIZE_H=$(du -h "$OUT_FILE" | cut -f1)
    log "SUCCESS: ${TIMESCALE_DB} → ${SIZE_H} in ${DURATION}s"

    # Verify the dump is readable
    if pg_restore --list "$OUT_FILE" >/dev/null 2>&1; then
        log "Integrity check passed"
    else
        log_error "Dump file is not readable by pg_restore"
        notify "TimescaleDB Backup INTEGRITY FAIL" "$(basename "$OUT_FILE") unreadable" urgent "warning,backup"
        exit 1
    fi

    find "$BACKUP_DIR" -type f -name "*.dump" -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true
    find "$BACKUP_DIR" -type d -empty -delete 2>/dev/null || true

    notify "TimescaleDB Backup OK" \
        "${TIMESCALE_DB}: ${SIZE_H} in ${DURATION}s, retention ${RETENTION_DAYS}d" \
        low "white_check_mark,backup"
    exit 0
else
    log_error "pg_dump failed"
    notify "TimescaleDB Backup FAILED" "pg_dump returned non-zero" urgent "rotating_light,backup"
    exit 1
fi
