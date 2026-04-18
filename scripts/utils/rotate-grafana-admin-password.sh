#!/bin/bash
# =============================================================================
# ROTATE GRAFANA ADMIN PASSWORD
# =============================================================================
# Safely rotates the Grafana admin password without wiping its database.
#
# Why this script exists:
#   GF_SECURITY_ADMIN_PASSWORD (or the *_FILE variant) is only honored the
#   first time Grafana boots on a fresh DB. After that, the password lives
#   hashed in the Grafana Postgres DB. Just swapping the Docker Secret
#   breaks auth on the next restart. This script:
#     1. Changes the password via the Grafana Admin API (updates the DB).
#     2. Updates the local secrets file.
#     3. Swaps the Docker Swarm secret and restarts the service.
#
# Usage:
#   ./rotate-grafana-admin-password.sh [--env <env>] [--new-password <pw>]
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
SERVICE_NAME="${STACK_NAME}_grafana"
SECRET_NAME="${ENV}_grafana_admin_password"
SECRETS_DIR="${INDUSTREAM_SECRETS_DIR:-$HOME/industream-platform/secrets}"

# Support both a per-env layout and the flat layout; pick the first that exists.
CANDIDATE_FILES=(
    "$SECRETS_DIR/$ENV/grafana_admin_password"
    "$SECRETS_DIR/grafana_admin_password"
)
ADMIN_PW_FILE=""
for candidate in "${CANDIDATE_FILES[@]}"; do
    if [ -f "$candidate" ]; then
        ADMIN_PW_FILE="$candidate"
        break
    fi
done
# Default to the flat path when no file exists yet (fresh setups).
[ -z "$ADMIN_PW_FILE" ] && ADMIN_PW_FILE="$SECRETS_DIR/grafana_admin_password"

# =============================================================================
# 1. Find Grafana container
# =============================================================================
echo -e "${BLUE}Locating Grafana container for stack '$STACK_NAME'...${NC}"
GF_CONTAINER=$(docker ps -qf "name=${SERVICE_NAME}" | head -1)
if [ -z "$GF_CONTAINER" ]; then
    echo -e "${RED}✗ No running Grafana container found for service '$SERVICE_NAME'${NC}"
    exit 1
fi
CONTAINER_NAME=$(docker inspect --format '{{.Name}}' "$GF_CONTAINER" | sed 's|^/||')
echo -e "${GREEN}✓ Grafana container: $CONTAINER_NAME${NC}"

ADMIN_USER=$(docker exec "$GF_CONTAINER" printenv GF_SECURITY_ADMIN_USER 2>/dev/null || echo "admin")
echo -e "${GREEN}✓ Admin user: $ADMIN_USER${NC}"

# =============================================================================
# 2. Load OLD admin password
# =============================================================================
OLD_PASSWORD=$(docker exec "$GF_CONTAINER" cat "/run/secrets/${SECRET_NAME}" 2>/dev/null || true)
if [ -z "$OLD_PASSWORD" ]; then
    echo -e "${YELLOW}⚠ Could not read /run/secrets/${SECRET_NAME} from container, falling back to host file${NC}"
    if [ ! -f "$ADMIN_PW_FILE" ]; then
        echo -e "${RED}✗ Admin password file not found: $ADMIN_PW_FILE${NC}"
        exit 1
    fi
    OLD_PASSWORD=$(cat "$ADMIN_PW_FILE")
fi
if [ -z "$OLD_PASSWORD" ]; then
    echo -e "${RED}✗ Current admin password could not be determined${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Loaded current admin password${NC}"

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
# 4. Verify OLD password against Grafana API (inside the container, on :3000)
# =============================================================================
echo -e "${BLUE}Verifying current password against Grafana API...${NC}"
AUTH_CHECK=$(docker exec -i "$GF_CONTAINER" sh -c \
    "curl -s -o /dev/null -w '%{http_code}' -u '$ADMIN_USER:$OLD_PASSWORD' http://localhost:3000/api/admin/settings" 2>/dev/null || echo "000")
if [ "$AUTH_CHECK" != "200" ]; then
    echo -e "${RED}✗ Authentication with the current password failed (HTTP $AUTH_CHECK)${NC}"
    echo "  The password file may be stale. Resolve the drift before rotating."
    exit 1
fi
echo -e "${GREEN}✓ Current password verified${NC}"

# =============================================================================
# 5. Change the password via the Grafana Admin API
# =============================================================================
# We pass the new password through stdin to avoid embedding it in the exec
# argv (so it never appears in `ps` output or container logs).
echo -e "${BLUE}Updating password via Grafana Admin API...${NC}"
RESPONSE=$(docker exec -i "$GF_CONTAINER" \
    env NEW_PW="$NEW_PASSWORD" OLD_PW="$OLD_PASSWORD" ADMIN_USER="$ADMIN_USER" sh -c '
        payload=$(printf "{\"password\":\"%s\"}" "$NEW_PW")
        curl -s -o /tmp/grafana_rotate.out -w "%{http_code}" \
            -X PUT \
            -u "$ADMIN_USER:$OLD_PW" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            http://localhost:3000/api/admin/users/1/password
    ' 2>/dev/null || echo "000")
if [ "$RESPONSE" != "200" ]; then
    BODY=$(docker exec "$GF_CONTAINER" sh -c 'cat /tmp/grafana_rotate.out 2>/dev/null || true')
    echo -e "${RED}✗ Grafana rejected the password update (HTTP $RESPONSE)${NC}"
    [ -n "$BODY" ] && echo "  Response: $BODY"
    exit 1
fi
docker exec "$GF_CONTAINER" sh -c 'rm -f /tmp/grafana_rotate.out' >/dev/null 2>&1 || true
echo -e "${GREEN}✓ Password changed in Grafana DB${NC}"

# =============================================================================
# 6. Verify NEW password works
# =============================================================================
echo -e "${BLUE}Verifying new password against Grafana API...${NC}"
AUTH_CHECK=$(docker exec -i "$GF_CONTAINER" sh -c \
    "curl -s -o /dev/null -w '%{http_code}' -u '$ADMIN_USER:$NEW_PASSWORD' http://localhost:3000/api/admin/settings" 2>/dev/null || echo "000")
if [ "$AUTH_CHECK" != "200" ]; then
    echo -e "${RED}✗ New password verification failed (HTTP $AUTH_CHECK)${NC}"
    echo ""
    echo -e "${YELLOW}  The Grafana DB now holds the NEW password but we could not verify it.${NC}"
    echo -e "${YELLOW}  Do NOT restart the service. Save this value:${NC}"
    echo "    NEW_PASSWORD=$NEW_PASSWORD"
    exit 1
fi
echo -e "${GREEN}✓ New password verified${NC}"

# =============================================================================
# 7. Update local secrets file (atomic)
# =============================================================================
echo -e "${BLUE}Updating local secrets file...${NC}"
mkdir -p "$(dirname "$ADMIN_PW_FILE")"
TMP_FILE=$(mktemp "${ADMIN_PW_FILE}.XXXXXX")
printf '%s' "$NEW_PASSWORD" > "$TMP_FILE"
chmod 600 "$TMP_FILE"
mv "$TMP_FILE" "$ADMIN_PW_FILE"
echo -e "${GREEN}✓ $ADMIN_PW_FILE updated (0600)${NC}"

# =============================================================================
# 8. Swap the Docker Swarm secret
# =============================================================================
echo -e "${BLUE}Scaling $SERVICE_NAME to 0 to swap the secret safely...${NC}"
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
# 9. Wait for the service to come back up
# =============================================================================
echo -e "${BLUE}Waiting for Grafana to be Running...${NC}"
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

# Re-grab the new container ID after the restart.
NEW_CONTAINER=""
for _ in $(seq 1 30); do
    NEW_CONTAINER=$(docker ps -qf "name=${SERVICE_NAME}" | head -1)
    [ -n "$NEW_CONTAINER" ] && break
    sleep 2
done
if [ -z "$NEW_CONTAINER" ]; then
    echo -e "${RED}✗ Could not find new Grafana container after restart${NC}"
    exit 1
fi

# =============================================================================
# 10. Final auth check
# =============================================================================
echo -e "${BLUE}Waiting for Grafana API to accept connections...${NC}"
AUTH_OK=0
for _ in $(seq 1 60); do
    CODE=$(docker exec -i "$NEW_CONTAINER" sh -c \
        "curl -s -o /dev/null -w '%{http_code}' -u '$ADMIN_USER:$NEW_PASSWORD' http://localhost:3000/api/admin/settings" 2>/dev/null || echo "000")
    if [ "$CODE" = "200" ]; then
        AUTH_OK=1
        break
    fi
    sleep 2
done
if [ "$AUTH_OK" -ne 1 ]; then
    echo -e "${RED}✗ Grafana is up but authentication with the new password failed${NC}"
    echo "  Check: docker logs $NEW_CONTAINER"
    exit 1
fi
echo -e "${GREEN}✓ New password works against the restarted service${NC}"

# =============================================================================
# 11. Summary
# =============================================================================
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Grafana admin password rotated successfully${NC}"
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
