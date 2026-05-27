#!/bin/bash
# PostgreSQL Backup Script for Industream Platform
# Performs daily backups with configurable retention and notifications

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
BACKUP_DIR="${BACKUP_DIR:-/backups/postgres}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
# Auto-discover all non-template user databases unless DATABASES is set
# explicitly. Prevents silent drift when a new DB is added to
# POSTGRES_MULTIPLE_DATABASES but the backup list is forgotten.
if [ -z "${DATABASES:-}" ]; then
    DATABASES=$(PGPASSWORD="$(cat "/run/secrets/${ENV:-prod}_postgres_admin_password" 2>/dev/null || true)" \
        psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -d postgres -tAc \
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');" 2>/dev/null \
        | tr '\n' ' ')
fi
DATABASES="${DATABASES:-industream DataCatalog DataBridge}"

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
        # Verify gzip integrity
        if gzip -t "${backup_file}" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# ============================================================================
# Main
# ============================================================================

# Read password from Docker secret if available (supports env-prefixed secrets)
SECRET_FILE=$(ls /run/secrets/*postgres_admin_password 2>/dev/null | head -1)
if [ -n "${SECRET_FILE}" ] && [ -f "${SECRET_FILE}" ]; then
    PGPASSWORD=$(cat "${SECRET_FILE}" | tr -d '\n')
    log "Loaded PostgreSQL password from secret: ${SECRET_FILE}"
else
    PGPASSWORD="${POSTGRES_PASSWORD:-}"
    if [ -z "${PGPASSWORD}" ]; then
        log_error "No PostgreSQL password found"
        send_notification "Backup Failed" "PostgreSQL backup failed: No password configured" "urgent" "x,postgresql"
        exit 1
    fi
fi
export PGPASSWORD


# Timestamps
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATE_DIR=$(date +%Y-%m-%d)
START_TIME=$(date +%s)

# Create backup directory
mkdir -p "${BACKUP_DIR}/${DATE_DIR}"

log "=========================================="
log "PostgreSQL Backup Starting"
log "=========================================="
log "Host: ${POSTGRES_HOST}:${POSTGRES_PORT}"
log "Databases: ${DATABASES}"
log "Retention: ${RETENTION_DAYS} days"
log "=========================================="

# Track results
SUCCESS_COUNT=0
FAIL_COUNT=0
TOTAL_SIZE=0
FAILED_DBS=""

# Wait for PostgreSQL to be ready
log "Checking PostgreSQL connection..."
for i in $(seq 1 30); do
    if pg_isready -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" >/dev/null 2>&1; then
        log "PostgreSQL is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        log_error "PostgreSQL not ready after 30 seconds"
        send_notification "Backup Failed" "PostgreSQL backup failed: Database not reachable" "urgent" "x,postgresql"
        exit 1
    fi
    sleep 1
done

# Backup each database
for DB in ${DATABASES}; do
    BACKUP_FILE="${BACKUP_DIR}/${DATE_DIR}/${DB}_${TIMESTAMP}.sql.gz"
    log "Backing up database: ${DB}"

    if pg_dump -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" \
        --format=plain --no-owner --no-acl -d "${DB}" 2>/dev/null | gzip > "${BACKUP_FILE}"; then

        if verify_backup "${BACKUP_FILE}"; then
            FILE_SIZE=$(stat -f%z "${BACKUP_FILE}" 2>/dev/null || stat -c%s "${BACKUP_FILE}" 2>/dev/null || echo 0)
            FILE_SIZE_H=$(du -h "${BACKUP_FILE}" | cut -f1)
            TOTAL_SIZE=$((TOTAL_SIZE + FILE_SIZE))
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            log "SUCCESS: ${DB} (${FILE_SIZE_H})"
        else
            rm -f "${BACKUP_FILE}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_DBS="${FAILED_DBS} ${DB}"
            log_error "Backup verification failed for ${DB}"
        fi
    else
        rm -f "${BACKUP_FILE}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_DBS="${FAILED_DBS} ${DB}"
        log_error "Failed to backup ${DB}"
    fi
done

# Full cluster backup
FULL_BACKUP_FILE="${BACKUP_DIR}/${DATE_DIR}/full_cluster_${TIMESTAMP}.sql.gz"
log "Creating full cluster backup..."

if pg_dumpall -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" \
    --no-role-passwords 2>/dev/null | gzip > "${FULL_BACKUP_FILE}"; then

    if verify_backup "${FULL_BACKUP_FILE}"; then
        FILE_SIZE=$(stat -f%z "${FULL_BACKUP_FILE}" 2>/dev/null || stat -c%s "${FULL_BACKUP_FILE}" 2>/dev/null || echo 0)
        FILE_SIZE_H=$(du -h "${FULL_BACKUP_FILE}" | cut -f1)
        TOTAL_SIZE=$((TOTAL_SIZE + FILE_SIZE))
        log "SUCCESS: Full cluster backup (${FILE_SIZE_H})"
    else
        rm -f "${FULL_BACKUP_FILE}"
        log_error "Full cluster backup verification failed"
    fi
else
    rm -f "${FULL_BACKUP_FILE}"
    log_error "Failed to create full cluster backup"
fi

# Cleanup old backups
log "Cleaning up backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -type d -mtime +${RETENTION_DAYS} -exec rm -rf {} + 2>/dev/null || true
find "${BACKUP_DIR}" -type f -name "*.sql.gz" -mtime +${RETENTION_DAYS} -delete 2>/dev/null || true
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
log "Failed: ${FAIL_COUNT}"
log "Total size: ${TOTAL_SIZE_H}"

if [ -d "${BACKUP_DIR}/${DATE_DIR}" ]; then
    log "Today's backups:"
    ls -lh "${BACKUP_DIR}/${DATE_DIR}/"
fi

# Send notification
if [ ${FAIL_COUNT} -eq 0 ]; then
    send_notification \
        "PostgreSQL Backup OK" \
        "All ${SUCCESS_COUNT} databases backed up. Size: ${TOTAL_SIZE_H}, Duration: ${DURATION}s" \
        "low" "white_check_mark,postgresql"
    log "=========================================="
    log "Backup completed successfully"
    exit 0
else
    send_notification \
        "PostgreSQL Backup FAILED" \
        "Failed:${FAILED_DBS} | OK: ${SUCCESS_COUNT} | Failed: ${FAIL_COUNT}" \
        "high" "warning,postgresql"
    log "=========================================="
    log_error "Backup completed with ${FAIL_COUNT} failures"
    exit 1
fi
