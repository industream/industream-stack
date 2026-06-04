#!/bin/bash
# =============================================================================
# SEED LOGTO — bootstrap the Industream OIDC application + roles
# =============================================================================
# Run AFTER the EE overlay (docker-stack.ee.yml) is deployed and the Logto
# admin user has been created interactively at:
#   https://auth-admin.${INDUSTREAM_DOMAIN}
#
# Logto requires the first admin to be created via the web wizard — there is
# no API short-cut, by design. Once that's done, create a Machine-to-Machine
# application in the admin console (grant: "Logto Management API" with the
# `all` scope), then store its credentials at:
#   secrets/<env>/logto_m2m_credentials      ← JSON: {"appId":"…","appSecret":"…"}
#
# This script then idempotently provisions:
#   - OIDC application `industream-hub-app`        (the SPA web client)
#   - API resources, one per platform API, each with read/write/admin scopes
#     (`industream-hub` also carries the JWT `aud`)
#   - Roles (Grafana-aligned): industream-viewer / -editor / -admin, each
#     granted the matching scopes across ALL APIs (admin = everything)
#
# What it does NOT do (out of scope; do those via the admin console once):
#   - Create end-users (use SCIM / invitation flows or the admin console)
#   - Wire social/SSO connectors
#   - Configure email/SMS providers
#
# Re-running this script is safe: existing entities are detected by name and
# left untouched. Use `--force` to recreate (deletes + creates anew).
#
# Usage:
#   ./scripts/setup/seed-logto.sh --env prod
#   ./scripts/setup/seed-logto.sh --env prod --force
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

ENV=""
FORCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --env)   ENV="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --help|-h)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
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

# -----------------------------------------------------------------------------
# Load .env to read INDUSTREAM_DOMAIN and pick the Logto endpoints. We must
# `set -a` because the .env file uses bare KEY=value lines (no `export`).
# -----------------------------------------------------------------------------
ENV_FILE="$PROJECT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}✗ .env not found at $ENV_FILE${NC}" >&2
    exit 1
fi
set -a; source "$ENV_FILE"; set +a

DOMAIN="${INDUSTREAM_DOMAIN:-localhost}"
LOGTO_ADMIN_ENDPOINT="${LOGTO_ADMIN_ENDPOINT:-https://auth-admin.${DOMAIN}}"
LOGTO_PUBLIC_ENDPOINT="${LOGTO_ENDPOINT:-https://auth.${DOMAIN}}"

# -----------------------------------------------------------------------------
# Load M2M credentials. These cannot be auto-generated: Logto's first-run
# wizard mints them after the admin user creates the M2M app interactively.
# -----------------------------------------------------------------------------
M2M_FILE="$PROJECT_DIR/secrets/$ENV/logto_m2m_credentials"
if [ ! -f "$M2M_FILE" ]; then
    echo -e "${RED}✗ Missing M2M credentials at $M2M_FILE${NC}" >&2
    echo -e "${YELLOW}  Create them via the admin console:" >&2
    echo -e "    1. Open $LOGTO_ADMIN_ENDPOINT and finish the first-run wizard." >&2
    echo -e "    2. Applications → Create → Machine-to-Machine → name 'industream-seeder'." >&2
    echo -e "    3. Assign the 'Logto Management API' role with the 'all' scope." >&2
    echo -e "    4. Save the App ID + App Secret as JSON:" >&2
    echo -e "       echo '{\"appId\":\"…\",\"appSecret\":\"…\"}' > $M2M_FILE" >&2
    echo -e "       chmod 600 $M2M_FILE${NC}" >&2
    exit 1
fi

APP_ID=$(jq -r '.appId' "$M2M_FILE")
APP_SECRET=$(jq -r '.appSecret' "$M2M_FILE")
[ -n "$APP_ID" ] && [ "$APP_ID" != "null" ] || { echo -e "${RED}✗ appId missing in $M2M_FILE${NC}"; exit 1; }
[ -n "$APP_SECRET" ] && [ "$APP_SECRET" != "null" ] || { echo -e "${RED}✗ appSecret missing in $M2M_FILE${NC}"; exit 1; }

# -----------------------------------------------------------------------------
# Mint an access token for the Management API. The Management API resource
# is a built-in: https://default.logto.app/api (literal — used as the audience).
# -----------------------------------------------------------------------------
echo -e "${BLUE}Requesting Logto Management API access token...${NC}"
TOKEN_RESPONSE=$(curl -sS --fail-with-body \
    -X POST "$LOGTO_PUBLIC_ENDPOINT/oidc/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -u "${APP_ID}:${APP_SECRET}" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "scope=all" \
    --data-urlencode "resource=https://default.logto.app/api") || {
    echo -e "${RED}✗ Failed to obtain access token — check M2M creds or Logto reachability${NC}" >&2
    exit 1
}
ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
[ -n "$ACCESS_TOKEN" ] && [ "$ACCESS_TOKEN" != "null" ] || {
    echo -e "${RED}✗ Empty access token in response: $TOKEN_RESPONSE${NC}" >&2
    exit 1
}

API_BASE="$LOGTO_PUBLIC_ENDPOINT/api"
AUTH_HEADER="Authorization: Bearer $ACCESS_TOKEN"

# Idempotent helper: GET <list-endpoint>, find object by .name == $name,
# echo its id or empty string.
find_by_name() {
    local endpoint="$1"
    local name="$2"
    curl -sS -H "$AUTH_HEADER" "$API_BASE/$endpoint" \
        | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' \
        | head -n1
}

# -----------------------------------------------------------------------------
# 1) API resources (one per platform API) + read/write/admin scopes.
#    `industream-hub` also carries the JWT `aud`; the others are declared so
#    per-API audience validation is possible later. Scope ids are collected
#    per level so the roles below can grant them in bulk.
# -----------------------------------------------------------------------------
API_RESOURCES=(
    "industream-hub|https://hub.${DOMAIN}"
    "datacatalog|https://datacatalog-api.${DOMAIN}"
    "flowmaker|https://flowmaker.${DOMAIN}"
    "confighub|https://confighub.${DOMAIN}"
    "databridge|https://databridge.${DOMAIN}"
)
SCOPE_LEVELS=(read write admin)
READ_SCOPES=(); WRITE_SCOPES=(); ADMIN_SCOPES=()

# Create (or reuse) a resource by name; echo its id. Honors --force.
ensure_resource() {
    local name="$1" indicator="$2" id
    id=$(find_by_name resources "$name")
    if [ -n "$id" ] && [ "$FORCE" = true ]; then
        curl -sS -X DELETE -H "$AUTH_HEADER" "$API_BASE/resources/$id" >/dev/null; id=""
    fi
    if [ -z "$id" ]; then
        id=$(curl -sS --fail-with-body -X POST "$API_BASE/resources" \
            -H "$AUTH_HEADER" -H "Content-Type: application/json" \
            -d "{\"name\":\"$name\",\"indicator\":\"$indicator\"}" | jq -r '.id')
        echo -e "${GREEN}✓ Resource '$name' ($indicator)${NC}" >&2
    else
        echo -e "${YELLOW}⏭ Resource '$name' exists${NC}" >&2
    fi
    printf '%s' "$id"
}

# Create (or reuse) a scope on a resource; echo its id.
ensure_scope() {
    local rid="$1" sname="$2" sid
    sid=$(curl -sS -H "$AUTH_HEADER" "$API_BASE/resources/$rid/scopes" \
        | jq -r --arg n "$sname" '.[] | select(.name==$n) | .id' | head -n1)
    if [ -z "$sid" ]; then
        sid=$(curl -sS --fail-with-body -X POST "$API_BASE/resources/$rid/scopes" \
            -H "$AUTH_HEADER" -H "Content-Type: application/json" \
            -d "{\"name\":\"$sname\",\"description\":\"$sname access\"}" | jq -r '.id')
    fi
    printf '%s' "$sid"
}

for entry in "${API_RESOURCES[@]}"; do
    rname="${entry%%|*}"; rind="${entry##*|}"
    rid=$(ensure_resource "$rname" "$rind")
    [ -n "$rid" ] && [ "$rid" != "null" ] || { echo -e "${RED}✗ no id for resource '$rname'${NC}"; exit 1; }
    for lvl in "${SCOPE_LEVELS[@]}"; do
        sid=$(ensure_scope "$rid" "$lvl")
        case "$lvl" in
            read)  READ_SCOPES+=("$sid") ;;
            write) WRITE_SCOPES+=("$sid") ;;
            admin) ADMIN_SCOPES+=("$sid") ;;
        esac
    done
done
echo -e "${GREEN}✓ ${#API_RESOURCES[@]} API resources with read/write/admin scopes${NC}"

# -----------------------------------------------------------------------------
# 2) OIDC app = `industream-hub-app` (the SPA / web client used by uifusion-api)
# -----------------------------------------------------------------------------
APP_NAME="industream-hub-app"
APP_REDIRECT_URI="https://dashboard.${DOMAIN}/auth/callback"
EXISTING_APP_ID=$(find_by_name "applications" "$APP_NAME")
if [ -n "$EXISTING_APP_ID" ] && [ "$FORCE" = false ]; then
    echo -e "${YELLOW}⏭ Application '$APP_NAME' exists ($EXISTING_APP_ID), skipping${NC}"
else
    [ -n "$EXISTING_APP_ID" ] && curl -sS -X DELETE -H "$AUTH_HEADER" "$API_BASE/applications/$EXISTING_APP_ID" >/dev/null
    APP_PAYLOAD=$(jq -cn \
        --arg name "$APP_NAME" \
        --arg redirect "$APP_REDIRECT_URI" \
        '{
           name: $name,
           type: "Traditional",
           oidcClientMetadata: {
             redirectUris: [$redirect],
             postLogoutRedirectUris: [$redirect]
           }
         }')
    curl -sS --fail-with-body -X POST "$API_BASE/applications" \
        -H "$AUTH_HEADER" -H "Content-Type: application/json" \
        -d "$APP_PAYLOAD" >/dev/null
    echo -e "${GREEN}✓ Created application '$APP_NAME' (redirect: $APP_REDIRECT_URI)${NC}"
fi

# -----------------------------------------------------------------------------
# 3) Roles (Grafana-aligned): viewer / editor / admin.
#    viewer = read on every API; editor = read+write; admin = everything.
#    The `roles` claim drives Grafana (role_attribute_path) and the menu's
#    per-app gating; the `scope` claim carries the fine-grained access.
# -----------------------------------------------------------------------------
ensure_role() {
    local name="$1" desc="$2" id
    id=$(find_by_name roles "$name")
    if [ -n "$id" ] && [ "$FORCE" = true ]; then
        curl -sS -X DELETE -H "$AUTH_HEADER" "$API_BASE/roles/$id" >/dev/null; id=""
    fi
    if [ -z "$id" ]; then
        id=$(curl -sS --fail-with-body -X POST "$API_BASE/roles" \
            -H "$AUTH_HEADER" -H "Content-Type: application/json" \
            -d "{\"name\":\"$name\",\"description\":\"$desc\"}" | jq -r '.id')
        echo -e "${GREEN}✓ Role '$name'${NC}" >&2
    else
        echo -e "${YELLOW}⏭ Role '$name' exists${NC}" >&2
    fi
    printf '%s' "$id"
}

# Grant scope ids to a role (idempotent — Logto ignores already-granted ids).
assign_role_scopes() {
    local rid="$1"; shift
    [ "$#" -gt 0 ] || return 0
    local ids; ids=$(printf '%s\n' "$@" | jq -R . | jq -cs .)
    curl -sS -X POST "$API_BASE/roles/$rid/scopes" \
        -H "$AUTH_HEADER" -H "Content-Type: application/json" \
        -d "{\"scopeIds\":$ids}" >/dev/null 2>&1 || true
}

VIEWER_ID=$(ensure_role industream-viewer "Read-only across all Industream APIs (Grafana: Viewer)")
EDITOR_ID=$(ensure_role industream-editor "Read + write across all Industream APIs (Grafana: Editor)")
ADMIN_ID=$(ensure_role  industream-admin  "Full admin across all Industream APIs (Grafana: Admin)")

assign_role_scopes "$VIEWER_ID" "${READ_SCOPES[@]}"
assign_role_scopes "$EDITOR_ID" "${READ_SCOPES[@]}" "${WRITE_SCOPES[@]}"
assign_role_scopes "$ADMIN_ID"  "${READ_SCOPES[@]}" "${WRITE_SCOPES[@]}" "${ADMIN_SCOPES[@]}"
echo -e "${GREEN}✓ Roles viewer/editor/admin scoped (admin = all APIs)${NC}"

echo ""
echo -e "${GREEN}Logto seeding complete for environment '$ENV'.${NC}"
echo -e "${BLUE}Next: assign users to roles in the admin console, then set${NC}"
echo -e "${BLUE}uifusion-api OIDC_CLIENT_ID to '$APP_NAME'.${NC}"
