#!/bin/bash
set -e
set -u

# This script creates multiple databases and users in a single PostgreSQL instance
# Format: POSTGRES_MULTIPLE_DATABASES="db1:user1:password1,db2:user2:password2,..."
# Supports reading passwords from Docker secrets

# Function to read password from secret file or use provided value
# Supports both legacy (<user>_db_password) and multi-env (ENV_<user>_db_password) secret names
read_password() {
    local user=$1
    local provided_password=$2
    local secret_file=""
    local secret_pattern=""

    # Map user to secret pattern
    case "$user" in
        dashboard) secret_pattern="grafana_db_password" ;;
        datacatalog) secret_pattern="datacatalog_db_password" ;;
        databridge) secret_pattern="databridge_pg_password" ;;
    esac

    # Try multi-env format first (prod_grafana_db_password, dev_grafana_db_password, etc.)
    for f in /run/secrets/*_${secret_pattern}; do
        if [ -f "$f" ]; then
            secret_file="$f"
            break
        fi
    done

    # Fallback to legacy format
    if [ -z "$secret_file" ] && [ -f "/run/secrets/${secret_pattern}" ]; then
        secret_file="/run/secrets/${secret_pattern}"
    fi

    # Try to read from secret file first
    if [ -n "$secret_file" ] && [ -f "$secret_file" ]; then
        cat "$secret_file"
        echo "  (password loaded from $secret_file)" >&2
    else
        echo "$provided_password"
    fi
}

function create_user_and_database() {
    local database=$1
    local user=$2
    local password=$3

    # Try to read password from secret file
    password=$(read_password "$user" "$password")

    echo "  Creating user '$user' and database '$database'"

    # Create user if it doesn't exist, or update password if it does
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_user WHERE usename = '$user') THEN
                CREATE USER "$user" WITH PASSWORD '$password';
                RAISE NOTICE 'Created user %', '$user';
            ELSE
                ALTER USER "$user" WITH PASSWORD '$password';
                RAISE NOTICE 'Updated password for user %', '$user';
            END IF;
        END
        \$\$;
EOSQL

    # Create database if it doesn't exist
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        SELECT 'CREATE DATABASE "$database" OWNER "$user"'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$database')\gexec
EOSQL

    # Grant privileges
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        GRANT ALL PRIVILEGES ON DATABASE "$database" TO "$user";
EOSQL

    # Set schema ownership and default privileges
    # This ensures the app user owns the public schema and all objects within it,
    # preventing "permission denied" errors after backup restores
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$database" <<-EOSQL
        ALTER SCHEMA public OWNER TO "$user";
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "$user";
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "$user";
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO "$user";

        -- Fix ownership of any existing tables/sequences (handles backup restore case)
        DO \$\$
        DECLARE
            r RECORD;
        BEGIN
            FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tableowner != '$user'
            LOOP
                EXECUTE 'ALTER TABLE public.' || quote_ident(r.tablename) || ' OWNER TO "$user"';
                RAISE NOTICE 'Fixed ownership of table %', r.tablename;
            END LOOP;

            FOR r IN SELECT sequencename FROM pg_sequences WHERE schemaname = 'public' AND sequenceowner != '$user'
            LOOP
                EXECUTE 'ALTER SEQUENCE public.' || quote_ident(r.sequencename) || ' OWNER TO "$user"';
                RAISE NOTICE 'Fixed ownership of sequence %', r.sequencename;
            END LOOP;
        END
        \$\$;
EOSQL
}

if [ -n "${POSTGRES_MULTIPLE_DATABASES:-}" ]; then
    echo "Multiple database creation requested: $POSTGRES_MULTIPLE_DATABASES"

    # Split the POSTGRES_MULTIPLE_DATABASES variable by comma
    IFS=',' read -ra DBS <<< "$POSTGRES_MULTIPLE_DATABASES"

    for db_config in "${DBS[@]}"; do
        # Split each config by colon to get database:user:password
        IFS=':' read -ra CONFIG <<< "$db_config"

        if [ ${#CONFIG[@]} -eq 3 ]; then
            create_user_and_database "${CONFIG[0]}" "${CONFIG[1]}" "${CONFIG[2]}"
        else
            echo "  Warning: Invalid database config format: $db_config (expected format: database:user:password)"
        fi
    done

    echo "Multiple databases created successfully"
fi
