# Converging FlowMaker `master` deploy ↔ unified deploy

**Corrected 2026-06-07 from a direct audit of `industream-flowmaker@master`** (the
earlier version of this note relied on a pasted `CHANGES.md` that misdescribed the
work — it claimed v2 used full-ref bundles and dropped defaults; master does neither).

**TL;DR** — @dja-dsd's compose overhaul is **merged on `master`** (not a separate
`deployment-v2` branch; `feat/deployment` is 0 commits ahead). The unified tree in
`industream-stack/unified/` (one base + per-runtime overlays, swarm + compose) and
master are ~70% aligned in direction. This note maps them on REAL facts, flags the
divergences, lists the env to port, and the 1 confirmed bug.

## Where master and unified already agree ✅
| Principle | unified/ | master |
|---|---|---|
| Service names | `industream-hub-backend/-frontend`, `flowmaker-*` | same ✅ |
| Confighub v2 (LMDB) | `flowmaker-confighub-v2` | same ✅ (etcd retired) |
| DataCatalog Hub-JWT on compose | `base/datacatalog.yml` | `Authentication__Frontend__{Issuer,Audience,JwksUrl}` ✅ |
| Dual-port DataCatalog | `8002;8003` | `ASPNETCORE_URLS` dual-port ✅ |
| Edition = overlay | `base/` + `ee.yml` | `community.yml` / `ee.yml` overlays ✅ |
| A generation step exists | `render-bundles.sh` → bundle | `fm create` seds `.env.template` (`{{...}}`) ✅ |
| Proxy = Caddy (compose) | runtime compose | `infra.yml` Caddy ✅ |

The "a generation step exists" row matters: David already accepts rendering config
from a template, so our bundle generator is the **same shape**, just license-aware
and full-ref instead of `sed` placeholders.

## Divergences to reconcile
| # | Dimension | master | unified/ | Resolution |
|---|---|---|---|---|
| 1 | Image ref | inline `${COMMUNITY_REGISTRY:-ghcr.io/industream}/repo:${VER:-default}` | full-ref `${X_IMAGE}` from a license-aware bundle | **Keep bundle** (decided 2026-06-07). Sell at T0: same generation step, stricter. |
| 2 | Defaults | `:-default` on registry AND version | none (fail-loud) | Keep fail-loud; defaults can pull stale tags. |
| 3 | Worker image names | `flowmaker.boxes/flow-box-<x>` (long) | `flowmaker.boxes/<x>` (short) | **VERIFIED 2026-06-07 (manifest inspect):** community ghcr = SHORT pullable for all 15 (long missing for 7) → short is canonical, David's long refs partly broken. Enterprise 39t = was INCONSISTENT (opc-ua/rtsp = short; luminosity-box + minio-sink only `flow-box-` long). **RESOLVED 2026-06-07:** retagged both to short on 39t (`buildx imagetools create`, multiarch amd64+arm64 preserved). **SHORT is now canonical EVERYWHERE** (community 15/15 + enterprise 4/4 pullable); our tree is 100% pullable. David's long refs stay partly broken on community → align him to short at T0. |
| 4 | Version var names | `CORE_VERSION`, `FRONT_VERSION`, `UIFUSION_API_ENTERPRISE_VERSION` | `FLOWMAKER_CORE_VERSION`, `FLOWMAKER_FRONTEND_VERSION`, `UIFUSION_API_EE_VERSION` | Pick one set; map in the bundle generator. |
| 5 | Entitlement | compose `profiles:[premium]` (opc-ua/rtsp/luminosity) | deploy-time inclusion + ENTERPRISE_REGISTRY | Adopt `profiles:` — it's cleaner; our overlays can carry them. |
| 6 | Instance model | multi-instance: `fm create/up --workers --uimaker/init`, per-inst `.env`+network+override | base groups + bundle | T3: fold `fm` instance UX onto the unified base (one driver). |
| 7 | Driver | `fm` (1658 lines, instance-centric) | `scripts/deploy.sh` + industream-cli | T4: one driver + `fm`-compatible wrapper. |

## What unified/ ADDS (master doesn't have it) — additive, keep
- **Monitoring** (grafana-wrapper + prometheus/node-exporter/cadvisor/alertmanager) —
  master's compose deploys none. Decision #4 puts Grafana in compose scope.
- **DataBridge / InfluxDB / TimescaleDB** (`base/data.yml`) — not in master's compose.
- **Secret-file security** (`*_FILE` + `DB_SECRET_NAME` + `__DB_PASSWORD_PLACEHOLDER__`) —
  master inlines passwords (see bug below).
- **swarm runtime** from the same base — master is compose-only.
- The Logto fresh-DB entrypoint fix (seed before alteration).

## Env to PORT from master into base/ (T5)
Present on master, absent in our `base/` — functional, worth porting:
- `Authentication__Backend__ApiKey=${BACKEND_API_KEY}` (datacatalog-api).
- `Cors__AllowedOrigins=${...}` (datacatalog-api).
- `FM_CORS_ORIGIN` (flowmaker core).
- `IH_OIDC_INTROSPECTION_URL` (hub backend, EE).
- `DATACATALOG_API_URL` — confirm vs our `FM_DATACATALOG_URL`/`DATACATALOG_URL` (likely alias).

(The rest of the env diff — `MINIO_ROOT_PASSWORD`, `POSTGRES_PASSWORD`, `FM_WORKER_ID`,
`FM_CDN_*`, `CADDY_INGRESS_NETWORKS` — already exist in our tree under the runtime
overlays or as the `*_FILE` secret pattern; not truly missing.)

## 🔴 Confirmed bug on master (T6 — independent, fix onto master)
`docker-compose.datacatalog.yml`:
1. **Hardcoded DB password** `Password=industream4370` (API connection string + `POSTGRES_PASSWORD`).
   → file secret resolved by the dotnet-entrypoint (unified pattern).
2. **Missing `$`**: `Authentication__Frontend__Issuer={FM_AUTH_ISSUER:-hub-backend}` → the
   value becomes the literal string `{FM_AUTH_ISSUER:-hub-backend}`, breaking issuer
   validation. Should be `${FM_AUTH_ISSUER:-hub-backend}` (or `${HUB_AUTH_ISSUER}`, no default).

## T0 decisions locked with the user (2026-06-07)
- **#5 version-var naming → David's SHORT names** (`CORE_VERSION`, `FRONT_VERSION`,
  `UIFUSION_API_ENTERPRISE_VERSION`); the bundle generator maps them.
- **#6 entitlement → adopt David's `profiles:[premium]`** for gating premium workers.
- **#7 seeding → keep OUR `seed-*.sh`** (standalone, non-interactive `--stack/--domain`,
  declarative apps table, cross-runtime container discovery, + Logto OIDC bootstrap which
  his `fm init` lacks). The unified driver's `init` orchestrates them. His `cmd_init`
  logic (env/cdn + scheduler params) is verified-matched, not copied.
- **#8 canonical tree → `industream-stack` (LOCKED 2026-06-07).** The COMPLETE stack
  lives in industream-stack (platform-level: flowmaker + datacatalog + hub + databridge +
  monitoring + logto). David's `industream-flowmaker/deployment/fm` is **left as-is**; he
  removes it himself, on his own timeline, if/when he migrates — NOT force-retired. The
  `fm`-wrapper shim (calling the industream-stack driver) is an **optional migration aid**
  we can offer, not a requirement. Two systems coexist until David opts in; ours is canonical.

## Proposed next step
30-min sync (T0) to lock: (a) bundle full-ref over inline+defaults [we keep ours;
argument = same generation step, fail-loud, auditable release], (b) short vs long worker
image names [verify registry], (c) version-var naming, (d) adopt `profiles:[premium]`,
(e) one driver (`fm` UX on the unified base). Then fold master + unified/ into one tree
and retire the legacy swarm `docker-stack.*`.

— refs: unified tree `industream-stack/unified/` (PRs #24 merged, #25/#26/#27/#28;
drafts `feat/merge-v2-t1-naming`, `feat/merge-v2-t2-bundles`), `MERGE-DEPLOYMENT-V2-TODO.md`.
Audit source: `industream-flowmaker@master` (2026-06-03).

---

## 2026-06-08 — recheck + what landed

**Repo recheck (canonical `industream-flowmaker@master` via GitHub API).** David's
verbally-described simplification — *no templates, no defaults, a dedicated workers
stack that asks "which core", a 2nd workers stack on the same scheduler* — is **NOT
yet pushed**. What IS on master: a dedicated `docker-compose.workers.yml` (workers =
separate compose project) + the `fm` v2 CLI + instances ce/ee — but still WITH
`.env.defaults`, inline `${VAR:-default}`, and `{{CORE_VERSION}}` templating in `fm`.
`feat/deployment-v2` is ahead 1 / behind 1 of master (effectively merged; nothing
hides there). His new model is local/WIP ⇒ **we implemented the swarm side ahead of
him; lock `FM_ATTACHED_CORE` semantics at the next sync before he pushes.** (Aligning
signal: his open PR #222 "short worker image names" matches divergence #3's verdict.)

**Landed in `industream-stack` since the 06-07 audit:**
- **Split-stack workers-attach** (resolves row #6 for swarm): `deploy.sh --type
  core|workers`; a workers stack ATTACHES to an existing core via `FM_ATTACHED_CORE`
  (David's env convention, default = ENV) → joins `${FM_ATTACHED_CORE}-platform` and
  registers with that core's `flowmaker-scheduler`. A 2nd workers stack (newer versions)
  lands on the SAME scheduler. **Validated live (.233):** `workers-canary` joined the
  existing `prod-platform` (no new net; 63 containers shared), resolved
  `flowmaker-scheduler` cross-stack (`getent → 10.0.3.11`). Compose already attached
  natively via external `flowmaker-net`. (`runtime/swarm/_platform-attach.yml`.)
- **EE seeders wired into `deploy.sh`** (Phase 4): post-deploy Logto OIDC app + roles +
  bootstrap user (direct-DB, no M2M) + launchpad → greenfield EE loginnable without the
  admin wizard. Pairs with `industream-hub` #15 (republish `api-enterprise:2.1.3` — ships
  the seeders + fixes the `/app/data` LMDB volume perms).
- **Divergence #2 (no defaults) — gap closed for config:** the data-layer config vars
  (`INFLUX_*`, `*_DB_USER/NAME`, `TIMESCALEDB_*`, `POSTGRES_ADMIN_USER`, `OIDC_CLIENT_ID`)
  moved from inline `:-default` to explicit `runtime.{swarm,compose}.env` (fail-loud,
  zero behavior change). KEPT: derived OIDC URLs (`auth.${INDUSTREAM_DOMAIN}`), stable
  internal service URLs (`http://datacatalog-api:8080`, logto introspection/jwks),
  optional-empty (`OIDC_CLIENT_SECRET`, `BACKEND_API_KEY`), and credential defaults —
  stripping those would hardcode-per-env or remove a safe fallback.
- Dead var removed: `versions.env` `UIFUSION_VERSION` (unused; real tags are
  `UIFUSION_API/UI/API_EE_VERSION`).

**4-combo VM gate — all green:** swarm CE 43/43 · swarm EE 45/45 · compose CE 42/42 ·
compose EE 44/44.

**Open follow-ups (from the dead-code audit):** ① one canonical config dir — yml mounts
say `./config/*` but the files live under `base/config/*` (swarm resolves to the file
dir, compose to the project dir) → pick one, drop the duplicate `init-postgres.sh`.
② anchor candidates: the per-file swarm `networks:` block (×5) + `restart_policy` (×25).
③ archive the completed planning notes (`RESUME.md`, `UNIFICATION-PLAN.md`,
`DRIFT-RECONCILED.md`, `MERGE-DEPLOYMENT-V2-TODO.md`).
