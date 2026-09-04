# Air-gapped bundle — design

Date: 2026-09-03
Status: proposed
Scope: `unified/scripts/` (new `airgap.sh`, two flags on `deploy.sh`)

## Problem

The unified deploy assumes a reachable registry. `deploy.sh` pre-pulls every
image, then runs `docker stack deploy`, and the platform itself downloads two
more classes of artefact at boot. On a site with no internet — the HO8
delivery, and now a colleague's demo that must be updated at a customer
without connectivity — none of that works, and the failures are not all loud.

Today the only way to update such a site is `git pull` on the on-server
checkout (`/home/beadmin/industream-platform` at Bernegger), which an
air-gapped site cannot do. The gap is not only images: since July, most of the
fixes landed in the tree itself — `deploy.sh`, `base/*.yml`,
`runtime/swarm/*.yml`, the seeders — plus a handful of version bumps. A bundle
that carries images alone would ship a customer an old, broken deployment with
new containers.

### What breaks without a network

| Component | Behaviour offline |
|---|---|
| `deploy.sh` pre-pull (l.641) | non-fatal, but ~50 images × timeout wasted |
| `docker stack deploy` | defaults to `--resolve-image always` → contacts the registry for every tag→digest |
| `--with-registry-auth` | meaningless |
| Grafana (`base/monitoring.yml:97`) | `GF_PLUGINS_PREINSTALL_SYNC` is deliberately boot-blocking → **Grafana does not start at all** |
| `cdn-server` (Verdaccio, `base/core.yml:126`) | proxies npmjs and publishes on demand → stays empty → FlowMaker box definitions and the JS expression editor have no source |
| Seeders (menu-apps, ConfigHub, Logto) | work offline; the EE image ships `/app/oidc-seeds` and `/app/menu-seeds` |

## Non-goals

- OS prerequisites (Docker `.deb`s, preseed, disk bootstrap). The bundle
  reserves an optional `os/` directory that a separate ISO build can fill; no
  code for it here.
- A local Docker registry. See *Image delivery* below.
- Differential bundles. The format carries the metadata to add `--from` and
  `--against` later; the first implementation always ships everything.
- Multi-node swarm. `load.sh` can simply be replayed on each node; the three
  real targets (Bernegger `tmgissrv`, the HO8 VM, `.55`) are single-node.

## Decisions

**Image delivery is `docker load`, not a local registry.** Swarm has no
built-in registry, so a registry would be a new permanent service — and
pointing the stack at it means rewriting image references. The 46 Industream
images resolve through `${X_IMAGE}` and would follow `registries.env`, but
**15 third-party images hardcode their registry in `base/*.yml`**
(`postgres:`, `influxdb:`, `grafana/grafana-oss:`, `minio/minio:`, the four
`prom/*`, `timescale/timescaledb:`, `eclipse-mosquitto:`, `telegraf:`,
`portainer/portainer-ce:`, `hurlenko/filebrowser:`,
`ghcr.io/logto-io/logto:`, `${CADVISOR_IMAGE}:`). Serving those locally would
mean editing 15 load-bearing references or generating a per-service rewrite
overlay. A daemon mirror does not help: `registry-mirrors` only covers Docker
Hub, not ghcr.io or Harbor. With `docker load` no reference changes at all —
the local image carries exactly the name the YAML expects. This is what worked
for HO8 (53 images) and for the TMS bundle.

**The image list is produced by the deploy, never duplicated.** A second list
maintained inside `airgap.sh` would drift the first time a group is added —
the defect `render-bundles.sh` already had when its table was missing six
workers. `deploy.sh` gains `--list-images`, which reuses the existing
`FILES[]` assembly and env sourcing and prints the resolved list.

**The bundle is a directory of parts, never a monolith**, so that a corrupt or
oversized piece is re-copied on its own, and so that nothing has to be
reassembled on disk before it is loaded.

**On-site targets keep their git checkout**, and the bundle is unpacked over
it. After an air-gapped sync the checkout is knowingly detached from `origin`:
it will never receive another `git pull`, and pretending otherwise would
mislead whoever debugs it later. `AIRGAP_VERSION` records the shipped commit
and bundle id.

## Architecture

Three pieces, each with one job.

### 1. `deploy.sh --list-images`

Assembles `FILES[]` from `--edition/--runtime/--groups`, sources the env, and
prints one resolved image reference per line, then exits — the same shape as
the existing `--render`. The inline extractor at l.659-690 becomes a function
called by both this flag and the pre-pull.

### 2. `deploy.sh --airgap`

Skips the pre-pull, drops `--with-registry-auth`, and adds
`--resolve-image never` to `docker stack deploy` (l.698). Roughly 30 lines.

### 3. `unified/scripts/airgap.sh`

Sibling of `forge-bundle.sh`, same selection flags as `deploy.sh`.

`prepare` builds the bundle:

1. **Refuse a dirty working tree** on tracked files. What ships must be what
   was tested. This is not hypothetical: at the time of writing, `deploy.sh`
   has an uncommitted `seed_confighub()` whose seeder
   `scripts/setup/seed-confighub-stack.sh` is untracked — a `git archive`
   built now would ship a `deploy.sh` calling a script absent from the bundle,
   and ConfigHub seeding would fail on site, leaving every catalog-entry
   picker hanging on "Loading…".
2. Resolve the image list with `deploy.sh --list-images`.
3. Pull each image only if absent locally (`pull_if_absent`, from the TMS
   bundle script): a locally built image that was never pushed is a normal
   case when preparing a bundle, and must not block it — with a warning.
4. `docker save` **per group** into one zstd tarball per group. A single
   archive would deduplicate shared layers best (`docker save` writes each
   layer once per invocation) but cannot be resumed; per-group tarballs cost
   some duplication of the workers' shared base layers and buy file-by-file
   recovery. HO8 fit 53 images in 3.7 GB this way.
5. Tree = `git archive HEAD` of the whole repository (a few MB).
6. **Plus the bundle `.env.*` files actually sourced.** `deploy.sh:631` does
   `source "$BUNDLE_DIR"/.env.*` and some of those are not committed — the
   secrets hook blocks `git add` on them. A `git archive` alone would deliver
   a stack whose images resolve to empty strings.
7. **Harvest runtime assets from a live, connected instance; never rebuild
   them.** The source is the local Docker daemon by default and a
   `--harvest-from <docker-context>` otherwise, so a warmed staging deployment
   can supply the caches when the build machine has none.
   - *Grafana plugins*: start `grafana/grafana-oss:${GRAFANA_VERSION}` with
     the exact `GF_PLUGINS_PREINSTALL_SYNC` value, let it install, extract
     `/var/lib/grafana/plugins`. Re-implementing the download is what once
     left a 22 MB fragment of a 25.8 MB plugin in the volume, segfaulting on
     every load.
   - *CDN packages*: copy the `cdn-server-storage` (Verdaccio) and
     `cdn-cache-storage` (esm.sh) volumes from an instance that has actually
     served the boxes. **Fail loudly if the source is empty** — shipping an
     empty cache is the HO8 failure mode, and it surfaces as boxes with no
     definition, far from the cause.
8. Split any file above `--max-part-size` with `split -d -b`; write
   `PARTS.sha256`, `MANIFEST.sha256` and `bundle.json` (version, edition,
   runtime, groups, git commit, images with digests).

`verify <bundle>` re-checks the sums and, more importantly, **replays
`--list-images` against the tree inside the bundle** and compares it to the
manifest. That catches a group added between build and departure.

## Bundle format

```
industream-airgap-<version>-<edition>-<runtime>/
├── images/
│   ├── core.tar.zst.00        # split: exceeded the part cap
│   ├── core.tar.zst.01
│   ├── workers.tar.zst        # intact: fit
│   └── monitoring.tar.zst
├── tree/                      # git archive HEAD + the resolved bundle .env.*
├── assets/
│   ├── grafana-plugins/       # 4 plugins, pre-extracted
│   └── cdn-packages/          # Verdaccio storage + esm cache
├── os/                        # reserved, empty
├── bundle.json
├── MANIFEST.sha256
├── PARTS.sha256
└── install.sh
```

`--max-part-size` defaults to **3800M**, keeping every file under the 4 GiB
FAT32 per-file limit — the limit that forced the HO8 USB key to exFAT.
`--max-part-size 0` disables splitting.

Loading never reassembles:

```sh
cat images/core.tar.zst.* | zstd -dc | docker load
```

Part sums are verified first, in a cheap read pass, so a bad part is caught
before Docker is touched. This also avoids a second copy of the archive on
disk — which matters, because Docker 29 stores images under
`/var/lib/containerd`, not `/var/lib/docker` (22 GB vs 4 KB measured at HO8,
where a single mounted volume froze the machine mid-install).

## On-site flow (`install.sh`)

Identical for a first install and for an update; the difference is only what
is already there.

1. **Preflights**, all blocking: Docker present; swarm `active` when
   `--runtime swarm`; **free space checked on `/var/lib/containerd` as well as
   `/var/lib/docker`**, against the uncompressed size recorded in
   `bundle.json`; **clock sanity**, because drift breaks proxy TLS and Hub JWT
   with errors that never mention time; part checksums; `airgap.sh verify`.
2. Load images, streamed.
3. **Sync the tree**: tar the current tree into `backups/` first, then rsync
   with hard exclusions — `.env.*`, `secrets/`, `unified/custom/`,
   `unified/instances/`, `.deploy-state/`. Never `git reset --hard`, never a
   bare `cp -r`: both have already clobbered untracked state on these hosts.
   Write `AIRGAP_VERSION`.
4. **Seed the assets — on every deploy, not only the first.** Grafana plugins
   into the `grafana-data` volume under `plugins/` (there is no separate
   plugins volume; `GF_PLUGINS_PREINSTALL_SYNC` installs into
   `/var/lib/grafana`), CDN packages into `cdn-server-storage` and
   `cdn-cache-storage`, each via an ephemeral container mounting the volume.
   **The volume names are runtime-dependent, and are not the `<stack>_<volume>`
   default**: the swarm overlays pin an explicit `name: ${ENV}-<volume>`
   (`runtime/swarm/monitoring.yml:219`, `core.yml:184-188`), so the real volume
   is `prod-grafana-data`; compose declares no name and takes the
   `<project>_<volume>` default. Seeding the wrong name silently creates an
   unused volume and leaves Grafana unable to boot. Idempotent, and replayed
   whenever a bump to `GRAFANA_DATABRIDGE_PLUGIN` would otherwise send Grafana
   looking for a new version it cannot reach.
5. `deploy.sh --airgap …`, with the edition, runtime and groups read back from
   `bundle.json` so the deploy matches what was bundled; each is overridable on
   the command line for the rare site that narrows its footprint.

`install.sh` exposes **no `--down`**: `deploy.sh --down` destroys
`caddy_data`, hence the CA, hence every workstation that had trusted the
certificate.

Rollback is replaying the previous bundle's `install.sh`; the previous bundle
therefore stays on site. Data volumes are never touched — `docker stack rm`
does not remove them.

## Verification

The bench is a libvirt VM on a **genuinely isolated** network — no default
route, no DHCP (the `ho8-rehearsal` pattern). A VM that still holds a default
route will pass tests it should fail.

Two scripted scenarios:

**Cold install.** Blank VM plus bundle. Observable signals, not "the service
is up":

- every service at N/N;
- `GET /api/datasources` on Grafana **lists the DataBridge datasource**
  (proves the plugin seeding, the one that silently degrades);
- a FlowMaker box loads its definition from the CDN (proves Verdaccio is
  actually serving, not merely running);
- the Hub `/apps` endpoint returns the launchpad tiles;
- DataCatalog answers 401 without a bearer and 200 with one.

**Update N-1 → N.** Install N-1, then apply N:

- services converge;
- `.env.<env>`, `secrets/` and `unified/custom/` are byte-identical before and
  after;
- the Grafana plugin is at the new version;
- a measurement written before the update is readable after it.

Build-side tests: `verify` must fail on a bundle with one image removed;
`--list-images` must match what `--render` references (drift guard); splitting
and re-concatenating a file above the cap must reproduce its sha256.

## Known issues, not addressed here

- `seed-confighub-stack.sh:47` and `seed-confighub.sh:44` write
  `DATACATALOG_URL="https://datacatalog.${DOMAIN}"`, a hostname no deployment
  routes — only `datacatalog-api.` exists. Pre-existing, orthogonal to this
  work, worth its own fix.
- Multi-node swarm needs `load.sh` replayed per node, or the local-registry
  path: a rewrite overlay for the 15 third-party references plus a registry
  service. Documented so it is not re-discovered later.
