#!/bin/bash
# =============================================================================
# ROTATE POSTGRES ADMIN PASSWORD
# =============================================================================
# Safely rotates the Postgres admin password without wiping the data volume.
#
# Why this script exists:
#   Postgres reads POSTGRES_PASSWORD only on first init. After that, the
#   password lives hashed in pg_authid inside the data volume. Just swapping
#   the Docker Secret breaks auth on the next restart. This script changes
#   the password IN the DB first, then swaps the Docker Secret, then restarts
#   the service — no data loss, no destructive reinit.
#
# Usage:
#   ./rotate-postgres-password.sh [--env <env>] [--new-password <pw>]
#
# Examples:
#   ./rotate-postgres-password.sh
#   ./rotate-postgres-password.sh --env staging
#   ./rotate-postgres-password.sh --new-password 'My$tr0ng!Pass'
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

ENV="prod"
NEW_PASSWORD=""

usage() {
    echo "Usage: $0 [--env <env>] [--new-password <pw>]"
    echo "  --env             Environment (default: prod). Affects secret name + service."
    echo "  --new-password    Use this password instead of generating one."
    echo "  --help / -h       Show this help."
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --env)
            ENV="$2"
            shift 2
            ;;
        --new-password)
            NEW_PASSWORD="$2"
            shift 2
            ;;
        -h|--help)
            usage 0
            ;;
        *)
            echo -e "${RED}✗ Unknown argument: $1${NC}"
            usage 1
            ;;
    esac
done

STACK_NAME="industream-${ENV}"
SERVICE_NAME="${STACK_NAME}_postgres"
SECRET_NAME="${ENV}_postgres_admin_password"
SECRETS_DIR="${INDUSTREAM_SECRETS_DIR:-$HOME/industream-platform/secrets}"
ADMIN_PW_FILE="$SECRETS_DIR/postgres_admin_password"

# =============================================================================
# 1. Find Postgres container
# =============================================================================
echo -e "${BLUE}Locating Postgres container for stack '$STACK_NAME'...${NC}"
POSTGRES_CONTAINER=$(docker ps -qf "name=${SERVICE_NAME}" | head -1)
if [ -z "$POSTGRES_CONTAINER" ]; then
    echo -e "${RED}✗ No running Postgres container found for service '$SERVICE_NAME'${NC}"
    echo "  Make sure the Industream stack is running: industream status"
    exit 1
fi
CONTAINER_NAME=$(docker inspect --format '{{.Name}}' "$POSTGRES_CONTAINER" | sed 's|^/||')
echo -e "${GREEN}✓ Postgres container: $CONTAINER_NAME${NC}"

ADMIN_USER=$(docker exec "$POSTGRES_CONTAINER" printenv POSTGRES_USER 2>/dev/null || echo "postgres")
echo -e "${GREEN}✓ Admin user: $ADMIN_USER${NC}"

# =============================================================================
# 2. Load OLD admin password
# =============================================================================
if [ ! -f "$ADMIN_PW_FILE" ]; then
    echo -e "${RED}✗ Admin password file not found: $ADMIN_PW_FILE${NC}"
    echo "  Override the path with: INDUSTREAM_SECRETS_DIR=/path/to/secrets $0 ..."
    exit 1
fi
OLD_PASSWORD=$(cat "$ADMIN_PW_FILE")
if [ -z "$OLD_PASSWORD" ]; then
    echo -e "${RED}✗ Admin password file is empty: $ADMIN_PW_FILE${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Loaded current admin password from $ADMIN_PW_FILE${NC}"

# =============================================================================
# 3. Generate NEW password if not supplied
# =============================================================================
if [ -z "$NEW_PASSWORD" ]; then
    NEW_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-32)
    PW_GENERATED=1
    echo -e "${GREEN}✓ Generated new 32-char password${NC}"
else
    PW_GENERATED=0
    echo -e "${GREEN}✓ Using supplied new password${NC}"
fi

# =============================================================================
# 4. Verify the OLD password works
# =============================================================================
echo -e "${BLUE}Verifying current password against running Postgres...${NC}"
if ! docker exec -i -e PGPASSWORD="$OLD_PASSWORD" "$POSTGRES_CONTAINER" \
        psql -v ON_ERROR_STOP=1 -U "$ADMIN_USER" -d postgres -c "SELECT 1" >/dev/null 2>&1; then
    echo -e "${RED}✗ Authentication with the current password failed${NC}"
    echo "  The password in $ADMIN_PW_FILE does not match the live database."
    echo "  Resolve the drift before attempting rotation."
    exit 1
fi
echo -e "${GREEN}✓ Current password verified${NC}"

# =============================================================================
# 5. ALTER USER inside Postgres
# =============================================================================
echo -e "${BLUE}Updating password in Postgres (ALTER USER)...${NC}"
docker exec -i -e PGPASSWORD="$OLD_PASSWORD" "$POSTGRES_CONTAINER" \
  psql -v ON_ERROR_STOP=1 -U "$ADMIN_USER" -d postgres <<EOF
ALTER USER "$ADMIN_USER" WITH ENCRYPTED PASSWORD '$NEW_PASSWORD';
EOF
echo -e "${GREEN}✓ Password changed in pg_authid${NC}"

# =============================================================================
# 6. Verify the NEW password works
# =============================================================================
echo -e "${BLUE}Verifying new password against running Postgres...${NC}"
if ! docker exec -i -e PGPASSWORD="$NEW_PASSWORD" "$POSTGRES_CONTAINER" \
        psql -v ON_ERROR_STOP=1 -U "$ADMIN_USER" -d postgres -c "SELECT 1" >/dev/null 2>&1; then
    echo -e "${RED}✗ Authentication with the NEW password failed after ALTER USER${NC}"
    echo ""
    echo -e "${YELLOW}  IMPORTANT: the database now expects the new password but the${NC}"
    echo -e "${YELLOW}  Docker Secret has not been swapped yet. Do NOT restart the${NC}"
    echo -e "${YELLOW}  service. Investigate why psql rejected the new credential and${NC}"
    echo -e "${YELLOW}  retry the secret swap manually with this value:${NC}"
    echo ""
    echo "    NEW_PASSWORD=$NEW_PASSWORD"
    echo ""
    exit 1
fi
echo -e "${GREEN}✓ New password verified against live DB${NC}"

# =============================================================================
# 7. Persist the new password to the local secrets file
# =============================================================================
echo -e "${BLUE}Updating local secrets file...${NC}"
# Write through a temp file in the same directory to keep the swap atomic
# and avoid leaving a half-written password file on a crash.
TMP_FILE=$(mktemp "${ADMIN_PW_FILE}.XXXXXX")
printf '%s' "$NEW_PASSWORD" > "$TMP_FILE"
chmod 600 "$TMP_FILE"
mv "$TMP_FILE" "$ADMIN_PW_FILE"
echo -e "${GREEN}✓ $ADMIN_PW_FILE updated (0600)${NC}"

# =============================================================================
# 8. Swap the Docker Swarm secret
# =============================================================================
echo -e "${BLUE}Scaling $SERVICE_NAME to 0 to release the secret...${NC}"
docker service scale "${SERVICE_NAME}=0" >/dev/null

# Poll until no postgres tasks remain in a non-terminal state, otherwise
# `docker secret rm` will fail with "secret in use".
for _ in $(seq 1 60); do
    RUNNING_TASKS=$(docker service ps "$SERVICE_NAME" \
        --filter "desired-state=running" \
        --format "{{.ID}}" | wc -l)
    ACTIVE_TASKS=$(docker service ps "$SERVICE_NAME" \
        --format "{{.CurrentState}}" \
        | grep -E "^(Running|Starting|Preparing|Assigned|Accepted|Ready)" \
        | wc -l)
    if [ "$RUNNING_TASKS" -eq 0 ] && [ "$ACTIVE_TASKS" -eq 0 ]; then
        break
    fi
    sleep 2
done
echo -e "${GREEN}✓ Service drained${NC}"

echo -e "${BLUE}Removing old Docker secret '$SECRET_NAME'...${NC}"
if docker secret inspect "$SECRET_NAME" >/dev/null 2>&1; then
    docker secret rm "$SECRET_NAME" >/dev/null
    echo -e "${GREEN}✓ Old secret removed${NC}"
else
    echo -e "${YELLOW}⚠ Secret '$SECRET_NAME' did not exist — creating fresh${NC}"
fi

echo -e "${BLUE}Creating new Docker secret '$SECRET_NAME'...${NC}"
printf '%s' "$NEW_PASSWORD" | docker secret create "$SECRET_NAME" - >/dev/null
echo -e "${GREEN}✓ New secret created${NC}"

echo -e "${BLUE}Scaling $SERVICE_NAME back to 1...${NC}"
docker service scale "${SERVICE_NAME}=1" >/dev/null

# =============================================================================
# 9. Wait for the service to be Running
# =============================================================================
echo -e "${BLUE}Waiting for service to come back up...${NC}"
SERVICE_READY=0
for _ in $(seq 1 60); do
    RUNNING=$(docker service ps "$SERVICE_NAME" \
        --filter "desired-state=running" \
        --format "{{.CurrentState}}" \
        | grep -c "^Running" || true)
    if [ "$RUNNING" -ge 1 ]; then
        SERVICE_READY=1
        break
    fi
    sleep 2
done
if [ "$SERVICE_READY" -ne 1 ]; then
    echo -e "${RED}✗ Service did not reach Running state within timeout${NC}"
    echo "  Inspect with: docker service ps $SERVICE_NAME"
    exit 1
fi
echo -e "${GREEN}✓ Service is Running${NC}"

# Re-grab the (new) container ID — the previous one is gone after scale 0/1.
echo -e "${BLUE}Locating new Postgres container...${NC}"
NEW_CONTAINER=""
for _ in $(seq 1 30); do
    NEW_CONTAINER=$(docker ps -qf "name=${SERVICE_NAME}" | head -1)
    if [ -n "$NEW_CONTAINER" ]; then
        break
    fi
    sleep 2
done
if [ -z "$NEW_CONTAINER" ]; then
    echo -e "${RED}✗ Could not find new Postgres container after restart${NC}"
    exit 1
fi
echo -e "${GREEN}✓ New container: $(docker inspect --format '{{.Name}}' "$NEW_CONTAINER" | sed 's|^/||')${NC}"

# =============================================================================
# 10. Final verification — wait until Postgres accepts connections
# =============================================================================
echo -e "${BLUE}Waiting for Postgres to accept connections with the new password...${NC}"
AUTH_OK=0
for _ in $(seq 1 30); do
    if docker exec -i -e PGPASSWORD="$NEW_PASSWORD" "$NEW_CONTAINER" \
            psql -v ON_ERROR_STOP=1 -U "$ADMIN_USER" -d postgres -c "SELECT 1" >/dev/null 2>&1; then
        AUTH_OK=1
        break
    fi
    sleep 2
done
if [ "$AUTH_OK" -ne 1 ]; then
    echo -e "${RED}✗ Postgres is up but authentication with the new password failed${NC}"
    echo "  Check container logs: docker logs $NEW_CONTAINER"
    exit 1
fi
echo -e "${GREEN}✓ New password works against the restarted service${NC}"

# =============================================================================
# 11. Summary
# =============================================================================
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Postgres admin password rotated successfully${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Environment:    $ENV"
echo "  Service:        $SERVICE_NAME"
echo "  Secret:         $SECRET_NAME"
echo "  Admin user:     $ADMIN_USER"
echo "  Secrets file:   $ADMIN_PW_FILE"
echo ""
echo -e "${YELLOW}  NEW PASSWORD:${NC}"
echo -e "${YELLOW}    $NEW_PASSWORD${NC}"
echo ""
if [ "$PW_GENERATED" -eq 1 ]; then
    echo -e "${YELLOW}  ⚠ Auto-generated — save it in your password manager NOW.${NC}"
    echo -e "${YELLOW}    It is also stored at $ADMIN_PW_FILE (0600).${NC}"
else
    echo -e "${YELLOW}  ⚠ Make sure the password is recorded in your password manager.${NC}"
fi
echo ""
echo "  Any service that mounts $SECRET_NAME will pick up the new value"
echo "  on its next restart. Restart dependent services if needed."
echo ""
