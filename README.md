# Industream Platform — Deployment

The deployment source for the Industream platform: an **orchestrator-neutral**
description of every service that renders to **both Docker Swarm and Docker
Compose** from one tree, in **Community (CE)** or **Enterprise (EE)** editions.

Everything lives under [`unified/`](./unified). One assembler — `deploy.sh` —
builds the right compose-file set from `{runtime, edition, env, groups}` and
either renders it (validation) or deploys it.

## Table of Contents

- [What it is](#what-it-is)
- [Quickest path: the CLI (recommended)](#quickest-path-the-cli-recommended)
- [Editions: Community vs Enterprise](#editions-community-vs-enterprise)
- [Direct / advanced path](#direct--advanced-path)
- [Secrets](#secrets)
- [Custom stacks & workers](#custom-stacks--workers)
- [Multi-environment](#multi-environment)
- [Prerequisites](#prerequisites)
- [Legacy (deprecated)](#legacy-deprecated)

## What it is

The tree is built from layers that compose cleanly for any of the 4 deploys
(CE/EE × swarm/compose):

```
unified/
├── base/<group>.yml          # orchestrator-neutral: image + functional env only
├── runtime/swarm/<group>.yml  # swarm plumbing: deploy:/Traefik/docker-secrets/overlay-nets
├── runtime/compose/<group>.yml # compose plumbing: Caddy/file-secrets/restart
├── versions.env / registries.env / auth.env   # single sources of truth
├── releases/bundle-platform-<ver>/  # full-ref ${X_IMAGE} vars (license-aware)
├── custom/                    # YOUR overlays — added last, you win (see below)
└── scripts/
    ├── deploy.sh              # THE assembler (renders or deploys)
    └── render-bundles.sh      # builds a release bundle from versions + registries
```

For each selected **group** (`core`, `flowmaker`, `datacatalog`, `workers`,
`data`, `monitoring`), `deploy.sh` stacks `base/<group>.yml` then its runtime
overlay; appends the EE transform when `--edition ee`; then appends any
[`custom/`](./unified/custom) overlays. Image tags resolve from a rendered
**bundle**, which picks each image's registry by its license class (community →
GHCR, enterprise → Harbor). The files stay plain Compose-Spec, so the whole
assembly is reproducible by hand without the CLI.

## Quickest path: the CLI (recommended)

The `industream` CLI (separate repo `industream/industream-cli`) installs every
prerequisite, clones this tree, and drives `deploy.sh` for you.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/industream/industream-cli/main/install.sh)
```

> Use `bash <(curl …)`, **not** `curl … | bash` — the process substitution keeps
> a TTY so the interactive prompts work.

The installer:

1. Asks for the **orchestrator**: **Swarm** (production cluster) or **Compose**
   (dev / demo, single host — no Swarm).
2. Installs prerequisites (Git, Docker, Node.js 22+) and, for Swarm, initializes
   the swarm.
3. Installs the `industream` CLI and prints a logout/reconnect step (Docker group
   membership needs a fresh session).

After you reconnect, complete the install:

```bash
industream install --runtime swarm     # or: --runtime compose
```

Day-to-day commands:

| Command | Purpose |
|---|---|
| `industream doctor --fix` | Preflight every dependency `deploy.sh` needs and provision what's missing (swarm/secrets/networks/bundle). |
| `industream deploy` | (Re)assemble and deploy the platform via `deploy.sh`. |
| `industream status` | Show running services. |
| `industream logs` | Stream service logs. |
| `industream stop` | Tear the platform down. |

Run `industream doctor --fix` first on any host — it tells you exactly which
`deploy.sh` invocation is ready to run.

## Editions: Community vs Enterprise

Edition is **license-driven**, not a free choice:

- **Community (CE)** — the default, **no license required**. Pulls public images
  from `ghcr.io/industream`. Includes the full open platform and the
  community-class FlowMaker workers.
- **Enterprise (EE)** — unlocked by a valid **Keygen license**:

  ```bash
  industream license --set <token>
  ```

  EE applies `base/ee.yml` (e.g. Logto-based identity) and pulls premium images
  (enterprise UIFusion API, OPC-UA / RTSP / MinIO-sink / luminosity workers, …)
  from the Harbor at `39t88114.c1.gra9.container-registry.ovh.net` using the
  license's robot credentials. With no/community license the CLI deploys CE.

Registries are configured in [`unified/registries.env`](./unified/registries.env)
(`COMMUNITY_REGISTRY` / `ENTERPRISE_REGISTRY`).

## Direct / advanced path

Without the CLI, drive the tree yourself. First render a release bundle (the
full-ref `${X_IMAGE}` vars), then assemble:

```bash
cd unified

# 1) render the image bundle from versions.env + registries.env
./scripts/render-bundles.sh 1.0.1

# 2) assemble + deploy (or just validate with --render)
./scripts/deploy.sh --runtime swarm   --edition ce --env prod --stack industream-prod
./scripts/deploy.sh --runtime compose --edition ce --env dev  --project fm-dev
```

`deploy.sh` flags:

| Flag | Meaning |
|---|---|
| `--runtime swarm\|compose` | Target orchestrator (**required**). |
| `--edition ce\|ee` | CE (default) or EE (adds the `ee.yml` transform). |
| `--env <env>` | Environment id (default `prod`); sources `.env.<env>`. |
| `--stack <name>` | Swarm stack name (**required** for swarm). |
| `--project <name>` | Compose project name (**required** for compose). |
| `--groups "<list>"` | Group set to assemble. Default: `core flowmaker datacatalog workers data monitoring`. |
| `--type core\|workers` | Split-stack footprint: `core` = platform minus workers; `workers` = a workers-only stack that attaches to an existing core. |
| `--bundle <ver>` | Pick `releases/bundle-platform-<ver>/`. Auto-selected when exactly one bundle exists. |
| `--render` | Validate the assembled config and exit — deploy nothing. |

`--render` validates all 4 combos: compose via `docker compose config`, swarm via
per-file YAML validation (swarm `${ENV}-*` key interpolation only happens at
`docker stack deploy` time).

## Secrets

Secrets differ by runtime; `industream doctor --fix` (or
`scripts/setup/create-secrets.sh`) provisions them:

- **Swarm** — external Docker secrets named `<env>_<name>` (e.g.
  `prod_postgres_admin_password`, `prod_grafana_admin_password`,
  `prod_influx_admin_token`; EE adds `prod_logto_db_url` / `prod_logto_db_password`).
- **Compose** — file secrets named `<name>` under `SECRETS_DIR`.

Never commit secret files or `.env` overrides.

## Custom stacks & workers

Add your own services / FlowMaker workers, or override platform ones, **without
forking** — drop Compose-Spec files into [`unified/custom/`](./unified/custom):

- `custom/*.yml` — runtime-neutral.
- `custom/swarm/*.yml` / `custom/compose/*.yml` — runtime-specific.

`deploy.sh` includes them **last**, so your files win on any conflict. An empty
`custom/` is a no-op. See [`unified/custom/README.md`](./unified/custom/README.md)
for the rules (notably: never use `${VAR}` in a YAML mapping **key**).

For an **optional, named footprint** you want to toggle per deploy, add a real
group instead: create `base/<name>.yml` (+ optional `runtime/<rt>/<name>.yml`)
and select it with `--groups "core … <name>"`.

## Multi-environment

Run several isolated environments on one host: each `--env <env>` gets its own
`.env.<env>` site config, `<env>_*` secrets and `<env>-*` resources. Keep stacks /
projects distinct with `--stack` (swarm) or `--project` (compose):

```bash
./scripts/deploy.sh --runtime swarm --edition ce --env prod    --stack industream-prod
./scripts/deploy.sh --runtime swarm --edition ce --env staging --stack industream-staging
```

## Prerequisites

- **Docker Engine** with either **Swarm mode** (production) or the **Compose v2**
  plugin (dev / single host).
- **Node.js 22+** if you use the CLI.
- `python3` for swarm `--render` validation.

The CLI installer provisions Docker, Node.js and (for swarm) initializes the
swarm automatically, so on a fresh host you typically only run the one-liner.

## Legacy (deprecated)

The root-level `docker-stack.*.yml` files, `industream.sh`, `scripts/deploy-swarm.sh`,
`scripts/deploy-traefik.sh` and the per-env `create-secrets.sh` flow are the
**legacy single-runtime model** and are being decommissioned. New deployments
should use the [`unified/`](./unified) tree (CLI or `deploy.sh`) described above.

## License

See [`LICENSE`](./LICENSE) (community, BSL 1.1) and
[`LICENSE-PROPRIETARY`](./LICENSE-PROPRIETARY) (premium add-ons).
