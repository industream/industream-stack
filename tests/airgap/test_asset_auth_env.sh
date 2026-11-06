#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/bin/sleep"
chmod +x "$fixture/bin/sleep"
export PATH="$fixture/bin:$PATH"
source "$REPO_ROOT/unified/scripts/lib/datacatalog-cors.sh"
unset DATACATALOG_CORS_ALLOWED_ORIGINS
INDUSTREAM_DOMAIN=plant.test INDUSTREAM_HUB_ORIGIN=https://hub.plant.test RUNTIME=swarm
expected='https://hub.plant.test,https://flowmaker.plant.test,https://datacatalog-ui.plant.test'
assert_eq "$(datacatalog_cors_origins)" "$expected" "Swarm CORS covers Hub, FlowMaker and DataCatalog UI"
DATACATALOG_CORS_ALLOWED_ORIGINS='https://custom.example,http://localhost:5173'
assert_eq "$(datacatalog_cors_origins)" "$DATACATALOG_CORS_ALLOWED_ORIGINS" "explicit allowlist replaces the default"
unset DATACATALOG_CORS_ALLOWED_ORIGINS
RUNTIME=compose FM_DOMAIN=compose.test
assert_eq "$(datacatalog_cors_origins)" 'https://hub.plant.test,https://frontend.compose.test,https://datacatalog-ui.compose.test' "Compose origins follow its routing domain"
(
  unset INDUSTREAM_HUB_ORIGIN
  export RUNTIME FM_DOMAIN
  python3 - "$REPO_ROOT" "$(datacatalog_cors_origins)" <<'PY'
import sys,yaml
from pathlib import Path
root=Path(sys.argv[1])/'unified'
services=[('runtime/compose/core.yml','industream-hub-frontend'),('runtime/compose/flowmaker.yml','flowmaker-frontend'),('runtime.compose.yml','datacatalog-ui')]
origins=[]
for filename,service in services:
    labels=yaml.safe_load((root/filename).read_text())['services'][service]['labels']
    origins.append('https://'+labels['caddy'].replace('${FM_DOMAIN}','compose.test'))
assert sys.argv[2].split(',')==origins,(sys.argv[2],origins)
print('  ✓ default Compose allowlist matches actual frontend Caddy routes')
PY
)
(
  unset INDUSTREAM_HUB_ORIGIN
  RUNTIME=swarm
  python3 - "$REPO_ROOT" "$(datacatalog_cors_origins)" <<'PY'
import re,sys,yaml
from pathlib import Path
root=Path(sys.argv[1])/'unified'
services=[('runtime/swarm/core.yml','industream-hub-frontend'),('runtime/swarm/flowmaker.yml','flowmaker-frontend'),('runtime.swarm.yml','datacatalog-ui')]
origins=[]
for filename,service in services:
    labels=yaml.safe_load((root/filename).read_text())['services'][service]['deploy']['labels']
    rule=next(label for label in labels if '-secure.rule=Host(' in label)
    host=re.search(r'Host\(`([^`]+)`\)',rule)[1]
    origins.append('https://'+host.replace('${INDUSTREAM_DOMAIN}','plant.test'))
assert sys.argv[2].split(',')==origins,(sys.argv[2],origins)
print('  ✓ default Swarm allowlist matches actual frontend Traefik routes')
PY
)
unset FM_DOMAIN
RUNTIME=swarm

# Render the actual API template through Swarm's own interpolator, without a daemon.
export DATACATALOG_CORS_ALLOWED_ORIGINS="$expected"
export DATACATALOG_API_IMAGE=example/api:1 DATACATALOG_UI_IMAGE=example/ui:1
export HUB_AUTH_ISSUER=hub-backend HUB_AUTH_AUDIENCE=industream-hub HUB_AUTH_JWKS_URL=http://industream-hub-backend:3050/auth/jwks
export INDUSTREAM_DOMAIN INDUSTREAM_HUB_ORIGIN
export DATACATALOG_DB_SECRET_NAME=test_datacatalog_db_password DATACATALOG_DB_HOST=postgres
render="$(docker stack config -c "$REPO_ROOT/unified/base/datacatalog.yml" 2>/dev/null)"
assert_contains "$render" "$expected" "Swarm renders the complete allowlist as a literal"
assert_contains "$render" 'Authentication__Frontend__Issuer: hub-backend' "issuer stays aligned with Hub"
assert_contains "$render" 'Authentication__Frontend__Audience: industream-hub' "audience stays aligned with Hub"
assert_contains "$render" 'Authentication__Frontend__JwksUrl: http://industream-hub-backend:3050/auth/jwks' "JWKS uses the canonical internal Hub address"
DATACATALOG_CORS_ALLOWED_ORIGINS=https://custom.example
render="$(docker stack config -c "$REPO_ROOT/unified/base/datacatalog.yml" 2>/dev/null)"
assert_contains "$render" 'Cors__AllowedOrigins: https://custom.example' "Swarm honors an explicit allowlist"

python3 - "$REPO_ROOT" <<'PY'
import sys,yaml
from pathlib import Path
root=Path(sys.argv[1])/'unified'
base=yaml.safe_load((root/'base/core.yml').read_text())
swarm=yaml.safe_load((root/'runtime/swarm/core.yml').read_text())
env=base['services']['industream-hub-backend']['environment']
assert 'IH_JWT_SIGNING_KEY_FILE=/run/secrets/hub_jwt_signing_key' in env
assert 'IH_ISSUER=${HUB_AUTH_ISSUER}' in env
assert 'IH_AUDIENCE=${HUB_AUTH_AUDIENCE}' in env
mount=swarm['services']['industream-hub-backend']['secrets']
assert {'source':'hub_jwt_signing_key','target':'hub_jwt_signing_key'} in mount
assert swarm['secrets']['hub_jwt_signing_key']=={'name':'${ENV}_hub_jwt_signing_key','external':True}
flowmaker=yaml.safe_load((root/'base/flowmaker.yml').read_text())
for service in ['flowmaker-confighub','flowmaker-logging','flowmaker-scheduler']:
    values=flowmaker['services'][service]['environment']
    for name in ['ISSUER','AUDIENCE','JWKS_URL']:
        assert 'FM_AUTH_'+name+'=${HUB_AUTH_'+name+'}' in values
print('  ✓ signing-key env, mount and env-scoped secret agree')
print('  ✓ Hub, DataCatalog and FlowMaker share the JWT verification contract')
PY

# Listing/rendering must not provision a signing key. A real deploy must.
cd "$REPO_ROOT/unified"
with_docker_stub ./scripts/deploy.sh --runtime swarm --edition ce --env test --stack test \
  --bundle 1.0.1 --groups core --list-images >/dev/null
[[ "$(cat "$DOCKER_LOG")" != *'secret inspect test_hub_jwt_signing_key'* ]] || fail "list-images provisioned the key"
pass "list-images stays side-effect free"
DEPLOY_TIMEOUT=1 with_docker_stub ./scripts/deploy.sh --runtime swarm --edition ce --env test --stack test \
  --bundle 1.0.1 --groups core --airgap >/dev/null 2>&1 || true
assert_contains "$(cat "$DOCKER_LOG")" 'secret inspect test_hub_jwt_signing_key' "real core deploy prepares its signing-key secret"

# A site's domain/allowlist is read after bundle defaults, including the
# Compose path where exported values otherwise hide --env-file overrides.
cp -a "$REPO_ROOT/unified" "$fixture/unified"
cp -a "$REPO_ROOT/scripts" "$fixture/scripts"
cat > "$fixture/unified/.env.test" <<'ENV'
INDUSTREAM_DOMAIN=site.test
FM_DOMAIN=site.test
INDUSTREAM_HUB_ORIGIN=https://portal.site.test
FM_NETWORK=site-net
ENV
unset DATACATALOG_CORS_ALLOWED_ORIGINS
export DOCKER_STUB_LOG_ENV=DATACATALOG_CORS_ALLOWED_ORIGINS
with_docker_stub "$fixture/unified/scripts/deploy.sh" --runtime compose --edition ce --env test --project test \
  --bundle 1.0.1 --groups datacatalog --render >/dev/null
assert_contains "$(cat "$DOCKER_LOG")" 'env DATACATALOG_CORS_ALLOWED_ORIGINS=https://portal.site.test,https://frontend.site.test,https://datacatalog-ui.site.test' "site domain overrides are applied before deriving CORS"
printf 'DATACATALOG_CORS_ALLOWED_ORIGINS=https://special.site.test\n' >> "$fixture/unified/.env.test"
with_docker_stub "$fixture/unified/scripts/deploy.sh" --runtime compose --edition ce --env test --project test \
  --bundle 1.0.1 --groups datacatalog --render >/dev/null
assert_contains "$(cat "$DOCKER_LOG")" 'env DATACATALOG_CORS_ALLOWED_ORIGINS=https://special.site.test' "site allowlist overrides win in Compose rendering"
OUT_DIR="$fixture/portainer" bash "$fixture/unified/scripts/render-portainer-stacks.sh" \
  --env test --edition ce --bundle 1.0.2 > "$fixture/portainer.log" 2>&1
assert_eq "$(grep '^DATACATALOG_CORS_ALLOWED_ORIGINS=' "$fixture/portainer/stack.env" | tail -1)" \
  'DATACATALOG_CORS_ALLOWED_ORIGINS=https://special.site.test' "Portainer stack.env preserves the site override"
OUT_DIR="$fixture/baked" bash "$fixture/unified/scripts/render-portainer-stacks.sh" \
  --env test --edition ce --bundle 1.0.2 --baked > "$fixture/baked.log" 2>&1
python3 - "$fixture/baked/datacatalog/docker-compose.yml" <<'PY'
import sys,yaml
env=yaml.safe_load(open(sys.argv[1]))['services']['datacatalog-api']['environment']
env=dict(item.split('=',1) for item in env) if isinstance(env,list) else env
assert env['Cors__AllowedOrigins']=='https://special.site.test',env['Cors__AllowedOrigins']
print('  ✓ baked Portainer stack contains the literal allowlist')
PY
