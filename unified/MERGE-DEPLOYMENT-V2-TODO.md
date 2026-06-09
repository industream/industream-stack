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
