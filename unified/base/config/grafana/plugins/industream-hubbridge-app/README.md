# Industream Hub Bridge — Grafana plugin

Background-only app plugin that connects Grafana to the Industream Hub
runtime protocol (`industream-hub/v1/*`).

Hand-written AMD module — no build step required. Mounted into the Grafana
container as a read-only volume.

## What it does

- **Route sync (bidirectional)** — listens to Grafana's `locationService` and
  posts `industream-hub/v1/route` to the wrapper, which relays to the Hub
  shell. Reverse direction: handles `navigate/back/forward` from the shell.
- **Theme sync (bidirectional)** — broadcasts the current Grafana theme on
  start, and applies remote `set-theme` events via the user preferences API
  (reload required — Grafana's runtime theme switch is not in the public API).

Auth bootstrap is **not** in scope of this plugin (Grafana validates JWTs at
the platform level via `auth.jwt` config). The plugin assumes a logged-in
session.

## Why hand-written, not scaffolded

`@grafana/create-plugin` produces a webpack pipeline with ~300 npm deps for
a simple background-only plugin. For PoC scope, an AMD module written
directly is enough and avoids the build chain. Migrate to the official
scaffold when production-ready (signing, types, dev hot-reload).

## Loading

Mounted at `/var/lib/grafana/plugins/industream-hubbridge-app/` via the
docker-compose volume. Grafana 13 refuses unsigned plugins by default —
whitelist this plugin ID via the env var
`GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=industream-hubbridge-app`.
