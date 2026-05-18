# Custom stack files

Drop client-specific Docker Swarm stack overrides here without touching the
official `docker-stack.*.yml` files. They are auto-discovered by
`scripts/deploy-swarm.sh` and merged on top of the platform stacks.

Two conventions are supported:

1. **Repo root** — any file matching `docker-stack.custom*.yml` at the project
   root (e.g. `docker-stack.custom.acme.yml`).
2. **This folder** — any `.yml` / `.yaml` file inside `custom/`
   (e.g. `custom/acme-overrides.yml`).

Files are loaded in alphabetical order, after every conditional official
stack. Each file is validated with `docker compose config -q` before the
stack is deployed; an invalid file aborts the deployment.

Use `./scripts/deploy-swarm.sh --no-custom` to skip the auto-discovery
(useful when debugging an issue suspected of coming from a custom file).
