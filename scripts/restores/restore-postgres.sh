#!/bin/bash
# PostgreSQL Restore Script for Industream Platform
# Restores databases from backup files

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
BACKUP_DIR="${BACKUP_DIR:-/backups/postgres}"
POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"

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
    echo "  -d, --database NAME     Database to restore (required unless using -f with full backup)"
    echo "  -f, --file PATH         Backup file to restore from (optional, uses latest if not specified)"
    echo "  -l, --list              List available backups"
    echo "  --no-drop               Do not drop database before restore (append mode)"
    echo "  -y, --yes               Skip confirmation prompt"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --list                              # List all available backups"
    echo "  $0 -d keycloak                         # Restore keycloak from latest backup"
    echo "  $0 -d industream -f /backups/postgres/2024-01-15/industream_20240115_020000.sql.gz"
    echo "  $0 -d DataCatalog -y                   # Restore without confirmation"
    echo ""
}

list_backups() {
    log "Available backups in ${BACKUP_DIR}:"
    echo ""

    if [ ! -d "${BACKUP_DIR}" ]; then
        log_error "Backup directory not found: ${BACKUP_DIR}"
        exit 1
    fi

    # Find all backup directories and list their contents
    find "${BACKUP_DIR}" -type d -name "20*" 2>/dev/null | sort -r | head -10 | while read -r dir; do
        echo -e "${BLUE}${dir}/${NC}"
        ls -lh "${dir}"/*.sql.gz 2>/dev/null | while read -r line; do
            echo "  ${line}"
        done
        echo ""
    done

    # Show available databases
    echo -e "${BLUE}Available databases in backups:${NC}"
    find "${BACKUP_DIR}" -type f -name "*.sql.gz" -exec basename {} \; 2>/dev/null | \
        grep -v "^full_cluster" | \
        sed 's/_[0-9]*_[0-9]*\.sql\.gz$//' | \
        sort -u | while read -r db; do
            LATEST=$(find "${BACKUP_DIR}" -type f -name "${db}_*.sql.gz" 2>/dev/null | sort -r | head -n 1)
            if [ -n "${LATEST}" ]; then
                SIZE=$(du -h "${LATEST}" 2>/dev/null | cut -f1)
                echo "  - ${db} (latest: $(basename "${LATEST}"), ${SIZE})"
            fi
        done
}

find_latest_backup() {
    local database="$1"
    find "${BACKUP_DIR}" -type f -name "${database}_*.sql.gz" 2>/dev/null | sort -r | head -n 1
}

load_password() {
    if [ -f /run/secrets/postgres_admin_password ]; then
        export PGPASSWORD=$(cat /run/secrets/postgres_admin_password)
    elif [ -n "${POSTGRES_PASSWORD:-}" ]; then
        export PGPASSWORD="${POSTGRES_PASSWORD}"
    else
        log_error "No PostgreSQL password found"
        log "Set POSTGRES_PASSWORD env var or mount /run/secrets/postgres_admin_password"
        exit 1
    fi
}

restore_database() {
    local database="$1"
    local backup_file="$2"
    local drop_first="${3:-true}"

    if [ ! -f "${backup_file}" ]; then
        log_error "Backup file not found: ${backup_file}"
        exit 1
    fi

    load_password

    log "Restoring ${database} from ${backup_file}..."

    if [ "${drop_first}" = "true" ]; then
        # Check if database exists
        DB_EXISTS=$(psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -tAc \
            "SELECT 1 FROM pg_database WHERE datname='${database}'" postgres 2>/dev/null || echo "")

        if [ "${DB_EXISTS}" = "1" ]; then
            log_warning "Dropping existing database ${database}..."

            # Terminate existing connections
            psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -c \
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${database}' AND pid <> pg_backend_pid();" \
                postgres 2>/dev/null || true

            # Drop database
            psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -c \
                "DROP DATABASE IF EXISTS \"${database}\";" postgres
        fi

        # Recreate database
        log "Creating database ${database}..."
        psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -c \
            "CREATE DATABASE \"${database}\";" postgres
    fi

    # Restore backup
    log "Decompressing and restoring..."
    if gunzip -c "${backup_file}" | psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" "${database}" 2>&1; then
        log_success "Database ${database} restored successfully"

        # Show table count
        TABLE_COUNT=$(psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -tAc \
            "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" "${database}" 2>/dev/null || echo "?")
        log "Tables restored: ${TABLE_COUNT}"
    else
        log_error "Failed to restore ${database}"
        exit 1
    fi
}

# ============================================================================
# Main
# ============================================================================
DATABASE=""
BACKUP_FILE=""
LIST_ONLY=false
DROP_FIRST=true
SKIP_CONFIRM=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--database)
            DATABASE="$2"
            shift 2
            ;;
        -f|--file)
            BACKUP_FILE="$2"
            shift 2
            ;;
        -l|--list)
            LIST_ONLY=true
            shift
            ;;
        --no-drop)
            DROP_FIRST=false
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
            # Support legacy positional argument (backup file)
            if [ -z "${BACKUP_FILE}" ] && [ -f "$1" ]; then
                BACKUP_FILE="$1"
            else
                log_error "Unknown option: $1"
                show_usage
                exit 1
            fi
            shift
            ;;
    esac
done

echo ""
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   PostgreSQL Restore Tool${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo ""

if [ "${LIST_ONLY}" = "true" ]; then
    list_backups
    exit 0
fi

# If file specified but no database, try to extract from filename
if [ -n "${BACKUP_FILE}" ] && [ -z "${DATABASE}" ]; then
    FILENAME=$(basename "${BACKUP_FILE}")
    if [[ "${FILENAME}" == full_cluster_* ]]; then
        log_error "Full cluster restore not supported in this version"
        log "Restore individual databases instead"
        exit 1
    else
        DATABASE=$(echo "${FILENAME}" | sed 's/_[0-9]\{8\}_[0-9]\{6\}\.sql\.gz$//')
        log "Detected database from filename: ${DATABASE}"
    fi
fi

if [ -z "${DATABASE}" ]; then
    log_error "Database name is required"
    show_usage
    exit 1
fi

# Find backup file if not specified
if [ -z "${BACKUP_FILE}" ]; then
    BACKUP_FILE=$(find_latest_backup "${DATABASE}")
    if [ -z "${BACKUP_FILE}" ]; then
        log_error "No backup found for database: ${DATABASE}"
        echo ""
        log "Available databases in backups:"
        find "${BACKUP_DIR}" -type f -name "*.sql.gz" -exec basename {} \; 2>/dev/null | \
            grep -v "^full_cluster" | \
            sed 's/_[0-9]*_[0-9]*\.sql\.gz$//' | sort -u
        exit 1
    fi
    log "Using latest backup: ${BACKUP_FILE}"
fi

# Show backup info
BACKUP_SIZE=$(du -h "${BACKUP_FILE}" 2>/dev/null | cut -f1)
BACKUP_DATE=$(stat -c %y "${BACKUP_FILE}" 2>/dev/null | cut -d. -f1 || stat -f %Sm "${BACKUP_FILE}" 2>/dev/null)

echo ""
log "Restore Details:"
echo "  Database:    ${DATABASE}"
echo "  Backup:      ${BACKUP_FILE}"
echo "  Size:        ${BACKUP_SIZE}"
echo "  Backup Date: ${BACKUP_DATE}"
echo "  Drop First:  ${DROP_FIRST}"
echo ""

# Confirmation
if [ "${SKIP_CONFIRM}" != "true" ]; then
    if [ "${DROP_FIRST}" = "true" ]; then
        log_warning "This will DROP and recreate database '${DATABASE}'!"
    else
        log_warning "This will restore into existing database '${DATABASE}'"
    fi
    echo ""
    read -p "Continue? [y/N] " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Restore cancelled"
        exit 0
    fi
fi

restore_database "${DATABASE}" "${BACKUP_FILE}" "${DROP_FIRST}"

echo ""
log_success "Restore completed!"
echo ""
