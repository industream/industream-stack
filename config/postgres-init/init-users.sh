#!/bin/bash
# =============================================================================
# PostgreSQL idempotent reconciler — users + databases
# =============================================================================
# This script creates (if missing) and password-reconciles users/databases for
# Keycloak and the dashboard (Grafana). It is safe to run multiple times:
#   - Users are created only if absent (DO block catches duplicate_object).
#   - Databases are created only if absent (pg_database lookup + \gexec).
#   - Passwords are ALWAYS re-applied via ALTER USER ... WITH ENCRYPTED
#     PASSWORD, so rotating the host secret and re-running this script syncs
#     the DB credentials without wiping data.
#
# When is it executed?
#   1. Automatically on first cluster init via /docker-entrypoint-initdb.d/.
#      BEWARE: Postgres runs scripts from that directory ONLY the very first
#      time the data directory is initialized. A new DB added to
#      POSTGRES_MULTIPLE_DATABASES or a rotated secret will NOT be picked up
#      on a simple container restart.
#   2. Manually, after changing the user/db list or rotating a secret:
#        docker exec -i <postgres-container> bash < \
#            /path/to/init-users.sh
#      or mount the script and:
#        docker exec <postgres-container> bash /path/to/init-users.sh
#
# NOTE (future improvement): `industream deploy` should run this reconciler as
# a pre-step so operators don't have to remember this manual command after
# editing POSTGRES_MULTIPLE_DATABASES or rotating credentials.
# =============================================================================

set -e

echo "[init-users] Reconciling database users and databases..."

# -----------------------------------------------------------------------------
# Keycloak user + database
# -----------------------------------------------------------------------------
if [ -n "${KC_DB_PASSWORD:-}" ]; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        DO \$\$
        BEGIN
            CREATE USER keycloak WITH PASSWORD '${KC_DB_PASSWORD}';
            RAISE NOTICE 'Created user: keycloak';
        EXCEPTION WHEN duplicate_object THEN
            RAISE NOTICE 'User keycloak already exists';
        END
        \$\$;

        -- Reconcile password (no-op if unchanged, rotates otherwise).
        ALTER USER keycloak WITH ENCRYPTED PASSWORD '${KC_DB_PASSWORD}';

        SELECT 'CREATE DATABASE keycloak OWNER keycloak'
        WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'keycloak')\gexec

        GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
EOSQL
    echo "[init-users] Keycloak reconciled"
else
    echo "[init-users] KC_DB_PASSWORD not set, skipping keycloak"
fi

# -----------------------------------------------------------------------------
# Dashboard (Grafana) user + database
# -----------------------------------------------------------------------------
if [ -n "${GRAFANA_DB_PASSWORD:-}" ]; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        DO \$\$
        BEGIN
            CREATE USER dashboard WITH PASSWORD '${GRAFANA_DB_PASSWORD}';
            RAISE NOTICE 'Created user: dashboard';
        EXCEPTION WHEN duplicate_object THEN
            RAISE NOTICE 'User dashboard already exists';
        END
        \$\$;

        -- Reconcile password (no-op if unchanged, rotates otherwise).
        ALTER USER dashboard WITH ENCRYPTED PASSWORD '${GRAFANA_DB_PASSWORD}';

        SELECT 'CREATE DATABASE dashboard OWNER dashboard'
        WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'dashboard')\gexec

        GRANT ALL PRIVILEGES ON DATABASE dashboard TO dashboard;
EOSQL
    echo "[init-users] Dashboard reconciled"
else
    echo "[init-users] GRAFANA_DB_PASSWORD not set, skipping dashboard"
fi

echo "[init-users] Done."
