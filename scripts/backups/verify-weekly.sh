#!/bin/bash
# Weekly Backup Verification Script for Industream Platform
# Verifies integrity of backups created in the last 7 days across:
#   - PostgreSQL plain SQL dumps (*.sql.gz)
#   - Volume archives (*.tar.gz, except influxdb_*.tar.gz)
#   - InfluxDB archives (influxdb_*.tar.gz)
#
# Verification levels:
#   1. File present and non-empty
#   2. Compression integrity (gzip -t / tar -tzf)
#   3. Format sanity:
#        - PostgreSQL: SQL header marker present (plain format, not pg_restore)
#        - InfluxDB:   archive contains the expected manifest / kv / sql files
#
# This script does NOT perform a full restore into a temporary database.
# See docs/runbook/backups.md for the rationale and the V2 roadmap.

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
BACKUP_DIR="${BACKUP_DIR:-/backups}"
LOG_DIR="${LOG_DIR:-/var/log/industream-backups}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-7}"

# Ntfy notification settings
NTFY_URL="${NTFY_URL:-http://ntfy:80}"
NTFY_TOPIC="${NTFY_TOPIC:-industream-backups}"

# ============================================================================
# Logging
# ============================================================================
mkdir -p "${LOG_DIR}" 2>/dev/null || LOG_DIR="/tmp"
LOG_FILE="${LOG_DIR}/verify-weekly-$(date +%Y%m%d).log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "${msg}" | tee -a "${LOG_FILE}"
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1"
    echo "${msg}" | tee -a "${LOG_FILE}" >&2
}

log_ok() {
    log "OK    | $1"
}

log_fail() {
    log_error "FAIL  | $1"
}

send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    local tags="${4:-}"

    if [ -n "${NTFY_URL}" ] && [ -n "${NTFY_TOPIC}" ]; then
        wget -qO- --post-data="${message}" \
            --header="Title: ${title}" \
            --header="Priority: ${priority}" \
            --header="Tags: ${tags}" \
            "${NTFY_URL}/${NTFY_TOPIC}" \
            >/dev/null 2>&1 || log "Warning: Failed to send Ntfy notification"
    fi
}

# ============================================================================
# Verifiers
# ============================================================================

# Verify gzip integrity of a single file.
verify_gzip() {
    local file="$1"
    [ -f "${file}" ] && [ -s "${file}" ] || return 1
    gzip -t "${file}" 2>/dev/null
}

# Verify tar.gz can be listed without error.
verify_tar_gz() {
    local file="$1"
    [ -f "${file}" ] && [ -s "${file}" ] || return 1
    tar -tzf "${file}" >/dev/null 2>&1
}

# Verify a PostgreSQL plain-format dump:
#   - gzip integrity
#   - decompresses to a stream that starts with a valid Postgres dump header
verify_postgres_dump() {
    local file="$1"
    verify_gzip "${file}" || return 1

    # Plain-format dumps start with a comment block; we look for any of the
    # canonical pg_dump / pg_dumpall markers within the first 4 KiB.
    local head
    head=$(gunzip -c "${file}" 2>/dev/null | head -c 4096 || true)
    if echo "${head}" | grep -qE '(PostgreSQL database (cluster )?dump|^SET statement_timeout|^-- Dumped from database version)'; then
        return 0
    fi
    return 1
}

# Verify an InfluxDB backup archive:
#   - tar.gz integrity
#   - contains at least one of the expected files emitted by `influx backup`
#     (manifest, kv, sql; .bolt or .gz variants depending on InfluxDB version)
verify_influxdb_archive() {
    local file="$1"
    verify_tar_gz "${file}" || return 1

    local listing
    listing=$(tar -tzf "${file}" 2>/dev/null || true)
    if echo "${listing}" | grep -qE '(\.manifest$|manifest\.json|\.bolt(\.gz)?$|kv\.bolt|sqlite|\.sql(\.gz)?$)'; then
        return 0
    fi
    return 1
}

# ============================================================================
# Main
# ============================================================================
log "=========================================="
log "Weekly Backup Verification Starting"
log "=========================================="
log "Backup root : ${BACKUP_DIR}"
log "Log file    : ${LOG_FILE}"
log "Window      : last ${MAX_AGE_DAYS} days"
log "=========================================="

if [ ! -d "${BACKUP_DIR}" ]; then
    log_error "Backup directory not found: ${BACKUP_DIR}"
    send_notification "Backup Verify FAILED" \
        "Backup directory ${BACKUP_DIR} not found" \
        "urgent" "x,floppy_disk"
    exit 1
fi

# Counters
PG_OK=0;  PG_FAIL=0
INF_OK=0; INF_FAIL=0
VOL_OK=0; VOL_FAIL=0
FAILED_FILES=""

# Collect files modified within the window. -print0 is used to handle spaces.
PG_FILES=$(find "${BACKUP_DIR}" -type f -name "*.sql.gz" -mtime -"${MAX_AGE_DAYS}" 2>/dev/null | sort || true)
INF_FILES=$(find "${BACKUP_DIR}" -type f -name "influxdb_*.tar.gz" -mtime -"${MAX_AGE_DAYS}" 2>/dev/null | sort || true)
# Volume archives = all *.tar.gz that are NOT influxdb backups
ALL_TGZ=$(find "${BACKUP_DIR}" -type f -name "*.tar.gz" -mtime -"${MAX_AGE_DAYS}" 2>/dev/null | sort || true)
VOL_FILES=$(echo "${ALL_TGZ}" | grep -v '/influxdb_[^/]*\.tar\.gz$' || true)

# --- PostgreSQL ---
log ""
log "--- PostgreSQL dumps ---"
if [ -z "${PG_FILES}" ]; then
    log "(no *.sql.gz files in the last ${MAX_AGE_DAYS} days)"
else
    while IFS= read -r f; do
        [ -z "${f}" ] && continue
        if verify_postgres_dump "${f}"; then
            log_ok "${f}"
            PG_OK=$((PG_OK + 1))
        else
            log_fail "${f}"
            PG_FAIL=$((PG_FAIL + 1))
            FAILED_FILES="${FAILED_FILES}\n  - ${f}"
        fi
    done <<< "${PG_FILES}"
fi

# --- InfluxDB ---
log ""
log "--- InfluxDB archives ---"
if [ -z "${INF_FILES}" ]; then
    log "(no influxdb_*.tar.gz files in the last ${MAX_AGE_DAYS} days)"
else
    while IFS= read -r f; do
        [ -z "${f}" ] && continue
        if verify_influxdb_archive "${f}"; then
            log_ok "${f}"
            INF_OK=$((INF_OK + 1))
        else
            log_fail "${f}"
            INF_FAIL=$((INF_FAIL + 1))
            FAILED_FILES="${FAILED_FILES}\n  - ${f}"
        fi
    done <<< "${INF_FILES}"
fi

# --- Volumes ---
log ""
log "--- Volume archives ---"
if [ -z "${VOL_FILES}" ]; then
    log "(no volume *.tar.gz files in the last ${MAX_AGE_DAYS} days)"
else
    while IFS= read -r f; do
        [ -z "${f}" ] && continue
        if verify_tar_gz "${f}"; then
            log_ok "${f}"
            VOL_OK=$((VOL_OK + 1))
        else
            log_fail "${f}"
            VOL_FAIL=$((VOL_FAIL + 1))
            FAILED_FILES="${FAILED_FILES}\n  - ${f}"
        fi
    done <<< "${VOL_FILES}"
fi

# --- Summary ---
TOTAL_OK=$((PG_OK + INF_OK + VOL_OK))
TOTAL_FAIL=$((PG_FAIL + INF_FAIL + VOL_FAIL))
TOTAL_FILES=$((TOTAL_OK + TOTAL_FAIL))

log ""
log "=========================================="
log "Verification Summary"
log "=========================================="
log "PostgreSQL : ${PG_OK} OK / ${PG_FAIL} FAIL"
log "InfluxDB   : ${INF_OK} OK / ${INF_FAIL} FAIL"
log "Volumes    : ${VOL_OK} OK / ${VOL_FAIL} FAIL"
log "----"
log "Total      : ${TOTAL_OK} OK / ${TOTAL_FAIL} FAIL"
log "=========================================="

# Decision: fail if any FAIL OR if no recent backups were found at all
if [ "${TOTAL_FILES}" -eq 0 ]; then
    log_error "No backups found in the last ${MAX_AGE_DAYS} days"
    send_notification \
        "Backup Verify FAILED" \
        "No backups found in ${BACKUP_DIR} over the last ${MAX_AGE_DAYS} days" \
        "urgent" "x,floppy_disk"
    exit 1
fi

if [ "${TOTAL_FAIL}" -gt 0 ]; then
    # shellcheck disable=SC2059
    DETAIL=$(printf "${FAILED_FILES}")
    send_notification \
        "Backup Verify FAILED" \
        "${TOTAL_FAIL}/${TOTAL_FILES} backups failed verification (PG:${PG_FAIL} Influx:${INF_FAIL} Vol:${VOL_FAIL}).${DETAIL}" \
        "high" "warning,floppy_disk"
    log_error "Verification finished with ${TOTAL_FAIL} failures"
    exit 1
fi

send_notification \
    "Backup Verify OK" \
    "All ${TOTAL_OK} backups verified successfully (PG:${PG_OK} Influx:${INF_OK} Vol:${VOL_OK})" \
    "low" "white_check_mark,floppy_disk"
log "Verification completed successfully"
exit 0
