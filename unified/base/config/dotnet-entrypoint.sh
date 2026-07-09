#!/bin/sh
# .NET Applications Entrypoint Wrapper for Docker Secrets
# Reads passwords from Docker secrets and injects them into connection strings
# Supports both legacy and multi-env (prod_*, dev_*, staging_*) secret names
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

# Default secret name pattern
DB_SECRET_PATTERN="${DB_SECRET_PATTERN:-db_password}"

# Read database password from secret if available
DB_SECRET_FILE=$(find_secret "${DB_SECRET_PATTERN}" 2>/dev/null || true)
if [ -n "$DB_SECRET_FILE" ] && [ -f "$DB_SECRET_FILE" ]; then
    DB_PASSWORD=$(read_secret "$DB_SECRET_FILE")
    echo "Loaded database password from secret: $DB_SECRET_FILE"

    # Replace __DB_PASSWORD_PLACEHOLDER__ in EVERY env var that carries it — not
    # only PostgreSql__ConnectionString. This covers ConnectionStrings__* (used by
    # IronStream MaterialCatalog/RecipeMaker) and URL-form vars (POSTGRES_URL for
    # the data-simulator) too, so any app can opt in with the placeholder + a
    # DB_SECRET_PATTERN, no per-app hardcoding here.
    ESCAPED_PASSWORD=$(printf '%s\n' "$DB_PASSWORD" | sed 's/[&/\]/\\&/g')
    for _v in $(env | grep '__DB_PASSWORD_PLACEHOLDER__' | cut -d= -f1); do
        eval "_cur=\$$_v"
        _new=$(printf '%s' "$_cur" | sed "s/__DB_PASSWORD_PLACEHOLDER__/$ESCAPED_PASSWORD/g")
        export "$_v=$_new"
        echo "Injected DB password into $_v"
    done
fi

# Read InfluxDB token from secret if available
TOKEN_FILE=$(find_secret "influx_admin_token" 2>/dev/null || true)
if [ -n "$TOKEN_FILE" ] && [ -f "$TOKEN_FILE" ]; then
    INFLUX_TOKEN=$(read_secret "$TOKEN_FILE")

    # For .NET apps using InfluxDb__Token
    if [ -n "${InfluxDb__Token}" ] && [ "${InfluxDb__Token}" = "__INFLUX_TOKEN_PLACEHOLDER__" ]; then
        export InfluxDb__Token="$INFLUX_TOKEN"
        echo "Loaded InfluxDB token into InfluxDb__Token from $TOKEN_FILE"
    fi

    # For timeseries-api using InfluxDB__Connection__Token
    if [ -n "${InfluxDB__Connection__Token:-}" ] && [ "${InfluxDB__Connection__Token}" = "__INFLUX_TOKEN_PLACEHOLDER__" ]; then
        export InfluxDB__Connection__Token="$INFLUX_TOKEN"
        echo "Loaded InfluxDB token into InfluxDB__Connection__Token from $TOKEN_FILE"
    fi
fi

# DataCatalog backend API key (Authentication__Backend__ApiKey) from the mounted
# secret — same find_secret/export pattern as the influx token above.
API_KEY_FILE=$(find_secret "datacatalog_api_key" 2>/dev/null || true)
if [ -n "$API_KEY_FILE" ]; then
    export Authentication__Backend__ApiKey="$(read_secret "$API_KEY_FILE")"
    echo "Loaded DataCatalog backend API key from $API_KEY_FILE"
fi

# Execute the original entrypoint (dotnet application)
exec "$@"
