#!/bin/bash
# =============================================================================
# CREATE EE DOCKER SECRETS — Logto overlay
# =============================================================================
# Generates the secrets consumed by docker-stack.ee.yml (Logto + its dedicated
# Postgres). Kept separate from create-secrets.sh to avoid coupling CE deploys
# to EE-only state, and so it can be safely re-run after a CE → EE promotion.
#
# Outputs (per-env, mode 0600):
#   secrets/<env>/logto_db_password            random hex(24)
#   secrets/<env>/logto_db_url                 postgres://postgres:<pwd>@logto-postgres:5432/logto
#   secrets/<env>/grafana_oidc_client_secret   random hex(32)
#
# And the matching Docker Swarm secrets:
#   <env>_logto_db_password
#   <env>_logto_db_url
#   <env>_grafana_oidc_client_secret
#
# Usage:
#   ./scripts/setup/create-secrets-ee.sh --env prod
#   ./scripts/setup/create-secrets-ee.sh --env prod --regenerate
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SECRETS_DIR="$PROJECT_DIR/secrets"

ENV=""
REGENERATE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --env)        ENV="$2"; shift 2 ;;
        --regenerate) REGENERATE=true; shift ;;
        --help|-h)
            echo "Usage: $0 --env <prod|dev|staging> [--regenerate]"
            exit 0 ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}" >&2
            exit 1 ;;
    esac
done

if [ -z "$ENV" ]; then
    echo -e "${RED}✗ Environment not specified (--env <prod|dev|staging>)${NC}" >&2
    exit 1
fi
if [[ ! "$ENV" =~ ^(prod|dev|staging)$ ]]; then
    echo -e "${RED}✗ Invalid environment: $ENV${NC}" >&2
    exit 1
fi

ENV_SECRETS_DIR="$SECRETS_DIR/$ENV"
mkdir -p "$ENV_SECRETS_DIR"
chmod 700 "$ENV_SECRETS_DIR"

# -----------------------------------------------------------------------------
# Returns the secret value: reads existing file unless --regenerate, otherwise
# writes a fresh random value. Side-effect: file is created with mode 0600.
# -----------------------------------------------------------------------------
get_or_generate() {
    local name="$1"
    local generator="$2"   # command-line that produces the value on stdout
    local f="$ENV_SECRETS_DIR/$name"
    if [ -f "$f" ] && [ "$REGENERATE" = false ]; then
        cat "$f"
        return
    fi
    local value
    value=$(eval "$generator")
    printf '%s' "$value" > "$f"
    chmod 600 "$f"
    printf '%s' "$value"
}

# -----------------------------------------------------------------------------
# Mirror an env-file secret into Docker Swarm as `<env>_<name>`. Idempotent.
# Swarm refuses to remove a secret mounted by a running service, so when
# --regenerate is asked we abort with a clear message rather than risk a
# partial rotation (the running Logto would keep the old DB password while the
# postgres container picks up the new one on next restart).
# -----------------------------------------------------------------------------
publish_swarm_secret() {
    local base_name="$1"
    local value="$2"
    local swarm_name="${ENV}_${base_name}"
    if docker secret ls --format '{{.Name}}' | grep -q "^${swarm_name}$"; then
        if [ "$REGENERATE" = true ]; then
            local in_use_by
            in_use_by=$(docker service ls --format '{{.Name}}' \
                | xargs -r -I{} docker service inspect {} \
                    --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{.SecretName}} {{end}}{{.Spec.Name}}' \
                | grep -E "^(.* )?${swarm_name} " | awk '{print $NF}' || true)
            if [ -n "$in_use_by" ]; then
                local services_csv
                services_csv=$(echo "$in_use_by" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
                echo -e "${RED}✗ Cannot rotate '$swarm_name' — used by service(s): $services_csv${NC}" >&2
                echo -e "${YELLOW}  Stop those services first, or rotate via the Logto Postgres" >&2
                echo -e "  procedure (re-issue DB password inside Postgres, then rerun).${NC}" >&2
                exit 1
            fi
            docker secret rm "$swarm_name" >/dev/null
            printf '%s' "$value" | docker secret create "$swarm_name" - >/dev/null
            echo -e "${YELLOW}↻ Rotated: $swarm_name${NC}"
        else
            echo -e "${YELLOW}⏭ $swarm_name already exists, skipping${NC}"
        fi
    else
        printf '%s' "$value" | docker secret create "$swarm_name" - >/dev/null
        echo -e "${GREEN}✓ Created: $swarm_name${NC}"
    fi
}

echo -e "${BLUE}Creating EE secrets for ${ENV^^} environment...${NC}"

# 1) Logto DB password
LOGTO_DB_PASSWORD=$(get_or_generate "logto_db_password" "openssl rand -hex 24")

# 2) Logto DB URL — built from the password. We use the Swarm service name
#    (`logto-postgres`) and the default database (`logto`) created by the
#    Postgres init in docker-stack.ee.yml.
LOGTO_DB_URL_GENERATOR="printf 'postgres://postgres:%s@logto-postgres:5432/logto' \"\$LOGTO_DB_PASSWORD\""
LOGTO_DB_URL=$(get_or_generate "logto_db_url" "$LOGTO_DB_URL_GENERATOR")

# 3) Grafana's OIDC client secret. Grafana reads it from
#    /run/secrets/<name> via GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET__FILE
#    (unified/base/ee.yml); deploy.sh pushes the same value into Logto's
#    `applications.secret` row after the label registrar has created it.
#    Replaces the old committed literal `unused-grafana`, which was derivable
#    from the public client_id and identical on every install.
GRAFANA_OIDC_CLIENT_SECRET=$(get_or_generate "grafana_oidc_client_secret" "openssl rand -hex 32")

publish_swarm_secret "logto_db_password"          "$LOGTO_DB_PASSWORD"
publish_swarm_secret "logto_db_url"               "$LOGTO_DB_URL"
publish_swarm_secret "grafana_oidc_client_secret" "$GRAFANA_OIDC_CLIENT_SECRET"

echo ""
echo -e "${BLUE}EE secrets ready under ${ENV_SECRETS_DIR}.${NC}"
