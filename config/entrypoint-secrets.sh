#!/bin/bash
# Docker Swarm Secrets Wrapper
# This script reads Docker secrets and exports them as environment variables
# for applications that don't support _FILE variants

set -e

# Function to load secret from file if it exists
load_secret() {
    local var_name=$1
    local secret_file="/run/secrets/$2"

    if [ -f "$secret_file" ]; then
        export "$var_name"="$(cat $secret_file)"
        echo "✓ Loaded secret: $var_name"
    fi
}

echo "Loading Docker Secrets..."

# PostgreSQL secrets
load_secret "POSTGRES_ADMIN_PASSWORD" "postgres_admin_password"
load_secret "KC_DB_PASSWORD" "keycloak_db_password"
load_secret "GRAFANA_DB_PASSWORD" "grafana_db_password"
load_secret "DATACATALOG_DB_PASSWORD" "datacatalog_db_password"

# Keycloak secrets
load_secret "KEYCLOAK_ADMIN_PASSWORD" "keycloak_admin_password"
load_secret "KC_DB_PASSWORD" "keycloak_db_password"

# Grafana secrets
load_secret "GF_SECURITY_ADMIN_PASSWORD" "grafana_admin_password"
load_secret "GRAFANA_DB_PASSWORD" "grafana_db_password"

# InfluxDB secrets
load_secret "DOCKER_INFLUXDB_INIT_PASSWORD" "influx_admin_password"
load_secret "DOCKER_INFLUXDB_INIT_ADMIN_TOKEN" "influx_admin_token"

# DataCatalog secret
load_secret "DATACATALOG_DB_PASSWORD" "datacatalog_db_password"

echo "Secrets loaded successfully!"

# Execute the original command
exec "$@"
