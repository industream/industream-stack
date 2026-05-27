#!/bin/bash
# =============================================================================
# POSTGRES MAJOR-VERSION MIGRATION HELPER
# =============================================================================
# Detects the PG_VERSION written inside the ${ENV}-postgres-data volume and,
# when it is older than the target version declared in .env, performs (or
# proposes) a dump/restore migration.
#
# Usage:
#   ./scripts/setup/migrate-postgres.sh --env prod                # interactive
#   ./scripts/setup/migrate-postgres.sh --env prod --check-only   # exit 2 if migration needed
#   ./scripts/setup/migrate-postgres.sh --env prod --yes          # non-interactive
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV=""
CHECK_ONLY=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --env) ENV="$2"; shift 2 ;;
        --check-only) CHECK_ONLY=true; shift ;;
        --yes|-y) AUTO_YES=true; shift ;;
        --help|-h)
            sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo -e "${RED}Unknown option: $1${NC}" >&2; exit 1 ;;
    esac
done

if [[ -z "${ENV}" ]]; then
    echo -e "${RED}--env is required (prod|dev|staging)${NC}" >&2
    exit 1
fi

ENV_FILE="${PROJECT_DIR}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
    echo -e "${RED}Missing ${ENV_FILE}${NC}" >&2
    exit 1
fi

# Read target version from .env. Supports both Debian-style "18.4" and
# Alpine-style "18-alpine" tags — we only care about the major number.
TARGET_VERSION=$(grep -E '^POSTGRES_VERSION=' "${ENV_FILE}" | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
if [[ -z "${TARGET_VERSION}" ]]; then
    echo -e "${RED}POSTGRES_VERSION not set in ${ENV_FILE}${NC}" >&2
    exit 1
fi
# Strip on first '.' or '-' to extract the major (18.4 -> 18, 18-alpine -> 18).
TARGET_MAJOR=$(echo "${TARGET_VERSION}" | sed -E 's/[.-].*$//')

VOLUME="${ENV}-postgres-data"
STACK_NAME="industream-${ENV}"
SERVICE="${STACK_NAME}_postgres"

# -----------------------------------------------------------------------------
# Detect installed version
# -----------------------------------------------------------------------------
if ! docker volume inspect "${VOLUME}" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ No existing volume '${VOLUME}' — fresh install, nothing to migrate.${NC}"
    exit 0
fi

# Read PG_VERSION file inside the volume via a throwaway container.
INSTALLED_MAJOR=$(docker run --rm \
    -v "${VOLUME}:/data:ro" \
    alpine:3 cat /data/PG_VERSION 2>/dev/null | tr -d '[:space:]' || true)

if [[ -z "${INSTALLED_MAJOR}" ]]; then
    echo -e "${YELLOW}Volume '${VOLUME}' exists but has no PG_VERSION marker — assuming empty.${NC}"
    exit 0
fi

echo -e "${BLUE}PostgreSQL versions for env '${ENV}':${NC}"
echo -e "  Installed (in volume): ${YELLOW}${INSTALLED_MAJOR}${NC}"
echo -e "  Target (.env):         ${GREEN}${TARGET_VERSION} (major ${TARGET_MAJOR})${NC}"

if [[ "${INSTALLED_MAJOR}" == "${TARGET_MAJOR}" ]]; then
    echo -e "${GREEN}✓ Versions match — no migration needed.${NC}"
    exit 0
fi

if [[ "${INSTALLED_MAJOR}" -gt "${TARGET_MAJOR}" ]]; then
    echo -e "${RED}✗ Installed version is newer than target. Downgrade is not supported.${NC}"
    exit 1
fi

# -----------------------------------------------------------------------------
# Migration needed
# -----------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}⚠ Major-version migration required: PG${INSTALLED_MAJOR} → PG${TARGET_MAJOR}${NC}"
echo -e "  Strategy: pg_dumpall → stop stack → backup volume → fresh deploy → restore"
echo ""

if [[ "${CHECK_ONLY}" == true ]]; then
    echo -e "${YELLOW}--check-only set; run again without it to perform the migration.${NC}"
    exit 2
fi

if [[ "${AUTO_YES}" != true ]]; then
    read -r -p "Proceed with migration of '${STACK_NAME}'? [y/N] " confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Step 1 — Dump
# -----------------------------------------------------------------------------
BACKUP_DIR="${PROJECT_DIR}/secrets/pg-migration"
mkdir -p "${BACKUP_DIR}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DUMP_FILE="${BACKUP_DIR}/${ENV}_pg${INSTALLED_MAJOR}_to_pg${TARGET_MAJOR}_${TIMESTAMP}.sql"

echo -e "${BLUE}[1/5] Dumping cluster to ${DUMP_FILE}${NC}"
RUNNING_TASK=$(docker ps -q -f "name=${SERVICE}." | head -1)
if [[ -z "${RUNNING_TASK}" ]]; then
    echo -e "${RED}Postgres service '${SERVICE}' is not running. Start the stack first.${NC}"
    exit 1
fi
docker exec "${RUNNING_TASK}" \
    bash -c 'pg_dumpall -U "${POSTGRES_USER:-postgres}"' > "${DUMP_FILE}"
echo -e "${GREEN}✓ Dump complete ($(du -h "${DUMP_FILE}" | cut -f1))${NC}"

# -----------------------------------------------------------------------------
# Step 2 — Remove stack
# -----------------------------------------------------------------------------
echo -e "${BLUE}[2/5] Removing stack '${STACK_NAME}'${NC}"
docker stack rm "${STACK_NAME}"

echo -e "${BLUE}    Waiting for tasks to drain...${NC}"
for i in {1..60}; do
    if ! docker service ls --filter "name=${STACK_NAME}_" --format '{{.Name}}' | grep -q .; then
        break
    fi
    sleep 2
done

# -----------------------------------------------------------------------------
# Step 3 — Backup old volume (rename via clone + delete)
# -----------------------------------------------------------------------------
BACKUP_VOLUME="${VOLUME}-pg${INSTALLED_MAJOR}-${TIMESTAMP}"
echo -e "${BLUE}[3/5] Backing up old volume → ${BACKUP_VOLUME}${NC}"
docker volume create "${BACKUP_VOLUME}" >/dev/null
docker run --rm \
    -v "${VOLUME}:/from:ro" \
    -v "${BACKUP_VOLUME}:/to" \
    alpine:3 sh -c 'cd /from && cp -a . /to/'
echo -e "${GREEN}✓ Old volume cloned. Removing live volume to force fresh init...${NC}"
docker volume rm "${VOLUME}"

# -----------------------------------------------------------------------------
# Step 4 — Redeploy stack (PG18 will initdb the empty volume)
# -----------------------------------------------------------------------------
echo -e "${BLUE}[4/5] Redeploying stack via deploy-swarm.sh${NC}"
"${PROJECT_DIR}/scripts/deploy-swarm.sh" --env "${ENV}" --skip-postgres-migration

echo -e "${BLUE}    Waiting for postgres to accept connections...${NC}"
for i in {1..60}; do
    NEW_TASK=$(docker ps -q -f "name=${SERVICE}." | head -1)
    if [[ -n "${NEW_TASK}" ]] && docker exec "${NEW_TASK}" \
            pg_isready -U "${POSTGRES_ADMIN_USER:-postgres}" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
NEW_TASK=$(docker ps -q -f "name=${SERVICE}." | head -1)
if [[ -z "${NEW_TASK}" ]]; then
    echo -e "${RED}Postgres did not come back up. Rollback: restore from volume '${BACKUP_VOLUME}'.${NC}"
    exit 1
fi

# -----------------------------------------------------------------------------
# Step 5 — Restore
# -----------------------------------------------------------------------------
echo -e "${BLUE}[5/5] Restoring dump into PG${TARGET_MAJOR}${NC}"
docker exec -i "${NEW_TASK}" \
    psql -U "${POSTGRES_ADMIN_USER:-postgres}" -d postgres < "${DUMP_FILE}"

echo ""
echo -e "${GREEN}✓ Migration complete.${NC}"
echo -e "  Backup volume kept: ${BACKUP_VOLUME}"
echo -e "  Dump file kept:     ${DUMP_FILE}"
echo -e "  Once you've verified everything, drop the backup with:"
echo -e "    docker volume rm ${BACKUP_VOLUME}"
