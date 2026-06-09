# RESUME — start here to pick up the deployment unification

Single entry point. Last updated 2026-06-05.

## Goal
One deployment source for the **4-deploy matrix** (CE/EE × swarm/compose):
orchestrator-neutral `base/*.yml` + thin `runtime.{swarm,compose}.yml` overlays +
single `versions.env`/`registries.env`/`auth.env` + one `scripts/deploy.sh`
assembler. Plain Compose-Spec (runnable without the CLI → BSL/CE fallback).
**Converge with David's `industream-flowmaker@feat/deployment-v2`** (his parallel
compose overhaul) — don't lose any of his features.

## Status (honest)
**Validated at ASSEMBLY only (`docker compose config` render) — NOT executed/deployed.**

| Task | State |
|---|---|
| Phase 0 audit + plan | ✅ `UNIFICATION-PLAN.md` (6 decisions) |
| Scaffold + datacatalog + security fix | ✅ PR **#24 merged** |
| Phase 1 (all groups + drift reconcile) | ✅ PR #25 — render 68 svc |
| EE overlay (`base/ee.yml`) | ✅ PR #26 |
| `deploy.sh` assembler | ✅ PR #27 |
| Integration (4-combo `--render` green) | ✅ PR #28 (compose 59/62 svc; swarm YAML-valid) |
| **T1** rename → `industream-hub-*` | ✅ draft branch `feat/merge-v2-t1-naming` |
| **T2** license-aware bundles | ✅ done — all 32 industream images full-ref from bundle (6 groups: core/flowmaker/datacatalog/data/monitoring/workers), `deploy.sh --bundle` wired, 4-combo render green |
| **T3** core/workers instances | ✅ done — `deploy.sh --groups "…"` (footprint-selectable; validated: core-only 12 svc, workers-only 15, full 44, bogus rejected). Fixed `GROUPS` clash with bash's reserved var → `GROUP_SET`. |
| **T4** one driver (fm ⇄ CLI) | ✅ MVP — `scripts/industream` driver (create/up/down/ps/logs/list/delete/init, cross-runtime, `--dry-run`) + `fm-wrapper.example` shim. Validated via dry-run + real `up --render`. Live exec untested (= T7 VM gate). `T4-DRIVER-DESIGN.md` for full fm→driver map. |
| **T5** port v2 extras | ✅ done — invariants verified + 4 env ported from master (ApiKey as secret-store export, Cors, FM_CORS_ORIGIN, IH_OIDC_INTROSPECTION_URL); 4-combo render green |
| **T6** 3 deployment-v2 bugs | ❌ deferred (PR on David's branch) |
| **T7** live VM gate (deploy 4 combos on .233/.41) | ❌ **not done — the real test** |
| **T8** decommission legacy trees | ❌ not started — scope = OUR swarm `docker-stack.*`. David's `fm` is left to HIM (#8 locked: complete stack in industream-stack; he deletes his fm on his own timeline). |

## David's v2 IS available — it's on `master` (corrected 2026-06-07)
Earlier note said "v2 not on remote" — WRONG. David's v2 landed on **`master`** of
industream/industream-flowmaker (last commit 2026-06-03; `feat/deployment` = 0 commits
ahead, fully merged). There was never a `deployment-v2` branch. Audited master directly.
**Not blocked.** T5-port, T3, T4 can read from master now.

### What master ACTUALLY is (vs the stale CHANGES.md we'd assumed)
- Image refs = **inline split** `${COMMUNITY_REGISTRY:-ghcr.io/industream}/repo:${VERSION:-default}`
  — NOT full-ref bundles. **Keeps `:-default` fallbacks** (we drop them). Worker images use
  **`flow-box-<x>` long names** (we use short). Version vars `CORE_VERSION`/`FRONT_VERSION`.
- David HAS a generation step too: `fm create` seds `.env.template` (`{{CORE_VERSION}}`,
  `{{WORKER_VERSIONS}}`…) → same pattern as our `render-bundles.sh`, just less structured.
- Edition select = compose **`profiles:[premium]`** + `community.yml`/`ee.yml` overlay files;
  multi-instance via `fm create/up --workers --uimaker/init`.
- NO monitoring, NO DataBridge/influx in his compose (ours-only, additive). Inline pw
  `<old-db-password>` (his bug). Caddy via infra.yml.
- **DECISION LOCKED (2026-06-07): keep our bundle full-ref model** (user likes it); converge
  David at T0 — argument: he already accepts a generation step (`fm` sed-templating).
- **T5-port candidates (real, on master):** `Authentication__Backend__ApiKey` (BACKEND_API_KEY),
  `Cors__AllowedOrigins`, `FM_CORS_ORIGIN`, `IH_OIDC_INTROSPECTION_URL` (EE).

## The blocking gate
**T0 = sync with David** to confirm the 6 decisions (see `UNIFICATION-PLAN.md §5`):
keep-both-proxies · vendor-seeders-for-CE · **adopt `industream-hub-*`** ·
grafana-compose-in-scope · EE=entitlements · **copy** his compose into `unified/`
(leave his repo intact) · bundles=full-ref-license-aware · one-driver(CLI)+fm-wrapper.
Show him: `CONVERGENCE-deployment-v2.md` + the feature-preservation table + the
T1/T2 draft branches (proof it works and he loses nothing).

## To resume
- **"reprends l'unif"** → after the David sync: T3 (instances) → T4 (driver) → T5
  (extras), then T7. T2-remainder (switch other base groups to `${X_IMAGE}`) is mechanical.
- **"gate VM"** → execute `VM-GATE-RUNBOOK.md`: deploy the 4 combos on .233 (swarm)
  + .41 (compose), validate (converge / JWKS / DataCatalog 401→200 / EE login / JWT probe).
- **T6** (independent, no David needed): fix the 3 bugs on `feat/deployment-v2`
  (inline pw `<old-db-password>`, missing `$` in JWT issuer, stray `wget-log`).

## Map of docs (all in `unified/`)
- `RESUME.md` — this file (start here).
- `UNIFICATION-PLAN.md` — full phased plan + 6 decisions.
- `DRIFT-RECONCILED.md` — every drift fixed + canonical choices.
- `MERGE-DEPLOYMENT-V2-TODO.md` — T0-T8 with deps + agent-parallelization.
- `CONVERGENCE-deployment-v2.md` — note for David (mapping + 3 bugs + merged model).
- `VM-GATE-RUNBOOK.md` — step-by-step live deploy gate.

## Branches / PRs
Stack: #24 (merged) · #25 #26 #27 #28 (open, stacked) · `feat/merge-v2-t1-naming` ·
`feat/merge-v2-t2-bundles` (draft, pending David). Hub: #11 (menu bearer, open) ·
#13 #14 (merged). `.233` runs the test shell `uifusion/ui:2.1.2-menufix2-dev`.

> Persistent memory (auto-loaded each session): `deploy-unification.md` +
> `industream-registry-distribution.md`.
