# T4 — Unified driver design (fold `fm` → one driver + `fm`-compatible wrapper)

**Decision (2026-06-07):** the target is a NEW unified thin driver (this tree's
`deploy.sh`/industream-cli) + an `fm`-compatible wrapper so David's muscle memory
keeps working. David's `fm` (1658 lines) is retired at T8. No code is copied; `fm`'s
behaviour is re-expressed on the unified base.

Source audited: `industream-flowmaker@master:deployment/fm` (19 commands).

## fm command surface → unified driver mapping
| `fm` command | What it does | Maps to | Runtime notes |
|---|---|---|---|
| `create <name>` | seds `.env.template` (`{{CORE_VERSION}}`, `{{FM_DOMAIN}}`…) → per-instance `.env` + dirs | `driver create` = render instance env from versions/registries/bundle | same generation step as `render-bundles.sh` |
| `up <name> [--workers] [--uimaker]` | `docker compose -p fm-<name> -f … up -d` | `deploy.sh --runtime compose --project fm-<name>` (+ `--with-workers/--with-uimaker`) | swarm: `--runtime swarm --stack` |
| `down <name>` | compose down | `driver down` → `compose down` / `stack rm` | |
| `ps <name>` | compose ps | `driver ps` → `compose ps` / `service ls` | |
| `logs <name> [svc]` | compose logs -f | `driver logs` | |
| `list` | enumerate instances + status/IP | `driver list` (scan projects/stacks) | |
| `delete <name>` | down + remove volumes/data | `driver delete` (guarded) | |
| `init <name>` | **post-deploy seeding**: ConfigHub + Hub apps (launchpad/origins) | `driver init` → our `seeders/` (seed-menu-apps, seed-logto app+user) | THE important one — already partly built in deploy-swarm hooks |
| `sync <name>` | sync config to ConfigHub | `driver sync` | ⚠ **fm defines `cmd_sync` TWICE (l.854 + l.1230)** — 2nd silently overrides 1st (latent bug, flag to David) |
| `launch-worker <…>` | dynamically attach a worker | `driver launch-worker` (workers group, attach to instance net) | ties into T3 instance model |
| `caddy:rebuild/stop/delete/logs/ca` | Caddy proxy lifecycle + local CA trust | `driver proxy <op>` abstracted per runtime | **compose→Caddy**, **swarm→Traefik** (different impl; some ops no-op on swarm) |
| `cdn-reset <name>` | reset verdaccio/esm.sh state | `driver cdn-reset` | |
| `hosts` | print/append /etc/hosts (dev) | `driver hosts` | dev convenience |
| `help` | usage | `driver help` + wrapper passthrough | |

## The wrapper
`fm` → thin shim: `fm <cmd> <args>` ⇒ `industream <cmd> <args>` (1:1 names above).
Ships in `industream-flowmaker/deployment/fm` at T8, replacing the 1658-line script
with a ~30-line passthrough. David types the same commands; one implementation runs.

## What stays runtime-specific (must abstract, not duplicate)
- **Proxy**: Caddy (compose) vs Traefik (swarm) — `driver proxy` dispatches per `--runtime`.
  Decision #1 keeps both proxies, so this abstraction is permanent, not transitional.
- **Instance addressing**: Caddy per-instance domain/IP (compose) vs Traefik labels +
  overlay net (swarm).

## Build order (T4 depends on T3)
1. T3 first: instance model on the unified base (`create`/`up --workers` semantics).
2. `driver {create,up,down,ps,logs,list,delete}` over deploy.sh.
3. `driver init/sync/launch-worker` over `seeders/` (port fm's ConfigHub+Hub-apps seeding).
4. `driver proxy` (Caddy/Traefik abstraction).
5. `fm` wrapper shim; validate every `fm`-style command on all 4 combos; then T8 retires fm.

## Open for T0 with David
- Confirm command names (keep `fm`'s exactly) + the `--workers/--uimaker` flags.
- Fix the duplicate `cmd_sync` in fm before/while porting.
- ConfigHub+Hub-apps `init` logic: reuse our seeders vs his — pick one source.
