# `custom/` — your own overlays (no fork needed)

Drop your own Compose-Spec `*.yml` files here to **add services / FlowMaker
workers** or **override platform ones** — without forking the deploy tree.

`scripts/deploy.sh` includes them **last**, after `base/`, the runtime overlays
and the EE transform, so **your files always win** on any conflict.

## Where to put files

| Location                 | Applied to        | Use for                                   |
| ------------------------ | ----------------- | ----------------------------------------- |
| `custom/*.yml`           | both runtimes     | runtime-neutral services / overrides      |
| `custom/swarm/*.yml`     | `--runtime swarm` | swarm-only plumbing (`deploy:`, secrets…) |
| `custom/compose/*.yml`   | `--runtime compose` | compose-only plumbing (`restart:`, …)   |

Within each location files are merged in **sorted (alphabetical) order**;
runtime-neutral files are merged before their runtime-specific peers. Prefix
with a number (`10-…`, `90-…`) if ordering between your own files matters.

Absent files are a no-op — an empty `custom/` changes nothing.

## Rules (same as the platform overlays)

- **Never use `${VAR}` in a YAML mapping KEY.** Neither `docker stack deploy`
  nor `docker compose config` interpolate variables in keys — only in *values*.
  This applies to the `networks:`, `secrets:` and `volumes:` name maps.

  ```yaml
  # ✗ WRONG — the key is not interpolated
  networks:
    ${ENV}-platform: { external: true }

  # ✓ RIGHT — fixed key, interpolated value
  networks:
    platform:
      name: ${ENV}-platform
      external: true
  secrets:
    my_secret:
      external: true
      name: ${ENV}_my_secret      # swarm external secret <env>_my_secret
  ```

- **Bind-mount source paths resolve relative to `base/`'s directory** (the
  assembler `cd`s into `unified/` and the platform files live under `base/`),
  not relative to `custom/`. Use a path reachable from there, e.g.
  `./base/config/...` or an absolute path.

- Keep files plain Compose-Spec so they stay runnable by hand (the CE / no-CLI
  fallback) — exactly like the platform `base/` and `runtime/` overlays.

## Example

`custom/compose/zz-extra-worker.yml`:

```yaml
services:
  my-extra-worker:
    image: ghcr.io/acme/my-flowmaker-worker:1.0.0
    restart: unless-stopped
    networks:
      platform:
    environment:
      FM_SCHEDULER_URL: http://flowmaker-scheduler:3000
networks:
  platform:
    name: ${ENV}-platform
    external: true
```

Deploy as usual — the overlay is picked up automatically:

```sh
./scripts/deploy.sh --runtime compose --edition ce --env dev --project fm-dev
# files: … custom/compose/zz-extra-worker.yml
# custom overlays: custom/compose/zz-extra-worker.yml
```

## Alternative: add a real group

For something you want to **select on/off per deploy**, add a proper group
instead of a custom overlay: create `base/<name>.yml` (orchestrator-neutral) and,
if needed, `runtime/<runtime>/<name>.yml`, then include it via `--groups`:

```sh
./scripts/deploy.sh --runtime swarm --edition ce --env prod \
  --groups "core flowmaker datacatalog workers data monitoring <name>" \
  --stack industream-prod
```

Use `custom/` for always-on local additions/overrides; use a `--groups` group
for an optional, named footprint.
