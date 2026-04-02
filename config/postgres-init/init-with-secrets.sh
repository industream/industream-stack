#!/bin/bash
# PostgreSQL Initialization Script for Docker Swarm with Secrets
# This script reads Docker secrets and creates users/databases automatically
set -e

echo "=== PostgreSQL Initialization with Docker Secrets ==="

# Function to read secret file
read_secret() {
    local secret_name=$1
    local secret_file="/run/secrets/${secret_name}"

    if [ -f "$secret_file" ]; then
        cat "$secret_file"
    else
        echo "⚠️  Warning: Secret file $secret_file not found" >&2
        return 1
    fi
}

# Read secrets (these will be mounted by Docker Swarm)
KEYCLOAK_DB_PASSWORD=$(read_secret "keycloak_db_password" || echo "")
GRAFANA_DB_PASSWORD=$(read_secret "grafana_db_password" || echo "")
DATACATALOG_DB_PASSWORD=$(read_secret "datacatalog_db_password" || echo "")

# Create Keycloak user and database
if [ -n "$KEYCLOAK_DB_PASSWORD" ]; then
    echo "Creating Keycloak user and database..."
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'keycloak') THEN
                CREATE USER keycloak WITH PASSWORD '$KEYCLOAK_DB_PASSWORD';
                RAISE NOTICE 'Created user: keycloak';
            ELSE
                RAISE NOTICE 'User keycloak already exists';
            END IF;
        END
        \$\$;

        SELECT 'CREATE DATABASE keycloak OWNER keycloak'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')\gexec

        GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
EOSQL
    echo "✓ Keycloak configured"
else
    echo "⚠️  Keycloak password secret not found, skipping..."
fi

# Create Grafana (dashboard) user and database
if [ -n "$GRAFANA_DB_PASSWORD" ]; then
    echo "Creating Grafana user and database..."
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'dashboard') THEN
                CREATE USER dashboard WITH PASSWORD '$GRAFANA_DB_PASSWORD';
                RAISE NOTICE 'Created user: dashboard';
            ELSE
                RAISE NOTICE 'User dashboard already exists';
            END IF;
        END
        \$\$;

        SELECT 'CREATE DATABASE industream OWNER dashboard'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'industream')\gexec

        GRANT ALL PRIVILEGES ON DATABASE industream TO dashboard;
EOSQL
    echo "✓ Grafana configured"
else
    echo "⚠️  Grafana password secret not found, skipping..."
fi

# Create DataCatalog database (using postgres user)
if [ -n "$DATACATALOG_DB_PASSWORD" ]; then
    echo "Creating DataCatalog database..."
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        SELECT 'CREATE DATABASE "DataCatalog" OWNER postgres'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'DataCatalog')\gexec

        GRANT ALL PRIVILEGES ON DATABASE "DataCatalog" TO postgres;
EOSQL
    echo "✓ DataCatalog configured"
else
    echo "⚠️  DataCatalog password secret not found, skipping..."
fi

echo "=== PostgreSQL Initialization Complete ==="
echo "Users created:"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "\du" | grep -E "keycloak|dashboard" || echo "  (checking users...)"
echo ""
echo "Databases created:"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "\l" | grep -E "keycloak|industream|DataCatalog" || echo "  (checking databases...)"
