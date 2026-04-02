#!/bin/bash
# InfluxDB Restore Script for Industream Platform
# Restores from native InfluxDB backup files

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
BACKUP_DIR="${BACKUP_DIR:-/backups/influxdb}"
INFLUXDB_HOST="${INFLUXDB_HOST:-http://influxdb:8086}"
INFLUXDB_ORG="${INFLUXDB_ORG:-industream}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================================
# Functions
# ============================================================================
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -f, --file PATH         Backup file to restore from (optional, uses latest if not specified)"
    echo "  -b, --bucket NAME       Restore specific bucket only (optional)"
    echo "  -l, --list              List available backups"
    echo "  --full                  Full restore (all buckets, requires empty InfluxDB)"
    echo "  -y, --yes               Skip confirmation prompt"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --list                              # List all available backups"
    echo "  $0                                     # Restore from latest backup"
    echo "  $0 -f /backups/influxdb/2024-01-15/influxdb_20240115_023000.tar.gz"
    echo "  $0 -b metrics                          # Restore only 'metrics' bucket"
    echo ""
}

load_token() {
    if [ -f /run/secrets/influx_admin_token ]; then
        export INFLUX_TOKEN=$(cat /run/secrets/influx_admin_token)
    elif [ -n "${INFLUX_TOKEN:-}" ]; then
        # Token already set
        :
    else
        log_error "No InfluxDB token found"
        log "Set INFLUX_TOKEN env var or mount /run/secrets/influx_admin_token"
        exit 1
    fi
}

list_backups() {
    log "Available InfluxDB backups in ${BACKUP_DIR}:"
    echo ""

    if [ ! -d "${BACKUP_DIR}" ]; then
        log_error "Backup directory not found: ${BACKUP_DIR}"
        exit 1
    fi

    find "${BACKUP_DIR}" -type f -name "influxdb_*.tar.gz" 2>/dev/null | sort -r | head -20 | while read -r file; do
        SIZE=$(du -h "${file}" 2>/dev/null | cut -f1)
        DATE=$(stat -c %y "${file}" 2>/dev/null | cut -d. -f1 || stat -f %Sm "${file}" 2>/dev/null)
        echo "  ${file}"
        echo "    Size: ${SIZE}, Created: ${DATE}"
        echo ""
    done
}

find_latest_backup() {
    find "${BACKUP_DIR}" -type f -name "influxdb_*.tar.gz" 2>/dev/null | sort -r | head -n 1
}

restore_backup() {
    local backup_file="$1"
    local bucket="${2:-}"
    local full_restore="${3:-false}"

    if [ ! -f "${backup_file}" ]; then
        log_error "Backup file not found: ${backup_file}"
        exit 1
    fi

    load_token

    # Create temp directory for extraction
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf ${TEMP_DIR}" EXIT

    log "Extracting backup to ${TEMP_DIR}..."
    tar -xzf "${backup_file}" -C "${TEMP_DIR}"

    # Find the backup directory inside
    BACKUP_DATA=$(find "${TEMP_DIR}" -type d -name "backup_*" -o -type d -name "influxdb_*" 2>/dev/null | head -1)
    if [ -z "${BACKUP_DATA}" ]; then
        # Maybe files are directly in temp dir
        BACKUP_DATA="${TEMP_DIR}"
    fi

    log "Backup data location: ${BACKUP_DATA}"

    if [ "${full_restore}" = "true" ]; then
        log "Performing full restore..."
        influx restore "${BACKUP_DATA}" \
            --host "${INFLUXDB_HOST}" \
            --org "${INFLUXDB_ORG}" \
            --full
    elif [ -n "${bucket}" ]; then
        log "Restoring bucket: ${bucket}..."
        influx restore "${BACKUP_DATA}" \
            --host "${INFLUXDB_HOST}" \
            --org "${INFLUXDB_ORG}" \
            --bucket "${bucket}"
    else
        log "Restoring all buckets..."
        influx restore "${BACKUP_DATA}" \
            --host "${INFLUXDB_HOST}" \
            --org "${INFLUXDB_ORG}"
    fi

    log_success "InfluxDB restore completed"

    # Show restored buckets
    log "Current buckets:"
    influx bucket list --host "${INFLUXDB_HOST}" --org "${INFLUXDB_ORG}" 2>/dev/null || true
}

# ============================================================================
# Main
# ============================================================================
BACKUP_FILE=""
BUCKET=""
LIST_ONLY=false
FULL_RESTORE=false
SKIP_CONFIRM=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--file)
            BACKUP_FILE="$2"
            shift 2
            ;;
        -b|--bucket)
            BUCKET="$2"
            shift 2
            ;;
        -l|--list)
            LIST_ONLY=true
            shift
            ;;
        --full)
            FULL_RESTORE=true
            shift
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

echo ""
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   InfluxDB Restore Tool${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo ""

if [ "${LIST_ONLY}" = "true" ]; then
    list_backups
    exit 0
fi

# Find backup file if not specified
if [ -z "${BACKUP_FILE}" ]; then
    BACKUP_FILE=$(find_latest_backup)
    if [ -z "${BACKUP_FILE}" ]; then
        log_error "No backup found in ${BACKUP_DIR}"
        exit 1
    fi
    log "Using latest backup: ${BACKUP_FILE}"
fi

# Show restore info
BACKUP_SIZE=$(du -h "${BACKUP_FILE}" 2>/dev/null | cut -f1)
BACKUP_DATE=$(stat -c %y "${BACKUP_FILE}" 2>/dev/null | cut -d. -f1 || stat -f %Sm "${BACKUP_FILE}" 2>/dev/null)

echo ""
log "Restore Details:"
echo "  Backup:      ${BACKUP_FILE}"
echo "  Size:        ${BACKUP_SIZE}"
echo "  Backup Date: ${BACKUP_DATE}"
echo "  Target Host: ${INFLUXDB_HOST}"
echo "  Organization: ${INFLUXDB_ORG}"
if [ -n "${BUCKET}" ]; then
    echo "  Bucket:      ${BUCKET}"
fi
if [ "${FULL_RESTORE}" = "true" ]; then
    echo "  Mode:        FULL RESTORE"
fi
echo ""

# Confirmation
if [ "${SKIP_CONFIRM}" != "true" ]; then
    if [ "${FULL_RESTORE}" = "true" ]; then
        log_warning "FULL RESTORE will overwrite ALL data in InfluxDB!"
    else
        log_warning "This will restore data to InfluxDB"
    fi
    echo ""
    read -p "Continue? [y/N] " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Restore cancelled"
        exit 0
    fi
fi

restore_backup "${BACKUP_FILE}" "${BUCKET}" "${FULL_RESTORE}"

echo ""
log_success "Restore completed!"
echo ""
