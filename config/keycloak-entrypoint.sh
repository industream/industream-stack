#!/bin/bash
# Keycloak Entrypoint Wrapper for Docker Secrets
set -e

# Read secrets and export as environment variables
# Support both legacy (keycloak_*) and new multi-env (ENV_keycloak_*) secret names
ADMIN_SECRET=""
DB_SECRET=""

# Try multi-env format first (prod_keycloak_*, dev_keycloak_*, etc.)
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

# Fallback to legacy format
[ -z "$ADMIN_SECRET" ] && [ -f "/run/secrets/keycloak_admin_password" ] && ADMIN_SECRET="/run/secrets/keycloak_admin_password"
[ -z "$DB_SECRET" ] && [ -f "/run/secrets/keycloak_db_password" ] && DB_SECRET="/run/secrets/keycloak_db_password"

# Export admin password
if [ -n "$ADMIN_SECRET" ]; then
    export KEYCLOAK_ADMIN_PASSWORD="$(cat "$ADMIN_SECRET")"
    export KC_BOOTSTRAP_ADMIN_PASSWORD="$KEYCLOAK_ADMIN_PASSWORD"
    echo "✓ Loaded KEYCLOAK_ADMIN_PASSWORD from $ADMIN_SECRET"
fi

# Export DB password
if [ -n "$DB_SECRET" ]; then
    export KC_DB_PASSWORD="$(cat "$DB_SECRET")"
    echo "✓ Loaded KC_DB_PASSWORD from $DB_SECRET"
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

# Wait for PostgreSQL before starting Keycloak
wait_for_postgres

# Execute the original Keycloak entrypoint
exec /opt/keycloak/bin/kc.sh "$@"
