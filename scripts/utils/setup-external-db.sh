#!/bin/bash
# =============================================================================
# SETUP EXTERNAL DATABASE ACCESS
# =============================================================================
# Creates a dedicated database + user in the existing Postgres instance, and
# launches a socat bridge that exposes Postgres on port 5432 of the host
# (reachable via the LAN/VPN — NOT via Internet unless the host itself is
# exposed).
#
# Usage:
#   ./setup-external-db.sh <db-name> <user-name> [password]
#
# Examples:
#   ./setup-external-db.sh monapp monapp_user
#   ./setup-external-db.sh monapp monapp_user 'My$tr0ng!Pass'
#
# If the password is omitted, a strong one is generated automatically.
# The script is idempotent — rerunning it updates the password and re-uses
# existing DB / user / bridge.
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

DB_NAME="${1:-}"
USER_NAME="${2:-}"
USER_PASSWORD="${3:-}"
STACK_NAME="${STACK_NAME:-industream-prod}"
SECRETS_DIR="${INDUSTREAM_SECRETS_DIR:-$HOME/industream-platform/secrets}"

if [ -z "$DB_NAME" ] || [ -z "$USER_NAME" ]; then
    echo "Usage: $0 <db-name> <user-name> [password]"
    echo ""
    echo "Environment overrides:"
    echo "  STACK_NAME               (default: industream-prod)"
    echo "  INDUSTREAM_SECRETS_DIR   (default: \$HOME/industream-platform/secrets)"
    exit 1
fi

# =============================================================================
# 1. Find Postgres container
# =============================================================================
POSTGRES_CONTAINER=$(docker ps -qf "name=${STACK_NAME}_postgres" | head -1)
if [ -z "$POSTGRES_CONTAINER" ]; then
    # Fallback: any container with "postgres" in its name
    POSTGRES_CONTAINER=$(docker ps -qf "name=postgres" | head -1)
fi
if [ -z "$POSTGRES_CONTAINER" ]; then
    echo -e "${RED}✗ No running Postgres container found${NC}"
    echo "  Make sure the Industream stack is running: industream status"
    exit 1
fi
echo -e "${GREEN}✓ Postgres container: $(docker inspect --format '{{.Name}}' "$POSTGRES_CONTAINER" | sed 's|^/||')${NC}"

# =============================================================================
# 2. Load admin credentials
# =============================================================================
ADMIN_PW_FILE="$SECRETS_DIR/postgres_admin_password"
if [ ! -f "$ADMIN_PW_FILE" ]; then
    echo -e "${RED}✗ Admin password file not found: $ADMIN_PW_FILE${NC}"
    echo "  Override the path with: INDUSTREAM_SECRETS_DIR=/path/to/secrets $0 ..."
    exit 1
fi
ADMIN_PW=$(cat "$ADMIN_PW_FILE")

ADMIN_USER=$(docker exec "$POSTGRES_CONTAINER" printenv POSTGRES_USER 2>/dev/null || echo "industream")
echo -e "${GREEN}✓ Admin user: $ADMIN_USER${NC}"

# =============================================================================
# 3. Generate password if missing
# =============================================================================
if [ -z "$USER_PASSWORD" ]; then
    USER_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-32)
    PW_GENERATED=1
else
    PW_GENERATED=0
fi

# =============================================================================
# 4. Create DB + user (idempotent)
# =============================================================================
echo -e "${BLUE}Configuring database '$DB_NAME' and user '$USER_NAME'...${NC}"

docker exec -i -e PGPASSWORD="$ADMIN_PW" "$POSTGRES_CONTAINER" \
  psql -v ON_ERROR_STOP=1 -U "$ADMIN_USER" -d postgres <<EOF
SELECT 'CREATE DATABASE "$DB_NAME"'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')\gexec

DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$USER_NAME') THEN
        CREATE USER "$USER_NAME" WITH ENCRYPTED PASSWORD '$USER_PASSWORD';
    ELSE
        ALTER USER "$USER_NAME" WITH ENCRYPTED PASSWORD '$USER_PASSWORD';
    END IF;
END
\$\$;

GRANT ALL PRIVILEGES ON DATABASE "$DB_NAME" TO "$USER_NAME";
EOF

docker exec -i -e PGPASSWORD="$ADMIN_PW" "$POSTGRES_CONTAINER" \
  psql -v ON_ERROR_STOP=1 -U "$ADMIN_USER" -d "$DB_NAME" <<EOF
GRANT ALL ON SCHEMA public TO "$USER_NAME";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "$USER_NAME";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "$USER_NAME";
EOF

echo -e "${GREEN}✓ Database + user ready${NC}"

# =============================================================================
# 5. Launch socat bridge (or reuse existing)
# =============================================================================
BRIDGE_NAME="pg-lan-bridge"

# Auto-detect the network postgres is attached to (more reliable than guessing
# "${STACK_NAME}_default", since stacks may use multiple networks with custom
# names like "industream-prod_data", "internal", etc.)
NETWORK_NAME=$(docker inspect "$POSTGRES_CONTAINER" \
    --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' \
    | grep -v '^$' | head -1)
if [ -z "$NETWORK_NAME" ]; then
    echo -e "${RED}✗ Could not detect Postgres network${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Postgres network: $NETWORK_NAME${NC}"

if docker ps -qf "name=^${BRIDGE_NAME}$" | grep -q .; then
    echo -e "${GREEN}✓ Socat bridge '$BRIDGE_NAME' already running${NC}"
else
    # Clean up any stopped container with the same name
    docker rm -f "$BRIDGE_NAME" 2>/dev/null || true

    echo -e "${BLUE}Starting socat bridge on port 5432...${NC}"
    docker run -d --restart=always --name "$BRIDGE_NAME" \
      --network "$NETWORK_NAME" \
      -p 5432:5432 \
      alpine/socat tcp-listen:5432,fork,reuseaddr tcp-connect:postgres:5432 > /dev/null
    echo -e "${GREEN}✓ Socat bridge started${NC}"
fi

# =============================================================================
# 6. Detect server IP and persist credentials
# =============================================================================
SERVER_IP=$(hostname -I | awk '{print $1}')

# Save credentials to a dedicated file under the secrets/ folder so they
# survive the script run and can be consulted later. Permissions set to 0600
# (owner read/write only) to keep the password off other users' reach.
EXTERNAL_DB_DIR="$SECRETS_DIR/external-dbs"
mkdir -p "$EXTERNAL_DB_DIR"
chmod 700 "$EXTERNAL_DB_DIR"

CREDS_FILE="$EXTERNAL_DB_DIR/${DB_NAME}.env"
cat > "$CREDS_FILE" <<EOF
# Industream external DB credentials — DO NOT COMMIT
# Generated by scripts/utils/setup-external-db.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
PG_HOST=$SERVER_IP
PG_PORT=5432
PG_DATABASE=$DB_NAME
PG_USER=$USER_NAME
PG_PASSWORD=$USER_PASSWORD
DATABASE_URL=postgres://$USER_NAME:$USER_PASSWORD@$SERVER_IP:5432/$DB_NAME
EOF
chmod 600 "$CREDS_FILE"
echo -e "${GREEN}✓ Credentials saved to $CREDS_FILE${NC}"

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  External DB access ready${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Database:  $DB_NAME"
echo "  User:      $USER_NAME"
echo "  Password:  $USER_PASSWORD"
echo "  Host:      $SERVER_IP:5432"
echo ""
echo "  Connection string:"
echo "    postgres://$USER_NAME:$USER_PASSWORD@$SERVER_IP:5432/$DB_NAME"
echo ""
echo "  Credentials file (owner-read only):"
echo "    $CREDS_FILE"
echo ""
echo "  Test from a machine on the LAN/VPN:"
echo "    psql \"postgres://$USER_NAME:$USER_PASSWORD@$SERVER_IP:5432/$DB_NAME\" -c 'SELECT version();'"
echo ""
if [ $PW_GENERATED -eq 1 ]; then
    echo -e "${YELLOW}⚠ Password was auto-generated — also saved to $CREDS_FILE${NC}"
    echo ""
fi
echo "  To stop the bridge:"
echo "    docker rm -f $BRIDGE_NAME"
echo ""
