# TODO — merge David's `deployment-v2` into the unified tree

Goal: pull every `deployment-v2` feature into `unified/` (one base + per-runtime
overlays, both runtimes), losing NONE of David's work, adding swarm + the fixes.
Each task ships behind a gate; legacy trees stay until the end (reversible).

## T0 — Lock decisions with David (prereq, blocking)
Sync to confirm (recommended resolutions in parens):
- Image model: bundles **generated** from a license-aware source (keep `${X_IMAGE}` UX, registry = community→ghcr / enterprise→39t).
- Canonical naming: **`industream-hub-backend` / `-frontend`** (adopt David's; we reverse our keep-`uifusion*` decision).
- Instances: keep **core/workers** UX **on top of** shared `base/*.yml`.
- Driver: **one** (industream-cli thin driver) with an `fm`-compatible surface.
- EE var: one name (`UIFUSION_API_EE_VERSION`).
→ Until T0, T1/T2 can start on the recommended resolutions but stay drafts.

## T1 — Naming rename  `uifusion*` → `industream-hub-*`  [agent-able, wide/mechanical]
- Rewrite service names + refs in `base/core.yml`, `base/ee.yml`, all `runtime/{swarm,compose}/*.yml`, `auth.env` (JWKS host), `scripts/deploy.sh`, the seeders, `base/datacatalog.yml` JwksUrl.
- Keep `industream-hub-backend` as the network alias on swarm (JWKS resolution).
- **Gate:** 4-combo `--render` still green; JWKS host resolves; JWT contract literals unchanged.
- Deps: T0(naming).

## T2 — Image-ref / bundle reconciliation  [agent-able]
- Add `scripts/render-bundles.sh`: from `versions.env` + `registries.env`, emit
  `releases/bundle-platform-X.Y.Z/.env.{core,workers,datacatalog}` with **full-ref**
  `${X_IMAGE}` vars, **license-aware** (community→ghcr, enterprise→39t).
- Switch `base/*.yml` images to `${X_IMAGE}` vars; `deploy.sh` sources the bundle.
- **Gate:** render green; each service resolves to the correct registry per license.
- Deps: T0(bundle).

## T3 — core/workers instance model  [agent-able]
- `deploy.sh --type core|workers`: core = platform + datacatalog (no workers);
  workers = `base/workers.yml` as a separate project attaching to a core's network.
- Port David's attach/detach (`FM_ATTACHED_CORE`) + `.env.bundle/` per instance.
- **Gate:** deploy a core, attach a workers instance (compose); workers register in confighub.
- Deps: T1, T2.

## T4 — Driver convergence  `fm` ⇄ `deploy.sh`/CLI  [careful, not parallel]
- Fold David's v2 `fm` (create/up/down/init, `list` TYPE/ATTACHED, bundle load,
  instance types) into the unified driver. CLI calls the same assembly; ship an
  `fm`-compatible wrapper so David's muscle-memory still works.
- **Gate:** `fm`-style commands drive all 4 combos via the unified driver.
- Deps: T3.

## T5 — Port master compose extras + apply fixes  [DONE 2026-06-07]
- ✅ Our-side invariants: 0 inline secrets (placeholder + DB_SECRET_NAME), all
  issuers interpolate `${...}`, render green.
- ✅ Ported from `industream-flowmaker@master` (NOT blocked — v2 is on master):
  `Authentication__Backend__ApiKey=${BACKEND_API_KEY:-}` (datacatalog, credential
  exported from the secret store by the deploy path — NEVER inline),
  `Cors__AllowedOrigins=${DATACATALOG_CORS_ORIGINS:-…}` (datacatalog),
  `FM_CORS_ORIGIN=${FLOWMAKER_CORS_ORIGIN:-…}` (flowmaker scheduler/confighub/logging),
  `IH_OIDC_INTROSPECTION_URL` (ee hub-backend, defaults to logto introspection).
- **Gate:** ✅ 4-combo render green; 0 inline secrets; issuer interpolates.
- Deps: T1 (done). NOT dependent on a missing branch — master read directly.

## T6 — Fix the 3 deployment-v2 bugs  [quick — PR onto David's branch]
- `<old-db-password>` inline → file secret (datacatalog-api + datacatalog-postgresql).
- `{FM_AUTH_ISSUER:-hub-backend}` → `${FM_AUTH_ISSUER:-hub-backend}` (missing `$`).
- Remove `deployment/wget-log`.
- Independent of the merge; do it on `feat/deployment-v2` so David benefits now.

## T7 — Validation  [gate]
- Re-render the 4 combos after T1-T5.
- **Live VM gate** (see `VM-GATE-RUNBOOK.md`): CE/EE × swarm/compose on .233 + .41;
  JWKS / DataCatalog 401→200 / EE login / JWT contract probe.
- Deps: T1-T5.

## T8 — Decommission  [last, reversible until here]
- Retire legacy swarm `docker-stack.*` and David's old `fm`; remove `USE_UNIFIED_*`
  flags; promote `validate-parity.sh` to a CI gate.
- Deps: T7 green twice.

## Parallelization (for an agent fleet, after T0)
```
T0 ─┬─ T1 ─┬─ T3 ── T4 ─┐
    ├─ T2 ─┘            ├─ T7 ── T8
    ├─ T5 ──────────────┘
    └─ T6 (independent, onto David's branch)
```
T1/T2/T5/T6 run in parallel; T3 needs T1+T2; T4 needs T3; T7 gates everything.

## Surfaced from the .205 EE/swarm greenfield run (2026-07-09)

A full **from-scratch** validation on `cdm@192.168.122.205` (wipe all stacks +
19 volumes + 21 secrets → recreate secrets from the on-disk source → deploy EE
swarm `core flowmaker datacatalog data ironstream data-simulator auth` → seed →
e2e) proved T7 EE/swarm end-to-end (Hub login, FlowMaker scheduler, filebrowser
SSO all green). It also surfaced 5 items NOT yet in the plan above:

### C1 — Fold the new `auth` group (oauth2-proxy SSO) into the converged tree
- New group added on `feature/ironstream-integration`: `base/auth.yml` +
  `runtime/{swarm,compose}/auth.yml` — an oauth2-proxy SSO edge fronting apps
  without native OIDC (filebrowser today; Prometheus/Alertmanager next) via
  Traefik forwardAuth → Logto. EE-only; gated in `deploy.sh` `EE_ONLY_GROUPS`.
- Swarm path is validated live; the compose/Caddy `forward_auth` overlay is
  UNVERIFIED (marked in-file).
- **TODO:** land it in the converged tree; verify the compose/Caddy path; decide
  whether the shared edge stays forwardAuth (one proxy, N hosts) or per-host.
- Gotchas baked into the files: forwardAuth address = oauth2-proxy ROOT `/` (not
  `/oauth2/auth`) so unauth browsers get a 302 (Traefik v3 `errors` can't restatus
  a 401); no healthcheck (distroless image, no shell); `SSL_INSECURE_SKIP_VERIFY`
  opt-in for the internal self-signed Traefik cert.

### C2 — Logto bootstrap is NOT hands-off (blocks a repeatable `industream init` EE)
- `seed-logto.sh` needs `secrets/<env>/logto_m2m_credentials` (appId/appSecret of
  a Management-API M2M app) that today is minted **interactively** via the Logto
  first-run wizard + admin console. A fresh Logto has none.
- Neither the Hub self-provisioning nor the seeders create a **login user** or
  **assign a role** — the platform boots with zero usable identities.
- On .205 this was bootstrapped by hand: the built-in admin-tenant `m-default`
  app (secret readable from `logto-postgres`) drove the Management API to create
  an `industream-seeder` M2M app (DEFAULT tenant, granted a `management-api` role)
  → wrote the creds file; then a test user + `industream-admin` role were created.
- **TODO (→ T4):** a non-interactive Logto bootstrap (seeder M2M app + an initial
  admin user + role assignment) so `industream init` EE is reproducible.

### C3 — Seeder provisioning overlaps / conflicts with Hub self-provisioning
- The Hub backend **self-provisions** on boot: the `industream-hub-app` SPA login
  client (id=`industream-hub-app`, redirect `https://<domain>/`) AND the launchpad
  tiles. Confirmed on .205 (appeared ~minutes after deploy, no seeder).
- `seed-logto.sh` ALSO creates an `industream-hub-app` (random id, redirect
  `dashboard.<domain>/auth/callback`) → a **duplicate** for a `dashboard` host not
  deployed here. Harmless but confusing.
- **Resolution:** let the Hub own the login app + tiles; trim `seed-logto.sh` to
  ONLY resources + roles (its unique value); likely **retire `seed-menu-apps-stack.sh`**
  (Hub already seeds tiles, and it is broken — see C4).

### C4 — `seed-menu-apps-stack.sh` still assumes the `uifusion-api` container name (→ T1)
- Fails with "No running 'uifusion-api' container found" — the service is now
  `industream-hub-backend`. This is residual T1 rename work in the seeders (T1 is
  done for the stack overlays but not the `scripts/setup/` seeders).

### C5 — Seeders fail on the internal self-signed TLS (no `curl -k`)
- `seed-logto.sh` (and peers) call `curl -sS --fail-with-body` without `-k`, so
  they die on the internal `.lan` self-signed Traefik cert
  (`SSL certificate problem: self-signed certificate`). Worked around on .205 with
  a `PATH`-injected `curl` wrapper adding `-k`.
- **TODO:** make the seeders honor an insecure/CA option for internal domains
  (env flag or `--cacert`), rather than requiring a wrapper.

### Also noted
- The seeders live in the **deployment-v2 parent** `scripts/setup/`
  (`create-secrets{,-ee}.sh`, `seed-{logto,confighub,menu-apps-stack}.sh`), NOT in
  `unified/scripts/`. Folding them into the unified driver is part of T4.
- `create-secrets.sh` is idempotent and sources on-disk `secrets/<env>/*` — so a
  full secret wipe is recoverable by re-running it (identical values, couplings
  like `logto_db_url`↔`logto_db_password` preserved). Good property to keep.
