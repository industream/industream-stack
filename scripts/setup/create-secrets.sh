#!/bin/bash
# =============================================================================
# CREATE DOCKER SECRETS - MULTI-ENVIRONMENT SUPPORT
# =============================================================================
# Create all required Docker secrets for Industream environments.
#
# SECURITY MODEL (audit 2026-04-18):
#   Each environment gets its OWN independently generated password. A dev
#   compromise MUST NOT leak prod credentials.
#   Per-env passwords are stored under secrets/<env>/<name> with mode 0600,
#   and the flat legacy layout secrets/<name> is still consulted as a
#   fallback (with a deprecation warning) so existing installs keep working.
#
# Usage:
#   ./scripts/setup/create-secrets.sh --env prod       # Create prod secrets
#   ./scripts/setup/create-secrets.sh --env dev        # Create dev secrets
#   ./scripts/setup/create-secrets.sh --env staging    # Create staging secrets
#   ./scripts/setup/create-secrets.sh --env prod --regenerate  # Force regenerate
# =============================================================================

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SECRETS_DIR="$PROJECT_DIR/secrets"

ENV=""
REGENERATE=false

# =============================================================================
# Parse arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --env)
            ENV="$2"
            shift 2
            ;;
        --regenerate)
            REGENERATE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 --env <prod|dev|staging> [--regenerate]"
            echo ""
            echo "Required:"
            echo "  --env <env>    Environment to create secrets for"
            echo "                 prod     - Production environment"
            echo "                 dev      - Development environment"
            echo "                 staging  - Staging environment"
            echo ""
            echo "Optional:"
            echo "  --regenerate   Rotate secrets not currently used by any service."
            echo "                 Secrets in use will abort the script with an error —"
            echo "                 stateful services need their dedicated rotation scripts."
            echo ""
            echo "Each environment gets an independent password — there is no"
            echo "'--env all' shortcut on purpose: a dev compromise must never"
            echo "unlock prod. Run the script once per environment."
            echo ""
            echo "Examples:"
            echo "  $0 --env prod          # Create secrets for production"
            echo "  $0 --env dev           # Create secrets for dev"
            echo "  $0 --env prod --regenerate  # Regenerate all prod secrets"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# =============================================================================
# Validate environment
# =============================================================================
if [ -z "$ENV" ]; then
    echo -e "${RED}✗ Environment not specified${NC}"
    echo "Usage: $0 --env <prod|dev|staging>"
    exit 1
fi

if [ "$ENV" = "all" ]; then
    echo -e "${RED}✗ '--env all' is no longer supported${NC}"
    echo "  Per-env password isolation requires running this script once per env:"
    echo "    $0 --env prod"
    echo "    $0 --env dev"
    echo "    $0 --env staging"
    exit 1
fi

if [[ ! "$ENV" =~ ^(prod|dev|staging)$ ]]; then
    echo -e "${RED}✗ Invalid environment: $ENV${NC}"
    echo "Valid environments: prod, dev, staging"
    exit 1
fi

echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Docker Secrets Creation Script${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo ""

# Check if Swarm is initialized
if [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" != "active" ]; then
    echo -e "${RED}✗ Docker Swarm is not initialized${NC}"
    echo "Run: docker swarm init"
    exit 1
fi
echo -e "${GREEN}✓ Docker Swarm is active${NC}"

# Create secrets directory (per-env subdir) if it doesn't exist
ENV_SECRETS_DIR="$SECRETS_DIR/$ENV"
mkdir -p "$ENV_SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
chmod 700 "$ENV_SECRETS_DIR"
echo -e "${GREEN}✓ Secrets directory: $ENV_SECRETS_DIR${NC}"
echo ""

# =============================================================================
# List of base secret names (each environment has its own value)
# =============================================================================
BASE_SECRETS=(
    "postgres_admin_password"
    "keycloak_admin_password"
    "keycloak_db_password"
    "grafana_admin_password"
    "grafana_db_password"
    "datacatalog_db_password"
    "influx_admin_password"
    "influx_admin_token"
    "minio_root_user"
    "minio_root_password"
    "ironstream_db_password"
    "timescaledb_password"
    "databridge_pg_password"
    "traefik_auth_htpasswd"
    "backup_monitor_htpasswd"
)

# =============================================================================
# Function to get or generate a secret value for the current environment.
# Resolution order:
#   1. secrets/<env>/<name>           (canonical, per-env)
#   2. secrets/<name>                 (legacy flat layout, migrated + warned)
#   3. generate a fresh random value
# Called as: get_or_generate_secret <name>
# Prints the secret value on stdout; side-effect is writing the file.
# =============================================================================
get_or_generate_secret() {
    local secret_name="$1"
    local env_file="$ENV_SECRETS_DIR/$secret_name"
    local legacy_file="$SECRETS_DIR/$secret_name"

    if [ -f "$env_file" ] && [ "$REGENERATE" = false ]; then
        cat "$env_file"
        return
    fi

    # Migrate from legacy flat layout (but only for non-regenerate runs —
    # a regenerate must produce a fresh value, not re-use the old one).
    if [ -f "$legacy_file" ] && [ "$REGENERATE" = false ]; then
        echo -e "  ${YELLOW}⚠ Migrating legacy $legacy_file → $env_file (deprecated flat layout)${NC}" >&2
        cp "$legacy_file" "$env_file"
        chmod 600 "$env_file"
        cat "$env_file"
        return
    fi

    # Generate a new random value and persist it.
    local new_secret
    if [ "$secret_name" = "traefik_auth_htpasswd" ] || [ "$secret_name" = "backup_monitor_htpasswd" ]; then
        new_secret=$(generate_htpasswd_line "admin")
    elif [[ "$secret_name" == *"_user" ]] || [[ "$secret_name" == *"_username" ]]; then
        # Readable default for identity fields (not a password).
        new_secret="admin"
    else
        new_secret=$(openssl rand -hex 24)
    fi
    printf '%s' "$new_secret" > "$env_file"
    chmod 600 "$env_file"
    printf '%s' "$new_secret"
}

# =============================================================================
# Generate an htpasswd line "user:hash" with a fresh random password.
# Prefers the `htpasswd` binary (bcrypt via -B) and falls back to
# `openssl passwd -apr1` when htpasswd is unavailable.
# Call as: generate_htpasswd_line <username>
# =============================================================================
generate_htpasswd_line() {
    local username="$1"
    local password hash
    password=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)

    if command -v htpasswd >/dev/null 2>&1; then
        # -n prints to stdout; -b reads password from CLI; -B selects bcrypt.
        hash=$(htpasswd -nbB "$username" "$password" | tr -d '\r\n')
    else
        # Fallback: MD5-APR1 via openssl. Still acceptable for Traefik basicAuth.
        local pw_hash
        pw_hash=$(openssl passwd -apr1 "$password")
        hash="${username}:${pw_hash}"
    fi
    printf '%s' "$hash"
}

# =============================================================================
# Function to create Docker secrets for an environment
# =============================================================================
create_secrets_for_env() {
    local env_name="$1"
    local created=0
    local skipped=0
    local updated=0

    echo -e "${BLUE}Creating secrets for ${env_name^^} environment...${NC}"
    echo ""

    for base_secret in "${BASE_SECRETS[@]}"; do
        local docker_secret="${env_name}_${base_secret}"
        local secret_value

        secret_value=$(get_or_generate_secret "$base_secret")

        # Check if Docker secret exists
        if docker secret ls --format '{{.Name}}' | grep -q "^${docker_secret}$"; then
            if [ "$REGENERATE" = true ]; then
                # Swarm refuses to remove a secret mounted by a running service,
                # and even if rm succeeded the mounted value would not update.
                local in_use_by
                in_use_by=$(docker service ls --format '{{.Name}}' \
                    | xargs -r -I{} docker service inspect {} --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{.SecretName}} {{end}}{{.Spec.Name}}' \
                    | grep -E "^(.* )?${docker_secret} " | awk '{print $NF}' || true)

                if [ -n "$in_use_by" ]; then
                    local services_csv
                    services_csv=$(echo "$in_use_by" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
                    echo -e "${RED}✗ Cannot rotate '$docker_secret' — currently used by service(s): $services_csv${NC}"
                    echo ""
                    echo -e "${YELLOW}  Docker Swarm secrets are immutable while mounted by a service."
                    echo -e "  For stateful services (postgres, keycloak), use the dedicated"
                    echo -e "  rotation scripts that update the password IN the database first:${NC}"
                    echo ""
                    echo "    ./scripts/utils/rotate-postgres-password.sh"
                    echo "    ./scripts/utils/rotate-keycloak-password.sh"
                    echo ""
                    echo -e "${YELLOW}  For other secrets, stop the service first, then rerun --regenerate.${NC}"
                    exit 1
                fi

                docker secret rm "$docker_secret"
                printf '%s' "$secret_value" | docker secret create "$docker_secret" - >/dev/null
                echo -e "${YELLOW}↻ Rotated secret: $docker_secret${NC}"
                updated=$((updated + 1))
            else
                echo -e "${YELLOW}⏭ Secret '$docker_secret' already exists, skipping...${NC}"
                skipped=$((skipped + 1))
            fi
        else
            printf '%s' "$secret_value" | docker secret create "$docker_secret" - >/dev/null
            echo -e "${GREEN}✓ Created secret: $docker_secret${NC}"
            created=$((created + 1))
        fi
    done

    echo ""
    echo -e "${BLUE}${env_name^^} environment:${NC}"
    echo -e "  Created: $created secrets"
    echo -e "  Updated: $updated secrets"
    echo -e "  Skipped: $skipped secrets (already exist)"
    echo ""
}

# =============================================================================
# Generate/load base secrets for this environment first
# =============================================================================
echo -e "${BLUE}Loading/generating base secrets for '${ENV}'...${NC}"
for base_secret in "${BASE_SECRETS[@]}"; do
    env_file="$ENV_SECRETS_DIR/$base_secret"
    if [ -f "$env_file" ] && [ "$REGENERATE" = false ]; then
        echo -e "  ${GREEN}✓${NC} $base_secret (from file)"
    else
        get_or_generate_secret "$base_secret" > /dev/null
        echo -e "  ${GREEN}✓${NC} $base_secret (generated)"
    fi
done
echo ""

# =============================================================================
# Propagate TRAEFIK_AUTH_HTPASSWD into .env so envsubst (run by
# deploy-traefik.sh) can inject it into the Traefik dynamic config template.
# Dollars are doubled (`$$`) so the resulting YAML still reads as single `$`
# after envsubst; Traefik needs single `$` in the bcrypt hash.
# =============================================================================
if [ -f "$ENV_SECRETS_DIR/traefik_auth_htpasswd" ]; then
    TRAEFIK_AUTH_HTPASSWD_RAW=$(cat "$ENV_SECRETS_DIR/traefik_auth_htpasswd")
    TRAEFIK_AUTH_HTPASSWD=$(printf '%s' "$TRAEFIK_AUTH_HTPASSWD_RAW" | sed 's/\$/\$\$/g')
    export TRAEFIK_AUTH_HTPASSWD

    ENV_FILE="$PROJECT_DIR/.env"
    if [ -f "$ENV_FILE" ]; then
        # Remove any previous line then append the fresh value.
        # Single-quote the value so that `set -a; source .env` keeps `$$`
        # literal instead of expanding it to the shell PID.
        # Any embedded single quote is escaped as '\'' (standard trick).
        ESCAPED_VAL=$(printf '%s' "$TRAEFIK_AUTH_HTPASSWD" | sed "s/'/'\\\\''/g")
        TMP_ENV=$(mktemp "${ENV_FILE}.XXXXXX")
        grep -v '^TRAEFIK_AUTH_HTPASSWD=' "$ENV_FILE" > "$TMP_ENV" || true
        printf "TRAEFIK_AUTH_HTPASSWD='%s'\n" "$ESCAPED_VAL" >> "$TMP_ENV"
        mv "$TMP_ENV" "$ENV_FILE"
        echo -e "${GREEN}✓ TRAEFIK_AUTH_HTPASSWD written to $ENV_FILE${NC}"
    else
        echo -e "${YELLOW}⚠ No .env found at $ENV_FILE; export TRAEFIK_AUTH_HTPASSWD before running deploy-traefik.sh${NC}"
    fi
fi

# Mirror the backup monitor htpasswd (bcrypt line) to the location Traefik
# mounts directly via `usersFile`. This file must be world-readable inside the
# Traefik container but we keep 0640 on the host.
if [ -f "$ENV_SECRETS_DIR/backup_monitor_htpasswd" ]; then
    BACKUP_MONITOR_HTPASSWD_DEST="$PROJECT_DIR/traefik-dynamic/backup-monitor-htpasswd"
    cp "$ENV_SECRETS_DIR/backup_monitor_htpasswd" "$BACKUP_MONITOR_HTPASSWD_DEST"
    chmod 640 "$BACKUP_MONITOR_HTPASSWD_DEST" 2>/dev/null || true
fi

# =============================================================================
# Create Swarm secrets for this environment
# =============================================================================
create_secrets_for_env "$ENV"

# =============================================================================
# Summary
# =============================================================================
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Secret creation complete!${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Local secrets saved in:${NC} $ENV_SECRETS_DIR"
echo ""
echo -e "${YELLOW}⚠ IMPORTANT:${NC}"
echo "  - Each environment has its OWN passwords (per-env isolation)"
echo "  - Host files in secrets/<env>/ are the source of truth"
echo "  - Add secrets/ to .gitignore to avoid committing passwords!"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  Deploy $ENV: ./scripts/deploy-swarm.sh --env $ENV"
echo ""
