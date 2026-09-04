# Airgap Bundle Runbook

Operational guide for installing and updating the Industream platform at a
site with **no internet access**, using the offline bundle built by
`unified/scripts/airgap.sh` and installed by its `install.sh`.

---

## Overview

| Step                  | Script                                  | Runs on           |
|------------------------|-----------------------------------------|--------------------|
| Build the bundle        | `unified/scripts/airgap.sh prepare`     | a connected machine |
| Verify before shipping  | `unified/scripts/airgap.sh verify`      | the connected machine, and again on site |
| Install / update        | `<bundle>/install.sh`                   | the airgapped site  |

A bundle is self-contained: the platform tree (`git archive` of the commit
it was built from), per-group `docker save` image tarballs, harvested
Grafana plugins and CDN packages, `bundle.json`, and checksum manifests
(`PARTS.sha256`, `MANIFEST.sha256`).

---

## 1. Build a bundle (connected machine)

The working tree must be clean (`prepare` refuses a dirty tree — what ships
must be what was tested):

```bash
cd unified
./scripts/airgap.sh prepare --runtime swarm --edition ee --out /media/usb
```

Common flags:

- `--env <env>` (default `prod`)
- `--groups "<group list>"` to ship a subset (default: everything
  `deploy.sh --print-groups` would deploy)
- `--max-part-size 3800M` (the default) keeps every shipped file under
  FAT32's 4 GiB per-file limit. **A real delivery hit this exactly** — a
  bundle built with a larger cap had to be reformatted onto a bigger stick
  before it would even copy. Leave it at the default unless the transport
  medium is known not to be FAT32.
- `--skip-images` / `--skip-assets` — testing/dev only, never for a bundle
  that will actually be shipped.

### The CDN harvest needs a warmed, connected instance

`airgap.sh prepare` harvests the CDN packages (FlowMaker box definitions)
from a **live, already-used** platform instance — `cdn-server` (Verdaccio)
only publishes a package the first time something asks for it, so an
instance nobody has pointed a build at yet has an **empty** cache. `prepare`
deliberately **fails loudly** rather than ship an empty one:

```
✗ CDN cache is empty — harvest from a warmed instance (--harvest-from) or the boxes will have no definition on site
```

On a real delivery this was missed once, and the empty cache only surfaced
much later, far from its actual cause: FlowMaker boxes with no definition
on the installed site.

If the build machine itself isn't the warmed instance, point the harvest at
one via a Docker context:

```bash
docker context create warmed-source --docker "host=ssh://user@warmed-host"
./scripts/airgap.sh prepare --runtime swarm --edition ee --out /media/usb \
  --harvest-from warmed-source
```

For **compose**, also pass `--harvest-project <project>` if the warmed
instance's compose project name differs from `--env` — compose has no fixed
volume-naming convention the way the swarm overlays do, so a mismatch here
silently harvests from (or reports empty against) the wrong volumes.

> **Honest gap:** the "CDN copy succeeds and yields real packages" path has
> never actually been exercised in this project's tests — no warmed instance
> was available to test against. Only the "finds nothing → abort" path is
> proven. Treat the harvest step itself as unverified until it has been run
> once against a real warmed instance and its output inspected.

### Grafana plugin version bumps

If a bundle bumps `GRAFANA_DATABRIDGE_PLUGIN` (or any preinstalled plugin
version) since the site's last install, that bundle **must** be installed —
`install.sh` re-seeds the Grafana plugins volume on every run, not only the
first. `GF_PLUGINS_PREINSTALL_SYNC` is **boot-blocking**: if Grafana starts
looking for a plugin version that was never seeded, it never starts at all.

### Verify before shipping

```bash
./scripts/airgap.sh verify /media/usb/industream-airgap-<commit>-ee-swarm
```

This re-checks `MANIFEST.sha256` / `PARTS.sha256` and replays
`deploy.sh --list-images` against the bundle's own tree, catching a group
added after the build before it ever reaches a site.

---

## 2. Transport

Copy the bundle directory to the transport medium as-is — no
re-compression, no reassembly needed on either end. FAT32 works at the
default `--max-part-size` (3800M). Do not rename or restructure the bundle
directory; `install.sh` resolves everything relative to its own location.

---

## 3. Install on a fresh site

```bash
cd /media/usb/industream-airgap-<commit>-ee-swarm
bash install.sh --target /opt/industream-platform --stack industream-prod   # swarm
bash install.sh --target /opt/industream-platform --project fm-prod        # compose
```

For compose, pass `--project <name>` explicitly and pick a name deliberately
— `install.sh` will fall back to `fm-<env>` if you don't, but that default
is only ever a placeholder, not a site convention. `--stack` defaults to
`industream-prod` if omitted. `--runtime`, `--edition`, `--env`, `--groups` all default to
whatever `bundle.json` recorded and can be overridden with the
same-named flag if this install genuinely needs to diverge from how the
bundle was built.

`install.sh` runs, in order:

1. **Preflight** — docker present, swarm active (swarm only), disk space on
   **both** `/var/lib/containerd` and `/var/lib/docker` (Docker 29 stores
   images under the former, not the latter — a real machine froze mid-install
   because only `/var/lib/docker` was checked), clock NTP-sync warning, and a
   full `airgap.sh verify` of the bundle. Verification **hard-stops before
   any Docker mutation** — a bad bundle never gets partway loaded.
   Budget roughly **50 GB free** for a full platform install.
2. **Image load** — streamed straight into `docker load`, never reassembled
   to disk.
3. **Tree sync** — `rsync` with hard, root-anchored exclusions for site-local
   state (`/unified/.env.*`, `/secrets/`, `/unified/custom/`,
   `/unified/instances/`, `/.deploy-state/`, `/backups/`), preceded by a
   timestamped snapshot under `backups/`.
4. **Asset seeding** — Grafana plugins and CDN packages, into
   `${ENV}-<volume>` (swarm) or `<project>_<volume>` (compose).
5. **Deploy** — `deploy.sh --airgap` with the runtime/edition/env/groups/
   bundle version from `bundle.json` (or your overrides) plus `--stack` or
   `--project`. `--airgap` skips the pre-pull and passes
   `--resolve-image never` to `stack deploy` — nothing reaches the network.

`--yes` is accepted (reserved for a future confirmation prompt — there is
none today). `--no-deploy` stops after asset seeding, before `deploy.sh`
runs — useful to stage a site without deploying yet.

---

## 4. Update an existing site

Same command, pointed at the **existing** `--target`:

```bash
cd /media/usb/industream-airgap-<new-commit>-ee-swarm
bash install.sh --target /opt/industream-platform --stack industream-prod
```

The sync step snapshots the current tree under `backups/` before touching
anything, and preserves every path listed above — `.env.<env>`, `secrets/`,
`custom/` overlays, `instances/`, and `.deploy-state/` all survive.

---

## 5. Roll back

Rollback is **replaying the previous bundle's `install.sh`** against the
same `--target`. For this to work, **the previous bundle must still be
present on site** — never delete a bundle directory after installing it.

```bash
cd /path/to/previous/industream-airgap-<old-commit>-ee-swarm
bash install.sh --target /opt/industream-platform --stack industream-prod
```

This re-syncs the tree to the old commit, reloads the old images (already
on disk from the earlier install — nothing is re-fetched), and redeploys.

---

## Never do this

- **Never run a teardown against this platform.** `deploy.sh`'s teardown
  removes `caddy_data`, which holds the CA — deleting it invalidates the
  certificate every workstation on site has already trusted. `install.sh`
  deliberately exposes **no** flag that reaches it.
- **Never `git reset --hard` (or a bare `cp -r`) on the site checkout.**
  Both have already destroyed untracked site state on real installs. The
  only supported way to update the tree is `install.sh` itself, which uses
  `rsync` with explicit exclusions and takes a snapshot first.

---

## The site checkout is not a git clone

`install.sh` writes the tree with `git archive` output, not a clone — the
checkout at `$TARGET` is **knowingly detached from `origin`**. It will never
take another `git pull`, `git fetch`, or `git log` against a real history.
The **only** record of what commit and bundle a site is running is:

```
$TARGET/AIRGAP_VERSION
```

written on every install/update:

```
commit=<short-sha>
bundle=<bundle-directory-name>
installed=<ISO-8601 timestamp>
```

Read this file first when diagnosing a site — never assume the checkout's
git metadata means anything.
