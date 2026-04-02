#!/bin/bash
set -e

echo "Creating database users..."

# Create Keycloak user and database
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'keycloak') THEN
            CREATE USER keycloak WITH PASSWORD '${KC_DB_PASSWORD}';
        END IF;
    END
    \$\$;
    
    CREATE DATABASE IF NOT EXISTS keycloak OWNER keycloak;
EOSQL

# Create Dashboard user and database  
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'dashboard') THEN
            CREATE USER dashboard WITH PASSWORD '${GRAFANA_DB_PASSWORD}';
        END IF;
    END
    \$\$;
    
    CREATE DATABASE IF NOT EXISTS dashboard OWNER dashboard;
EOSQL

echo "Database users created successfully"
