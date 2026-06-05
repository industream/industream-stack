# DRIFT-RECONCILED.md

> Phase 1 unified-deploy extraction (2026-06-05). Records every divergence found
> between the two source trees — `industream-stack` (Swarm/Traefik) and
> `industream-flowmaker/deployment` (Compose/Caddy) — and the canonical choice
> made in the neutral `base/*.yml` + per-runtime `runtime/{swarm,compose}/*.yml`.
>
> Invariant kept across ALL groups: **no inline image tag** (every `image:` →
> `${VAR}` from `versions.env`, no `:-default` → fails loud); **no inline
> password** (file-secrets only); image tags sourced exclusively from
> `versions.env`; registries from `registries.env`; Hub JWT contract from
> `auth.env` (`iss=hub-backend`, `aud=industream-hub`, JWKS
> `http://uifusion-api:3050/auth/jwks` — THE INVARIANT, unchanged).

---

## 1. Drift table per group

### workers (19 flow-box workers)

| Kind | Swarm source | Compose source | Canonical |
|------|--------------|----------------|-----------|
| Image name | `flowmaker.boxes/<x>` (short) | `flowmaker.boxes/flow-box-<x>` (long, WRONG) | **short** `flowmaker.boxes/<x>` |
| Tag | `:-2.0.3` inline defaults | `:-2.0.3` inline defaults | **removed** → `${WORKER_*_VERSION}` only |
| Registry | premium=opc-ua/rtsp on ENTERPRISE | premium=opc-ua/rtsp only | **4 premium** (opc-ua, rtsp, luminosity, minio-sink) → `ENTERPRISE_REGISTRY`; 15 community → `COMMUNITY_REGISTRY` |
| Service name | `worker-http-client`, `worker-conditional-validator` | `worker-http`, `worker-conditional-dataset-validator` | **swarm names** (`worker-http-client`, `worker-conditional-validator`) |
| FM_WORKER_ID | `worker-datacatalog-mapper001` | `worker-dcmapper-002` | **`worker-datacatalog-mapper001`** |
| Healthcheck | `test:[NONE]` (dumb ZMQ pipes) | (none) | **`[NONE]`** (swarm overlay) |
| Topology | deploy.resources+restart_policy, `${ENV}-platform` net, healthcheck NONE | restart:unless-stopped, external `flowmaker-net`, profiles:[premium] | split per-runtime overlay |

Shared `x-worker` anchor extracted (FM_RUNTIME_HTTP_ADDRESS, FM_ROUTER_TRANSPORT_ADDRESS `tcp://*:5560`, FM_WORKER_LOG_SOCKET_IO_ENDPOINT, FM_CDN_REGISTRY_URL, FM_DATACATALOG_URL); per-worker only FM_WORKER_ID + FM_WORKER_TRANSPORT_ADV_ADDRESS.

### core (uifusion shell+api, minio, cdn)

| Kind | Swarm source | Compose source | Canonical |
|------|--------------|----------------|-----------|
| uifusion-api name | `uifusion-api` (+ alias `industream-hub-backend`) | `industream-hub-backend` | **`uifusion-api`** (decision #3) + permanent alias |
| uifusion shell name | `uifusion` | `industream-hub-frontend` | **`uifusion`** |
| IH_* auth env | `:-default` fallbacks | hardcoded `hub-backend`/`industream-hub` | **`${HUB_AUTH_ISSUER}`/`${HUB_AUTH_AUDIENCE}`** from auth.env (values preserved exactly) |
| minio secret | external docker secret | **inline `MINIO_ROOT_USER=ROOTUSER`/`PASSWORD=CHANGEME123`** (LEAK) | **file-secret only** (`*_FILE` → `/run/secrets/<name>`); inline removed |
| minio exposure | Traefik on `s3.${FM_DOMAIN}` | host-port publish 9000/9001 | **Caddy reverse-proxy** (drop host ports) |
| cdn tags | `:-default` | hardcoded 2.0.0/2.0.2 | `${CDN_SERVER_VERSION}`/`${CDN_CACHE_VERSION}` |

### flowmaker (scheduler/confighub/logging frontend)

| Kind | Swarm source | Compose source | Canonical |
|------|--------------|----------------|-----------|
| FM_AUTH_* block | **OMITTED** (unauth traffic!) | present | **ON everywhere** (scheduler+confighub+logging, both runtimes) from auth.env |
| JWKS URL | `uifusion-api:3050` | `industream-hub-backend:3050` | **`http://uifusion-api:3050/auth/jwks`** (alias owned by core group) |
| confighub PUBLIC port | proxied **4000** (wrong) | proxied 4001 | **4001** public / 4000 internal backend |
| logger PUBLIC port | proxied **3000** (wrong) | proxied 3001 | **3001** public / 3000 internal |
| frontend upstream | Traefik port 80 | Caddy `{{upstreams 80}}` | **80** (already aligned) |
| scheduler port | 3121 public / 3120 internal | same | **3121** public (3120 never proxied) |
| FMUI hub origin | `https://${INDUSTREAM_DOMAIN}` | `https://hub.${FM_DOMAIN}` | neutral **`${INDUSTREAM_HUB_ORIGIN}`** in base |
| scheduler debug | (none) | `command:[node,--inspect=0.0.0.0:9229,...]` | **dropped** (security/parity; belongs in ee/dev overlay) |
| volumes | `${ENV}-flowmaker-*-data` named | host binds `${FM_DC_VOLUMEROOT:-./volumes}` | **named volumes** both runtimes |

### data (databridge-api, influxdb, timescaledb, postgres)

| Kind | Swarm source | Compose source | Canonical |
|------|--------------|----------------|-----------|
| Tags | `:-2.3.0-dev`, `influxdb:-2.9.1`, `timescaledb:-latest-pg17` | n/a (swarm-only group) | **bare `${VAR}`** from versions.env |
| DB password | `__DB_PASSWORD_PLACEHOLDER__` via dotnet-entrypoint | (new slice authored) | placeholder resolved by `DB_SECRET_PATTERN` (NOT `DB_SECRET_NAME`) |
| influx token | `__INFLUX_TOKEN_PLACEHOLDER__` | (new) | placeholder via influxdb-entrypoint |
| PG host | shared `postgres` | dedicated `databridge-postgresql-db` | parametrized `${DATABRIDGE_PG_DB_HOST}` per runtime |
| Compose slice | n/a | NONE existed | **authored new** (Caddy labels + file secrets + dedicated DB, datacatalog precedent) |

### monitoring (grafana+wrapper, prometheus, node-exporter, cadvisor, postgres-exporter, alertmanager)

| Kind | Swarm source | Compose source | Canonical |
|------|--------------|----------------|-----------|
| Tags | all `:-default` (v3.2.1/v1.9.0/v0.57.0/v0.16.0/v0.28.1/1.0.1) | n/a | **bare `${VAR}`** from versions.env |
| cadvisor image | inline `:-ghcr.io/google/cadvisor` | n/a | `${CADVISOR_IMAGE}` var (upstream moved ghcr v0.56+) |
| Grafana in compose | swarm-only | NONE | **IN SCOPE** (decision #4): new compose slice authored; JWT-auth env folded into base |
| grafana+wrapper JWT | in `docker-stack.grafana-wrapper.yml` only | n/a | **moved into base** (default for both runtimes) |
| Grafana DB | shared `postgres` | dedicated `grafana-postgresql` | parametrized `${GRAFANA_DB_HOST}` per runtime |
| selfsigned CA / WS-live router | swarm-only | n/a | kept in `runtime/swarm/monitoring.yml` |
| ntfy | present | n/a | **NOT carried** (out of monitoring group scope) |

---

## 2. Canonical decisions (cross-group, locked)

| Decision | Value | Notes |
|----------|-------|-------|
| confighub public port | **4001** | internal backend 4000; swarm source was wrong |
| logger public port | **3001** | internal 3000 (scheduler log socket uses :3000) |
| scheduler public port | **3121** | 3120 worker-backend internal, never proxied |
| Hub JWKS URL | **`http://uifusion-api:3050/auth/jwks`** | THE INVARIANT (auth.env); `industream-hub-backend` is a permanent alias on each net |
| Hub JWT iss/aud | **`hub-backend` / `industream-hub`** | unchanged; lint-enforced by validate-parity.sh |
| FM_AUTH_* | **ON everywhere** | scheduler + confighub + logging, both runtimes |
| Worker image scheme | **short** `flowmaker.boxes/<x>` | long `flow-box-<x>` names were wrong |
| Worker premium set | **4** (opc-ua-client, rtsp-client, luminosity-box, minio-sink) → ENTERPRISE | 15 community → COMMUNITY |
| Worker healthcheck | **`test:[NONE]`** | dumb ZMQ pipes, scheduler-tracked |
| uifusion canonical name | **`uifusion-api`** / **`uifusion`** | + alias `industream-hub-backend` (no hard rename) |
| Image tags | **versions.env only**, no `:-default` | fail-loud on missing var |
| Secrets | **file-secrets only** | no inline password anywhere (minio leak removed) |
| Volumes | **named** | host binds become per-instance overrides, not base |

---

## 3. Version vars added to versions.env (Phase 1)

| Var | Value | Source |
|-----|-------|--------|
| `UIFUSION_UI_VERSION` | 2.1.2 | align with API |
| `MINIO_VERSION` | RELEASE.2025-02-07T23-21-09Z | swarm source (pinned, never `latest`) |
| `CDN_SERVER_VERSION` | 2.0.0 | compose+swarm agree |
| `CDN_CACHE_VERSION` | 2.0.2 | compose+swarm agree |
| `INFLUXDB_VERSION` | 2.9.1 | data source default |
| `TIMESCALEDB_VERSION` | 2.17.2-pg17 | source was `latest-pg17` → PINNED |
| `GRAFANA_WRAPPER_VERSION` | 1.0.1 | was inline-default |
| `PROMETHEUS_VERSION` | v3.2.1 | was inline-default |
| `NODE_EXPORTER_VERSION` | v1.9.0 | was inline-default |
| `CADVISOR_IMAGE` | ghcr.io/google/cadvisor | upstream moved ghcr v0.56+ |
| `CADVISOR_VERSION` | v0.57.0 | was inline-default |
| `POSTGRES_EXPORTER_VERSION` | v0.16.0 | was inline-default |
| `ALERTMANAGER_VERSION` | v0.28.1 | was inline-default |

(Already present, unchanged: all 19 `WORKER_*_VERSION`, `UIFUSION_API_VERSION`,
`FLOWMAKER_CORE/FRONTEND/LOGGER_VERSION`, `DATABRIDGE_API_VERSION`,
`DATACATALOG_*`, `GRAFANA_VERSION`, `POSTGRES_VERSION`, `LOGTO_VERSION`.)

**Full compose assembly render: PASS** (`docker compose ... config` → EXIT 0, 68
services, all image tags resolve, no dangling/blank tags, no inline secrets).

---

## 4. Remaining gaps / TODOs (carry into Phase 2+)

### Runtime env contracts (NOT yet in runtime.compose.env / runtime.swarm.env — owner must add)

The full render passes because docker compose tolerates blank-string interpolation
for these topology vars, but each must be supplied at real deploy time:

- **core**: `MINIO_ROOT_USER_SECRET_NAME` / `MINIO_ROOT_PASSWORD_SECRET_NAME`
  (compose: `minio_root_user`/`minio_root_password`; swarm: `${ENV}_minio_root_*`).
  NOTE: compose top-level secret KEYS are LITERAL (docker compose does not
  interpolate secret keys) — must stay in lockstep with these env values.
- **data**: compose → `DATABRIDGE_PG_DB_HOST=databridge-postgresql-db`,
  `DATABRIDGE_PG_DB_SECRET_PATTERN=databridge_pg_password`,
  `TIMESCALEDB_DB_SECRET_NAME=timescaledb_password`,
  `TIMESCALEDB_DB_SECRET_PATTERN=timescaledb_password`; swarm →
  `DATABRIDGE_PG_DB_HOST=postgres`, `TIMESCALEDB_DB_SECRET_NAME=${ENV}_timescaledb_password`.
- **monitoring**: compose → `GRAFANA_DB_HOST=grafana-postgresql`,
  `POSTGRES_EXPORTER_DB_HOST=postgres`, `GRAFANA_ADMIN_USER=admin`,
  `GRAFANA_DB_NAME=industream`, `GRAFANA_DB_USER=dashboard`,
  `GF_DATABASE_SSL_MODE=disable`, `GF_APP_MODE=production`, `GF_LOG_LEVEL=info`,
  `TZ=Europe/Berlin`, `POSTGRES_ADMIN_USER=postgres`, plus secret-name vars
  (`GRAFANA_ADMIN_PASSWORD_SECRET_NAME=grafana_admin_password`,
  `GRAFANA_DB_PASSWORD_SECRET_NAME=grafana_db_password`,
  `POSTGRES_ADMIN_PASSWORD_SECRET_NAME=postgres_admin_password`); swarm → same
  with `${ENV}_`-prefixed secret names and `*_DB_HOST=postgres`.
- **flowmaker**: `FM_DOMAIN`/`FM_NETWORK`/`INDUSTREAM_HUB_ORIGIN`/`FM_PROTOCOL`
  supplied per-instance (`.env`); harness injects them.

### ⚠️ Grafana-compose Caddy-CA JWKS (decision #4 hard part — UNRESOLVED in YAML)

Caddy serves the grafana-hub-wrapper over an **internal cert**; Grafana 13
fetches the Hub JWKS over that TLS and **ignores `tls_skip_verify`**. Caddy's
local CA root (`/data/caddy/pki/authorities/local/root.crt`) MUST be exported
and bind-mounted into Grafana's `SSL_CERT_DIR` (var `CADDY_LOCAL_CA`). Until the
deployer provisions that bind, **JWKS validation fails closed**. A deploy-time
hook to extract the Caddy CA is required — **not solvable in YAML alone** (mirror
of the swarm `grafana-wrapper-selfsigned` CA-mount). Add as a Phase-3/4 task.

### Other open items

- **worker-manager EXCLUDED** from `workers` group: it is a Traefik-routed
  control-plane service (docker.sock mount + `WORKER_MANAGER_VERSION`, absent
  from versions.env), not a flow-box. Belongs in a future **infra/control-plane**
  group; if unified, add `WORKER_MANAGER_VERSION` to versions.env there.
- **JWKS alias dependency**: `uifusion-api` ↔ `industream-hub-backend` alias is
  owned by `base/core.yml` overlays. flowmaker + monitoring + datacatalog all
  depend on it resolving; core agent must guarantee the alias or FM/Grafana auth
  fails closed.
- **uifusion-config volume**: compose source had NO `/app/data` mount (only swarm
  had `./config/uifusion` bind). Unified uses a NAMED volume `uifusion-config`. If
  the compose deploy relied on a host-bind seeded config, the seeder/deploy path
  must populate the named volume instead.
- **`unified/config/` dir**: data + datacatalog overlays bind-mount
  `./config/{dotnet,influxdb}-entrypoint.sh`. A `unified/config/` dir (or symlink
  to `../config`) must exist at deploy time; both scripts already live at
  `industream-stack/config/`.
- **Latent datacatalog bug (NOT touched)**: `base/datacatalog.yml` sets
  `DB_SECRET_NAME`, but `dotnet-entrypoint.sh` reads `DB_SECRET_PATTERN` →
  falls back to default `db_password` pattern. The data group correctly uses
  `DB_SECRET_PATTERN`. Fix datacatalog in a follow-up.
- **ENTERPRISE_REGISTRY for grafana-wrapper**: base uses `ENTERPRISE_REGISTRY`
  (39t…). Swarm source defaulted to 842… for staging — confirm the unified 39t
  is correct for the wrapper pull or wire a staging override.
- **Swarm overlays not compose-config-validatable**: every `runtime/swarm/*.yml`
  uses swarm-only variable map KEYS (`${ENV}-platform` net, `${ENV}_*` secret
  keys) that `docker compose config` rejects but `docker stack deploy` accepts.
  Same limitation as the proven datacatalog increment-1 swarm file — validate
  swarm files via a swarm-side render (`deploy-swarm.sh` / `docker stack deploy
  --dry`) in CI, NOT compose-config. **The required COMPOSE render passes.**
