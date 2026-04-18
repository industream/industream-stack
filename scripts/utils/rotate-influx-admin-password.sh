#!/bin/bash
# =============================================================================
# ROTATE INFLUXDB 2 ADMIN PASSWORD (and optionally the admin TOKEN)
# =============================================================================
# Safely rotates the InfluxDB admin password without wiping the bolt DB.
#
# Why this script exists:
#   DOCKER_INFLUXDB_INIT_PASSWORD is only honored on first boot. After that
#   the password (and the auth tokens) live inside the influxd bolt DB. Just
#   swapping the Docker Secret breaks subsequent auth. This script:
#     1. Uses `influx user password` against the live container to update
#        the password (authenticated with the existing admin token).
#     2. Updates the local secrets file.
#     3. Swaps the Docker Swarm secret and restarts the service.
#
# By default this script rotates only the admin PASSWORD. The admin TOKEN is
# a separate secret (used for service-to-service auth) — pass --rotate-token
# to also generate a new admin token. Be aware: rotating the token will break
# any caller still hardcoded against the old token.
#
# Usage:
#   ./rotate-influx-admin-password.sh [--env <env>] [--new-password <pw>] [--rotate-token]
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

ENV="prod"
NEW_PASSWORD=""
ROTATE_TOKEN=0

usage() {
    echo "Usage: $0 [--env <env>] [--new-password <pw>] [--rotate-token]"
    echo "  --env             Environment (default: prod). Affects secret name + service."
    echo "  --new-password    Use this admin password instead of generating one."
    echo "  --rotate-token    Also rotate the admin TOKEN (separate secret). Off by default."
    echo "  --help / -h       Show this help."
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --env) ENV="$2"; shift 2 ;;
        --new-password) NEW_PASSWORD="$2"; shift 2 ;;
        --rotate-token) ROTATE_TOKEN=1; shift ;;
        -h|--help) usage 0 ;;
        *)
            echo -e "${RED}✗ Unknown argument: $1${NC}"
            usage 1
            ;;
    esac
done

STACK_NAME="industream-${ENV}"
SERVICE_NAME="${STACK_NAME}_influxdb"
PW_SECRET_NAME="${ENV}_influx_admin_password"
TOKEN_SECRET_NAME="${ENV}_influx_admin_token"
SECRETS_DIR="${INDUSTREAM_SECRETS_DIR:-$HOME/industream-platform/secrets}"

# Support both per-env and flat secret-file layouts.
resolve_secret_file() {
    local base="$1"
    local candidates=(
        "$SECRETS_DIR/$ENV/$base"
        "$SECRETS_DIR/$base"
    )
    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            echo "$c"
            return
        fi
    done
    echo "$SECRETS_DIR/$base"
}
PW_FILE=$(resolve_secret_file "influx_admin_password")
TOKEN_FILE=$(resolve_secret_file "influx_admin_token")

# =============================================================================
# 1. Find InfluxDB container
# =============================================================================
echo -e "${BLUE}Locating InfluxDB container for stack '$STACK_NAME'...${NC}"
INFLUX_CONTAINER=$(docker ps -qf "name=${SERVICE_NAME}" | head -1)
if [ -z "$INFLUX_CONTAINER" ]; then
    echo -e "${RED}✗ No running InfluxDB container found for service '$SERVICE_NAME'${NC}"
    exit 1
fi
CONTAINER_NAME=$(docker inspect --format '{{.Name}}' "$INFLUX_CONTAINER" | sed 's|^/||')
echo -e "${GREEN}✓ InfluxDB container: $CONTAINER_NAME${NC}"

ADMIN_USER=$(docker exec "$INFLUX_CONTAINER" printenv DOCKER_INFLUXDB_INIT_USERNAME 2>/dev/null || echo "admin")
ORG=$(docker exec "$INFLUX_CONTAINER" printenv DOCKER_INFLUXDB_INIT_ORG 2>/dev/null || echo "industream")
echo -e "${GREEN}✓ Admin user: $ADMIN_USER${NC}"
echo -e "${GREEN}✓ Org: $ORG${NC}"

# =============================================================================
# 2. Load OLD admin password and OLD admin token
# =============================================================================
OLD_PASSWORD=$(docker exec "$INFLUX_CONTAINER" cat "/run/secrets/${PW_SECRET_NAME}" 2>/dev/null || true)
if [ -z "$OLD_PASSWORD" ]; then
    echo -e "${YELLOW}⚠ Could not read /run/secrets/${PW_SECRET_NAME}, falling back to host file${NC}"
    [ -f "$PW_FILE" ] && OLD_PASSWORD=$(cat "$PW_FILE")
fi
if [ -z "$OLD_PASSWORD" ]; then
    echo -e "${RED}✗ Current admin password could not be determined${NC}"
    exit 1
fi

OLD_TOKEN=$(docker exec "$INFLUX_CONTAINER" cat "/run/secrets/${TOKEN_SECRET_NAME}" 2>/dev/null || true)
if [ -z "$OLD_TOKEN" ]; then
    echo -e "${YELLOW}⚠ Could not read /run/secrets/${TOKEN_SECRET_NAME}, falling back to host file${NC}"
    [ -f "$TOKEN_FILE" ] && OLD_TOKEN=$(cat "$TOKEN_FILE")
fi
if [ -z "$OLD_TOKEN" ]; then
    echo -e "${RED}✗ Current admin token could not be determined (needed to authenticate the password change)${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Loaded current admin password and token${NC}"

# =============================================================================
# 3. Generate NEW password and (optionally) NEW token
# =============================================================================
if [ -z "$NEW_PASSWORD" ]; then
    NEW_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-32)
    PW_GENERATED=1
    echo -e "${GREEN}✓ Generated new 32-char password${NC}"
else
    PW_GENERATED=0
    echo -e "${GREEN}✓ Using supplied new password${NC}"
fi

NEW_TOKEN=""
if [ "$ROTATE_TOKEN" -eq 1 ]; then
    NEW_TOKEN=$(openssl rand -hex 32)
    echo -e "${GREEN}✓ Generated new admin token${NC}"
fi

# =============================================================================
# 4. Verify the OLD token authenticates against InfluxDB
# =============================================================================
echo -e "${BLUE}Verifying current admin token...${NC}"
if ! docker exec -i -e INFLUX_TOKEN="$OLD_TOKEN" "$INFLUX_CONTAINER" \
        influx ping >/dev/null 2>&1; then
    echo -e "${RED}✗ InfluxDB did not respond to ping${NC}"
    exit 1
fi
if ! docker exec -i -e INFLUX_TOKEN="$OLD_TOKEN" "$INFLUX_CONTAINER" \
        influx user list --org "$ORG" >/dev/null 2>&1; then
    echo -e "${RED}✗ Current admin token authentication failed${NC}"
    echo "  The token in $TOKEN_FILE may be stale."
    exit 1
fi
echo -e "${GREEN}✓ Current admin token verified${NC}"

# =============================================================================
# 5. Change the admin password via influx CLI
# =============================================================================
# Pass the new password via stdin (influx user password reads it interactively
# when --password is not used). We use --password to avoid TTY issues.
echo -e "${BLUE}Updating admin password via influx CLI...${NC}"
if ! docker exec -i -e INFLUX_TOKEN="$OLD_TOKEN" "$INFLUX_CONTAINER" \
        influx user password --name "$ADMIN_USER" --password "$NEW_PASSWORD" >/dev/null 2>&1; then
    echo -e "${RED}✗ influx user password failed${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Admin password updated in InfluxDB${NC}"

# =============================================================================
# 6. (Optional) Rotate the admin token
# =============================================================================
# Strategy: create a NEW operator token, verify it works, then delete the
# OLD operator token. We keep the original around until the new one is
# confirmed so we never end up locked out.
OLD_TOKEN_ID=""
if [ "$ROTATE_TOKEN" -eq 1 ]; then
    echo -e "${BLUE}Looking up existing admin token ID...${NC}"
    OLD_TOKEN_ID=$(docker exec -i -e INFLUX_TOKEN="$OLD_TOKEN" "$INFLUX_CONTAINER" \
        influx auth list --user "$ADMIN_USER" --json 2>/dev/null \
        | grep -E '"id"|"token"' \
        | awk -v t="$OLD_TOKEN" '
            /"id"/ { id=$0 }
            /"token"/ { if (index($0, t) > 0) { print id; exit } }
        ' \
        | sed -E 's/.*"id":[[:space:]]*"([^"]+)".*/\1/')
    if [ -z "$OLD_TOKEN_ID" ]; then
        echo -e "${YELLOW}⚠ Could not resolve old token ID — leaving the old token in place${NC}"
    fi

    echo -e "${BLUE}Creating new operator (admin) token...${NC}"
    if ! docker exec -i -e INFLUX_TOKEN="$OLD_TOKEN" "$INFLUX_CONTAINER" \
            influx auth create --org "$ORG" --user "$ADMIN_USER" --operator \
            --description "Rotated admin token $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --json > /tmp/new_token.json 2>/dev/null; then
        echo -e "${RED}✗ Failed to create new admin token${NC}"
        rm -f /tmp/new_token.json
        exit 1
    fi
    NEW_TOKEN=$(grep -E '"token"' /tmp/new_token.json | head -1 | sed -E 's/.*"token":[[:space:]]*"([^"]+)".*/\1/')
    rm -f /tmp/new_token.json
    if [ -z "$NEW_TOKEN" ]; then
        echo -e "${RED}✗ Could not parse new token from CLI output${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ New admin token created${NC}"

    echo -e "${BLUE}Verifying new admin token...${NC}"
    if ! docker exec -i -e INFLUX_TOKEN="$NEW_TOKEN" "$INFLUX_CONTAINER" \
            influx user list --org "$ORG" >/dev/null 2>&1; then
        echo -e "${RED}✗ New admin token verification failed${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ New admin token verified${NC}"

    if [ -n "$OLD_TOKEN_ID" ]; then
        echo -e "${BLUE}Deleting old admin token...${NC}"
        if ! docker exec -i -e INFLUX_TOKEN="$NEW_TOKEN" "$INFLUX_CONTAINER" \
                influx auth delete --id "$OLD_TOKEN_ID" >/dev/null 2>&1; then
            echo -e "${YELLOW}⚠ Failed to delete old token — please remove it manually${NC}"
        else
            echo -e "${GREEN}✓ Old admin token revoked${NC}"
        fi
    fi
fi

# =============================================================================
# 7. Verify NEW password works
# =============================================================================
echo -e "${BLUE}Verifying new password by re-creating a CLI config...${NC}"
# `influx user password` does not log the user in; we re-validate via the
# /api/v2/signin endpoint which accepts username/password (basic auth).
HTTP_CODE=$(docker exec -i "$INFLUX_CONTAINER" \
    env NEW_PW="$NEW_PASSWORD" ADMIN_USER="$ADMIN_USER" sh -c '
        curl -s -o /dev/null -w "%{http_code}" \
            -X POST -u "$ADMIN_USER:$NEW_PW" \
            http://localhost:8086/api/v2/signin
    ' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" != "204" ] && [ "$HTTP_CODE" != "200" ]; then
    echo -e "${RED}✗ New password verification failed (HTTP $HTTP_CODE)${NC}"
    echo ""
    echo -e "${YELLOW}  The DB now holds the NEW password but verification failed.${NC}"
    echo -e "${YELLOW}  Save this value before retrying:${NC}"
    echo "    NEW_PASSWORD=$NEW_PASSWORD"
    exit 1
fi
echo -e "${GREEN}✓ New password accepted by /api/v2/signin${NC}"

# =============================================================================
# 8. Persist new secrets to local files (atomic)
# =============================================================================
echo -e "${BLUE}Updating local secrets file(s)...${NC}"
mkdir -p "$(dirname "$PW_FILE")"
TMP_FILE=$(mktemp "${PW_FILE}.XXXXXX")
printf '%s' "$NEW_PASSWORD" > "$TMP_FILE"
chmod 600 "$TMP_FILE"
mv "$TMP_FILE" "$PW_FILE"
echo -e "${GREEN}✓ $PW_FILE updated (0600)${NC}"

if [ "$ROTATE_TOKEN" -eq 1 ]; then
    mkdir -p "$(dirname "$TOKEN_FILE")"
    TMP_FILE=$(mktemp "${TOKEN_FILE}.XXXXXX")
    printf '%s' "$NEW_TOKEN" > "$TMP_FILE"
    chmod 600 "$TMP_FILE"
    mv "$TMP_FILE" "$TOKEN_FILE"
    echo -e "${GREEN}✓ $TOKEN_FILE updated (0600)${NC}"
fi

# =============================================================================
# 9. Swap the Docker Swarm secret(s)
# =============================================================================
swap_swarm_secret() {
    local secret_name="$1"
    local new_value="$2"

    echo -e "${BLUE}Detaching '$secret_name' from $SERVICE_NAME...${NC}"
    docker service update --quiet --secret-rm "$secret_name" "$SERVICE_NAME" >/dev/null || true

    if docker secret inspect "$secret_name" >/dev/null 2>&1; then
        docker secret rm "$secret_name" >/dev/null
        echo -e "${GREEN}✓ Old secret '$secret_name' removed${NC}"
    fi

    printf '%s' "$new_value" | docker secret create "$secret_name" - >/dev/null
    echo -e "${GREEN}✓ New secret '$secret_name' created${NC}"

    docker service update --quiet \
        --secret-add "source=$secret_name,target=$secret_name" \
        "$SERVICE_NAME" >/dev/null
    echo -e "${GREEN}✓ Secret '$secret_name' re-attached${NC}"
}

echo -e "${BLUE}Scaling $SERVICE_NAME to 0 to swap secret(s) safely...${NC}"
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

swap_swarm_secret "$PW_SECRET_NAME" "$NEW_PASSWORD"
if [ "$ROTATE_TOKEN" -eq 1 ]; then
    swap_swarm_secret "$TOKEN_SECRET_NAME" "$NEW_TOKEN"
fi

echo -e "${BLUE}Scaling $SERVICE_NAME back to 1...${NC}"
docker service scale "${SERVICE_NAME}=1" >/dev/null

# =============================================================================
# 10. Wait for the service to come back up
# =============================================================================
echo -e "${BLUE}Waiting for InfluxDB to be Running...${NC}"
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
    echo -e "${RED}✗ Could not find new InfluxDB container after restart${NC}"
    exit 1
fi

# =============================================================================
# 11. Final auth check
# =============================================================================
echo -e "${BLUE}Waiting for InfluxDB to accept the new credentials...${NC}"
EFFECTIVE_TOKEN="$OLD_TOKEN"
[ "$ROTATE_TOKEN" -eq 1 ] && EFFECTIVE_TOKEN="$NEW_TOKEN"
AUTH_OK=0
for _ in $(seq 1 60); do
    if docker exec -i -e INFLUX_TOKEN="$EFFECTIVE_TOKEN" "$NEW_CONTAINER" \
            influx user list --org "$ORG" >/dev/null 2>&1; then
        AUTH_OK=1
        break
    fi
    sleep 2
done
if [ "$AUTH_OK" -ne 1 ]; then
    echo -e "${RED}✗ InfluxDB is up but the admin token does not authenticate${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Admin token verified against the restarted service${NC}"

# =============================================================================
# 12. Summary
# =============================================================================
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  InfluxDB admin credentials rotated${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Environment:    $ENV"
echo "  Service:        $SERVICE_NAME"
echo "  Admin user:     $ADMIN_USER"
echo "  Password file:  $PW_FILE"
echo "  Password secret:$PW_SECRET_NAME"
if [ "$ROTATE_TOKEN" -eq 1 ]; then
    echo "  Token file:     $TOKEN_FILE"
    echo "  Token secret:   $TOKEN_SECRET_NAME"
fi
echo ""
echo -e "${YELLOW}  NEW PASSWORD:${NC}"
echo -e "${YELLOW}    $NEW_PASSWORD${NC}"
if [ "$ROTATE_TOKEN" -eq 1 ]; then
    echo ""
    echo -e "${YELLOW}  NEW ADMIN TOKEN:${NC}"
    echo -e "${YELLOW}    $NEW_TOKEN${NC}"
fi
echo ""
if [ "$PW_GENERATED" -eq 1 ]; then
    echo -e "${YELLOW}  ⚠ Password was auto-generated — save it in your password manager NOW.${NC}"
fi
if [ "$ROTATE_TOKEN" -eq 1 ]; then
    echo -e "${YELLOW}  ⚠ Any service or workflow holding the OLD token will break.${NC}"
    echo -e "${YELLOW}    Restart consumers that mount '$TOKEN_SECRET_NAME':${NC}"
    echo "      docker service update --force <service>"
fi
echo ""
