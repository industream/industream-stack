#!/bin/bash
# Volume Restore Script for Industream Platform
# Restores Grafana data from backup archives

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
BACKUP_DIR="${BACKUP_DIR:-/backups/volumes}"

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
    echo "  -v, --volume NAME       Volume to restore (grafana-data)"
    echo "  -f, --file PATH         Backup file to restore from (optional, uses latest)"
    echo "  -t, --target PATH       Target directory to restore to"
    echo "  -l, --list              List available backups"
    echo "  -y, --yes               Skip confirmation prompt"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "IMPORTANT: Stop the service using the volume before restore!"
    echo ""
    echo "Examples:"
    echo "  $0 --list                              # List all available backups"
    echo "  $0 -v grafana-data -t /var/lib/grafana # Restore Grafana data"
    echo "  $0 -f /backups/volumes/2024-01-15/grafana-data_20240115_040000.tar.gz -t /data"
    echo ""
}

list_backups() {
    log "Available volume backups in ${BACKUP_DIR}:"
    echo ""

    if [ ! -d "${BACKUP_DIR}" ]; then
        log_error "Backup directory not found: ${BACKUP_DIR}"
        exit 1
    fi

    # Find all backup files
    find "${BACKUP_DIR}" -type f -name "*_data_*.tar.gz" 2>/dev/null | sort -r | head -30 | while read -r file; do
        SIZE=$(du -h "${file}" 2>/dev/null | cut -f1)
        DATE=$(stat -c %y "${file}" 2>/dev/null | cut -d. -f1 || stat -f %Sm "${file}" 2>/dev/null)
        VOLUME=$(basename "${file}" | sed 's/_[0-9]*_[0-9]*\.tar\.gz$//')
        echo "  ${file}"
        echo "    Volume: ${VOLUME}, Size: ${SIZE}, Created: ${DATE}"
        echo ""
    done

    # Show available volumes
    echo -e "${BLUE}Available volumes in backups:${NC}"
    find "${BACKUP_DIR}" -type f -name "*_data_*.tar.gz" -exec basename {} \; 2>/dev/null | \
        sed 's/_[0-9]*_[0-9]*\.tar\.gz$//' | \
        sort -u | while read -r vol; do
            LATEST=$(find "${BACKUP_DIR}" -type f -name "${vol}_*.tar.gz" 2>/dev/null | sort -r | head -n 1)
            if [ -n "${LATEST}" ]; then
                SIZE=$(du -h "${LATEST}" 2>/dev/null | cut -f1)
                echo "  - ${vol} (latest: $(basename "${LATEST}"), ${SIZE})"
            fi
        done
}

find_latest_backup() {
    local volume="$1"
    find "${BACKUP_DIR}" -type f -name "${volume}_*.tar.gz" 2>/dev/null | sort -r | head -n 1
}

restore_volume() {
    local backup_file="$1"
    local target_dir="$2"

    if [ ! -f "${backup_file}" ]; then
        log_error "Backup file not found: ${backup_file}"
        exit 1
    fi

    # Verify archive
    log "Verifying backup archive..."
    if ! tar -tzf "${backup_file}" >/dev/null 2>&1; then
        log_error "Backup archive is corrupted or invalid"
        exit 1
    fi

    # Show contents
    log "Archive contents:"
    tar -tzf "${backup_file}" | head -10
    echo "  ..."

    # Create target directory if needed
    if [ ! -d "${target_dir}" ]; then
        log "Creating target directory: ${target_dir}"
        mkdir -p "${target_dir}"
    fi

    # Backup existing data
    if [ "$(ls -A ${target_dir} 2>/dev/null)" ]; then
        BACKUP_OLD="${target_dir}.backup.$(date +%Y%m%d_%H%M%S)"
        log_warning "Target directory not empty, backing up to ${BACKUP_OLD}"
        cp -a "${target_dir}" "${BACKUP_OLD}"
    fi

    # Extract backup
    log "Extracting backup to ${target_dir}..."
    tar -xzf "${backup_file}" -C "${target_dir}" --strip-components=1

    log_success "Volume restored successfully"

    # Show restored content
    log "Restored files:"
    ls -la "${target_dir}" | head -15
}

# ============================================================================
# Main
# ============================================================================
VOLUME=""
BACKUP_FILE=""
TARGET_DIR=""
LIST_ONLY=false
SKIP_CONFIRM=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--volume)
            VOLUME="$2"
            shift 2
            ;;
        -f|--file)
            BACKUP_FILE="$2"
            shift 2
            ;;
        -t|--target)
            TARGET_DIR="$2"
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
echo -e "${BLUE}   Volume Restore Tool${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo ""

if [ "${LIST_ONLY}" = "true" ]; then
    list_backups
    exit 0
fi

# Validate inputs
if [ -z "${BACKUP_FILE}" ] && [ -z "${VOLUME}" ]; then
    log_error "Either --file or --volume is required"
    show_usage
    exit 1
fi

if [ -z "${TARGET_DIR}" ]; then
    log_error "Target directory (--target) is required"
    show_usage
    exit 1
fi

# Find backup file if not specified
if [ -z "${BACKUP_FILE}" ]; then
    BACKUP_FILE=$(find_latest_backup "${VOLUME}")
    if [ -z "${BACKUP_FILE}" ]; then
        log_error "No backup found for volume: ${VOLUME}"
        exit 1
    fi
    log "Using latest backup: ${BACKUP_FILE}"
fi

# Show restore info
BACKUP_SIZE=$(du -h "${BACKUP_FILE}" 2>/dev/null | cut -f1)
BACKUP_DATE=$(stat -c %y "${BACKUP_FILE}" 2>/dev/null | cut -d. -f1 || stat -f %Sm "${BACKUP_FILE}" 2>/dev/null)

echo ""
log "Restore Details:"
echo "  Backup:  ${BACKUP_FILE}"
echo "  Size:    ${BACKUP_SIZE}"
echo "  Created: ${BACKUP_DATE}"
echo "  Target:  ${TARGET_DIR}"
echo ""

# Confirmation
if [ "${SKIP_CONFIRM}" != "true" ]; then
    log_warning "This will restore data to ${TARGET_DIR}"
    if [ -d "${TARGET_DIR}" ] && [ "$(ls -A ${TARGET_DIR} 2>/dev/null)" ]; then
        log_warning "Target directory is not empty - existing data will be backed up"
    fi
    echo ""
    read -p "Continue? [y/N] " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Restore cancelled"
        exit 0
    fi
fi

restore_volume "${BACKUP_FILE}" "${TARGET_DIR}"

echo ""
log_success "Restore completed!"
log "Remember to restart the service using this volume"
echo ""
