#!/bin/bash
# =============================================================================
# PostgreSQL idempotent reconciler — Docker Swarm + Secrets edition
# =============================================================================
# Reads Docker secrets from /run/secrets/ and reconciles users/databases for
# Keycloak, Grafana (dashboard), and DataCatalog. Designed to be safe to run
# multiple times and to sync rotated secrets without wiping data.
#
# Idempotency rules:
#   - Users are created inside a DO block that catches duplicate_object.
#   - Databases are created conditionally via pg_database lookup + \gexec.
#   - Passwords are ALWAYS re-applied with ALTER USER ... WITH ENCRYPTED
#     PASSWORD so rotating the secret file and re-running this script syncs
#     credentials without recreating the role.
#
# Execution contexts:
#   1. First cluster init — Postgres auto-runs this from
#      /docker-entrypoint-initdb.d/. BEWARE: that directory is executed ONLY
#      on the very first init of the data volume. New databases added to
#      POSTGRES_MULTIPLE_DATABASES post-init will NOT be created, and rotated
#      secrets on the host will NOT sync, until you re-run this script.
#   2. Manual reconciliation after a secret rotation or DB/user list change:
#        docker exec -i <postgres-container> bash < \
#            /path/to/init-with-secrets.sh
#      or, if the script is already mounted in the container:
#        docker exec <postgres-container> \
#            bash /docker-entrypoint-initdb.d/init-with-secrets.sh
#
# NOTE (future improvement): `industream deploy` should invoke this reconciler
# as a pre-deploy step against a running Postgres service so operators don't
# have to remember this after rotating a secret or editing
# POSTGRES_MULTIPLE_DATABASES. Leaving as a TODO for the CLI.
# =============================================================================

set -e

echo "=== PostgreSQL Idempotent Reconciler (Docker Secrets) ==="

# -----------------------------------------------------------------------------
# Read secret from /run/secrets/<name>. Returns empty if the file is missing.
# -----------------------------------------------------------------------------
read_secret() {
    local secret_name="$1"
    local secret_file="/run/secrets/${secret_name}"

    if [ -f "$secret_file" ]; then
        cat "$secret_file"
    else
        echo "[init-with-secrets] Secret file ${secret_file} not found" >&2
        return 1
    fi
}

KEYCLOAK_DB_PASSWORD=$(read_secret "keycloak_db_password" || echo "")
GRAFANA_DB_PASSWORD=$(read_secret "grafana_db_password" || echo "")
DATACATALOG_DB_PASSWORD=$(read_secret "datacatalog_db_password" || echo "")

# -----------------------------------------------------------------------------
# Keycloak user + database
# -----------------------------------------------------------------------------
if [ -n "$KEYCLOAK_DB_PASSWORD" ]; then
    echo "[init-with-secrets] Reconciling Keycloak user and database..."
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        DO \$\$
        BEGIN
            CREATE USER keycloak WITH PASSWORD '$KEYCLOAK_DB_PASSWORD';
            RAISE NOTICE 'Created user: keycloak';
        EXCEPTION WHEN duplicate_object THEN
            RAISE NOTICE 'User keycloak already exists';
        END
        \$\$;

        -- Sync password on every run (rotates if secret changed).
        ALTER USER keycloak WITH ENCRYPTED PASSWORD '$KEYCLOAK_DB_PASSWORD';

        SELECT 'CREATE DATABASE keycloak OWNER keycloak'
        WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'keycloak')\gexec

        GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
EOSQL
    echo "[init-with-secrets] Keycloak reconciled"
else
    echo "[init-with-secrets] Keycloak password secret missing, skipping."
fi

# -----------------------------------------------------------------------------
# Grafana (dashboard) user + industream database
# -----------------------------------------------------------------------------
if [ -n "$GRAFANA_DB_PASSWORD" ]; then
    echo "[init-with-secrets] Reconciling Grafana user and database..."
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        DO \$\$
        BEGIN
            CREATE USER dashboard WITH PASSWORD '$GRAFANA_DB_PASSWORD';
            RAISE NOTICE 'Created user: dashboard';
        EXCEPTION WHEN duplicate_object THEN
            RAISE NOTICE 'User dashboard already exists';
        END
        \$\$;

        ALTER USER dashboard WITH ENCRYPTED PASSWORD '$GRAFANA_DB_PASSWORD';

        SELECT 'CREATE DATABASE industream OWNER dashboard'
        WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'industream')\gexec

        GRANT ALL PRIVILEGES ON DATABASE industream TO dashboard;
EOSQL
    echo "[init-with-secrets] Grafana reconciled"
else
    echo "[init-with-secrets] Grafana password secret missing, skipping."
fi

# -----------------------------------------------------------------------------
# DataCatalog database (owned by the admin postgres user)
# -----------------------------------------------------------------------------
if [ -n "$DATACATALOG_DB_PASSWORD" ]; then
    echo "[init-with-secrets] Reconciling DataCatalog database..."
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        SELECT 'CREATE DATABASE "DataCatalog" OWNER ' || quote_ident('$POSTGRES_USER')
        WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'DataCatalog')\gexec

        GRANT ALL PRIVILEGES ON DATABASE "DataCatalog" TO "$POSTGRES_USER";
EOSQL
    echo "[init-with-secrets] DataCatalog reconciled"
else
    echo "[init-with-secrets] DataCatalog password secret missing, skipping."
fi

echo ""
echo "=== Reconciliation complete ==="
echo "Users:"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "\du" | grep -E "keycloak|dashboard" || echo "  (none matching keycloak|dashboard)"
echo ""
echo "Databases:"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "\l" | grep -E "keycloak|industream|DataCatalog" || echo "  (none matching keycloak|industream|DataCatalog)"
