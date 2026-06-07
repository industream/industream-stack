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

## Proposed next step
30-min sync (T0) to lock: (a) bundle full-ref over inline+defaults [we keep ours;
argument = same generation step, fail-loud, auditable release], (b) short vs long worker
image names [verify registry], (c) version-var naming, (d) adopt `profiles:[premium]`,
(e) one driver (`fm` UX on the unified base). Then fold master + unified/ into one tree
and retire the legacy swarm `docker-stack.*`.

— refs: unified tree `industream-stack/unified/` (PRs #24 merged, #25/#26/#27/#28;
drafts `feat/merge-v2-t1-naming`, `feat/merge-v2-t2-bundles`), `MERGE-DEPLOYMENT-V2-TODO.md`.
Audit source: `industream-flowmaker@master` (2026-06-03).
