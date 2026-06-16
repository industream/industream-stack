# Unified deployment (`unified/`)

One source for the **4-deploy matrix** (CE/EE × swarm/compose). An
orchestrator-neutral **base** per group + thin **per-runtime overlays**, a
**single version/registry/auth source**, assembled by `scripts/deploy.sh` and
driven by the `industream` instance driver. Files stay plain Compose-Spec, so
the assembly is reproducible by hand without the CLI (BSL/CE no-CLI fallback).

## Layout

The tree is **per group** — no single top-level runtime overlay. Each group has
an orchestrator-neutral `base/<group>.yml` and (optionally) a swarm and a
compose overlay:

```
unified/
├── versions.env            # SINGLE source of truth for every image tag
├── registries.env          # COMMUNITY_REGISTRY (GHCR) / ENTERPRISE_REGISTRY (Harbor 39t…)
├── auth.env                # Hub JWT contract (iss=hub-backend, aud=industream-hub, JWKS) — INVARIANT
├── runtime.swarm.env       # swarm-topology interpolation values
├── runtime.compose.env     # compose-topology interpolation values
├── base/<group>.yml        # orchestrator-neutral: image + functional env only
├── runtime/swarm/<group>.yml    # swarm plumbing: deploy:/Traefik/docker-secrets/overlay-nets
├── runtime/compose/<group>.yml  # compose plumbing: Caddy/file-secrets/restart/dedicated-DB
├── releases/
│   ├── bundle-platform-<ver>/   # full-ref ${X_IMAGE} vars (render-bundles.sh, license-aware)
│   └── portainer/<env>-<edition>/ # per-group editable stacks (render-portainer-stacks.sh)
├── custom/                 # YOUR overlays — added last, you win (see custom/README.md)
├── instances/             # named deployments (instance.env) for the `industream` driver
└── scripts/
    ├── deploy.sh                  # THE assembler (renders or deploys)
    ├── industream                 # instance lifecycle driver over deploy.sh
    ├── render-bundles.sh          # build a release bundle from versions + registries
    ├── render-portainer-stacks.sh # split the deploy into editable Portainer stacks (mode B)
    └── deploy-state.sh            # versioned deploy state: snapshot / render / diff
```

### Groups

| Group | Contents | Edition |
|---|---|---|
| `core` | UIFusion Hub API/UI, CDN | CE + EE |
| `flowmaker` | FlowMaker launcher, ConfigHub, logger, frontend | CE + EE |
| `datacatalog` | DataCatalog API + UI | CE + EE |
| `data` | DataBridge API + InfluxDB store (CE time-series) | CE + EE |
| `monitoring` | Grafana (+ Hub-SSO wrapper), Prometheus, Alertmanager, exporters | CE + EE |
| `workers` | community FlowMaker flow-box workers | CE + EE |
| `ee` | EE transform: UIFusion EE API + Logto identity (applied, not selected) | EE |
| `workers-premium` | enterprise workers (opc-ua / rtsp / luminosity / minio-sink) | **EE only** |
| `timescale` | TimescaleDB store (EE alternative to the CE InfluxDB in `data`) | **EE only** |
| `portainer` | optional ops console (mode A) | CE + EE, opt-in |

## Assembly (`scripts/deploy.sh` — one rule, both engines)

`deploy.sh` builds the compose-file list from `{edition, runtime, env, groups}`,
sources the single env sources (in order: `registries.env` → `versions.env` →
`auth.env` → `runtime.<runtime>.env` → the selected bundle's `.env.*` →
`.env.<env>`), then dispatches `docker compose up` (compose) or pre-pulls images
and runs `docker stack deploy` (swarm). For each selected group it stacks
`base/<group>.yml` then `runtime/<runtime>/<group>.yml`; appends the EE transform
(`base/ee.yml` + its runtime overlay) when `--edition ee`; then appends any
`custom/` overlays **last** (you win on conflict).

```bash
cd unified

# 1) render the image bundle once (full-ref ${X_IMAGE} vars, license-aware)
./scripts/render-bundles.sh 1.0.1

# 2) assemble + deploy (or validate only with --render)
./scripts/deploy.sh --runtime swarm   --edition ee --env prod --bundle 1.0.1 --stack industream-prod
./scripts/deploy.sh --runtime compose --edition ce --env dev  --bundle 1.0.1 --project fm-dev
```

### Flags

| Flag | Meaning |
|---|---|
| `--runtime swarm\|compose` | Target orchestrator (**required**). |
| `--edition ce\|ee` | CE (default) or EE (adds the `base/ee.yml` transform + EE-only groups). |
| `--env <env>` | Environment id (default `prod`); sources `.env.<env>`. |
| `--stack <name>` | Swarm stack name (**required** for swarm). |
| `--project <name>` | Compose project name (**required** for compose). |
| `--groups "<list>"` | Group set to assemble. Default: `core flowmaker datacatalog workers data monitoring`. |
| `--workers "<csv>"` | Deploy ONLY these flow-box workers (subset of `workers`/`workers-premium`); omit = all. Custom workers are never filtered. |
| `--type core\|workers` | Split-stack footprint: `core` = platform minus workers; `workers` = a workers-only stack attaching to an existing core's `${FM_ATTACHED_CORE}-platform` net. |
| `--bundle <ver>` | Pick `releases/bundle-platform-<ver>/`. Auto-selected when exactly one bundle exists. |
| `--render` | Validate the assembled config and exit — deploy nothing. |

> **Default group set** (in `deploy.sh`): `core flowmaker datacatalog workers
> data monitoring`. `portainer`, `timescale`, `workers-premium` and the `ee`
> transform are **not** in the default set. `timescale` and `workers-premium`
> are **Enterprise-only** — `deploy.sh` rejects them in `--groups` unless
> `--edition ee`. `portainer` is opt-in for either edition (see below).

`--render` validates all 4 combos: compose via `docker compose config`; swarm via
per-file YAML validation (swarm `${ENV}-*` key interpolation only resolves at
`docker stack deploy` time).

After deploy, `deploy.sh` runs best-effort, non-fatal **post-deploy seeders** for
both editions (the Hub launchpad menu tiles) and, on EE, the Logto OIDC
app/roles/bootstrap-user seeders shipped in the EE hub image.

## Portainer (optional ops console)

Two independent ways to bring Portainer into the picture.

### Mode A — the `portainer` group (view + manage)

The optional `portainer` group (`base/portainer.yml` +
`runtime/{swarm,compose}/portainer.yml`) deploys the Portainer CE console
(`PORTAINER_VERSION`, admin password from the `portainer_admin_password` secret
created by `scripts/setup/create-secrets.sh`). It is **CE *and* EE**, opt-in.

Add it by including `portainer` in `--groups` (or via the CLI
`industream install --with-portainer`). On swarm it routes at
`portainer.${INDUSTREAM_DOMAIN}` (Traefik → :9000, manager-pinned for the Docker
socket); on compose it gets `portainer.${FM_DOMAIN}` (Caddy → :9000).

What it gives: a UI to **view** and **per-service manage** (scale, restart, logs,
image update, env) the deployed swarm/compose stacks. A CLI-deployed stack is
"external/limited" in Portainer — viewable per service, but **not editable** as a
whole stack file (Portainer has no source for it). For editable stacks, use
mode B.

### Mode B — `render-portainer-stacks.sh` (one editable stack per group)

`scripts/render-portainer-stacks.sh` splits the deploy into **one editable
Portainer stack per group**, written under
`releases/portainer/<env>-<edition>/<group>/docker-compose.yml` (+ a shared
`stack.env`, a `.env`, a `bootstrap.sh`, and a `README.md`). Portainer can then
**own each group as a Git stack** pointing at its subfolder, so each is editable
in the UI and redeployable from Git.

```bash
./scripts/render-portainer-stacks.sh --env prod --edition ee [--bundle 1.0.1] \
    [--workers "worker-timer,worker-…"] [--with-portainer] [--baked]
```

Flags: `--env` / `--edition ce|ee` (selects the group set: CE = core flowmaker
datacatalog data monitoring workers; EE also adds `workers-premium` +
`timescale`), `--bundle`, `--workers` (per-worker selection), `--with-portainer`
(also emit the `portainer` group), `--baked` (see caveat). The EE transform and
Logto fold into the **core** stack (that is where the hub services live). The
shared overlay network is externalised to `${ENV}-platform` (every group stack
attaches to the one pre-created network instead of each creating it), so run
`bootstrap.sh` + `create-secrets.sh` before adding the stacks.

> **Mode B is swarm-only** (`RUNTIME=swarm` in the script; the compose split is a
> later step).

#### ⚠ Deploy method matters — templated vs `--baked`

By default the rendered files stay **templated**: `${VARS}` resolve from the
sibling `stack.env`. Portainer's **string / web-editor / API** deploy does an
**incomplete `${VAR}` substitution** — notably it misses the secret `target:`
field and `*_FILE` envs, so a templated file deployed that way mounts secrets at
the literal path `/run/secrets/${ENV}_…` and stateful services crash.

- **Git-repository** deploy → compose does the **full** substitution from
  `stack.env` → use the **templated** files as rendered. The intended GitOps path.
- **string / web-editor / API** deploy → you **MUST** re-render with `--baked`
  (every `${VAR}` is already interpolated to a literal, so Portainer does no
  substitution).

> Edits made in the Portainer editor are not pushed back to Git — keep Git the
> source of truth and re-render to avoid drift (see deploy-state, next).

## Deploy state (versioning / audit / drift)

`scripts/deploy-state.sh` maintains a nested git repo at `<repo-root>/.deploy-state`
(one level above `unified/`, ignored by the platform clone) that versions both
sides of a deployment:

| Command | Does |
|---|---|
| `deploy-state.sh init` | Create the state repo (`0700`, `main` branch, local git identity). |
| `deploy-state.sh snapshot` | Pull the **live** Portainer-owned stacks into `live/<stack>/` (compose + `stack.env` + `_stacks.json` audit metadata). |
| `deploy-state.sh render [--env E] [--edition ce\|ee]` | Record the **desired** state into `desired/<group>/` (always `render-portainer-stacks.sh --baked`, so it is textually comparable with live). |
| `deploy-state.sh diff` | Show drift between desired and live. |
| `deploy-state.sh log` | State-repo history. |

`snapshot` runs **before** a redeploy (a best-effort, non-fatal hook is wired
into `deploy.sh`: when a `.deploy-state` repo exists it snapshots first, so
manual edits made in the Portainer UI are never silently overwritten unrecorded).
Each idempotent snapshot/render commits only when something actually changed.

**Auth** for `snapshot`: `PORTAINER_API_KEY` (preferred) or `PORTAINER_PASSWORD`
(+ optional `PORTAINER_USER`, default `admin`) from the environment; otherwise it
falls back to the install's local secrets store
(`<repo-root>/secrets/<env>/portainer_api_key` or `…/portainer_admin_password`).
Neither found → soft exit `3` (the deploy hook skips cleanly). Credentials never
ride in `curl`'s argv.

**Secrets are scrubbed identically on BOTH sides** (live and desired) by one
shared redactor (values → `<redacted>`), so the repo is safe to retain and
diffs stay noise-free. Nothing unscrubbed is ever committed.

> Like mode B, deploy-state is **swarm-targeted** (it reads/renders the
> per-group Portainer stacks).

## Compose vs Swarm parity

The compose path runs the **full application**: every group/service, file
secrets, the EE Logto identity + Hub-menu/Logto seeders, `--workers` selection,
and Portainer mode A. What differs is the **day-2 tooling and some hardening**,
which are swarm-only or need manual provisioning on compose:

| Capability | Swarm | Compose | Source |
|---|---|---|---|
| Application (all groups, secrets, EE, seeders, worker select, Portainer mode A) | ✅ | ✅ | `deploy.sh` |
| Portainer mode B (editable per-group stacks) | ✅ | ✗ | `render-portainer-stacks.sh` (`RUNTIME=swarm`) |
| deploy-state `render` / `diff` | ✅ | ✗ (only the pre-deploy `snapshot` hook fires) | `deploy-state.sh` |
| Grafana Hub-SSO trust (JWKS over internal CA) | ✅ auto (CA mount) | ⚠ manual `CADDY_LOCAL_CA` | `runtime/{swarm,compose}/monitoring.yml` |
| Prometheus / Alertmanager edge auth + rate-limit | ✅ `traefik-auth@file,rate-limit@file` | ✗ none | `runtime/swarm/monitoring.yml` |
| `deploy:` resource limits enforced | ✅ | ⚠ ignored except where compose re-declares `mem_limit` | `base/*.yml` vs `runtime/compose/core.yml` |
| Logto admin route (`auth-admin.`) | ✅ exposed (:3002) | ✗ only `auth.` (:3001) | `runtime/swarm/ee.yml` vs `runtime/compose/ee.yml` |

Notes:

- **Grafana Hub-SSO on compose** needs Caddy's internal CA exported as a PEM and
  bind-mounted into Grafana's extra-CA dir via `CADDY_LOCAL_CA` (default
  `./secrets/caddy-internal-ca.crt`). It is **not auto-provisioned** by the
  deployer — until you provide a readable PEM the JWKS fetch fails and tokens are
  rejected. See the TODO header in `runtime/compose/monitoring.yml`. Swarm wires
  the equivalent CA mount automatically.
- **`deploy:` resource limits** are honoured by swarm but **ignored by
  `docker compose up`**, except where a compose overlay re-declares `mem_limit`
  (currently `runtime/compose/core.yml`).
- **Logto admin** (`auth-admin.${INDUSTREAM_DOMAIN}` → :3002) is exposed only on
  swarm; the compose EE overlay publishes only the public `auth.${FM_DOMAIN}`
  endpoint (:3001).
