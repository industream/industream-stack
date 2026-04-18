#!/bin/bash
# =============================================================================
# ROTATE POSTGRES APP USER PASSWORD (generic)
# =============================================================================
# Rotates the password of any non-admin Postgres user (keycloak, grafana,
# databridge, datacatalog, dashboard, ironstream, timescaledb, ...) without
# breaking the dependent service.
#
# Why this script exists:
#   Dependent services read their DB password from a mounted Docker Swarm
#   secret at boot time, while the Postgres cluster stores the hash in
#   pg_authid inside its data volume. Just swapping the Docker Secret breaks
#   authentication on the next restart. This script:
#     1. Uses the Postgres admin account to ALTER USER in the live DB.
#     2. Swaps the matching Docker Swarm secret atomically.
#     3. Optionally forces a restart of the dependent service so it picks up
#        the new password from its mounted file.
#
# Usage:
#   ./rotate-postgres-app-password.sh \
#       --env <env> \
#       --user <postgres-user> \
#       --secret <swarm-secret-name> \
#       [--secret-file <relative-name>] \
#       [--new-password <pw>] \
#       [--restart-service <service>]
#
# Examples:
#   # Keycloak DB user (restart Keycloak so it re-reads the mounted secret)
#   ./rotate-postgres-app-password.sh \
#       --env prod \
#       --user keycloak \
#       --secret prod_keycloak_db_password \
#       --restart-service industream-prod_keycloak
#
#   # Grafana DB user
#   ./rotate-postgres-app-password.sh \
#       --env prod --user grafana --secret prod_grafana_db_password \
#       --restart-service industream-prod_grafana
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

ENV="prod"
PG_USER=""
SECRET_NAME=""
SECRET_FILE=""
NEW_PASSWORD=""
RESTART_SERVICE=""

usage() {
    echo "Usage: $0 --env <env> --user <pg-user> --secret <swarm-secret> [options]"
    echo "  --env              Environment (default: prod). Affects stack/service names."
    echo "  --user             Postgres role to rotate (e.g. keycloak, grafana)."
    echo "  --secret           Docker Swarm secret name holding the password."
    echo "  --secret-file      File name under secrets/ to update."
    echo "                     Defaults to the secret name with the '<env>_' prefix stripped."
    echo "  --new-password     Use this password instead of generating one."
    echo "  --restart-service  Force-restart this service after the swap so it"
    echo "                     re-reads the mounted secret (e.g. the app using the DB)."
    echo "  --help / -h        Show this help."
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --env) ENV="$2"; shift 2 ;;
        --user) PG_USER="$2"; shift 2 ;;
        --secret) SECRET_NAME="$2"; shift 2 ;;
        --secret-file) SECRET_FILE="$2"; shift 2 ;;
        --new-password) NEW_PASSWORD="$2"; shift 2 ;;
        --restart-service) RESTART_SERVICE="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *)
            echo -e "${RED}✗ Unknown argument: $1${NC}"
            usage 1
            ;;
    esac
done

if [ -z "$PG_USER" ] || [ -z "$SECRET_NAME" ]; then
    echo -e "${RED}✗ --user and --secret are required${NC}"
    usage 1
fi

STACK_NAME="industream-${ENV}"
PG_SERVICE_NAME="${STACK_NAME}_postgres"
ADMIN_SECRET_NAME="${ENV}_postgres_admin_password"
SECRETS_DIR="${INDUSTREAM_SECRETS_DIR:-$HOME/industream-platform/secrets}"

# Default secret file name: strip leading "<env>_" from the swarm secret name.
if [ -z "$SECRET_FILE" ]; then
    SECRET_FILE="${SECRET_NAME#${ENV}_}"
fi
LOCAL_SECRET_FILE="$SECRETS_DIR/$SECRET_FILE"

# =============================================================================
# 1. Find Postgres container
# =============================================================================
echo -e "${BLUE}Locating Postgres container for stack '$STACK_NAME'...${NC}"
PG_CONTAINER=$(docker ps -qf "name=${PG_SERVICE_NAME}" | head -1)
if [ -z "$PG_CONTAINER" ]; then
    echo -e "${RED}✗ No running Postgres container found for service '$PG_SERVICE_NAME'${NC}"
    exit 1
fi
CONTAINER_NAME=$(docker inspect --format '{{.Name}}' "$PG_CONTAINER" | sed 's|^/||')
echo -e "${GREEN}✓ Postgres container: $CONTAINER_NAME${NC}"

ADMIN_USER=$(docker exec "$PG_CONTAINER" printenv POSTGRES_USER 2>/dev/null || echo "postgres")
echo -e "${GREEN}✓ Admin user: $ADMIN_USER${NC}"

# =============================================================================
# 2. Load Postgres ADMIN password (used to run ALTER USER)
# =============================================================================
ADMIN_PASSWORD=$(docker exec "$PG_CONTAINER" cat "/run/secrets/${ADMIN_SECRET_NAME}" 2>/dev/null || true)
if [ -z "$ADMIN_PASSWORD" ]; then
    echo -e "${YELLOW}⚠ Could not read admin secret from container, falling back to host file${NC}"
    ADMIN_FILE="$SECRETS_DIR/postgres_admin_password"
    if [ ! -f "$ADMIN_FILE" ]; then
        echo -e "${RED}✗ Admin password file not found: $ADMIN_FILE${NC}"
        exit 1
    fi
    ADMIN_PASSWORD=$(cat "$ADMIN_FILE")
fi
if [ -z "$ADMIN_PASSWORD" ]; then
    echo -e "${RED}✗ Postgres admin password is empty; cannot ALTER USER${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Loaded Postgres admin password${NC}"

# =============================================================================
# 3. Verify admin auth before touching anything
# =============================================================================
echo -e "${BLUE}Verifying admin authentication...${NC}"
if ! docker exec -i -e PGPASSWORD="$ADMIN_PASSWORD" "$PG_CONTAINER" \
        psql -v ON_ERROR_STOP=1 -U "$ADMIN_USER" -d postgres -c "SELECT 1" >/dev/null 2>&1; then
    echo -e "${RED}✗ Admin authentication failed — aborting${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Admin authentication OK${NC}"

# =============================================================================
# 4. Check the target role exists
# =============================================================================
ROLE_EXISTS=$(docker exec -i -e PGPASSWORD="$ADMIN_PASSWORD" "$PG_CONTAINER" \
    psql -tAU "$ADMIN_USER" -d postgres \
    -c "SELECT 1 FROM pg_roles WHERE rolname = '$PG_USER'" 2>/dev/null | tr -d '[:space:]')
if [ "$ROLE_EXISTS" != "1" ]; then
    echo -e "${RED}✗ Postgres role '$PG_USER' does not exist${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Role '$PG_USER' exists${NC}"

# =============================================================================
# 5. Generate NEW password if not supplied
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
# 6. ALTER USER inside Postgres (bound via psql variable — no shell injection)
# =============================================================================
echo -e "${BLUE}Updating password for role '$PG_USER' in Postgres...${NC}"
if ! docker exec -i -e PGPASSWORD="$ADMIN_PASSWORD" "$PG_CONTAINER" \
        psql -v ON_ERROR_STOP=1 -U "$ADMIN_USER" -d postgres \
        -v "role=$PG_USER" -v "pw=$NEW_PASSWORD" \
        -c "ALTER USER \"$PG_USER\" WITH ENCRYPTED PASSWORD :'pw'" >/dev/null; then
    echo -e "${RED}✗ ALTER USER failed${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Password updated in pg_authid${NC}"

# =============================================================================
# 7. Verify NEW password works for this role
# =============================================================================
echo -e "${BLUE}Verifying new password for '$PG_USER'...${NC}"
if ! docker exec -i -e PGPASSWORD="$NEW_PASSWORD" "$PG_CONTAINER" \
        psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d postgres -c "SELECT 1" >/dev/null 2>&1; then
    echo -e "${RED}✗ Authentication with the new password failed${NC}"
    echo ""
    echo -e "${YELLOW}  IMPORTANT: the DB now holds the NEW password but the Docker${NC}"
    echo -e "${YELLOW}  Swarm secret has not been swapped yet. Do NOT restart the${NC}"
    echo -e "${YELLOW}  dependent service. Investigate and retry manually with:${NC}"
    echo ""
    echo "    NEW_PASSWORD=$NEW_PASSWORD"
    echo ""
    exit 1
fi
echo -e "${GREEN}✓ New password works for '$PG_USER'${NC}"

# =============================================================================
# 8. Update local secrets file (atomic)
# =============================================================================
echo -e "${BLUE}Updating local secrets file...${NC}"
mkdir -p "$SECRETS_DIR"
TMP_FILE=$(mktemp "${LOCAL_SECRET_FILE}.XXXXXX")
printf '%s' "$NEW_PASSWORD" > "$TMP_FILE"
chmod 600 "$TMP_FILE"
mv "$TMP_FILE" "$LOCAL_SECRET_FILE"
echo -e "${GREEN}✓ $LOCAL_SECRET_FILE updated (0600)${NC}"

# =============================================================================
# 9. Swap the Docker Swarm secret
# =============================================================================
# The secret may or may not be attached to services. Detach from any service
# that uses it, then rm+create, then re-attach with the original target name.
echo -e "${BLUE}Inspecting services that reference '$SECRET_NAME'...${NC}"
REFERENCING_SERVICES=$(docker service ls --format '{{.Name}}' | while read -r svc; do
    if docker service inspect "$svc" --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{.SecretName}} {{end}}' 2>/dev/null \
        | tr ' ' '\n' | grep -qx "$SECRET_NAME"; then
        echo "$svc"
    fi
done)

if [ -n "$REFERENCING_SERVICES" ]; then
    echo -e "${GREEN}✓ Services using this secret:${NC}"
    echo "$REFERENCING_SERVICES" | sed 's/^/    - /'
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        echo -e "${BLUE}Detaching '$SECRET_NAME' from $svc...${NC}"
        docker service update --quiet --secret-rm "$SECRET_NAME" "$svc" >/dev/null
    done <<< "$REFERENCING_SERVICES"
    echo -e "${GREEN}✓ Secret detached from all services${NC}"
else
    echo -e "${YELLOW}⚠ No running service currently references '$SECRET_NAME'${NC}"
fi

if docker secret inspect "$SECRET_NAME" >/dev/null 2>&1; then
    docker secret rm "$SECRET_NAME" >/dev/null
    echo -e "${GREEN}✓ Old Docker secret removed${NC}"
else
    echo -e "${YELLOW}⚠ Secret '$SECRET_NAME' did not exist — creating fresh${NC}"
fi

printf '%s' "$NEW_PASSWORD" | docker secret create "$SECRET_NAME" - >/dev/null
echo -e "${GREEN}✓ New Docker secret created${NC}"

if [ -n "$REFERENCING_SERVICES" ]; then
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        echo -e "${BLUE}Re-attaching '$SECRET_NAME' to $svc...${NC}"
        docker service update --quiet \
            --secret-add "source=$SECRET_NAME,target=$SECRET_NAME" \
            "$svc" >/dev/null
    done <<< "$REFERENCING_SERVICES"
    echo -e "${GREEN}✓ Secret re-attached to all services${NC}"
fi

# =============================================================================
# 10. Optionally restart the dependent service
# =============================================================================
if [ -n "$RESTART_SERVICE" ]; then
    echo -e "${BLUE}Force-restarting $RESTART_SERVICE to pick up new password...${NC}"
    if ! docker service inspect "$RESTART_SERVICE" >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ Service '$RESTART_SERVICE' not found — skipping restart${NC}"
    else
        docker service update --quiet --force "$RESTART_SERVICE" >/dev/null
        echo -e "${BLUE}Waiting for $RESTART_SERVICE to reach Running state...${NC}"
        SERVICE_READY=0
        for _ in $(seq 1 120); do
            STATE=$(docker service ps "$RESTART_SERVICE" \
                --filter "desired-state=running" \
                --format '{{.CurrentState}}' 2>/dev/null | head -1)
            if echo "$STATE" | grep -q '^Running'; then
                SERVICE_READY=1
                break
            fi
            sleep 2
        done
        if [ "$SERVICE_READY" -ne 1 ]; then
            echo -e "${YELLOW}⚠ Service did not reach Running state within timeout${NC}"
            echo "  Inspect with: docker service ps $RESTART_SERVICE"
        else
            echo -e "${GREEN}✓ Service '$RESTART_SERVICE' is Running${NC}"
        fi
    fi
fi

# =============================================================================
# 11. Summary
# =============================================================================
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Postgres user '$PG_USER' password rotated${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Environment:    $ENV"
echo "  Postgres user:  $PG_USER"
echo "  Swarm secret:   $SECRET_NAME"
echo "  Secrets file:   $LOCAL_SECRET_FILE"
if [ -n "$RESTART_SERVICE" ]; then
    echo "  Restarted:      $RESTART_SERVICE"
fi
echo ""
echo -e "${YELLOW}  NEW PASSWORD:${NC}"
echo -e "${YELLOW}    $NEW_PASSWORD${NC}"
echo ""
if [ "$PW_GENERATED" -eq 1 ]; then
    echo -e "${YELLOW}  ⚠ Auto-generated — save it in your password manager NOW.${NC}"
    echo -e "${YELLOW}    It is also stored at $LOCAL_SECRET_FILE (0600).${NC}"
else
    echo -e "${YELLOW}  ⚠ Make sure the password is recorded in your password manager.${NC}"
fi
echo ""
if [ -z "$RESTART_SERVICE" ]; then
    echo "  Any service that mounts '$SECRET_NAME' will pick up the new value"
    echo "  on its next restart. Consider:"
    echo "    docker service update --force <service>"
    echo ""
fi
