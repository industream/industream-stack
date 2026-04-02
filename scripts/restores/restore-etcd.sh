#!/bin/bash
# etcd Restore Script for Industream Platform
# Restores from etcd snapshot files

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
BACKUP_DIR="${BACKUP_DIR:-/backups/etcd}"
ETCD_DATA_DIR="${ETCD_DATA_DIR:-/var/lib/etcd}"
ETCD_NAME="${ETCD_NAME:-default}"

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
    echo "  -f, --file PATH         Snapshot file to restore from (optional, uses latest if not specified)"
    echo "  -l, --list              List available snapshots"
    echo "  --data-dir PATH         etcd data directory (default: /var/lib/etcd)"
    echo "  -y, --yes               Skip confirmation prompt"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "IMPORTANT: etcd must be stopped before restore!"
    echo ""
    echo "Restore procedure:"
    echo "  1. Stop etcd service:     docker service scale industream_etcd=0"
    echo "  2. Run this restore script"
    echo "  3. Start etcd service:    docker service scale industream_etcd=1"
    echo ""
    echo "Examples:"
    echo "  $0 --list                              # List all available snapshots"
    echo "  $0                                     # Restore from latest snapshot"
    echo "  $0 -f /backups/etcd/2024-01-15/etcd_snapshot_20240115_033000.db.gz"
    echo ""
}

list_backups() {
    log "Available etcd snapshots in ${BACKUP_DIR}:"
    echo ""

    if [ ! -d "${BACKUP_DIR}" ]; then
        log_error "Backup directory not found: ${BACKUP_DIR}"
        exit 1
    fi

    find "${BACKUP_DIR}" -type f -name "etcd_snapshot_*.db.gz" 2>/dev/null | sort -r | head -20 | while read -r file; do
        SIZE=$(du -h "${file}" 2>/dev/null | cut -f1)
        DATE=$(stat -c %y "${file}" 2>/dev/null | cut -d. -f1 || stat -f %Sm "${file}" 2>/dev/null)
        echo "  ${file}"
        echo "    Size: ${SIZE}, Created: ${DATE}"

        # Try to show snapshot info if we can decompress
        TEMP_SNAP=$(mktemp)
        if gunzip -c "${file}" > "${TEMP_SNAP}" 2>/dev/null; then
            if command -v etcdctl &>/dev/null; then
                etcdctl snapshot status "${TEMP_SNAP}" 2>/dev/null | sed 's/^/    /' || true
            fi
        fi
        rm -f "${TEMP_SNAP}"
        echo ""
    done
}

find_latest_backup() {
    find "${BACKUP_DIR}" -type f -name "etcd_snapshot_*.db.gz" 2>/dev/null | sort -r | head -n 1
}

restore_snapshot() {
    local snapshot_file="$1"
    local data_dir="$2"

    if [ ! -f "${snapshot_file}" ]; then
        log_error "Snapshot file not found: ${snapshot_file}"
        exit 1
    fi

    # Check if etcd might be running
    if pgrep -x etcd > /dev/null 2>&1; then
        log_error "etcd appears to be running. Stop it before restore."
        log "Run: docker service scale industream_etcd=0"
        exit 1
    fi

    # Create temp file for decompression
    TEMP_SNAP=$(mktemp)
    trap "rm -f ${TEMP_SNAP}" EXIT

    log "Decompressing snapshot..."
    gunzip -c "${snapshot_file}" > "${TEMP_SNAP}"

    # Verify snapshot
    log "Verifying snapshot..."
    if command -v etcdctl &>/dev/null; then
        etcdctl snapshot status "${TEMP_SNAP}" || {
            log_error "Snapshot verification failed"
            exit 1
        }
    fi

    # Backup existing data directory
    if [ -d "${data_dir}" ] && [ "$(ls -A ${data_dir} 2>/dev/null)" ]; then
        BACKUP_OLD="${data_dir}.backup.$(date +%Y%m%d_%H%M%S)"
        log_warning "Backing up existing data to ${BACKUP_OLD}"
        mv "${data_dir}" "${BACKUP_OLD}"
    fi

    # Restore snapshot
    log "Restoring snapshot to ${data_dir}..."
    etcdctl snapshot restore "${TEMP_SNAP}" \
        --name "${ETCD_NAME}" \
        --data-dir "${data_dir}" \
        --initial-cluster "${ETCD_NAME}=http://localhost:2380" \
        --initial-cluster-token "etcd-cluster-1" \
        --initial-advertise-peer-urls "http://localhost:2380"

    log_success "etcd snapshot restored successfully"
    log "Data directory: ${data_dir}"

    echo ""
    log_warning "Next steps:"
    echo "  1. Verify data directory permissions"
    echo "  2. Start etcd: docker service scale industream_etcd=1"
    echo "  3. Verify: etcdctl endpoint health"
}

# ============================================================================
# Main
# ============================================================================
SNAPSHOT_FILE=""
DATA_DIR="${ETCD_DATA_DIR}"
LIST_ONLY=false
SKIP_CONFIRM=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--file)
            SNAPSHOT_FILE="$2"
            shift 2
            ;;
        --data-dir)
            DATA_DIR="$2"
            shift 2
            ;;
        -l|--list)
            LIST_ONLY=true
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
echo -e "${BLUE}   etcd Restore Tool${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo ""

if [ "${LIST_ONLY}" = "true" ]; then
    list_backups
    exit 0
fi

# Find snapshot file if not specified
if [ -z "${SNAPSHOT_FILE}" ]; then
    SNAPSHOT_FILE=$(find_latest_backup)
    if [ -z "${SNAPSHOT_FILE}" ]; then
        log_error "No snapshot found in ${BACKUP_DIR}"
        exit 1
    fi
    log "Using latest snapshot: ${SNAPSHOT_FILE}"
fi

# Show restore info
BACKUP_SIZE=$(du -h "${SNAPSHOT_FILE}" 2>/dev/null | cut -f1)
BACKUP_DATE=$(stat -c %y "${SNAPSHOT_FILE}" 2>/dev/null | cut -d. -f1 || stat -f %Sm "${SNAPSHOT_FILE}" 2>/dev/null)

echo ""
log "Restore Details:"
echo "  Snapshot:   ${SNAPSHOT_FILE}"
echo "  Size:       ${BACKUP_SIZE}"
echo "  Created:    ${BACKUP_DATE}"
echo "  Data Dir:   ${DATA_DIR}"
echo ""

# Confirmation
if [ "${SKIP_CONFIRM}" != "true" ]; then
    log_warning "This will REPLACE the etcd data directory!"
    log_warning "Ensure etcd is STOPPED before proceeding."
    echo ""
    read -p "Is etcd stopped and ready for restore? [y/N] " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Restore cancelled"
        exit 0
    fi
fi

restore_snapshot "${SNAPSHOT_FILE}" "${DATA_DIR}"

echo ""
log_success "Restore completed!"
echo ""
