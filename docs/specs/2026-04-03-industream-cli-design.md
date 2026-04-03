# Industream CLI — Design Specification

> Date: 2026-04-03
> Status: Draft
> Repo: `industream/industream-cli` (to be created)

## Summary

A standalone CLI tool for installing, managing and monitoring the Industream platform. Replaces the current bash scripts (`industream.sh`, `install.sh`, `fm`) with a modern terminal UI built on Node.js and Ink.

Distributed as a single binary (Node SEA) — no runtime dependencies. Installed via `curl -fsSL https://install.industream.com | bash`.

## Goals

1. **Unified management** — one tool for install, deploy, status, update, secrets, logs
2. **Beautiful TUI** — live dashboard, spinners, interactive prompts (Ink + React)
3. **Update awareness** — compare deployed versions vs registry, propose upgrades
4. **License-aware** — enforce BSL 1.1 / Proprietary module separation
5. **Dual audience** — simple wizard for clients, advanced commands for Industream team

## Non-Goals (MVP)

- Web-based UI (future)
- Remote management of multiple clusters (future)
- License server / online validation (future — MVP uses offline JWT)
- Auto-provisioning of VMs or cloud infrastructure

## Architecture

### Approach: CLI + Repo (Option B)

The CLI is a lightweight orchestrator. The deployment configuration lives in the `industream-swarm` repository, cloned locally to `~/industream-platform/`.

```
                   ┌──────────────────────────┐
                   │  industream CLI binary    │
                   │  (Node SEA, ~50-90 MB)    │
                   │                           │
                   │  Ink TUI + commands        │
                   │  Module registry embedded │
                   │  License validator (JWT)   │
                   └─────────┬────────────────┘
                             │ orchestrates
                   ┌─────────▼────────────────┐
                   │  ~/industream-platform/    │
                   │  (git clone of swarm repo) │
                   │                           │
                   │  docker-stack.*.yml        │
                   │  scripts/                  │
                   │  config/                   │
                   │  secrets/                  │
                   └─────────┬────────────────┘
                             │ deploys to
                   ┌─────────▼────────────────┐
                   │  Docker Swarm             │
                   │  Traefik, Postgres,        │
                   │  Keycloak, FlowMaker,      │
                   │  DataCatalog, Workers...   │
                   └──────────────────────────┘
```

### Why not monolithic (Option A)?

The stack YAML files change frequently (new worker versions, new services). Embedding them in the binary would require a CLI rebuild for every version bump. With Option B, `industream update` does a `git pull` on the swarm repo — the CLI only needs updating for new features.

## Distribution

### Install flow

```bash
curl -fsSL https://install.industream.com | bash
```

The bootstrap script:
1. Detects OS and architecture (linux-x64, linux-arm64)
2. Downloads the binary from GitHub Releases (`industream/industream-cli`)
3. Places it in `~/.local/bin/industream` (or `/usr/local/bin/` with sudo)
4. Creates `~/.industream/` config directory
5. Runs `industream install` if first-time setup

### Auto-update

On launch, the CLI checks its version against the latest GitHub Release (with a 24h cache). If a newer version is available, it shows a non-blocking notification:

```
  Update available: 1.2.0 → 1.3.0
  Run: industream self-update
```

### Build

Node SEA (Single Executable Application) compiles the TypeScript project into a standalone ELF binary. GitHub Actions builds for linux-x64 and linux-arm64 on each release tag.

## Commands

### `industream` (no args)

Interactive menu — same experience as current `industream.sh` but with Ink TUI.

### `industream install`

Interactive wizard for first-time setup:

1. **Prerequisites check** — Docker, Docker Swarm, disk space, RAM
2. **License selection**:
   - Community (free, BSL 1.1 modules only)
   - Enter license key (JWT)
   - Start 90-day trial (all modules)
3. **Registry credentials** — OVH Harbor login
4. **Domain configuration** — `industream.platform.lan` or custom
5. **Environment selection** — same menu as current (prod, dev, staging, demo)
6. **Deploy** — clones swarm repo, creates secrets, deploys stacks
7. **Seed ConfigHub** — sets environment URLs and scheduler
8. **Summary** — shows URLs, credentials, /etc/hosts entries

### `industream status`

Live Ink dashboard showing all services:

```
┌─ INDUSTREAM PLATFORM ───────────────────────────────────┐
│  License: Enterprise (ArcelorMittal)  Expires: 347 days │
│  Domain:  industream.platform.lan     Env: prod         │
├─────────────────────────────────────────────────────────┤
│  SERVICE              STATUS    VERSION    UPDATE       │
│  ● Traefik            running   v3.2.0     ✓ latest    │
│  ● PostgreSQL         running   18-alpine  ✓ latest    │
│  ● Keycloak           running   26.1.0     ⬆ 26.2.0   │
│  ● UIFusion           running   1.0.8      ✓ latest    │
│  ● FlowMaker          running   2.0.2      ✓ latest    │
│  ● DataCatalog API    running   1.9.0      ⬆ 1.10.0   │
│  ● DataCatalog UI     running   1.9.0      ⬆ 1.10.0   │
│  ● InfluxDB           running   2.7.11     ✓ latest    │
│  ● DataBridge         running   1.0.1      ✓ latest    │
│  ● Grafana            running   12.4.1     ✓ latest    │
│  ○ AI Studio          stopped   —          🔒 premium  │
│  Workers: 18/18 running                                 │
│  Memory: 4.2 GB / 8 GB        CPU: 23%                │
├─────────────────────────────────────────────────────────┤
│  [u] Update available  [l] Logs  [r] Refresh  [q] Quit │
└─────────────────────────────────────────────────────────┘
```

Data sources:
- Service status: `docker service ls` + `docker service ps`
- Versions deployed: parsed from running image tags
- Updates available: compared against OVH Harbor registry tags
- Resource usage: `docker stats`
- License: read from `~/.industream/industream.license`

### `industream update`

1. **CLI update** — checks GitHub Releases for newer binary
2. **Stack update** — `git pull` on `~/industream-platform/`
3. **Version diff** — compares `.env` versions vs deployed vs registry latest
4. **Interactive upgrade** — select which services to update
5. **Rolling deploy** — `docker service update --image` for each selected service

### `industream deploy [--env prod|dev|staging|demo]`

Deploys an environment. Delegates to existing `scripts/deploy-swarm.sh` via `execa`. Filters stack files based on license (excludes premium modules for community).

### `industream stop [--env prod|dev|staging]`

Stops an environment via `docker stack rm`.

### `industream logs [service]`

Streams logs from a Docker service. If no service specified, shows an interactive selector.

### `industream secrets [--show] [--regenerate]`

- Default: lists secret names
- `--show`: displays secret values from local `secrets/` directory
- `--regenerate`: regenerates and rotates secrets

### `industream license`

Displays current license info. Allows updating the license key.

### `industream uninstall [--env X]`

Removes stacks, secrets, and optionally volumes for an environment.

## Licensing Model

### Tiers

| Tier | License | Modules | Price |
|------|---------|---------|-------|
| **Community** | BSL 1.1 | Core platform, BSL connectors, basic analytics | Free |
| **Trial** | 90-day trial | All modules | Free |
| **Pro** | Commercial | Community + selected premium modules | Paid |
| **Enterprise** | Commercial | All modules + support + SLA | Paid |

### License file format

JWT signed with ES256 (ECDSA P-256). Stored at `~/.industream/industream.license`.

```json
{
  "iss": "industream.com",
  "sub": "client-uuid",
  "customer": "Customer Name",
  "plan": "enterprise",
  "modules": ["opc-ua-connector", "s7-connector", "onnx-runtime", "ironstream"],
  "seats": 50,
  "iat": 1743638400,
  "exp": 1775174400,
  "trial": false
}
```

### Validation

- **Offline**: The CLI embeds the Industream ES256 public key. Signature verification requires no network.
- **Grace period**: 30 days after expiration, services continue running. CLI shows warnings. After 30 days, deploys are blocked.
- **Community fallback**: Expired licenses fall back to community tier (BSL modules only).

### Module registry

A `modules.json` file embedded in the CLI maps each module to its license tier, Docker image, stack file, and status. Updated with each CLI release. Source of truth: `Industream_Module_License_Registry_Pricing 2026.xlsx`.

### Enforcement

At deploy time, the CLI:
1. Reads the license JWT
2. Verifies signature against embedded public key
3. Checks expiration
4. Filters `docker-stack.*.yml` services to include only licensed modules
5. Generates resolved stack file and deploys

Premium modules in `industream status` show a lock icon (`🔒 premium`) for unlicensed modules.

## Module Registry Structure

```json
{
  "modules": [
    {
      "id": "opc-ua-connector",
      "name": "OPC-UA connector",
      "category": "DataBridge — live connectors",
      "description": "Source & sink — industrial standard for PLCs and SCADA systems",
      "license": "proprietary",
      "status": "ready",
      "stackFile": "docker-stack.workers.yml",
      "serviceName": "worker-opc-ua-client",
      "imagePattern": "flowmaker.boxes/flow-box-opc-ua-client"
    }
  ]
}
```

## Tech Stack

| Dependency | Purpose |
|------------|---------|
| `ink` | React-based terminal UI framework |
| `ink-table` | Table component for status dashboard |
| `commander` | CLI argument parsing and help generation |
| `execa` | Shell command execution (docker, git) |
| `jose` | JWT signature verification (license) |
| `semver` | Version comparison for update checker |
| TypeScript | Type safety |
| Node SEA | Binary compilation |

## Project Structure

```
industream-cli/
├── src/
│   ├── index.ts                 # Entry point, command router
│   ├── commands/
│   │   ├── install.tsx           # Install wizard
│   │   ├── status.tsx            # Live dashboard
│   │   ├── update.ts             # Update checker + applier
│   │   ├── deploy.ts             # Deploy orchestrator
│   │   ├── stop.ts               # Stop environments
│   │   ├── logs.ts               # Log viewer
│   │   ├── secrets.ts            # Secret management
│   │   ├── license.ts            # License management
│   │   └── uninstall.ts          # Uninstall
│   ├── lib/
│   │   ├── docker.ts             # Docker/Swarm API wrapper
│   │   ├── registry.ts           # OVH Harbor registry client
│   │   ├── license.ts            # JWT license validator
│   │   ├── modules.ts            # Module registry loader
│   │   ├── swarm-repo.ts         # Git clone/pull industream-swarm
│   │   └── config.ts             # Local config (~/.industream/)
│   └── components/
│       ├── ServiceTable.tsx       # Service status table
│       ├── Spinner.tsx            # Deploy progress indicator
│       ├── Banner.tsx             # Industream ASCII banner
│       └── LicenseBadge.tsx       # License tier display
├── modules.json                  # Module registry
├── package.json
├── tsconfig.json
├── .github/
│   └── workflows/
│       └── release.yml           # Build + publish binaries
└── scripts/
    └── build-sea.sh              # Node SEA build script
```

## Config Directory

```
~/.industream/
├── config.json          # CLI preferences, default env
├── industream.license   # License JWT file
└── update-check.json    # Last update check timestamp + result
```

## Error Handling

- **No Docker**: Clear message with install instructions
- **No Swarm**: Offer to run `docker swarm init`
- **No license file**: Fall back to Community tier
- **Expired license**: 30-day grace with warnings, then Community fallback
- **Registry unreachable**: Deploy from local images, skip update check
- **Git unavailable**: Download swarm repo as tarball from GitHub Releases

## Testing Strategy

- **Unit tests**: License validator, version comparator, module registry
- **Integration tests**: Docker mock for service status parsing
- **E2E tests**: VM-based deployment test (same as current `industream-test` VM)

## Migration Path

The CLI replaces `industream.sh` and `install.sh`. The bash scripts remain in `industream-swarm` as a fallback but are no longer the primary interface. The `fm` CLI in `industream-flowmaker` remains independent (dev tooling).

## Future Considerations (post-MVP)

- Remote cluster management via SSH
- Web dashboard companion
- License server for online validation
- Plugin system for custom modules
- `industream doctor` — diagnostic command
- `industream backup` / `industream restore` — managed backup operations
