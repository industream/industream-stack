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
