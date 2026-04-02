#!/bin/bash
# InfluxDB Native Backup Script for Industream Platform
# Uses influx CLI for consistent backups

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
BACKUP_DIR="${BACKUP_DIR:-/backups/influxdb}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
INFLUXDB_HOST="${INFLUXDB_HOST:-http://influxdb:8086}"
INFLUXDB_ORG="${INFLUXDB_ORG:-industream}"
INFLUXDB_BUCKET="${INFLUXDB_BUCKET:-}"

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

# ============================================================================
# Main
# ============================================================================

# Read token from Docker secret (supports env-prefixed secrets)
SECRET_FILE=$(ls /run/secrets/*influx_admin_token 2>/dev/null | head -1)
if [ -n "${SECRET_FILE}" ] && [ -f "${SECRET_FILE}" ]; then
    INFLUX_TOKEN=$(cat "${SECRET_FILE}" | tr -d '\n')
    log "Loaded InfluxDB token from secret: ${SECRET_FILE}"
else
    INFLUX_TOKEN="${INFLUX_TOKEN:-}"
    if [ -z "${INFLUX_TOKEN}" ]; then
        log_error "No InfluxDB token found"
        send_notification "InfluxDB Backup Failed" "No authentication token configured" "urgent" "x,floppy_disk"
        exit 1
    fi
fi
export INFLUX_TOKEN


# Timestamps
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATE_DIR=$(date +%Y-%m-%d)
START_TIME=$(date +%s)

# Create backup directory
BACKUP_PATH="${BACKUP_DIR}/${DATE_DIR}/influxdb_${TIMESTAMP}"
mkdir -p "${BACKUP_PATH}"

log "=========================================="
log "InfluxDB Backup Starting"
log "=========================================="
log "Host: ${INFLUXDB_HOST}"
log "Organization: ${INFLUXDB_ORG}"
log "Bucket: ${INFLUXDB_BUCKET:-all}"
log "Retention: ${RETENTION_DAYS} days"
log "=========================================="

# Wait for InfluxDB to be ready
log "Checking InfluxDB connection..."
for i in $(seq 1 30); do
    if curl -s "${INFLUXDB_HOST}/health" | grep -q '"status":"pass"'; then
        log "InfluxDB is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        log_error "InfluxDB not ready after 30 seconds"
        send_notification "InfluxDB Backup Failed" "Database not reachable" "urgent" "x,floppy_disk"
        exit 1
    fi
    sleep 1
done

# Perform backup
log "Starting InfluxDB backup..."

BACKUP_ARGS="--host ${INFLUXDB_HOST} --token ${INFLUX_TOKEN} --org ${INFLUXDB_ORG}"

if [ -n "${INFLUXDB_BUCKET}" ]; then
    BACKUP_ARGS="${BACKUP_ARGS} --bucket ${INFLUXDB_BUCKET}"
    log "Backing up bucket: ${INFLUXDB_BUCKET}"
else
    log "Backing up all buckets"
fi

if influx backup ${BACKUP_ARGS} "${BACKUP_PATH}" 2>&1; then
    log "InfluxDB backup completed"
else
    log_error "InfluxDB backup failed"
    send_notification "InfluxDB Backup Failed" "Backup command failed" "high" "warning,floppy_disk"
    rm -rf "${BACKUP_PATH}"
    exit 1
fi

# Compress backup
log "Compressing backup..."
ARCHIVE_FILE="${BACKUP_DIR}/${DATE_DIR}/influxdb_${TIMESTAMP}.tar.gz"
if tar -czf "${ARCHIVE_FILE}" -C "${BACKUP_DIR}/${DATE_DIR}" "influxdb_${TIMESTAMP}"; then
    rm -rf "${BACKUP_PATH}"
    BACKUP_SIZE=$(du -h "${ARCHIVE_FILE}" | cut -f1)
    log "Backup compressed: ${BACKUP_SIZE}"
else
    log_error "Failed to compress backup"
    send_notification "InfluxDB Backup Failed" "Compression failed" "high" "warning,floppy_disk"
    exit 1
fi

# Verify backup
log "Verifying backup integrity..."
if tar -tzf "${ARCHIVE_FILE}" >/dev/null 2>&1; then
    log "Backup verification passed"
else
    log_error "Backup verification failed"
    send_notification "InfluxDB Backup Failed" "Verification failed" "high" "warning,floppy_disk"
    rm -f "${ARCHIVE_FILE}"
    exit 1
fi

# Cleanup old backups
log "Cleaning up backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -type f -name "influxdb_*.tar.gz" -mtime +${RETENTION_DAYS} -delete 2>/dev/null || true
find "${BACKUP_DIR}" -type d -empty -delete 2>/dev/null || true

# Calculate duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Summary
log "=========================================="
log "Backup Summary"
log "=========================================="
log "Duration: ${DURATION} seconds"
log "Backup size: ${BACKUP_SIZE}"
log "Location: ${ARCHIVE_FILE}"

# List today's backups
if [ -d "${BACKUP_DIR}/${DATE_DIR}" ]; then
    log "Today's backups:"
    ls -lh "${BACKUP_DIR}/${DATE_DIR}/"
fi

# Send success notification
send_notification \
    "InfluxDB Backup OK" \
    "Backup completed. Size: ${BACKUP_SIZE}, Duration: ${DURATION}s" \
    "low" "white_check_mark,floppy_disk"

log "=========================================="
log "InfluxDB backup completed successfully"
exit 0
