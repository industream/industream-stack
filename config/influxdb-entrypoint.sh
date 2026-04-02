#!/bin/sh
# InfluxDB Entrypoint Wrapper for Docker Secrets
# Reads passwords/tokens from Docker secrets and exports as environment variables
# Supports both legacy (influx_admin_password) and multi-env (prod_influx_admin_password) secret names
set -e

# Function to read a secret file
read_secret() {
    secret_path="$1"
    if [ -f "$secret_path" ]; then
        cat "$secret_path" | tr -d '\n'
    fi
}

# Function to find secret file (supports multi-env prefixes)
find_secret() {
    pattern="$1"
    # Try multi-env format first (prod_*, dev_*, staging_*)
    for f in /run/secrets/*_${pattern}; do
        if [ -f "$f" ]; then
            echo "$f"
            return 0
        fi
    done
    # Fallback to legacy format
    if [ -f "/run/secrets/${pattern}" ]; then
        echo "/run/secrets/${pattern}"
        return 0
    fi
    return 1
}

# Read InfluxDB admin password from secret
PASSWORD_FILE=$(find_secret "influx_admin_password" 2>/dev/null || true)
if [ -n "$PASSWORD_FILE" ] && [ -f "$PASSWORD_FILE" ]; then
    INFLUX_PASSWORD=$(read_secret "$PASSWORD_FILE")
    export DOCKER_INFLUXDB_INIT_PASSWORD="$INFLUX_PASSWORD"
    echo "Loaded DOCKER_INFLUXDB_INIT_PASSWORD from $PASSWORD_FILE"
fi

# Read InfluxDB admin token from secret
TOKEN_FILE=$(find_secret "influx_admin_token" 2>/dev/null || true)
if [ -n "$TOKEN_FILE" ] && [ -f "$TOKEN_FILE" ]; then
    INFLUX_TOKEN=$(read_secret "$TOKEN_FILE")
    export DOCKER_INFLUXDB_INIT_ADMIN_TOKEN="$INFLUX_TOKEN"
    echo "Loaded DOCKER_INFLUXDB_INIT_ADMIN_TOKEN from $TOKEN_FILE"
fi

# Execute the original entrypoint
exec /entrypoint.sh "$@"
