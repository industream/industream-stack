#!/bin/bash
# =============================================================================
# seed-filebrowser-sso.sh — hands-off SSO provisioning for the IronStream
# filebrowser (oauth2-proxy → Logto). Run post-deploy, AFTER seed_ee (Logto up).
# Idempotent + strictly non-fatal (a deploy never fails because SSO seeding did).
#
# Bootstrap ordering: oauth2-proxy is deployed with an external client secret
# that only exists once Logto is up. deploy.sh pre-creates a PLACEHOLDER client
# secret so the stack deploy succeeds; this seeder mints the real Logto client,
# swaps the secret, sets OAUTH2_PROXY_CLIENT_ID, force-updates oauth2-proxy, and
# flips filebrowser to proxy-auth.
#
# Env in: STACK (swarm stack), ENV, INDUSTREAM_DOMAIN. Optional: FB_SSO_SKIP=1.
# =============================================================================
set -uo pipefail
[[ "${FB_SSO_SKIP:-0}" == 1 ]] && { echo "  ⚠ filebrowser SSO seeding skipped (FB_SSO_SKIP=1)"; exit 0; }

STACK="${STACK:-industream-prod}"; ENV="${ENV:-prod}"
DOMAIN="${INDUSTREAM_DOMAIN:-localhost}"
ADMIN_EP="https://auth-admin.$DOMAIN"; CORE_EP="https://auth.$DOMAIN"; API="$CORE_EP/api"
FB_SVC="${STACK}_ironstream-filebrowser"; OP_SVC="${STACK}_oauth2-proxy"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ENVFILE="$HERE/../.env.${ENV}"
[[ -f "$ENVFILE" ]] || ENVFILE="$HERE/../unified/.env.${ENV}"

echo "▶ filebrowser SSO seeder (Logto client + oauth2-proxy + proxy-auth)…"

# Only meaningful when both the filebrowser and oauth2-proxy services are present.
docker service inspect "$FB_SVC" >/dev/null 2>&1 || { echo "  ⚠ no $FB_SVC — skipping (filebrowser not deployed)"; exit 0; }
docker service inspect "$OP_SVC" >/dev/null 2>&1 || { echo "  ⚠ no $OP_SVC — skipping (auth group not deployed)"; exit 0; }

# Management API token via the built-in admin-tenant m-default app (its secret is
# readable from logto-postgres; it mints a default-tenant Management API token on
# the ADMIN endpoint). Same access seed_ee's image seeder relies on.
pg=$(docker ps -q --filter "label=com.docker.swarm.service.name=${STACK}_logto-postgres" | head -1)
[[ -z "$pg" ]] && { echo "  ⚠ logto-postgres not found — skipping"; exit 0; }
msec=$(docker exec "$pg" psql -U postgres -d logto -t -A -c "select secret from applications where id='m-default';" 2>/dev/null)
tok=$(curl -sk -X POST "$ADMIN_EP/oidc/token" -u "m-default:$msec" \
  -d grant_type=client_credentials --data-urlencode "resource=https://default.logto.app/api" -d scope=all | jq -r '.access_token // ""')
[[ -z "$tok" ]] && { echo "  ⚠ could not obtain Logto Management API token — skipping"; exit 0; }
AH="Authorization: Bearer $tok"

# 1) filebrowser Logto app (Traditional / confidential) — reuse or create.
cb="https://filebrowser.${DOMAIN}/oauth2/callback"
cid=$(curl -sk -H "$AH" "$API/applications?page_size=50" | jq -r '.[]|select(.name=="IronStream Filebrowser")|.id' | head -1)
if [[ -z "$cid" || "$cid" == null ]]; then
  cid=$(curl -sk -X POST "$API/applications" -H "$AH" -H 'Content-Type: application/json' \
    -d "{\"name\":\"IronStream Filebrowser\",\"type\":\"Traditional\",\"description\":\"SSO gateway (oauth2-proxy)\",\"oidcClientMetadata\":{\"redirectUris\":[\"$cb\"],\"postLogoutRedirectUris\":[\"https://filebrowser.${DOMAIN}/\"]}}" | jq -r .id)
fi
[[ -z "$cid" || "$cid" == null ]] && { echo "  ⚠ filebrowser app creation failed — skipping"; exit 0; }
csec=$(curl -sk -H "$AH" "$API/applications/$cid/secrets" | jq -r '.[0].value')

# 2) swap the real client secret into oauth2-proxy. Docker secrets are immutable
#    AND in-use-locked, so: DETACH the placeholder from the service first, wait for
#    the docker secret to free up, remove it, create the real one. Also ensure the
#    cookie secret exists (32 raw bytes).
secname="${ENV}_oauth2_proxy_client_secret"
docker service update --detach=true --secret-rm "$secname" "$OP_SVC" >/dev/null 2>&1
for _i in $(seq 1 20); do docker secret rm "$secname" >/dev/null 2>&1 && break; sleep 2; done
printf '%s' "$csec" | docker secret create "$secname" - >/dev/null
docker secret ls --format '{{.Name}}' | grep -q "^${ENV}_oauth2_proxy_cookie_secret$" \
  || openssl rand 32 | docker secret create "${ENV}_oauth2_proxy_cookie_secret" - >/dev/null

# 3) persist OAUTH2_PROXY_CLIENT_ID (for future deploys) + re-attach the (now real)
#    secret and set the client id → oauth2-proxy restarts and reaches OIDC.
if [[ -f "$ENVFILE" ]]; then
  grep -q '^OAUTH2_PROXY_CLIENT_ID=' "$ENVFILE" \
    && sed -i "s#^OAUTH2_PROXY_CLIENT_ID=.*#OAUTH2_PROXY_CLIENT_ID=$cid#" "$ENVFILE" \
    || printf 'OAUTH2_PROXY_CLIENT_ID=%s\n' "$cid" >> "$ENVFILE"
fi
docker service update --detach=true --force \
  --env-add "OAUTH2_PROXY_CLIENT_ID=$cid" \
  --secret-add "source=$secname,target=$secname" \
  "$OP_SVC" >/dev/null 2>&1
echo "  ✓ Logto client '$cid' + oauth2-proxy updated"

# 4) flip filebrowser to proxy-auth (BoltDB write-exclusive → scale 0 first).
if ! docker run --rm -v "${ENV}-ironstream-filebrowser-config:/config" hurlenko/filebrowser:v2.63.5 \
     config cat -d /config/filebrowser.db 2>/dev/null | grep -q '"method":"proxy"'; then
  docker service scale "$FB_SVC"=0 >/dev/null 2>&1; sleep 6
  docker run --rm -v "${ENV}-ironstream-filebrowser-config:/config" hurlenko/filebrowser:v2.63.5 \
    config set --auth.method=proxy --auth.header=X-Auth-Request-Email -d /config/filebrowser.db >/dev/null 2>&1
  docker service scale "$FB_SVC"=1 >/dev/null 2>&1
  echo "  ✓ filebrowser → auth.method=proxy (X-Auth-Request-Email)"
else
  echo "  ✓ filebrowser already in proxy-auth"
fi
echo "  ✓ filebrowser SSO ready — https://filebrowser.${DOMAIN}/"
