# Live VM gate — runbook (dedicated session)

Validate the unified tree by actually deploying the **4 combos** (CE/EE ×
swarm/compose) on the test VMs. The assembler gate (`deploy.sh --render`) is
already green; this is the *deploy-for-real* gate, especially for **swarm**
(`compose config` can't render the `${ENV}-platform` overlay-network keys — only
a live `stack deploy` proves them).

## 0. Prereqs (once)
- Branch: **`feat/unified-deploy-integration`** (PR #28) — contains all of `unified/`.
- VMs:
  - **swarm** → `192.168.122.233` (`industream-test`): has `traefik-shared` stack + `prod_*` docker secrets + overlay nets. Repo at `~/industream-platform` (= industream-stack checkout).
  - **compose** → `192.168.122.41` (`industream-compose-test`): Caddy + David's `fm`. Deploy the unified stack as a **separate project** so it doesn't touch his instances.
- Get the tree on each VM: `cd ~/industream-platform && git fetch && git checkout feat/unified-deploy-integration` (swarm), or rsync `unified/` to .41.
- **Secrets must pre-exist** (the deploy does NOT create them):
  - swarm: `prod_datacatalog_db_password`, `prod_logto_db_url`, `prod_logto_db_password`, `prod_minio_*`, `prod_grafana_*`, `prod_influx_*`, `prod_postgres_admin_password`, `prod_timescaledb_password`, `prod_databridge_pg_password` (all already created on .233).
  - compose: files under `${SECRETS_DIR}` (default `./secrets/`): `datacatalog_db_password`, `logto_db_url`, `logto_db_password`, `minio_*`, `grafana_*`, `influx_*`, etc.
- **`unified/config/dotnet-entrypoint.sh`** must exist (datacatalog mounts it). Copy from the legacy `config/dotnet-entrypoint.sh` if absent.
- Per-env file `unified/.env.<env>` with: `INDUSTREAM_DOMAIN`, `TLS_MODE`, `INDUSTREAM_HUB_ORIGIN`, and (compose) `FM_DOMAIN`, `FM_NETWORK`, `SECRETS_DIR`. (`.env.test` is a dummy template.)

## 1. The 4 deploys
```sh
cd ~/industream-platform/unified   # (swarm)   |  unified/ on .41 (compose)

# --- swarm (on .233) ---  stack deploy interpolates ${ENV}-* correctly
./scripts/deploy.sh --runtime swarm --edition ce --env prod --stack industream-unified
./scripts/deploy.sh --runtime swarm --edition ee --env prod --stack industream-unified   # adds Logto

# --- compose (on .41) ---  isolated project, won't touch David's fm
./scripts/deploy.sh --runtime compose --edition ce --env <env> --project uni-ce
./scripts/deploy.sh --runtime compose --edition ee --env <env> --project uni-ee
```
> ⚠️ On swarm, use a **distinct stack name + domain** from the running
> `industream-prod` (else Traefik route conflict). Either a throwaway domain in
> `.env.prod` or tear down `industream-prod` first.

## 2. Post-deploy seeders (EE) — until Phase 4 wires them into deploy.sh
Run manually after an EE deploy (they already accept `--runtime`):
```sh
# extract from the EE Hub image (or vendored seeders/)
seed-logto-stack.sh  --runtime swarm --stack industream-unified            # OIDC app
seed-logto.sh        --runtime swarm --stack industream-unified --user admin --password "$(cat secrets/.../hub_backend_admin_password)" --redirect "https://$DOMAIN/" --role admin   # roles + user
seed-menu-apps-stack.sh --domain $DOMAIN --runtime swarm --stack industream-unified   # launchpad + bridge origins
```

## 3. Validation per combo (the gate)
1. **Converge:** all services `1/1` (swarm) / `Up` (compose); no crash-loop.
2. **Images:** short worker names + aligned versions; EE = `api-enterprise` + `logto` pinned.
3. **JWKS:** `curl -s http://uifusion-api:3050/auth/jwks | jq .keys` non-empty.
4. **DataCatalog auth (the security fix):** unauth request → 401; with a Hub bearer → 200.
5. **EE login:** Logto user logs in → Hub loads → DataCatalog tree (bearer) → Grafana SSO.
6. **JWT contract probe:** decoded token has `iss=hub-backend`, `aud=industream-hub`.

## 4. Known gaps to expect (fix during the gate)
- **Grafana-compose SSO:** needs a deploy-time hook to export the Caddy internal
  CA + bind-mount it into Grafana's `SSL_CERT_DIR` (Grafana 13 ignores
  `tls_skip_verify` for JWKS). Until then, compose-EE Grafana SSO fails closed.
- **datacatalog** `DB_SECRET_NAME` vs the connection-string placeholder: verify
  `dotnet-entrypoint.sh` reads `/run/secrets/${DB_SECRET_NAME}` and replaces
  `__DB_PASSWORD_PLACEHOLDER__` (latent note from Phase 1).
- **worker-manager** not in the unified tree yet (deferred infra group).
- Swarm overlay-net keys (`${ENV}-platform`) only validate at `stack deploy`.

## 5. Rollback
The legacy `docker-stack.*` (swarm) and David's `fm` (compose) are untouched and
still deploy the old way. `deploy.sh` is additive; remove the test stack/project
to revert. Nothing in this gate modifies the running `industream-prod`.
