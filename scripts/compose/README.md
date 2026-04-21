# scripts/compose/

Thematic split of the legacy monolithic `industream-flowmaker/deployment/fm`
script (1721 lines, 17 commands). Behaviour is unchanged — every `cmd_*`
function was copied verbatim — only the file layout and a handful of path
variables were touched.

## Layout

| File | Responsibilities |
|------|------------------|
| `lib/common.sh` | Colors, `log_*`, `prompt*`, `get_existing_*`, `read_root_env`, `COMPOSE_ROOT` / `INSTANCES_DIR` resolution |
| `fm-instance.sh` | `create`, `up`, `down`, `ps`, `logs`, `list`, `delete` |
| `fm-caddy.sh` | `caddy:rebuild`, `caddy:stop`, `caddy:delete`, `caddy:logs`, `caddy:ca` (+ `caddy_health_check`) |
| `fm-sync.sh` | `init`, `sync` |
| `fm-worker.sh` | `launch-worker`, `cdn-reset` |
| `fm-hosts.sh` | `hosts` (+ `get_local_ips`, `select_ip`) |
| `fm` | Compat wrapper: dispatches legacy subcommands to the thematic scripts |
| `validate-parity.sh` | Parity check between legacy `fm` and the split (pre-existing) |

## Usage

### Direct bash invocation

```bash
./scripts/compose/fm-instance.sh create dev
./scripts/compose/fm-caddy.sh rebuild
./scripts/compose/fm-sync.sh sync dev
./scripts/compose/fm-worker.sh launch-worker dev timer
./scripts/compose/fm-hosts.sh
```

### Compat wrapper (old muscle memory)

```bash
./scripts/compose/fm up dev --workers
./scripts/compose/fm caddy:rebuild
./scripts/compose/fm init dev
```

### Via the top-level CLI

```bash
industream dev create dev        # → scripts/compose/fm-create.sh (see note)
industream caddy:rebuild         # → scripts/compose/fm-caddy.sh rebuild
```

> Note: the legacy `scripts/industream` dispatcher routes
> `industream dev <cmd>` to `scripts/compose/fm-<cmd>.sh`. Until that
> dispatcher is updated to match this thematic split, prefer the compat
> wrapper `./scripts/compose/fm <cmd>` or call the thematic scripts directly.

## Environment overrides

Both variables are optional; defaults keep the pre-split behaviour.

| Var | Default | Purpose |
|-----|---------|---------|
| `COMPOSE_ROOT` | `../../../industream-flowmaker/deployment` | Directory containing `docker-compose.*.yml`, `.env.defaults`, `.env.template`, `docker-compose.infra*.yml` |
| `FM_INSTANCES_DIR` | `$COMPOSE_ROOT/instances` | Per-instance `.env` + override storage |

## Notes on the split

- The legacy `fm` defined `cmd_sync` at lines 872 **and** 1168 and `cmd_init`
  at lines 1048 **and** 1344. Bash keeps the last definition, so only the
  second versions were ever executed. The split keeps only those live
  versions.
- `cmd_create` and `cmd_delete` used to call `cmd_caddy_rebuild` directly.
  Since caddy lives in a separate file now, the call goes through
  `"$SCRIPT_DIR/fm-caddy.sh" rebuild`.
- The legacy `fm` still lives in `industream-flowmaker/deployment/fm` and is
  unchanged; it is kept around for anyone who still invokes it in-place.
