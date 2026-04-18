#!/bin/bash
# =============================================================================
# ROTATE MINIO ROOT PASSWORD
# =============================================================================
# Safely rotates the MinIO root (MINIO_ROOT_PASSWORD) without breaking the
# cluster.
#
# Why this script exists:
#   MinIO reads MINIO_ROOT_USER / MINIO_ROOT_PASSWORD at boot time. Unlike
#   Postgres/Keycloak, MinIO does NOT persist the root credential inside the
#   data volume — it always uses whatever the environment says on startup.
#   That means we can:
#     1. Update the local secret file (atomic).
#     2. Swap the Docker Swarm secret.
#     3. Restart the service (it will re-bind the new root password on boot).
#     4. Verify via `mc admin info`.
#
# Usage:
#   ./rotate-minio-root-password.sh [--env <env>] [--new-password <pw>]
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
    echo "  --env             Environment (default: prod)."
    echo "  --new-password    Use this password instead of generating one."
    echo "  --help / -h       Show this help."
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --env) ENV="$2"; shift 2 ;;
        --new-password) NEW_PASSWORD="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *)
            echo -e "${RED}✗ Unknown argument: $1${NC}"
            usage 1
            ;;
    esac
done

STACK_NAME="industream-${ENV}"
SERVICE_NAME="${STACK_NAME}_minio"
SECRET_NAME="${ENV}_minio_root_password"
SECRETS_DIR="${INDUSTREAM_SECRETS_DIR:-$HOME/industream-platform/secrets}"

# Support both per-env and flat secret-file layouts.
CANDIDATE_FILES=(
    "$SECRETS_DIR/$ENV/minio_root_password"
    "$SECRETS_DIR/minio_root_password"
)
PW_FILE=""
for candidate in "${CANDIDATE_FILES[@]}"; do
    if [ -f "$candidate" ]; then
        PW_FILE="$candidate"
        break
    fi
done
[ -z "$PW_FILE" ] && PW_FILE="$SECRETS_DIR/minio_root_password"

# =============================================================================
# 1. Find MinIO container
# =============================================================================
echo -e "${BLUE}Locating MinIO container for stack '$STACK_NAME'...${NC}"
MINIO_CONTAINER=$(docker ps -qf "name=${SERVICE_NAME}" | head -1)
if [ -z "$MINIO_CONTAINER" ]; then
    echo -e "${RED}✗ No running MinIO container found for service '$SERVICE_NAME'${NC}"
    exit 1
fi
CONTAINER_NAME=$(docker inspect --format '{{.Name}}' "$MINIO_CONTAINER" | sed 's|^/||')
echo -e "${GREEN}✓ MinIO container: $CONTAINER_NAME${NC}"

ROOT_USER=$(docker exec "$MINIO_CONTAINER" printenv MINIO_ROOT_USER 2>/dev/null || echo "")
if [ -z "$ROOT_USER" ]; then
    # MinIO image may read the user from *_FILE as well.
    ROOT_USER_FILE=$(docker exec "$MINIO_CONTAINER" printenv MINIO_ROOT_USER_FILE 2>/dev/null || true)
    if [ -n "$ROOT_USER_FILE" ]; then
        ROOT_USER=$(docker exec "$MINIO_CONTAINER" cat "$ROOT_USER_FILE" 2>/dev/null || true)
    fi
fi
[ -z "$ROOT_USER" ] && ROOT_USER="minioadmin"
echo -e "${GREEN}✓ Root user: $ROOT_USER${NC}"

# =============================================================================
# 2. Load OLD root password
# =============================================================================
OLD_PASSWORD=$(docker exec "$MINIO_CONTAINER" cat "/run/secrets/${SECRET_NAME}" 2>/dev/null || true)
if [ -z "$OLD_PASSWORD" ]; then
    echo -e "${YELLOW}⚠ Could not read /run/secrets/${SECRET_NAME}, falling back to host file${NC}"
    if [ ! -f "$PW_FILE" ]; then
        echo -e "${RED}✗ Root password file not found: $PW_FILE${NC}"
        exit 1
    fi
    OLD_PASSWORD=$(cat "$PW_FILE")
fi
if [ -z "$OLD_PASSWORD" ]; then
    echo -e "${RED}✗ Current root password could not be determined${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Loaded current root password${NC}"

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

# MinIO root password must be at least 8 characters.
if [ "${#NEW_PASSWORD}" -lt 8 ]; then
    echo -e "${RED}✗ New password must be at least 8 characters${NC}"
    exit 1
fi

# =============================================================================
# 4. Verify the OLD password works via `mc`
# =============================================================================
echo -e "${BLUE}Verifying current root password with mc...${NC}"
if ! docker exec -i \
        -e MC_HOST_rotate="http://${ROOT_USER}:${OLD_PASSWORD}@localhost:9000" \
        "$MINIO_CONTAINER" mc admin info rotate >/dev/null 2>&1; then
    echo -e "${RED}✗ Authentication with the current root password failed${NC}"
    echo "  Your local secret file or Swarm secret may be out of sync with MinIO."
    echo "  Resolve the drift before attempting rotation."
    exit 1
fi
echo -e "${GREEN}✓ Current password verified${NC}"

# =============================================================================
# 5. Persist new password to the local secrets file (atomic)
# =============================================================================
echo -e "${BLUE}Updating local secrets file...${NC}"
mkdir -p "$(dirname "$PW_FILE")"
TMP_FILE=$(mktemp "${PW_FILE}.XXXXXX")
printf '%s' "$NEW_PASSWORD" > "$TMP_FILE"
chmod 600 "$TMP_FILE"
mv "$TMP_FILE" "$PW_FILE"
echo -e "${GREEN}✓ $PW_FILE updated (0600)${NC}"

# =============================================================================
# 6. Swap the Docker Swarm secret
# =============================================================================
# MinIO root auth is driven by the env var on boot, so the sequence is:
# scale to 0 → detach/rm/create/attach the swarm secret → scale back to 1.
echo -e "${BLUE}Scaling $SERVICE_NAME to 0 to swap secret safely...${NC}"
docker service scale "${SERVICE_NAME}=0" >/dev/null

for _ in $(seq 1 60); do
    ACTIVE=$(docker service ps "$SERVICE_NAME" \
        --format "{{.CurrentState}}" 2>/dev/null \
        | grep -E "^(Running|Starting|Preparing|Assigned|Accepted|Ready)" \
        | wc -l)
    [ "$ACTIVE" = "0" ] && break
    sleep 2
done
echo -e "${GREEN}✓ Service drained${NC}"

echo -e "${BLUE}Detaching secret '$SECRET_NAME' from service...${NC}"
docker service update --quiet --secret-rm "$SECRET_NAME" "$SERVICE_NAME" >/dev/null || true
echo -e "${GREEN}✓ Secret detached${NC}"

if docker secret inspect "$SECRET_NAME" >/dev/null 2>&1; then
    docker secret rm "$SECRET_NAME" >/dev/null
    echo -e "${GREEN}✓ Old secret removed${NC}"
fi

printf '%s' "$NEW_PASSWORD" | docker secret create "$SECRET_NAME" - >/dev/null
echo -e "${GREEN}✓ New secret created${NC}"

echo -e "${BLUE}Re-attaching secret to service...${NC}"
docker service update --quiet \
    --secret-add "source=$SECRET_NAME,target=$SECRET_NAME" \
    "$SERVICE_NAME" >/dev/null
echo -e "${GREEN}✓ Secret re-attached${NC}"

echo -e "${BLUE}Scaling $SERVICE_NAME back to 1...${NC}"
docker service scale "${SERVICE_NAME}=1" >/dev/null

# =============================================================================
# 7. Wait for the service to be Running
# =============================================================================
echo -e "${BLUE}Waiting for MinIO to be Running...${NC}"
SERVICE_READY=0
for _ in $(seq 1 120); do
    STATE=$(docker service ps "$SERVICE_NAME" \
        --filter "desired-state=running" \
        --format '{{.CurrentState}}' 2>/dev/null | head -1)
    if echo "$STATE" | grep -q '^Running'; then
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

NEW_CONTAINER=""
for _ in $(seq 1 30); do
    NEW_CONTAINER=$(docker ps -qf "name=${SERVICE_NAME}" | head -1)
    [ -n "$NEW_CONTAINER" ] && break
    sleep 2
done
if [ -z "$NEW_CONTAINER" ]; then
    echo -e "${RED}✗ Could not find new MinIO container after restart${NC}"
    exit 1
fi

# =============================================================================
# 8. Final auth check with the NEW password
# =============================================================================
echo -e "${BLUE}Waiting for MinIO to accept connections with the new password...${NC}"
AUTH_OK=0
for _ in $(seq 1 60); do
    if docker exec -i \
            -e MC_HOST_rotate="http://${ROOT_USER}:${NEW_PASSWORD}@localhost:9000" \
            "$NEW_CONTAINER" mc admin info rotate >/dev/null 2>&1; then
        AUTH_OK=1
        break
    fi
    sleep 2
done
if [ "$AUTH_OK" -ne 1 ]; then
    echo -e "${RED}✗ MinIO is up but authentication with the new password failed${NC}"
    echo "  Check container logs: docker logs $NEW_CONTAINER"
    exit 1
fi
echo -e "${GREEN}✓ New password works against the restarted MinIO${NC}"

# =============================================================================
# 9. Summary
# =============================================================================
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  MinIO root password rotated successfully${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Environment:    $ENV"
echo "  Service:        $SERVICE_NAME"
echo "  Secret:         $SECRET_NAME"
echo "  Root user:      $ROOT_USER"
echo "  Secrets file:   $PW_FILE"
echo ""
echo -e "${YELLOW}  NEW PASSWORD:${NC}"
echo -e "${YELLOW}    $NEW_PASSWORD${NC}"
echo ""
if [ "$PW_GENERATED" -eq 1 ]; then
    echo -e "${YELLOW}  ⚠ Auto-generated — save it in your password manager NOW.${NC}"
    echo -e "${YELLOW}    It is also stored at $PW_FILE (0600).${NC}"
else
    echo -e "${YELLOW}  ⚠ Make sure the password is recorded in your password manager.${NC}"
fi
echo ""
echo "  Any service that mounts $SECRET_NAME will pick up the new value"
echo "  on its next restart. Restart dependent services if needed."
echo ""
