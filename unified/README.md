# Unified deployment (`unified/`) — WIP

One source for the **4-deploy matrix** (CE/EE × swarm/compose). Implements the
target from `../UNIFICATION-PLAN.md`: an orchestrator-neutral **base** + thin
**per-runtime overlays**, a **single version source**, driven (later) by the thin
`industream-cli`. Files stay plain Compose-Spec → runnable without the CLI
(BSL/CE no-CLI fallback).

## Layout
```
unified/
├── versions.env        # SINGLE source of truth for every image tag
├── registries.env      # COMMUNITY_REGISTRY (ghcr) / ENTERPRISE_REGISTRY (39t)
├── auth.env            # JWT contract (iss=hub-backend, aud=industream-hub, JWKS) — INVARIANT
├── base/               # orchestrator-neutral (image + functional env only)
│   └── datacatalog.yml # ✅ done (increment 1)
├── runtime.swarm.yml   # swarm plumbing: deploy:/Traefik/docker-secrets/overlay-nets
├── runtime.swarm.env   # swarm-topology interpolation values (DB host, secret name)
├── runtime.compose.yml # compose plumbing: Caddy/file-secrets/restart/dedicated-DB
├── runtime.compose.env # compose-topology interpolation values
└── seeders/            # runtime-agnostic (--runtime swarm|compose) — to vendor
```

## Assembly (one rule, both engines)
```sh
# compose
docker compose --env-file registries.env --env-file versions.env --env-file auth.env \
  --env-file runtime.compose.env --env-file .env.<env> \
  -f base/datacatalog.yml [-f base/...] -f runtime.compose.yml up -d

# swarm (deploy.sh / CLI renders + stack deploy)
docker stack deploy -c base/datacatalog.yml [-c base/...] -c runtime.swarm.yml <stack>
```

## Status
- **Increment 1 (this branch):** scaffold + version/registry/auth single sources +
  **datacatalog vertical slice**. Carries the **security + auth fix** for compose:
  - added the missing **Hub-JWT validation block** (was unauthenticated),
  - removed the inline **`Password=industream4370`** → file secret + `dotnet-entrypoint`
    (same `/run/secrets/<name>` mechanism as swarm),
  - **dual-port 8002;8003** (was 8080).
  Compose render validated (`docker compose config`).

## Next (per UNIFICATION-PLAN.md phases)
- Phase 1: reconcile remaining drifts (worker names/tags, ports, FlowMaker auth, hub alias).
- Phase 2-3: extract `base/` for workers → core → flowmaker → data → monitoring.
- Phase 4: `base/ee.yml` + runtime-agnostic seeders + CLI thin driver.
- Phase 5: CE no-CLI recipe, decommission legacy, CI parity gate.

> ⚠️ Open coordination: moving `industream-flowmaker/deployment/` (David's `fm`)
> into this tree is decision **#6** — needs David's buy-in first.
