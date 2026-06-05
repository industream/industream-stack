# Industream Deployment Unification Plan

> Goal: collapse the two parallel hand-maintained deployment trees
> (`industream-stack` = Swarm/Traefik, `industream-flowmaker/deployment` = Compose/Caddy)
> into ONE shared Compose-Spec **base** + thin per-runtime overlays, with a single
> version source, runtime-agnostic seeders, driven by a THIN `industream-cli`.
> Files must stay plain YAML, runnable **without** the CLI. CE must have a no-CLI
> fallback (BSL requirement). Matrix to support: **CE/EE × swarm/compose = 4 deploys**.
>
> HARD INVARIANT: the JWT contract never changes — `iss=hub-backend`,
> `aud=industream-hub`, JWKS at `http://uifusion-api:3050/auth/jwks`. Every phase
> validates this contract end to end.

---

## 0. Principles

1. **Base is orchestrator-neutral Compose Spec.** `base/*.yml` carries ONLY image +
   functional env + depends_on intent + named-volume *intent*. No `deploy:`, no
   Traefik/Caddy labels, no secrets backend, no network names.
2. **Overlays are thin and orchestrator-specific.** `runtime.swarm.yml` adds
   `deploy:` / Traefik labels / docker-secret objects / overlay networks.
   `runtime.compose.yml` adds `mem_limit`/`cpus` / Caddy labels / file-secrets /
   `flowmaker-net`. Edition (`ee.yml`) is a third axis, orthogonal to runtime.
3. **Bash is the source of truth; the CLI is optional sugar.** Every deploy must be
   reproducible with a documented `docker compose -f ... up` / `docker stack deploy`
   incantation. The CLI only assembles the file list and exports env.
4. **One version source** (`versions.env`) consumed by both orchestrators. Inline
   `:-default` fallbacks are removed (or generated) so a tag lives in exactly ONE place.
5. **Reconcile-before-share.** Service names, image repo paths and version tags are
   drifted today (see §2 / Phase 1) and MUST be unified before any base.yml is authored,
   otherwise `validate-parity.sh` keeps passing on a false green.

---

## 1. Target file layout

```
industream-deploy/                      # single canonical tree (new repo or stack root)
├── versions.env                        # SINGLE source of truth for every image tag
├── registries.env                      # COMMUNITY_REGISTRY / ENTERPRISE_REGISTRY (+ legacy alias)
├── auth.env                            # HUB_AUTH_ISSUER=hub-backend / AUDIENCE / JWKS_URL (shared)
│
├── base/                               # orchestrator-neutral Compose-Spec (image + env only)
│   ├── core.yml                        # postgres, uifusion(ui), uifusion-api, minio, cdn-server/cache
│   ├── flowmaker.yml                   # scheduler, confighub, logging, frontend
│   ├── datacatalog.yml                 # datacatalog-api, datacatalog-ui, datacatalog-postgresql
│   ├── workers.yml                     # 17 BSL workers (anchored: x-worker)
│   ├── workers-premium.yml             # opc-ua, rtsp, luminosity, minio-sink (entitlement-gated)
│   ├── data.yml                        # influxdb, databridge x3, timescaledb   (swarm-origin, ported)
│   ├── monitoring.yml                  # grafana, prometheus, exporters, alertmanager, ntfy
│   └── ee.yml                          # Logto + logto-postgres + Hub-backend OAUTH override
│
├── runtime.swarm.yml                   # deploy:/Traefik labels/secret objects/${ENV}-* nets+vols
├── runtime.compose.yml                 # mem_limit/cpus/Caddy labels/file-secrets/flowmaker-net
│
├── proxy/
│   ├── traefik/                        # docker-stack.traefik.yml + traefik-dynamic/*.template
│   └── caddy/                          # docker-compose.infra.yml (caddy-docker-proxy)
│
├── overlays.swarm/                     # swarm-only extras kept as-is
│   ├── backup.yml  demo.yml  ironstream.yml  grafana-wrapper.yml  grafana-wrapper-selfsigned.yml
│
├── seeders/                            # runtime-agnostic (--runtime swarm|compose --stack|--project)
│   ├── seed-confighub.sh   seed-menu-apps.sh   seed-logto.sh(M2M)   seed-logto-labels.sh
│
├── scripts/
│   ├── deploy.sh                       # ONE assembler: builds -f list from {edition,runtime,flags}
│   ├── validate-parity.sh              # extended: keys + names + image-path + values + JWT contract
│   └── render-versions.sh              # versions.env -> (optional) inline-default sync / lint
│
└── .env.{prod,dev,staging}.example     # per-env: domain, TLS, secrets names; sources versions.env
```

Assembly rule (single function, both in `deploy.sh` and the CLI):

```
FILES = base/core base/flowmaker base/datacatalog base/workers base/data base/monitoring
        [+ base/workers-premium  unless --community]
        [+ base/ee.yml           if EDITION=ee]
        + runtime.<swarm|compose>.yml          # LAST among shared (overlay wins)
        [+ overlays.swarm/*      per swarm flags]
ENV   = registries.env + versions.env + auth.env + .env.<env>
```

---

## 2. Per-service 90/10 table (shared vs orchestrator-specific)

Derived from the diff finding. "Shared %" = image + functional env block + depends_on.
"Runtime %" = deploy/labels/secrets/networks/volumes/healthcheck-shape.

| Service | Shared (base.yml) | Orchestrator-specific (overlay) | Split | Reconcile first |
|---|---|---|---|---|
| uifusion-api (Hub backend) | image, full `IH_*` env, JWKS port 3050/3051, issuer/audience | Traefik vs Caddy labels; secret injection (`.env` vs file); net alias `industream-hub-backend`; `deploy.resources` vs `mem_limit` | ~55/45 | **NAME: `uifusion-api` vs `industream-hub-backend`** |
| uifusion (Hub shell) | image, NODE env, CONFIG_URL shape | router labels; EE OAUTH flip is swarm-only today | ~50/50 | NAME `uifusion` vs `industream-hub-frontend`; EE shell flip asymmetric |
| datacatalog-api | image, `Authentication__Frontend__Issuer/Audience/JwksUrl`, ports 8002/8003 | secret-name vs inline pw; labels; nets | ~40/60 | **compose has NO Hub-JWT block + inline pw `industream4370`** |
| datacatalog-ui | image, `NODE_ENV`, `DATACATALOG_API_URL` shape | host value; labels; nets | ~60/40 | host value only |
| flowmaker-scheduler/confighub/logging | image, `FM_RUNTIME_*`/`FM_CONFIGHUB_URL`/ports 3120/3121/4000/3000 | labels; nets; healthcheck shape | ~70/30 | **swarm omits `FM_AUTH_*`; compose sets it** (auth-on vs auth-off) |
| flowmaker-frontend | image, NODE env | labels; nets | ~70/30 | upstream port: swarm named svc vs caddy `{{upstreams 80}}` |
| workers (×17, x-worker anchor) | image, `FM_WORKER_ID/RUNTIME/ROUTER/LOG/CDN/DATACATALOG_URL`, tcp://*:5560 | healthcheck (`NONE` swarm vs omitted); nets; deploy/restart | **~90/10** | **image path `flow-box-X` vs `X`; tag drift (js 2.1.0/2.1.3 …)** |
| workers-premium | same anchor + ENTERPRISE_REGISTRY | profile `premium` (compose) vs `--exclude`/entitlement (swarm) | ~85/15 | premium gating mechanism differs |
| minio | image, command, `MINIO_ROOT_*` | secret `_FILE` (swarm) vs file/host-ports (compose); nets | ~50/50 | — |
| influxdb / timescaledb / databridge×3 | image, env | swarm-only today | n/a | **missing in compose — port them** |
| grafana / grafana-wrapper | image, GF_* incl `GF_AUTH_JWT_EXPECT_CLAIMS={iss:hub-backend,aud:industream-hub}` | extra_hosts host-gateway; Traefik | n/a | **swarm-only — compose has no grafana** |
| Logto + logto-postgres (EE) | image `ghcr.io/logto-io/logto`, `TRUST_PROXY_HEADER`, `ENDPOINT/ADMIN_ENDPOINT` shape, pg sidecar | secret path + entrypoint `db alteration deploy latest` (swarm only); labels | ~70/30 | LOGTO_VERSION pinned (not `latest`); entrypoint step parity |

Aggregate: **workers ~90/10** (best base candidate); **backends ~40–70/30–60**;
**stateful/proxy services lowest**. Confirms: share image+env, overlay everything else.

---

## 3. Skeleton — `base/core.yml` (uifusion-api, representative)

`base/core.yml` (NEUTRAL — no deploy, no labels, no secrets backend, no net names):

```yaml
# base/core.yml — orchestrator-neutral. Runnable as-is under plain `docker compose`
# for the CE no-CLI fallback when merged with runtime.compose.yml.
x-restart-intent: &restart-intent
  # neutral hint; mapped to deploy.restart_policy (swarm) / restart (compose) by overlay
  # left empty in base; overlays own the real policy.

services:
  uifusion-api:                        # CANONICAL NAME (reconciled in Phase 1)
    image: ${COMMUNITY_REGISTRY:-ghcr.io/industream}/uifusion/api:${UIFUSION_API_VERSION}
    environment:
      - CONFIG_PATH=/app/data/config.json
      - IH_PUBLIC_PORT=3050
      - IH_INTERNAL_PORT=3051
      - IH_AUTH_METHOD=${IH_AUTH_METHOD:-BASIC}      # EE overlay flips to OAUTH
      - IH_USERNAME=${HUB_BACKEND_ADMIN_USER:-admin} # value source differs per runtime
      - IH_PASSWORD=${HUB_BACKEND_ADMIN_PASSWORD:-admin}
      - IH_EMAIL=admin@${INDUSTREAM_DOMAIN:-localhost}
      - IH_FIRSTNAME=Admin
      - IH_LASTNAME=User
      - IH_ROLE=admin
      - IH_ACCOUNT_NAME=industream
      # --- JWT CONTRACT (NEVER CHANGES) ---
      - IH_ISSUER=${HUB_AUTH_ISSUER:-hub-backend}
      - IH_AUDIENCE=${HUB_AUTH_AUDIENCE:-industream-hub}
      - IH_ACCESS_TOKEN_TTL_SECONDS=900
      - IH_REFRESH_TOKEN_TTL_SECONDS=2592000
      - IH_BACKEND_ORIGIN=${INDUSTREAM_HUB_ORIGIN:-http://localhost}
      - HUB_DATA_PATH=/app/data/hub
    volumes:
      - uifusion-config:/app/data        # volume NAME resolved by overlay
    healthcheck:
      test: ["CMD","wget","--no-verbose","--tries=1","--spider","http://localhost:3050/auth/jwks"]
      interval: 30s
      timeout: 3s
      retries: 3
      start_period: 15s
```

`runtime.swarm.yml` (adds ONLY swarm specifics):

```yaml
services:
  uifusion-api:
    networks:
      traefik-public: {}
      ${ENV}-platform:
        aliases: [ industream-hub-backend ]   # JWKS resolution alias
    deploy:
      labels:
        - traefik.enable=true
        - traefik.http.routers.${ENV}-uifusion-api-secure.entrypoints=websecure
        - traefik.http.routers.${ENV}-uifusion-api-secure.rule=Host(`${INDUSTREAM_DOMAIN}`) && PathPrefix(`/api/uifusion`)
        - traefik.http.routers.${ENV}-uifusion-api-secure.tls=true
        - traefik.http.routers.${ENV}-uifusion-api-secure.service=${ENV}-uifusion-api
        - traefik.http.routers.${ENV}-uifusion-api-secure.middlewares=${ENV}-uifusion-api-stripprefix,security-headers@file
        - traefik.http.middlewares.${ENV}-uifusion-api-stripprefix.stripprefix.prefixes=/api/uifusion
        - traefik.http.services.${ENV}-uifusion-api.loadbalancer.server.port=3050
      resources:
        limits:   { cpus: '0.25', memory: 64M }
        reservations: { cpus: '0.03', memory: 32M }
      restart_policy: { condition: any, delay: 5s, max_attempts: 0, window: 120s }
volumes:
  uifusion-config: { name: ${ENV}-uifusion-config }
networks:
  traefik-public: { external: true, name: traefik-shared_traefik-public }
  ${ENV}-platform: { driver: overlay, attachable: true }
# NOTE: uifusion-api does NOT read *_FILE — deploy.sh exports HUB_BACKEND_ADMIN_* from
# secrets/${ENV}/hub_backend_admin_{user,password} before stack deploy.
```

`runtime.compose.yml` (adds ONLY compose specifics):

```yaml
services:
  uifusion-api:
    networks: [ flowmaker-net ]
    mem_limit: 64m
    mem_reservation: 32m
    restart: unless-stopped
    labels:
      caddy: hub-api.${FM_DOMAIN}
      caddy.reverse_proxy: "{{upstreams 3050}}"
      caddy.tls.issuer: internal
      caddy.tls.issuer.lifetime: 24000h
volumes:
  uifusion-config:
    driver: local        # bind/named under instance dir
networks:
  flowmaker-net: { name: ${FM_NETWORK}, external: true }
```

EE delta lives in `base/ee.yml` and is identical in spirit for both runtimes
(image swap to `uifusion/api-enterprise`, `IH_AUTH_METHOD=OAUTH`, `OIDC_*` block).

---

## 4. Phases

> Each phase ships to two throwaway test VMs: **vm-swarm** (3-node swarm + Traefik
> shared stack) and **vm-compose** (single host + Caddy). "Parallelizable" tasks are
> tagged `[A1]…[An]` → one subagent each.

### Phase 1 — Reconcile drift (NO base yet)

**Scope:** unify the things that block sharing. Pure edits to existing files; no layout change.

- `[A1]` Unify worker image paths: pick ONE scheme (recommend `flowmaker.boxes/<name>`,
  the swarm scheme) after confirming tags exist in the registry; rewrite the 17 compose
  `flow-box-<name>` refs.
- `[A2]` Unify worker/version tags into a draft `versions.env`; resolve every divergence
  (js 2.1.0↔2.1.3, mqtt 2.2.0↔2.2.3, modbus 2.1.0↔2.1.3, postgres-client 2.0.3↔2.0.6,
  timeseries 2.0.9↔2.1.1, opc-ua 2.0.3↔2.5.5, dc-mapper 1.0.1↔1.0.4, DC api/ui, UIFusion).
  Tags chosen = "latest known-good" verified against registry.
- `[A3]` Close compose datacatalog-api auth gap: add the `Authentication__Frontend__*`
  Hub-JWT block; remove inline `Password=industream4370` → secret/file.
- `[A4]` Decide FlowMaker core auth: enable `FM_AUTH_*` on the **swarm** side too
  (compose already has it) so the core is auth-on everywhere. Keep JWKS URL identical.
- `[A5]` Rename decision applied as **network aliases only** for now (no hard rename yet):
  ensure both trees expose alias `industream-hub-backend` so JWKS resolves identically.

**Validation gate (vm-swarm + vm-compose):** existing deploy paths still come up green;
`curl -s $JWKS | jq .keys` returns the same kid set on both; menu loads; one flow runs.
**Rollback:** revert per-file; no structural change, so `git revert` of the PR set.

### Phase 2 — Single version source + extract base for ONE service group (workers)

**Scope:** prove the base/overlay split on the highest-share group (workers, ~90/10).

- `[A1]` Create `versions.env` + `registries.env` + `auth.env`; make `deploy-swarm.sh`
  and `fm` source them; delete inline `:-default` tags for workers (sourced now).
  `render-versions.sh` lints "no tag outside versions.env".
- `[A2]` Write `base/workers.yml` with `x-worker` anchor (only image/WORKER_ID/ADV vary).
- `[A3]` Write the worker slice of `runtime.swarm.yml` (deploy/healthcheck NONE/nets) and
  `runtime.compose.yml` (restart/labels/nets).
- `[A4]` Teach `deploy.sh` to assemble `base/workers.yml + runtime.<r>.yml`; wire both
  orchestrators to it behind a feature flag (`USE_UNIFIED_WORKERS=1`).

**Validation gate:** on each VM, deploy with `USE_UNIFIED_WORKERS=1`; assert identical
`docker service ls`/`docker compose ps` worker set, same image digests pulled, workers
register in confighub, a data-logger→postgres flow completes. Diff `docker compose config`
output before/after for non-worker services = empty (no collateral change).
**Rollback:** unset `USE_UNIFIED_WORKERS` → old hardcoded lists; files are additive.

### Phase 3 — Extract base for backends + stateful + proxy split

**Scope:** core, flowmaker, datacatalog, data, monitoring into `base/`; proxy isolated.

- `[A1]` `base/core.yml` (uifusion, uifusion-api, minio, cdn) + swarm/compose overlay slices.
- `[A2]` `base/flowmaker.yml` + overlays (fix confighub upstream port drift 4000 vs 4001,
  logger 3000 vs 3001 — pick canonical, update Caddy/Traefik accordingly).
- `[A3]` `base/datacatalog.yml` + overlays (carries the Phase-1 reconciled auth block).
- `[A4]` Port swarm-only `data.yml` (influx/databridge×3/timescale) into `base/data.yml`;
  add compose overlay slice so EE/CE-compose can optionally run them.
- `[A5]` Move proxy out: `proxy/traefik/*` and `proxy/caddy/*`; nothing in base references
  a proxy. Document the **standardize-the-proxy** decision (see §5) — until decided, keep both.
- `[A6]` Grafana: keep swarm-only for now (compose grafana is a separate decision); ensure
  `GF_AUTH_JWT_EXPECT_CLAIMS` stays `{iss:hub-backend,aud:industream-hub}`.

**Validation gate:** full CE deploy on both VMs from unified files; JWT contract probe
(login → token → `aud`/`iss` asserted → DataCatalog API 200 → menu non-empty → Grafana SSO
on swarm). `validate-parity.sh` (now extended to compare values + names + image paths)
passes with zero skips.
**Rollback:** old `docker-stack.*`/`docker-compose.*` kept in repo one cycle; deploy scripts
switch via `USE_UNIFIED_BASE=1`; flip back to revert.

### Phase 4 — EE overlay + runtime-agnostic seeders + CLI thin driver

**Scope:** make EE reachable and seeded identically on both runtimes; wire the CLI.

- `[A1]` `base/ee.yml`: Hub-backend OAUTH override + Logto + logto-postgres; pin
  `LOGTO_VERSION` (NOT `latest`); reconcile entrypoint (`db alteration deploy latest`)
  across runtimes; fix `ENTERPRISE_REGISTRY` legacy-default drift (842 → 39t) in
  grafana-wrapper + EE; unify `UIFUSION_API_EE_VERSION` vs `_ENTERPRISE_VERSION` → one name.
- `[A2]` Move all 4 seeders to `seeders/`, ensure `--runtime swarm|compose --stack|--project`
  works for each. Replace `fm init`'s hand-rolled 2-app upsert with `seed-menu-apps.sh`.
  Add Logto label seeder + M2M roles/resources seeder to BOTH post-deploy hooks.
- `[A3]` `deploy.sh`: add `--edition ce|ee`; for ee append `base/ee.yml` and run Logto+menu
  seeders (best-effort, logged, non-fatal as today but with explicit exit-code summary).
- `[A4]` CLI thin driver: add `DeployOptions.edition`; SwarmRuntime appends `--with-ee-overlay`
  when entitlements say enterprise (close the "EE never passed on swarm" gap); ComposeRuntime
  derives EE from **entitlements**, not `plan==='enterprise'`; add `runtime.seed(env)` to the
  contract wrapping the seeders for both. Remove hardcoded `DEV_MONOREPO_SCRIPTS` from shipped build.

**Validation gate:** EE deploy on both VMs from a signed test license → Logto OIDC app +
roles + resources present, menu has 5 apps, auth-bridge origin allowlist includes the
grafana/dashboard subdomain, SSO login succeeds, JWT still `iss=hub-backend/aud=industream-hub`.
CE deploy still green (EE files absent).
**Rollback:** `--edition ce` and not-appending `ee.yml` reproduces Phase-3 CE exactly;
CLI edition flag defaults off.

### Phase 5 — CE no-CLI fallback, decommission old trees, cutover

**Scope:** BSL guarantee + remove duplication.

- `[A1]` Ship `docker-compose.community.yml` recipe + a documented one-liner:
  `docker compose --env-file registries.env --env-file versions.env --env-file auth.env
  -f base/core.yml -f base/flowmaker.yml -f base/datacatalog.yml -f base/workers.yml
  -f runtime.compose.yml -f proxy/caddy/docker-compose.infra.yml up -d`
  pointing at anonymous `ghcr.io/industream`, **zero keygen calls**. Add to README +
  smoke-test in CI.
- `[A2]` Delete `docker-stack.*` / `docker-compose.*` legacy files (kept since Phase 2/3).
  Remove `USE_UNIFIED_*` feature flags (unified is now the only path).
- `[A3]` Extend `validate-parity.sh` into a CI gate: image-path scheme, value-level env on
  shared keys, JWT contract literals (`hub-backend`/`industream-hub`/`:3050/auth/jwks`),
  no `latest` on EE-critical images, no inline secrets.
- `[A4]` Resolve the open proxy decision (§5) and, if "standardize", migrate the loser tree.

**Validation gate:** the 4-deploy matrix (CE-swarm, EE-swarm, CE-compose, EE-compose) all
green on the VMs from the SAME base files; the CE no-CLI one-liner brings up a working
non-commercial stack with no license/keygen network call (verify with egress block).
**Rollback:** legacy files restorable from the tag cut at start of Phase 5; cutover is the
last reversible point — gate the CI flip on two consecutive green matrix runs.

---

## 5. Open decisions (must be resolved, blocking marked)

> **DECISIONS LOG — resolved 2026-06-05:**
> 1. **Proxy → KEEP BOTH** (Traefik swarm / Caddy compose; base proxy-agnostic).
> 2. **CE no-CLI fallback → VENDOR the seeders** into the public compose recipe (no CLI, no EE image needed). [reco]
> 3. **Rename → KEEP `uifusion*` canonical + permanent alias `industream-hub-backend`** (no hard rename). [reco]
> 4. **Grafana in compose → YES, IN SCOPE (overrides the "out of scope" reco).** Port Grafana + wrapper to compose. Extra work: Caddy serves the wrapper over an **internal cert**, and Grafana's JWT auth fetches the Hub JWKS over that self-signed TLS → need the **Caddy internal CA trusted by Grafana** (mirror of the swarm `grafana-wrapper-selfsigned` CA-mount trick, because Grafana 13 ignores `tls_skip_verify` for JWKS). → add a `[A]` task in Phase 3/4 + a new open sub-decision: Caddy internal-CA distribution to the grafana container.
> 5. **EE signal → ENTITLEMENTS as the single source** (`INDUSTREAM_EDITION` ↔ `--edition`/`--with-ee-overlay`, both runtimes). [reco]
> 6. **CONSOLIDATE into ONE deploy repo = `industream-stack`** (later rename → `industream-deploy`). `industream-flowmaker/deployment/` (the `fm` script + compose files + instances) **migrates in**; `fm`'s LOGIC is **absorbed into the single `scripts/deploy.sh` assembler + the CLI thin driver** (not kept as a parallel script). Keep `fm`'s useful *concepts*: per-instance `.env`/projects (`fm-ce`/`fm-ee`), the `create` flow, the shared auto-networked Caddy. `industream-flowmaker` keeps ONLY the FlowMaker app source. **⚠️ BLOCKING / cross-team: `deployment/` is David's repo (active, just pushed #228) → moving it out requires his buy-in. This is the FIRST thing to align with David before implementation.**
>
>    **🔧 REFINEMENT (2026-06-05, Phase 1 integration): do NOT move `industream-flowmaker/deployment/` out of David's repo. LEAVE it intact there and COPY the compose tree INTO this unified project instead.** The Phase-1 extraction already produced `unified/runtime/compose/*` + `unified/base/*` as orchestrator-neutral copies — David's `deployment/` is untouched, so there is **no cross-team disruption and no buy-in gate**: David keeps running his `fm`/compose deployment unchanged throughout the transition, while `industream-stack` builds the unified assembler against the copied tree. The two trees co-exist until the unified path is proven; only then (a later, non-blocking step) does David's `deployment/` get retired by agreement — it is **no longer a BLOCKING prerequisite** for implementation. Net effect: Phase 1 unblocks immediately; the "align with David first" gate is downgraded from *blocking* to *eventual courtesy retirement*.



1. ✅ **DECIDED (2026-06-05): keep both** — Traefik for swarm, Caddy for compose; `base.yml` never references a proxy (lives 100% in `runtime.*` overlays). Rationale: each proxy is best in its native context (Traefik = native Swarm provider + multi-node + `@file` middleware chain the stack relies on; Caddy = single-host auto-HTTPS simplicity). Standardizing deferred to a separate epic; if ever done, Traefik (it also drives plain compose; Caddy-on-swarm is the weak combo).

   ~~**Standardize the proxy? (BLOCKS Phase 5/A4, not earlier).**~~
   Options: (a) keep both (Traefik for swarm, Caddy for compose) — least work, proxy stays
   100% in overlays, base never mentions it; (b) standardize on Traefik everywhere — must
   embed/manage a per-instance Traefik + file-provider middlewares for compose, re-express
   nothing on swarm; (c) standardize on Caddy everywhere — re-express every Traefik
   router/middleware/security-header as Caddy labels on swarm and replace `@file` chain.
   Must FIRST reconcile upstream port drift (confighub 4000/4001, logger 3000/3001).
   **Recommendation: (a) for the 4-deploy unification; defer (b/c) to a separate epic.**
2. **BSL / CE no-CLI fallback shape (BLOCKS Phase 5/A1).**
   The CLI is effectively proprietary (keygen-gated). CE BSL grant requires a usable
   no-CLI path. Decision: ship the documented `docker compose ... up` recipe + community
   marker, anonymous GHCR pulls, no keygen. Confirm: does the community Hub image carry the
   in-image seeders (`/app/menu-seeds`, `/app/oidc-seeds`) so CE menu seeding works without
   the CLI, or do we vendor `seeders/` into the public recipe? **Recommend vendoring.**
3. **Service rename: `uifusion`/`uifusion-api` → `industream-hub-frontend/-backend`?**
   Breaking (Traefik router names + JWKS alias + every consumer URL keyed on it). Phase 1
   uses aliases only. Decide whether to do the hard rename atomically in a dedicated PR or
   keep `uifusion*` canonical + alias forever. **Recommend: keep `uifusion*` canonical,
   alias `industream-hub-backend` permanently** (less blast radius).
4. **Does compose grow Grafana?** Today swarm-only. If yes, needs a Caddy-internal-cert
   JWKS bridge (the host-gateway/`tls_skip_verify` swarm workaround is Traefik-specific).
   **Recommend: out of scope for unification; track separately.**
5. **EE detection canonicalization:** make `entitlements` the ONLY EE signal in both the
   CLI and `deploy.sh` (today: swarm flag-only, compose `plan===` string). Wire
   `INDUSTREAM_EDITION` ↔ `--edition`/`--with-ee-overlay` so the two edition signals can't
   diverge (current swarm gap).

---

## 6. Single-version-source design

**`versions.env`** is the ONLY place a tag is written. Format:

```sh
# versions.env — SINGLE SOURCE OF TRUTH. No tag may appear anywhere else.
UIFUSION_VERSION=2.1.2
UIFUSION_UI_VERSION=2.1.2
UIFUSION_API_VERSION=2.1.2
UIFUSION_API_EE_VERSION=2.1.2          # one canonical name (kills _ENTERPRISE_ alias)
DATACATALOG_API_VERSION=1.9.1
DATACATALOG_UI_VERSION=1.9.2
DATABRIDGE_API_VERSION=2.3.0
FLOWMAKER_CORE_VERSION=2.1.0
FLOWMAKER_FRONTEND_VERSION=2.1.0
FLOWMAKER_LOGGER_VERSION=2.1.0
WORKER_JS_EXPRESSION_VERSION=2.1.3
WORKER_MQTT_CLIENT_VERSION=2.2.3
WORKER_MODBUS_TCP_VERSION=2.1.3
WORKER_POSTGRES_CLIENT_VERSION=2.0.6
WORKER_TIMESERIES_VERSION=2.1.1
WORKER_INFLUX_CLIENT_VERSION=2.0.8
WORKER_OPC_UA_VERSION=2.5.5
WORKER_DATACATALOG_MAPPER_VERSION=1.0.4
GRAFANA_VERSION=13.0.1
INFLUXDB_VERSION=2.9.1
LOGTO_VERSION=1.21.0                    # PINNED — never 'latest'
# ... one line per image
```

Rules enforced by `render-versions.sh` (CI lint):
1. **No inline `:-<tag>` defaults** in base YAML. `image:` uses bare `${VAR}` so a missing
   var fails the deploy loudly instead of silently shipping a stale/`-dev` tag.
2. Both `deploy.sh` and the CLI `--env-file versions.env` it FIRST, then per-env `.env`
   may override for hotfixes (documented, lint-warned).
3. `registries.env` (COMMUNITY/ENTERPRISE/legacy alias) and `auth.env`
   (`HUB_AUTH_ISSUER=hub-backend`, `HUB_AUTH_AUDIENCE=industream-hub`,
   `HUB_JWKS_URL=http://uifusion-api:3050/auth/jwks`) are likewise single-sourced and
   referenced — never re-declared per file. This kills the 4-layer resolution ambiguity.
4. Release bot bumps ONLY `versions.env`; CI parity gate fails if any tag literal appears
   elsewhere or if EE-critical images use `latest`.

---

## 7. Risk register (top)

- **False-green parity:** extend `validate-parity.sh` before trusting it (Phase 1/5).
- **Naive single base.yml consumed by both engines drops fields:** compose ignores
  `deploy.placement/secrets-objects`; stack ignores `mem_limit/cpus/ports/profiles`.
  Mitigation: the 60–70% orchestrator-specific surface lives ONLY in `runtime.*.yml`,
  never in base — base is the 30–40% intersection.
- **Inline-secret leakage to swarm:** never flatten `industream4370` into base; secrets
  stay overlay-only (Phase 1/A3 + Phase 5 CI gate).
- **EE silent degrade:** seeders best-effort; Phase 4 adds an explicit exit-code summary
  so a missing in-image seeder is loud, not a buried warning.
- **Cutover irreversibility:** keep legacy files one full cycle; gate CI flip on two green
  4-deploy matrix runs.
