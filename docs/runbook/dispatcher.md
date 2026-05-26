# Image dispatcher — runbook

> Promote a worker image from the internal staging Harbor to its final public
> destination (GHCR for BSL, `39t88114` Harbor for proprietary), driven by
> `industream-cli/modules.json`.

## Architecture in three sentences

CI in each worker repo builds the image and pushes it to the staging Harbor at
`842775dh.c1.gra9.container-registry.ovh.net/<path>:<tag>`. The dispatcher
workflow in this repo reads `industream-cli/modules.json`, classifies the image
by its `license` (and optional `enterpriseVariant`), and copies it with `crane`
to either `ghcr.io/industream/<path>:<tag>` (community / BSL) or
`39t88114.c1.gra9.container-registry.ovh.net/<path>:<tag>` (enterprise).
Customer CLIs pull from those public registries — they never touch staging.

```
   worker repo CI
        │ push
        ▼
   842775dh/<path>:<tag>     (staging, internal only)
        │ repository_dispatch → dispatch-image.yml
        ▼
   classify (modules.json)
        │
        ├── license=bsl    → ghcr.io/industream/<path>:<tag>
        └── license=prop   → 39t88114/<path>:<tag>
            (or enterpriseVariant path → always 39t88114)
```

## Manual trigger

Use `gh workflow run` from any checkout of this repo:

```bash
gh workflow run dispatch-image.yml \
  -f source_image='842775dh.c1.gra9.container-registry.ovh.net/flowmaker.boxes/flow-box-timer:2.0.3' \
  -f module_id='worker-timer'

# Watch the latest run
gh run watch
```

The job prints a `### Promotion plan` summary table (Module / License /
Source / Destination / Auth) on the run page before any login.

## Integrating from a worker repo

Drop the following step into the existing build workflow of every worker
repo, **after** the push to staging Harbor succeeds:

```yaml
- name: Trigger registry dispatcher
  env:
    DISPATCH_TOKEN: ${{ secrets.DISPATCH_TOKEN }}   # PAT with `repo` scope on industream-stack
    IMAGE_REF: 842775dh.c1.gra9.container-registry.ovh.net/${{ env.IMAGE_PATH }}:${{ env.VERSION }}
    MODULE_ID: worker-timer                           # value from modules.json `id`
  run: |
    curl -fsS -X POST \
      -H "Authorization: Bearer $DISPATCH_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      https://api.github.com/repos/industream/industream-stack/dispatches \
      -d @- <<EOF
    {
      "event_type": "image-built",
      "client_payload": {
        "source_image": "$IMAGE_REF",
        "module_id":    "$MODULE_ID"
      }
    }
    EOF
```

The dispatcher rejects payloads where `source_image` does not start with the
staging host or contains shell metacharacters, so a compromised worker repo
cannot pivot to push an arbitrary image elsewhere.

## Required secrets

Set these on the `industream-stack` repo (one-time):

```bash
gh secret set STAGING_HARBOR_USER     --body 'robot$dispatcher'
gh secret set STAGING_HARBOR_PASS     --body "$(pass show industream/harbor/staging/dispatcher)"
gh secret set ENTERPRISE_HARBOR_USER  --body 'robot$dispatcher'
gh secret set ENTERPRISE_HARBOR_PASS  --body "$(pass show industream/harbor/enterprise/dispatcher)"
gh secret set GHCR_TOKEN              --body "$(pass show industream/ghcr/dispatcher-pat)"

# Optional Ntfy notifications
gh secret set NTFY_URL    --body 'https://ntfy.industream.io'
gh secret set NTFY_TOPIC  --body 'industream-dispatcher'
```

Notes:
- `GHCR_TOKEN` must be a **PAT** (classic or fine-grained) belonging to a bot
  user with **`write:packages`** and **admin on `industream/*` container
  packages** (needed to flip visibility to public). The built-in
  `GITHUB_TOKEN` cannot publish across orgs.
- Staging robot needs `pull` on every project on `842775dh`.
- Enterprise robot needs `push` on every project on `39t88114`.

## Bulk first-time migration

To promote **every existing tag** currently on staging Harbor to its final
destination — typically run once when first wiring this up:

```bash
# Dry-run first (no creds needed for destinations)
STAGING_USER='robot$dispatcher' STAGING_PASS='…' \
  scripts/ops/promote-bulk.sh --dry-run

# Live (BSL modules → GHCR, proprietary → 39t88114, including enterpriseVariant)
STAGING_USER='robot$dispatcher'  STAGING_PASS='…' \
GHCR_USER='industream-bot'       GHCR_PASS='ghp_…' \
ENTERPRISE_USER='robot$dispatcher' ENTERPRISE_PASS='…' \
  scripts/ops/promote-bulk.sh

# Narrow scope while debugging
… scripts/ops/promote-bulk.sh --repo flow-box-timer --include-dev
```

Idempotent: tags already present on the destination are reported as `OK`
and skipped.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `module_id 'X' not found in modules.json` | The worker repo passed an `id` that does not exist | Add the module to `industream-cli/modules.json` first, or fix the `module_id` in the worker repo's dispatch step |
| `source path 'Y' does not match module 'X'` | The image path in staging Harbor differs from `imagePattern` / `enterpriseVariant` for that module | Either update `modules.json` to match the real path or correct the worker repo's image name |
| `unauthorized: authentication required` on staging | Robot creds wrong or expired | `gh secret list`, then re-set `STAGING_HARBOR_USER/PASS` |
| `unauthorized` on `ghcr.io` | `GHCR_TOKEN` lacks `write:packages` or is expired | Re-issue the PAT, ensure it is fine-grained with **Packages: read+write** scope on the `industream` org |
| `denied: requested access to the resource is denied` on push to GHCR | The owner org / package visibility is misconfigured | Manually visit `https://github.com/orgs/industream/packages` once, set the package to public; subsequent runs flip new packages automatically |
| GHCR package stays private after first push | API call to flip visibility failed (404 right after creation) | Re-run the workflow once; or flip via the GH UI under *Packages → Package settings → Change visibility* |
| `MANIFEST_UNKNOWN` on `crane copy` | Source tag does not exist on staging Harbor (typo in `source_image`) | Double-check the tag with `crane ls 842775dh.c1.gra9.container-registry.ovh.net/<path>` |
| `429 Too Many Requests` from GHCR | Anonymous pull throttle hit during a big bulk run | Run `promote-bulk.sh` with `--repo` to narrow scope; spread big migrations over a few sessions |

## Related

- `.github/workflows/dispatch-image.yml` — the dispatcher workflow
- `scripts/ops/promote-bulk.sh` — one-shot bulk migration
- `industream-cli/docs/REGISTRY-ARCHITECTURE.md` — full design doc
- [`mirror-sync.md`](./mirror-sync.md) — superseded legacy mirror (kept during Phase 4 cutover)
