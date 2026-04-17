#!/bin/bash
# =============================================================================
# CREATE DOCKER SECRETS - MULTI-ENVIRONMENT SUPPORT
# =============================================================================
# Create all required Docker secrets for Industream environments.
# Secrets are shared across all environments (same passwords).
# Passwords are stored locally in secrets/ folder for reference.
#
# Usage:
#   ./scripts/setup/create-secrets.sh --env prod       # Create prod secrets
#   ./scripts/setup/create-secrets.sh --env dev        # Create dev secrets
#   ./scripts/setup/create-secrets.sh --env staging    # Create staging secrets
#   ./scripts/setup/create-secrets.sh --env all        # Create all environments
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
            echo "Usage: $0 --env <prod|dev|staging|all> [--regenerate]"
            echo ""
            echo "Required:"
            echo "  --env <env>    Environment to create secrets for"
            echo "                 prod     - Production environment"
            echo "                 dev      - Development environment"
            echo "                 staging  - Staging environment"
            echo "                 all      - All environments"
            echo ""
            echo "Optional:"
            echo "  --regenerate   Rotate secrets not currently used by any service."
            echo "                 Secrets in use will abort the script with an error —"
            echo "                 stateful services need their dedicated rotation scripts."
            echo ""
            echo "Examples:"
            echo "  $0 --env prod          # Create secrets for production"
            echo "  $0 --env all           # Create secrets for all environments"
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
    echo "Usage: $0 --env <prod|dev|staging|all>"
    exit 1
fi

if [[ ! "$ENV" =~ ^(prod|dev|staging|all)$ ]]; then
    echo -e "${RED}✗ Invalid environment: $ENV${NC}"
    echo "Valid environments: prod, dev, staging, all"
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

# Create secrets directory if it doesn't exist
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
echo -e "${GREEN}✓ Secrets directory: $SECRETS_DIR${NC}"
echo ""

# =============================================================================
# List of base secret names (shared across all environments)
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
    "cloudbeaver_admin_password"
    "ironstream_db_password"
    "timescaledb_password"
    "databridge_pg_password"
)

# =============================================================================
# Function to get or generate a secret value
# Returns the secret value (reads from file or generates new)
# =============================================================================
get_or_generate_secret() {
    local secret_name="$1"
    local secret_file="$SECRETS_DIR/$secret_name"

    if [ -f "$secret_file" ] && [ "$REGENERATE" = false ]; then
        # Read existing secret from file
        cat "$secret_file"
    else
        # Generate new secret and save to file
        local new_secret
        if [[ "$secret_name" == *"_user" ]] || [[ "$secret_name" == *"_username" ]]; then
            # For user/username secrets, use a readable default
            new_secret="admin"
        else
            new_secret=$(openssl rand -hex 24)
        fi
        echo -n "$new_secret" > "$secret_file"
        chmod 600 "$secret_file"
        echo "$new_secret"
    fi
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

        # Get or generate the secret value (same for all environments)
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
                echo -n "$secret_value" | docker secret create "$docker_secret" - >/dev/null
                echo -e "${YELLOW}↻ Rotated secret: $docker_secret${NC}"
                updated=$((updated + 1))
            else
                echo -e "${YELLOW}⏭ Secret '$docker_secret' already exists, skipping...${NC}"
                skipped=$((skipped + 1))
            fi
        else
            # Create new Docker secret
            echo -n "$secret_value" | docker secret create "$docker_secret" - >/dev/null
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
# Generate/load all base secrets first (ensures same values across envs)
# =============================================================================
echo -e "${BLUE}Loading/generating base secrets...${NC}"
for base_secret in "${BASE_SECRETS[@]}"; do
    secret_file="$SECRETS_DIR/$base_secret"
    if [ -f "$secret_file" ] && [ "$REGENERATE" = false ]; then
        echo -e "  ${GREEN}✓${NC} $base_secret (from file)"
    else
        get_or_generate_secret "$base_secret" > /dev/null
        echo -e "  ${GREEN}✓${NC} $base_secret (generated)"
    fi
done
echo ""

# =============================================================================
# Create secrets based on environment
# =============================================================================
if [ "$ENV" = "all" ]; then
    echo -e "${BLUE}Creating secrets for ALL environments...${NC}"
    echo ""
    create_secrets_for_env "prod"
    create_secrets_for_env "dev"
    create_secrets_for_env "staging"
else
    create_secrets_for_env "$ENV"
fi

# =============================================================================
# Summary
# =============================================================================
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Secret creation complete!${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Local secrets saved in:${NC} $SECRETS_DIR"
echo ""
echo -e "${YELLOW}⚠ IMPORTANT:${NC}"
echo "  - Secrets are SHARED across all environments (same passwords)"
echo "  - Local files in secrets/ folder are the source of truth"
echo "  - Add secrets/ to .gitignore to avoid committing passwords!"
echo ""
echo -e "${BLUE}Next steps:${NC}"
if [ "$ENV" = "all" ] || [ "$ENV" = "prod" ]; then
    echo "  Deploy prod:    ./scripts/deploy-swarm.sh --env prod"
fi
if [ "$ENV" = "all" ] || [ "$ENV" = "dev" ]; then
    echo "  Deploy dev:     ./scripts/deploy-swarm.sh --env dev"
fi
if [ "$ENV" = "all" ] || [ "$ENV" = "staging" ]; then
    echo "  Deploy staging: ./scripts/deploy-swarm.sh --env staging"
fi
echo ""
