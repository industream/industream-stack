# Custom stack files

> **Operator rule of thumb**: any durable change to a service goes here.
> Never `docker service update --env-add/--label-add/--limit-*` manually
> for anything you expect to survive a redeploy. See
> [`docs/runbook/patching.md`](../docs/runbook/patching.md) for the full
> policy.

Drop client-specific Docker Swarm stack overrides here without touching the
official `docker-stack.*.yml` files. They are auto-discovered by
`scripts/deploy-swarm.sh` and merged on top of the platform stacks.

## Conventions

Two locations are supported (both are auto-discovered, alphabetical order):

1. **Repo root** — any file matching `docker-stack.custom*.yml` at the project
   root (e.g. `docker-stack.custom.acme.yml`).
2. **This folder** — any `.yml` / `.yaml` file inside `custom/`
   (e.g. `custom/acme-overrides.yml`).

Files are loaded after every conditional official stack. Each file is
validated with `docker compose config -q` before the stack is deployed;
an invalid file aborts the deployment.

## Skip

Use `./scripts/deploy-swarm.sh --no-custom` to skip the auto-discovery
(useful when debugging an issue suspected of coming from a custom file).

## Examples

### Add an env var to keycloak

`custom/docker-stack.keycloak-overrides.yml`:

```yaml
services:
  keycloak:
    environment:
      - KC_LOG_LEVEL=DEBUG
```

### Bump CPU/memory limits for a worker

`custom/docker-stack.worker-resources.yml`:

```yaml
services:
  worker-timeseries:
    deploy:
      resources:
        limits:
          cpus: "2.0"
          memory: 2G
```

### Add a custom Traefik label

`custom/docker-stack.traefik-custom.yml`:

```yaml
services:
  uifusion:
    deploy:
      labels:
        - "traefik.http.routers.uifusion.middlewares=my-custom-mw@file"
```

### Install an extra Grafana plugin

The Grafana image obeys `GF_INSTALL_PLUGINS` — comma-separated list of
plugin IDs (optionally pinned with a space + version). The plugin is
downloaded into the persistent `${ENV}-grafana-data` volume on first
boot, so subsequent restarts are no-ops unless you set
`GF_INSTALL_PLUGINS_FORCE_REINSTALL=true`. Outbound HTTPS to
`grafana.com` is required at first boot.

`custom/docker-stack.grafana-plugins.yml` (e.g. for DSD):

```yaml
services:
  grafana:
    environment:
      - GF_INSTALL_PLUGINS=volkovlabs-echarts-panel
```

## Merge caveats — read before overriding core services

`deploy-swarm.sh` merges every discovered custom file on top of the
core stack with `docker compose config`. Compose merge rules are **not
uniform** across keys, so know what you're touching:

| Key                                 | Merge behaviour            | Implication                                             |
|-------------------------------------|----------------------------|---------------------------------------------------------|
| `environment` (list or map)         | Merged by key              | Safe — add/replace individual vars only                 |
| `labels`                            | Merged by key              | Safe — same as environment                              |
| `deploy.resources` (map)            | Merged by key              | Safe — bump `memory` without losing `cpus`              |
| `networks` (list)                   | Merged by deduplication    | Safe — append new networks                              |
| `volumes` (array of mounts)         | **Replaced entirely**      | Redeclaring drops every core mount — copy them all      |
| `secrets` (array)                   | **Replaced entirely**      | Same as volumes                                         |
| `ports`                             | **Replaced entirely**      | Rare in this project but still applies                  |
| `command` / `entrypoint`            | Replaced                   | Override fully replaces the core value                  |
| `depends_on`                        | Replaced                   | Redeclare every dependency if you touch this            |
| `deploy.placement.constraints`      | **Replaced entirely**      | Watch out if the core service has constraints           |

**Rule of thumb**: if the field is an array of complex objects
(volumes, secrets, constraints, ports), assume it is fully replaced
and copy the core values you still need into your override file.

### Volume / data caveats

- Don't change the `${ENV}-` volume prefix or you'll spawn a parallel
  empty volume.
- Plugins / data written *inside* a volume (e.g. Grafana plugins under
  `/var/lib/grafana/plugins`) persist across redeploys, but a
  `docker volume rm` wipes them. Install env vars
  (e.g. `GF_INSTALL_PLUGINS`) re-bootstrap on first boot, **provided
  the container has outbound internet access**.
- Pointing a service to a different volume in the override does **not**
  migrate the old data — you have to copy it manually.

### Secret caveats

- Adding a secret to a core service requires redeclaring the full
  `secrets:` array (it's replaced, not merged).
- Use `${ENV}_<name>` prefix to match `create-secrets.sh` conventions.
