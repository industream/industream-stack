#!/bin/bash
# etcd Snapshot Backup Script for Industream Platform
# Uses etcdctl for consistent snapshots

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
BACKUP_DIR="${BACKUP_DIR:-/backups/etcd}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
ETCD_ENDPOINTS="${ETCD_ENDPOINTS:-http://etcd:2379}"

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


# Timestamps
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATE_DIR=$(date +%Y-%m-%d)
START_TIME=$(date +%s)

# Create backup directory
mkdir -p "${BACKUP_DIR}/${DATE_DIR}"

log "=========================================="
log "etcd Snapshot Backup Starting"
log "=========================================="
log "Endpoints: ${ETCD_ENDPOINTS}"
log "Retention: ${RETENTION_DAYS} days"
log "=========================================="

# Wait for etcd to be ready
log "Checking etcd connection..."
for i in $(seq 1 30); do
    if etcdctl --endpoints="${ETCD_ENDPOINTS}" endpoint health >/dev/null 2>&1; then
        log "etcd is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        log_error "etcd not ready after 30 seconds"
        send_notification "etcd Backup Failed" "etcd not reachable" "urgent" "x,package"
        exit 1
    fi
    sleep 1
done

# Get cluster info
log "Getting cluster status..."
etcdctl --endpoints="${ETCD_ENDPOINTS}" endpoint status --write-out=table 2>/dev/null || true

# Perform snapshot
SNAPSHOT_FILE="${BACKUP_DIR}/${DATE_DIR}/etcd_snapshot_${TIMESTAMP}.db"
log "Creating etcd snapshot..."

if etcdctl --endpoints="${ETCD_ENDPOINTS}" snapshot save "${SNAPSHOT_FILE}" 2>&1; then
    log "Snapshot created successfully"
else
    log_error "Failed to create snapshot"
    send_notification "etcd Backup Failed" "Snapshot command failed" "high" "warning,package"
    exit 1
fi

# Verify snapshot
log "Verifying snapshot..."
if etcdctl snapshot status "${SNAPSHOT_FILE}" --write-out=table 2>&1; then
    log "Snapshot verification passed"
else
    log_error "Snapshot verification failed"
    send_notification "etcd Backup Failed" "Verification failed" "high" "warning,package"
    rm -f "${SNAPSHOT_FILE}"
    exit 1
fi

# Compress snapshot
log "Compressing snapshot..."
ARCHIVE_FILE="${SNAPSHOT_FILE}.gz"
if gzip -c "${SNAPSHOT_FILE}" > "${ARCHIVE_FILE}"; then
    rm -f "${SNAPSHOT_FILE}"
    BACKUP_SIZE=$(du -h "${ARCHIVE_FILE}" | cut -f1)
    log "Snapshot compressed: ${BACKUP_SIZE}"
else
    log_error "Failed to compress snapshot"
    send_notification "etcd Backup Failed" "Compression failed" "high" "warning,package"
    exit 1
fi

# Cleanup old backups
log "Cleaning up backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -type f -name "etcd_snapshot_*.db.gz" -mtime +${RETENTION_DAYS} -delete 2>/dev/null || true
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
    "etcd Backup OK" \
    "Snapshot completed. Size: ${BACKUP_SIZE}, Duration: ${DURATION}s" \
    "low" "white_check_mark,package"

log "=========================================="
log "etcd backup completed successfully"
exit 0
