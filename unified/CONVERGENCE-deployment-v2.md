# Converging `deployment-v2` ↔ unified deploy

**TL;DR** — @dja-dsd and I independently built a deployment overhaul from opposite
sides: your `industream-flowmaker@feat/deployment-v2` (compose) and the unified
tree in `industream-stack/unified/` (one base + per-runtime overlays, covering
**both** swarm and compose). We're ~80% aligned on direction — let's merge into
**one** model before the two (plus the legacy swarm `docker-stack.*`) diverge
further. This note maps the two, flags 3 bugs, and proposes the merged shape.

## We independently reached the same conclusions ✅
| Principle | unified/ | deployment-v2 |
|---|---|---|
| No fallback defaults; fail loud | `versions.env`, no `${VAR:-default}` | removes every `${VAR:-default}` ✅ |
| Single versioned source for images | `versions.env` + `registries.env` | **release bundles** (`.env.{core,workers,datacatalog}`) ✅ |
| Separate by lifecycle | `base/<group>.yml` groups | **core / workers instance types** ✅ |
| DataCatalog Hub-JWT on compose | `base/datacatalog.yml` | you added the `Authentication__Frontend__*` block ✅ |
| Dual-port DataCatalog | `8002;8003` | `ASPNETCORE_URLS=8002;8003` ✅ |

Direction is shared. The rest is reconciling **shapes**.

## Differences to reconcile
1. **Image references.** v2 = one full-ref var per service (`${DATACATALOG_API_IMAGE}`)
   from a bundle. unified = `${REGISTRY}/name:${VERSION}` (registry **and** tag split),
   where `registries.env` is **license-aware** (community→GHCR, enterprise→39t). The v2
   bundle example pins `842775dh` (staging) for everything → loses the community/
   enterprise split. **Proposal:** keep the bundle UX, but generate bundles per
   *edition* from a license-aware registry map (or keep `versions.env`+`registries.env`
   and render bundles from them). Either way: one tag source, license-aware registry.
2. **Service naming.** v2 renamed to `industream-hub-backend` / `-frontend`. unified
   kept `uifusion*` + a permanent `industream-hub-backend` network alias (less blast
   radius). You already did the rename → **let's pick `industream-hub-backend` as
   canonical** and I'll align the swarm side + the JWKS alias.
3. **Instances vs overlays.** v2 = `core` + attachable `workers` instances. unified =
   `base/core.yml` + `base/workers.yml` files in one project. These compose well: the
   unified `base/` files can BE the content of your bundle/instance types. **Proposal:**
   keep your core/workers instance UX on top of shared `base/*.yml`.
4. **One driver.** v2 = the rewritten `fm`. unified = `scripts/deploy.sh` assembler
   (+ the `industream-cli` thin driver). These must converge into ONE. The CLI already
   has a runtime abstraction (swarm/compose); it can call the same assembly `fm` does.
5. **EE version var.** `UIFUSION_API_ENTERPRISE_VERSION` (v2) vs `UIFUSION_API_EE_VERSION`
   (unified). Pick one name.

## 🔴 Bugs in `deployment-v2` (independent of the merge — worth fixing now)
1. **Hardcoded DB password** `Password=industream4370` is still inline in
   `docker-compose.datacatalog.yml` (both the API connection string and
   `datacatalog-postgresql` `POSTGRES_PASSWORD`). → move to a file secret resolved by
   the dotnet-entrypoint (the unified `base/datacatalog.yml` shows this pattern:
   `__DB_PASSWORD_PLACEHOLDER__` + `/run/secrets/<name>`).
2. **Missing `$`** in the JWT issuer:
   `Authentication__Frontend__Issuer={FM_AUTH_ISSUER:-hub-backend}` → the value becomes
   the literal string `{FM_AUTH_ISSUER:-hub-backend}`, so issuer validation breaks. Should
   be `${FM_AUTH_ISSUER:-hub-backend}` (or, post-merge, `${HUB_AUTH_ISSUER}` with no default).
3. `deployment/wget-log` looks accidentally committed → remove.

## What the unified side adds (and v2 doesn't have yet)
- **Both runtimes** from one base — v2 is compose-only; unified renders swarm too
  (the swarm `docker-stack.*` is the third system we want to retire).
- The **security fix** (no inline pw) and the **Logto fresh-DB entrypoint fix** (seed
  before alteration — fixes the greenfield EE crash-loop).
- License-aware registry split + JWT-contract lint (`iss=hub-backend`/`aud=industream-hub`
  enforced, never changes).

## Proposed merged model
**`base/*.yml` (neutral, both runtimes) + `runtime.{swarm,compose}.yml` overlays + a
single license-aware version/registry source rendered into your bundles + your
core/workers instance UX, all driven by the one `industream-cli` thin driver.**
CE deploys stay reproducible with plain `docker compose` (no CLI) for the BSL grant.

## Proposed next step
A 30-min sync to lock: (a) bundle format vs versions/registries, (b) canonical naming
(`industream-hub-backend`), (c) instances-on-top-of-base, (d) one driver (CLI). Then I
fold `deployment-v2` and `unified/` into a single tree and we retire the legacy swarm
`docker-stack.*`.

— refs: unified tree `industream-stack/unified/` (PRs #24 merged, #25/#26/#27/#28),
`UNIFICATION-PLAN.md`, `DRIFT-RECONCILED.md`.
