# Community-mirror sync — runbook

> Keep the new community Harbor (`39t88114.c1.gra9.container-registry.ovh.net`)
> and the legacy `flowmaker.community/*` sub-project on the premium Harbor
> in sync with every BSL 1.1 image we ship — automatically, every night.

## Why

Until the new community Harbor is fully cut over, every BSL release has to
live in **three** places:

1. The premium Harbor under its native project
   (`842775dh.../<project>/<image>:<tag>`) — produced by the existing CI.
2. The legacy `flowmaker.community/*` mirror on the same premium Harbor —
   external integrators still pin to this URL.
3. The new community Harbor (`39t88114.../<project>/<image>:<tag>`) — the
   eventual public, anonymous-pull destination.

Doing this by hand with `crane copy` every release is error-prone and was
the source of the `flow-box-timer` desync in March. This runbook covers
the automated mirror; see [`patching.md`](./patching.md) for the policy on
durable service changes.

## What gets mirrored

The source of truth is `industream-cli/modules.json` — every module with
`license == "bsl"` is mirrored, everything tagged `proprietary` is
**excluded** (premium-only). If `modules.json` is not checked out (e.g.
the `industream-cli` sub-repo is empty in CI), the script falls back to a
baked-in list that matches the current BSL inventory:

| Project           | Images                                                                                          |
|-------------------|-------------------------------------------------------------------------------------------------|
| `datacatalog`     | `api`, `ui`                                                                                     |
| `flowmaker.boxes` | 18 BSL workers (`flow-box-timer`, `flow-box-mqtt-client`, …); excludes premium-only workers     |
| `flowmaker.core`  | `cdn-cache`, `cdn-server`, `flowmaker-confighub-v2`, `flowmaker-front`, `flowmaker-launcher`, `flowmaker-logger` |
| `flowmaker.infra` | `flowmaker-worker-manager`                                                                      |
| `grafana`         | `grafana-industream`                                                                            |
| `timeseries`      | `api`                                                                                           |
| `uifusion`        | `api`, `ui`                                                                                     |

Premium-only (NOT mirrored): `flow-box-opc-ua-client`, `flow-box-rtsp-client`,
`flow-box-luminosity-box`, `monitoring/cadvisor`, `flowmaker.infra/backup-monitor`.

## How it runs

### CI (nightly + on demand)

`.github/workflows/sync-community-mirror.yml`:

- **Cron**: `0 3 * * *` (03:00 UTC, after the 02:00 backup window).
- **Manual**: Actions → "Sync community mirror" → *Run workflow*.
  Inputs: `dry_run` (bool), `include_dev` (bool), `repo_filter` (substring).
- **Concurrency**: only one mirror run at a time (`cancel-in-progress: false`),
  late triggers queue instead of stomping.
- **Notification**: Ntfy on both success and failure (best-effort).

### Local

```bash
# Dry-run a single repo (no creds required for community push)
PREMIUM_USER=robot$mirror PREMIUM_PASS='…' \
  scripts/ops/sync-community-mirror.sh --dry-run --repo flow-box-timer

# Live, full run
PREMIUM_USER=robot$mirror   PREMIUM_PASS='…' \
COMMUNITY_USER=robot$mirror COMMUNITY_PASS='…' \
  scripts/ops/sync-community-mirror.sh

# Mirror dev tags too (one-off, e.g. shipping a hotfix RC to a customer)
… scripts/ops/sync-community-mirror.sh --include-dev --repo flow-box-mqtt-client
```

Default tag filter skips: `latest`, `*-dev`, `*-alpha*`, `*-beta*`, `*-rc*`.
Override with `--include-dev`.

## Idempotency

Each tag is checked against **both** destinations before any copy. If both
already have the manifest, the tag is `OK` and skipped. Re-running the
script is always safe.

## GitHub secrets to set

```text
PREMIUM_HARBOR_USER       (robot account on 842775dh… with pull on every
                           BSL project + push on flowmaker.community/*)
PREMIUM_HARBOR_PASS
COMMUNITY_HARBOR_USER     (robot account on 39t88114… with push on every
                           top-level project)
COMMUNITY_HARBOR_PASS

# Optional
NTFY_URL                  e.g. https://ntfy.industream.io
NTFY_TOPIC                e.g. industream-mirror-sync (default)
```

Set them via:

```bash
gh secret set PREMIUM_HARBOR_USER --body 'robot$mirror'
gh secret set PREMIUM_HARBOR_PASS --body "$(pass show industream/harbor/premium/mirror-bot)"
gh secret set COMMUNITY_HARBOR_USER --body 'robot$mirror'
gh secret set COMMUNITY_HARBOR_PASS --body "$(pass show industream/harbor/community/mirror-bot)"
gh secret set NTFY_URL --body 'https://ntfy.industream.io'
```

The robot accounts must already exist on each Harbor — create them via the
Harbor UI under *Administration → Robot Accounts* with the minimum scopes
listed above. Do **not** reuse human accounts.

## Troubleshooting

| Symptom                                                  | Likely cause                                                   | Fix                                                                                                   |
|----------------------------------------------------------|----------------------------------------------------------------|-------------------------------------------------------------------------------------------------------|
| `unauthorized: authentication required`                  | Robot creds wrong or expired                                   | Check `gh secret list`; rotate the robot account in Harbor and re-set the secret                      |
| `MANIFEST_UNKNOWN` while listing tags                    | Source project / repo doesn't exist (often a typo)             | Verify `<project>/<image>` is real on the premium Harbor; correct `modules.json` or fallback list     |
| `denied: requested access to the resource is denied`     | Robot missing push permission on destination                   | Add `push` scope on the project in Harbor; for the new Harbor confirm the project exists              |
| Same tag appears as `FAILED` every night                 | Manifest exists but is corrupt on one side                     | Manually `crane delete <bad-ref>` then re-run; usually one of the dest projects ran out of quota      |
| `429 Too Many Requests` from Harbor                      | OVH rate-limit (rare; typically only on `crane ls`)            | Re-run with `--repo <one-repo>` to narrow scope; spread big bootstraps over several manual runs        |
| Workflow fails at *Validate required secrets*            | One of the four required secrets is empty                      | `gh secret list` and re-set the missing one                                                            |
| Script picks fallback list instead of `modules.json`     | `industream-cli` sub-repo not checked out (expected in CI)     | Cosmetic; fallback list is kept in sync. If you intend to use `modules.json`, pass `--modules-json …` |

## Related

- [`backups.md`](./backups.md) — backup runbook (same Ntfy topic pattern)
- [`patching.md`](./patching.md) — durable-change policy
- `scripts/ops/clone-harbor-community.sh` — one-shot manual cousin, kept
  for the initial bootstrap (do not delete; the nightly script doesn't
  cover the historical mass-copy)
- `scripts/ops/sync-community-mirror.sh` — the nightly script described here
- `.github/workflows/sync-community-mirror.yml` — the CI wrapper
