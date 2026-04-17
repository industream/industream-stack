#!/bin/bash
# =============================================================================
# ROTATE KEYCLOAK ADMIN PASSWORD
# =============================================================================
# Rotates the Keycloak master-realm admin password SAFELY:
#   1. Changes the password inside Keycloak via kcadm.sh (updates the DB).
#   2. Updates the local secrets file.
#   3. Swaps the Docker Swarm secret and restarts the service.
#
# The naive approach (just regenerating the Docker Secret) does NOT work for
# Keycloak: KC_BOOTSTRAP_ADMIN_PASSWORD is only honored on first boot. After
# that, the hash lives in the Keycloak DB — the secret must be changed in the
# DB FIRST, then the Docker Secret swapped to match.
#
# Usage:
#   ./rotate-keycloak-password.sh [--env <env>] [--new-password <pw>]
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

ENV="prod"
NEW_PASSWORD=""

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
            echo "Usage: $0 [--env <env>] [--new-password <pw>]"
            echo "  --env             Environment (default: prod)."
            echo "  --new-password    Use this password instead of generating one."
            echo "  --help / -h       Show this message."
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [--env <env>] [--new-password <pw>]" >&2
            exit 1
            ;;
    esac
done

SECRETS_DIR="${INDUSTREAM_SECRETS_DIR:-$HOME/industream-platform/secrets}"
OLD_PW_FILE="$SECRETS_DIR/keycloak_admin_password"
STACK_NAME="industream-${ENV}"
SERVICE_NAME="${STACK_NAME}_keycloak"
SECRET_NAME="${ENV}_keycloak_admin_password"

# =============================================================================
# 1. Find Keycloak container
# =============================================================================
KC_CONTAINER=$(docker ps -qf "name=${SERVICE_NAME}" | head -1)
if [ -z "$KC_CONTAINER" ]; then
    echo -e "${RED}✗ No running Keycloak container found for service '${SERVICE_NAME}'${NC}"
    echo "  Make sure the Industream stack is running: industream status"
    exit 1
fi
echo -e "${GREEN}✓ Keycloak container: $(docker inspect --format '{{.Name}}' "$KC_CONTAINER" | sed 's|^/||')${NC}"

# =============================================================================
# 2. Load OLD password
# =============================================================================
# Read from the mounted secret inside the running container — this is the
# authoritative source because it matches what Keycloak was bootstrapped with.
# The host file in secrets/ can drift (e.g. a previous --regenerate that
# rewrote the file but failed to update the Swarm secret on a live service).
OLD_PW=$(docker exec "$KC_CONTAINER" cat "/run/secrets/${SECRET_NAME}" 2>/dev/null || true)
if [ -z "$OLD_PW" ]; then
    echo -e "${YELLOW}⚠ Could not read /run/secrets/${SECRET_NAME} from container, falling back to host file${NC}"
    if [ ! -f "$OLD_PW_FILE" ]; then
        echo -e "${RED}✗ Old password file not found: $OLD_PW_FILE${NC}"
        echo "  Override the path with: INDUSTREAM_SECRETS_DIR=/path/to/secrets $0 ..."
        exit 1
    fi
    OLD_PW=$(cat "$OLD_PW_FILE")
    if [ -z "$OLD_PW" ]; then
        echo -e "${RED}✗ Old password file is empty: $OLD_PW_FILE${NC}"
        exit 1
    fi
fi

ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
if [ -f "$(dirname "$SECRETS_DIR")/.env" ]; then
    ENV_ADMIN=$(grep -E '^KEYCLOAK_ADMIN=' "$(dirname "$SECRETS_DIR")/.env" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
    [ -n "$ENV_ADMIN" ] && ADMIN_USER="$ENV_ADMIN"
fi
echo -e "${GREEN}✓ Admin user: $ADMIN_USER${NC}"

# =============================================================================
# 3. Generate NEW password if needed
# =============================================================================
if [ -z "$NEW_PASSWORD" ]; then
    NEW_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-32)
    PW_GENERATED=1
else
    PW_GENERATED=0
fi

# Keycloak may be deployed under a relative path (e.g. KC_HTTP_RELATIVE_PATH=/auth)
# The kcadm.sh --server URL must include that path, otherwise everything 404s.
KC_RELATIVE_PATH=$(docker exec "$KC_CONTAINER" printenv KC_HTTP_RELATIVE_PATH 2>/dev/null | sed 's|^/||;s|/$||' || true)
if [ -n "$KC_RELATIVE_PATH" ]; then
    KC_SERVER="http://localhost:8080/$KC_RELATIVE_PATH"
else
    KC_SERVER="http://localhost:8080"
fi
echo -e "${GREEN}✓ kcadm server URL: $KC_SERVER${NC}"

# =============================================================================
# 4. Authenticate kcadm with OLD password
# =============================================================================
echo -e "${BLUE}Authenticating against Keycloak with current password...${NC}"
if ! docker exec -i "$KC_CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials \
        --server "$KC_SERVER" \
        --realm master \
        --user "$ADMIN_USER" \
        --password "$OLD_PW" > /dev/null 2>&1; then
    echo -e "${RED}✗ Authentication failed with the current password${NC}"
    echo "  The password file '$OLD_PW_FILE' may be stale or wrong."
    echo "  Restore the correct password there before rotating."
    exit 1
fi
echo -e "${GREEN}✓ Authenticated with current password${NC}"

# =============================================================================
# 5. Find the admin user ID
# =============================================================================
ADMIN_ID=$(docker exec -i "$KC_CONTAINER" /opt/keycloak/bin/kcadm.sh get users \
    -r master -q "username=$ADMIN_USER" --fields id --format csv --noquotes 2>/dev/null \
    | tail -1 | tr -d '\r\n ')
if [ -z "$ADMIN_ID" ]; then
    echo -e "${RED}✗ Could not resolve admin user ID for '$ADMIN_USER'${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Admin user ID: $ADMIN_ID${NC}"

# =============================================================================
# 6. Set the new password inside Keycloak
# =============================================================================
echo -e "${BLUE}Updating password in Keycloak DB via kcadm.sh...${NC}"
if ! docker exec -i "$KC_CONTAINER" /opt/keycloak/bin/kcadm.sh set-password \
        -r master --userid "$ADMIN_ID" --new-password "$NEW_PASSWORD" > /dev/null 2>&1; then
    echo -e "${RED}✗ Failed to set new password in Keycloak${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Password updated in Keycloak DB${NC}"

# =============================================================================
# 7. Verify NEW password works
# =============================================================================
echo -e "${BLUE}Verifying new password...${NC}"
if ! docker exec -i "$KC_CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials \
        --server "$KC_SERVER" \
        --realm master \
        --user "$ADMIN_USER" \
        --password "$NEW_PASSWORD" > /dev/null 2>&1; then
    # DB now holds the NEW password, but we cannot confirm it works. Do NOT try
    # to roll back — the old hash is gone. Ask the user to intervene manually.
    echo -e "${RED}✗ New password verification failed${NC}"
    echo -e "${YELLOW}⚠ The Keycloak DB now holds the NEW password, but verification failed.${NC}"
    echo -e "${YELLOW}  DO NOT re-run this script. You must manually:${NC}"
    echo "    1. Confirm the new password works via the Keycloak UI"
    echo "    2. Write it to: $OLD_PW_FILE"
    echo "    3. Recreate the Docker Swarm secret '$SECRET_NAME'"
    echo "    4. Restart the service: docker service update --force $SERVICE_NAME"
    echo ""
    echo "  New password (save it NOW): $NEW_PASSWORD"
    exit 1
fi
echo -e "${GREEN}✓ New password verified${NC}"

# =============================================================================
# 8. Update local secrets file
# =============================================================================
printf '%s' "$NEW_PASSWORD" > "$OLD_PW_FILE"
chmod 600 "$OLD_PW_FILE"
echo -e "${GREEN}✓ Local secret file updated: $OLD_PW_FILE${NC}"

# =============================================================================
# 9. Swap the Docker Swarm secret
# =============================================================================
# Scaling to 0 isn't enough: the service SPEC still references the secret,
# so `docker secret rm` is refused. We have to detach the secret from the
# service first (--secret-rm), then rm+create, then reattach (--secret-add).
echo -e "${BLUE}Scaling $SERVICE_NAME down to drain tasks...${NC}"
docker service scale "$SERVICE_NAME=0" > /dev/null

for _ in $(seq 1 60); do
    ACTIVE=$(docker service ps "$SERVICE_NAME" \
        --format "{{.CurrentState}}" 2>/dev/null \
        | grep -E "^(Running|Starting|Preparing|Assigned|Accepted|Ready)" \
        | wc -l)
    [ "$ACTIVE" = "0" ] && break
    sleep 1
done
echo -e "${GREEN}✓ Tasks drained${NC}"

echo -e "${BLUE}Detaching secret '$SECRET_NAME' from service...${NC}"
docker service update --quiet --secret-rm "$SECRET_NAME" "$SERVICE_NAME" > /dev/null
echo -e "${GREEN}✓ Secret detached${NC}"

if docker secret inspect "$SECRET_NAME" > /dev/null 2>&1; then
    docker secret rm "$SECRET_NAME" > /dev/null
    echo -e "${GREEN}✓ Removed old secret '$SECRET_NAME'${NC}"
fi

printf '%s' "$NEW_PASSWORD" | docker secret create "$SECRET_NAME" - > /dev/null
echo -e "${GREEN}✓ Created new secret '$SECRET_NAME'${NC}"

echo -e "${BLUE}Re-attaching secret to service...${NC}"
docker service update --quiet \
    --secret-add "source=$SECRET_NAME,target=$SECRET_NAME" \
    "$SERVICE_NAME" > /dev/null
echo -e "${GREEN}✓ Secret re-attached${NC}"

echo -e "${BLUE}Scaling $SERVICE_NAME back up...${NC}"
docker service scale "$SERVICE_NAME=1" > /dev/null

# =============================================================================
# 10. Wait for the service to be healthy
# =============================================================================
echo -e "${BLUE}Waiting for Keycloak to be running...${NC}"
HEALTHY=0
for _ in $(seq 1 120); do
    STATE=$(docker service ps "$SERVICE_NAME" \
        --filter "desired-state=running" \
        --format '{{.CurrentState}}' 2>/dev/null | head -1)
    if echo "$STATE" | grep -q '^Running'; then
        HEALTHY=1
        break
    fi
    sleep 2
done
if [ "$HEALTHY" -ne 1 ]; then
    echo -e "${YELLOW}⚠ Service did not reach Running state within timeout${NC}"
    echo "  Check with: docker service ps $SERVICE_NAME"
else
    echo -e "${GREEN}✓ Service is running${NC}"
fi

# =============================================================================
# 11. Summary
# =============================================================================
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Keycloak admin password rotated${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Environment:   $ENV"
echo "  Service:       $SERVICE_NAME"
echo "  Admin user:    $ADMIN_USER"
echo "  New password:  $NEW_PASSWORD"
echo "  Secret file:   $OLD_PW_FILE"
echo "  Swarm secret:  $SECRET_NAME"
echo ""
if [ "$PW_GENERATED" -eq 1 ]; then
    echo -e "${YELLOW}⚠ Password was auto-generated — SAVE IT NOW to your password manager${NC}"
    echo ""
fi
