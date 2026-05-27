# Patching services — runbook

> **Rule of thumb**: any **durable** change to a service goes into a YAML file
> under [`custom/`](../../custom/). Imperative `docker service update`
> commands that touch spec (`--env-add`, `--label-add`, `--limit-*`,
> `--mount-add`, ...) are **forbidden** for changes that must survive a
> redeploy — they will be silently overwritten the next time
> `industream deploy` runs.

## The policy

```
┌────────────────────────────┬─────────────────────────────────────────┐
│ Change type                │ Where it goes                           │
├────────────────────────────┼─────────────────────────────────────────┤
│ env var, label, resource   │ custom/docker-stack.<name>.yml          │
│ image / tag                │ custom/docker-stack.<name>.yml          │
│ volume mount               │ custom/docker-stack.<name>.yml          │
│ replicas / placement       │ custom/docker-stack.<name>.yml          │
│ healthcheck                │ custom/docker-stack.<name>.yml          │
│                            │                                         │
│ Force restart (no spec     │ docker service update --force <svc>     │
│   change)                  │   (allowed — runtime op, not config)    │
│ Temporary scale to 0       │ docker service scale <svc>=0            │
│                            │   (allowed — runtime op, reverted at    │
│                            │   next deploy)                          │
│ Secret rotation            │ scripts/maintenance/rotate-*.sh         │
│ Container-level fix (DB    │ docker exec <container> ...             │
│   row, file in volume)     │   (allowed — touches data, not spec)    │
└────────────────────────────┴─────────────────────────────────────────┘
```

## Why

`docker stack deploy --prune` reconciles each service back to the spec
declared in the merged compose files. Anything you applied imperatively
that isn't in those files will be reverted. There is no built-in
"this-was-modified-by-hand-don't-touch" flag in Docker Swarm.

The custom stack files mechanism (auto-discovered by `deploy-swarm.sh`)
makes the YAML the **single source of truth**:

- Patches are versioned in git
- Re-deploys apply them automatically
- No drift between actual state and declared state

## Workflow

### 1. Adding a patch

```bash
# Pick a meaningful name. Multiple files are allowed; they merge.
cat > custom/docker-stack.keycloak-debug.yml <<'YAML'
services:
  keycloak:
    environment:
      - KC_LOG_LEVEL=DEBUG
YAML

# Validate locally
docker compose -f docker-stack.yml -f custom/docker-stack.keycloak-debug.yml config -q

# Redeploy
industream deploy --env prod
# or directly:
./scripts/deploy-swarm.sh --env prod
```

### 2. Reverting a patch

Just remove (or rename to `.disabled`) the file and redeploy:

```bash
rm custom/docker-stack.keycloak-debug.yml
industream deploy --env prod
```

### 3. Debugging "is this patch active?"

```bash
# Inspect the resolved compose (after merge)
docker compose \
  -f docker-stack.yml \
  -f docker-stack.flowmaker.yml \
  -f custom/docker-stack.keycloak-debug.yml \
  config | less

# Or, on the live service
docker service inspect industream-prod_uifusion-api --pretty | grep -i KC_LOG_LEVEL
```

### 4. Skipping custom files (debug)

If you suspect a custom file is the cause of a deploy failure:

```bash
./scripts/deploy-swarm.sh --env prod --no-custom
```

## What goes where — concrete examples

### Bumping an env var

```yaml
# custom/docker-stack.postgres-tuning.yml
services:
  postgres:
    environment:
      - POSTGRES_MAX_CONNECTIONS=300
```

### Adding a custom Traefik route

```yaml
# custom/docker-stack.acme-frontend.yml
services:
  uifusion:
    deploy:
      labels:
        - "traefik.http.routers.acme.rule=Host(`acme.example.com`)"
        - "traefik.http.routers.acme.tls=true"
```

### Raising worker resource limits

```yaml
# custom/docker-stack.worker-resources.yml
services:
  worker-timeseries:
    deploy:
      resources:
        limits:
          cpus: "2.0"
          memory: 2G
```

### Pinning an image to a specific tag

```yaml
# custom/docker-stack.pin-versions.yml
services:
  keycloak:
    image: keycloak/keycloak:26.1.0
```

## Imperative ops that ARE allowed

These don't change the service spec (no drift risk):

| Command | Use |
|---|---|
| `docker service update --force <svc>` | Restart all replicas without spec change |
| `docker service scale <svc>=0` then `=N` | Stop/start a service temporarily |
| `docker service logs -f <svc>` | Stream logs |
| `docker service ps <svc>` | List tasks |
| `docker exec <container> <cmd>` | Touch data inside a running container (DB row, file) |
| `scripts/maintenance/rotate-*.sh` | Live secret rotation (uses `--secret-rm/--secret-add` properly) |

## Trap: patches that look durable but aren't

A few common mistakes:

- `docker service update --env-add FOO=bar <svc>` — overwritten at next deploy
- `docker service update --label-add traefik.X=Y <svc>` — overwritten
- `docker service update --limit-memory 2g <svc>` — overwritten
- `docker service update --image <other-image> <svc>` — overwritten (and
  worse, no record in git of why you did it)

If you find yourself reaching for any of these, **stop** and write the
override into a `custom/*.yml` file.

## Related

- [`custom/README.md`](../../custom/README.md) — auto-discovery conventions
- [`backups.md`](./backups.md) — backup verification runbook
- `scripts/deploy-swarm.sh` — `--no-custom` flag implementation
