#!/bin/bash
# Keycloak Entrypoint Wrapper for Docker Secrets
#
# Keycloak 26 supports `*_FILE` env vars natively. We point those at the
# mounted Docker Secret files instead of `cat`-ing them and re-exporting the
# plaintext password — which would otherwise leak via /proc/<pid>/environ
# and `docker inspect`.
set -e

# Locate the mounted secret files.
# Support both multi-env layout (prod_keycloak_*, dev_keycloak_*, …)
# and the legacy flat layout (keycloak_*).
ADMIN_SECRET=""
DB_SECRET=""

for secret_file in /run/secrets/*_keycloak_admin_password; do
    if [ -f "$secret_file" ]; then
        ADMIN_SECRET="$secret_file"
        break
    fi
done

for secret_file in /run/secrets/*_keycloak_db_password; do
    if [ -f "$secret_file" ]; then
        DB_SECRET="$secret_file"
        break
    fi
done

# Fallback to legacy flat secret names.
[ -z "$ADMIN_SECRET" ] && [ -f "/run/secrets/keycloak_admin_password" ] && ADMIN_SECRET="/run/secrets/keycloak_admin_password"
[ -z "$DB_SECRET" ] && [ -f "/run/secrets/keycloak_db_password" ] && DB_SECRET="/run/secrets/keycloak_db_password"

# Point Keycloak at the file directly. KC_BOOTSTRAP_ADMIN_PASSWORD_FILE is
# only honored on first boot (initial admin user); after that the hash lives
# in the DB and rotations go through scripts/utils/rotate-keycloak-password.sh.
if [ -n "$ADMIN_SECRET" ]; then
    export KC_BOOTSTRAP_ADMIN_PASSWORD_FILE="$ADMIN_SECRET"
    echo "✓ KC_BOOTSTRAP_ADMIN_PASSWORD_FILE → $ADMIN_SECRET"
else
    echo "⚠ No keycloak_admin_password secret mounted — bootstrap admin will not be created"
fi

if [ -n "$DB_SECRET" ]; then
    export KC_DB_PASSWORD_FILE="$DB_SECRET"
    echo "✓ KC_DB_PASSWORD_FILE → $DB_SECRET"
else
    echo "⚠ No keycloak_db_password secret mounted — DB connection will fail"
fi

# Wait for PostgreSQL to be ready
wait_for_postgres() {
    local host="${KC_DB_URL_HOST:-postgres}"
    local port="${KC_DB_URL_PORT:-5432}"
    local max_attempts=30
    local attempt=1

    echo "Waiting for PostgreSQL at $host:$port..."

    while [ $attempt -le $max_attempts ]; do
        if timeout 2 bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
            echo "✓ PostgreSQL is available"
            return 0
        fi
        echo "Attempt $attempt/$max_attempts: PostgreSQL not ready, waiting..."
        sleep 2
        attempt=$((attempt + 1))
    done

    echo "✗ PostgreSQL not available after $max_attempts attempts"
    return 1
}

wait_for_postgres

# Execute the original Keycloak entrypoint
exec /opt/keycloak/bin/kc.sh "$@"
