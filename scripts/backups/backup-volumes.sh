#!/bin/bash
# Volume Backup Script for Industream Platform
# Backs up Grafana data volume
# Note: InfluxDB and etcd use native backup tools (see backup-influxdb.sh, backup-etcd.sh)

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
BACKUP_DIR="${BACKUP_DIR:-/backups/volumes}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

# Source directories to backup (mapped from Docker volumes)
GRAFANA_DATA="${GRAFANA_DATA:-/data/grafana}"

# Ntfy notification settings
NTFY_URL="${NTFY_URL:-http://ntfy:80}"
NTFY_TOPIC="${NTFY_TOPIC:-industream-backups}"

# ============================================================================
# Functions
# ============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
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

verify_backup() {
    local backup_file="$1"
    if [ -f "${backup_file}" ] && [ -s "${backup_file}" ]; then
        # Verify tar.gz integrity
        if tar -tzf "${backup_file}" >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

LAST_BACKUP_SIZE=0

backup_volume() {
    local SOURCE_DIR="$1"
    local VOLUME_NAME="$2"
    local BACKUP_FILE="${BACKUP_DIR}/${DATE_DIR}/${VOLUME_NAME}_${TIMESTAMP}.tar.gz"
    LAST_BACKUP_SIZE=0

    if [ ! -d "${SOURCE_DIR}" ]; then
        log "SKIP: ${VOLUME_NAME} - directory not found: ${SOURCE_DIR}"
        return 1
    fi

    if [ -z "$(ls -A "${SOURCE_DIR}" 2>/dev/null)" ]; then
        log "SKIP: ${VOLUME_NAME} - directory is empty"
        return 1
    fi

    log "Backing up ${VOLUME_NAME}..."

    if tar -czf "${BACKUP_FILE}" -C "$(dirname "${SOURCE_DIR}")" "$(basename "${SOURCE_DIR}")" 2>/dev/null; then
        if verify_backup "${BACKUP_FILE}"; then
            FILE_SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
            LAST_BACKUP_SIZE=$(stat -c%s "${BACKUP_FILE}" 2>/dev/null || stat -f%z "${BACKUP_FILE}" 2>/dev/null || echo 0)
            log "SUCCESS: ${VOLUME_NAME} (${FILE_SIZE})"
            return 0
        else
            log_error "Verification failed for ${VOLUME_NAME}"
            rm -f "${BACKUP_FILE}"
            return 1
        fi
    else
        log_error "Failed to backup ${VOLUME_NAME}"
        rm -f "${BACKUP_FILE}"
        return 1
    fi
}

# ============================================================================
# Main
# ============================================================================

# Timestamps
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATE_DIR=$(date +%Y-%m-%d)
START_TIME=$(date +%s)

# Create backup directory
mkdir -p "${BACKUP_DIR}/${DATE_DIR}"

log "=========================================="
log "Volume Backup Starting"
log "=========================================="
log "Retention: ${RETENTION_DAYS} days"
log "=========================================="

# Track results
SUCCESS_COUNT=0
FAIL_COUNT=0
TOTAL_SIZE=0
FAILED_VOLUMES=""

# Backup Grafana data
if backup_volume "${GRAFANA_DATA}" "grafana-data"; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    TOTAL_SIZE=$((TOTAL_SIZE + LAST_BACKUP_SIZE))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_VOLUMES="${FAILED_VOLUMES} grafana-data"
fi

# Cleanup old backups
log "Cleaning up backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -type f -name "*_data_*.tar.gz" -mtime +${RETENTION_DAYS} -delete 2>/dev/null || true
find "${BACKUP_DIR}" -type d -empty -delete 2>/dev/null || true

# Calculate duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Total size human readable
TOTAL_SIZE_H=$(numfmt --to=iec ${TOTAL_SIZE} 2>/dev/null || echo "${TOTAL_SIZE} bytes")

# Summary
log "=========================================="
log "Backup Summary"
log "=========================================="
log "Duration: ${DURATION} seconds"
log "Successful: ${SUCCESS_COUNT}"
log "Failed/Skipped: ${FAIL_COUNT}"
log "Total size: ${TOTAL_SIZE_H}"

if [ -d "${BACKUP_DIR}/${DATE_DIR}" ]; then
    log "Today's backups:"
    ls -lh "${BACKUP_DIR}/${DATE_DIR}/" 2>/dev/null || true
fi

log "=========================================="
if [ ${FAIL_COUNT} -eq 0 ] && [ ${SUCCESS_COUNT} -gt 0 ]; then
    log "Volume backup completed successfully"
    send_notification "Volume Backup OK" \
        "Grafana backup completed in ${DURATION}s. Size: ${TOTAL_SIZE_H}" \
        "low" "white_check_mark,floppy_disk"
    exit 0
elif [ ${SUCCESS_COUNT} -eq 0 ]; then
    log "No volumes were backed up"
    send_notification "Volume Backup Skipped" \
        "No volumes were backed up - directories may be empty" \
        "low" "warning,floppy_disk"
    exit 0
else
    log_error "Backup completed with ${FAIL_COUNT} failures/skips"
    send_notification "Volume Backup Warning" \
        "Backup had ${FAIL_COUNT} failures. Failed:${FAILED_VOLUMES}" \
        "high" "warning,floppy_disk"
    exit 1
fi
