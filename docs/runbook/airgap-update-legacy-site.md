# Updating a Legacy Air-Gapped Site

Step-by-step for the delivery this feature was built for: a customer site
running an **older platform version, installed before airgap bundles
existed**, being brought up to a current bundle with **no internet at either
end**.

This is the harder of the two paths. A fresh install has nothing to lose; an
update runs against a tree full of state nobody wrote down — the site's
`.env`, its secrets, its TLS material, whatever an engineer edited on site at
2am. Every step below therefore pairs an action with **a signal you can
observe**, because "the script exited 0" is not evidence that the site kept
its data.

For the general reference — bundle layout, flags, rollback, the never-do-this
list — see [`airgap.md`](airgap.md). This document is the delivery script.

---

## What makes a site "legacy" here

Exactly one thing: `$TARGET/AIRGAP_TREE_MANIFEST` does not exist. That file
is how `install.sh` knows which files a *bundle* put on the site versus which
files the *site* put there itself. Without it, the installer cannot tell them
apart — and it will not guess.

Check before you plan anything:

```bash
ls -l /opt/industream-platform/AIRGAP_VERSION /opt/industream-platform/AIRGAP_TREE_MANIFEST
```

| What you see | What it means |
|---|---|
| Neither file | Legacy site. This document. |
| Both files | The site was installed by a bundle; use [`airgap.md` §4](airgap.md) instead. |
| `AIRGAP_VERSION` only | Installed by an early bundle. Treat as legacy — same procedure. |

**Consequence of being legacy, stated plainly:** on this first update,
`install.sh` deletes **nothing**. It prints a warning saying so and writes
the manifest. Stale files a previous version left behind — a group overlay
for a group that no longer exists, say — stay on disk this once, and
`deploy.sh`'s `-f base/*.yml` glob can still pick them up. The **next**
update prunes normally. The gap is one update wide. If you know of a
specific stale file, remove it by hand after the update, not before.

---

## Before you leave for the site

### 1. Build the bundle from a clean tree

`prepare` refuses a dirty working tree on purpose: what ships must be what
was tested.

```bash
cd unified
./scripts/airgap.sh prepare --runtime swarm --edition ee --env prod --out /media/usb
```

→ **verify:** the command exits 0 and prints a bundle path. A build that
stops with `✗ CDN cache is empty` is doing its job — see
[`airgap.md`](airgap.md#the-cdn-harvest-needs-a-warmed-connected-instance);
harvest from a warmed instance rather than shipping an empty cache.

### 2. Verify the bundle on the machine that built it

```bash
./scripts/airgap.sh verify /media/usb/industream-airgap-<commit>-ee-swarm
```

→ **verify:** exits 0. This re-checks every checksum and replays
`deploy.sh --list-images` against the bundle's own tree, so a group added
after the build is caught here rather than on site.

### 3. Know what the site is running before you touch it

You cannot diff against a state you never recorded. On the site, **before**
the update:

```bash
cd /opt/industream-platform
docker stack services industream-prod --format '{{.Name}} {{.Replicas}}' | sort > /tmp/before-services.txt
find unified/base/certs secrets unified/custom unified/instances -type f 2>/dev/null | sort > /tmp/before-state.txt
sha256sum $(cat /tmp/before-state.txt) > /tmp/before-state.sha256 2>/dev/null
ls unified/.env.* 2>/dev/null
```

→ **verify:** `/tmp/before-state.sha256` is non-empty. These three files are
what turns step 6 from a hope into a check. Copy them somewhere off the
machine too.

### The reverse proxy is not in the bundle — check it is there

On swarm the platform routes through **Traefik**, deployed once as a separate
shared stack (`scripts/deploy-traefik.sh`, stack name `traefik-shared`) and
reached over an **external** network the platform's compose files declare by
an exact name:

```yaml
traefik-public:
  external: true
  name: traefik-shared_traefik-public
```

The bundle ships no Traefik image and the update never touches the proxy or
its certificates — which is good, and also means nothing in `install.sh`
preflights any of this. If the network is missing or named differently,
`docker stack deploy` fails at the very last step, after everything else has
already been done.

```bash
docker network ls | grep traefik-shared_traefik-public
docker stack services traefik-shared
docker image ls | grep -i traefik
```

→ **verify:** the network exists under that exact name, the stack has running
services, and the image is present locally. The third one matters offline: if
that container ever has to be recreated on site, the image cannot be pulled.

(Compose sites run Caddy outside the platform project in the same way; the
same three checks apply, against the Caddy container.)

---

## On site

### 4. Copy the bundle across

Copy the bundle **directory as-is**. No re-compression, no reassembly. Parts
are sized to stay under FAT32's 4 GiB per-file limit and are streamed
straight into `docker load` — never joined back together on disk.

→ **verify:** re-run `verify` on the site copy, from the bundle itself:

```bash
cd /media/usb/industream-airgap-<commit>-ee-swarm
bash install.sh --target /opt/industream-platform --stack industream-prod --no-deploy
```

Verification runs first and **hard-stops before any Docker mutation**, so a
bundle that got truncated in transit fails here, having changed nothing.

### 5. Run the update

`--no-deploy` above already synced the tree and seeded the assets. Now the
real run:

```bash
bash install.sh --target /opt/industream-platform --stack industream-prod
```

→ **verify:** the output contains the legacy warning —

```
⚠ no /opt/industream-platform/AIRGAP_TREE_MANIFEST found on an existing target — this site predates
  manifest-based pruning. Skipping stale-file removal this run…
```

Seeing it is correct on a legacy site, and it is your confirmation that
nothing was deleted. **Not** seeing it on a site you believed was legacy
means the site had a manifest and pruning ran — go check step 6 carefully.

### 6. Prove the site kept its state

This is the step that matters, and the one people skip.

```bash
cd /opt/industream-platform
sha256sum -c /tmp/before-state.sha256
```

→ **verify:** every line reads `OK`. A single `FAILED` means the update
overwrote site-local state — stop, and restore from the snapshot
`install.sh` took under `backups/` before it touched anything:

```bash
ls -t backups/tree-*.tar.gz | head -1
```

Also confirm the bookkeeping now exists, so the *next* update can prune:

```bash
ls -l AIRGAP_VERSION AIRGAP_TREE_MANIFEST
tr '\0' '\n' < AIRGAP_TREE_MANIFEST | wc -l
```

→ **verify:** `AIRGAP_TREE_MANIFEST` exists and lists a few hundred paths.
It is NUL-delimited installer bookkeeping — `tr '\0' '\n'` to read it, never
a plain `cat`.

### 7. Prove the platform actually came up

```bash
docker stack services industream-prod --format '{{.Name}} {{.Replicas}}' | sort > /tmp/after-services.txt
diff /tmp/before-services.txt /tmp/after-services.txt
docker stack services industream-prod --format '{{.Replicas}}' | grep -v '^\([0-9]*\)/\1$'
```

→ **verify:** the second command prints **nothing** — every service is at
its desired replica count. Services that appear or disappear in the `diff`
should correspond to groups the new bundle added or retired; anything else is
unexplained and worth stopping for.

For a deeper check that queries real payloads rather than replica counts,
run the bench's signal script:

```bash
tests/airgap/bench/check-signals.sh <domain> industream-prod
```

It verifies Grafana lists the DataBridge datasource, the CDN actually serves
a box definition, the Hub returns launchpad tiles, and DataCatalog rejects an
anonymous request while accepting a valid bearer. Two of those need
`HUB_BEARER_TOKEN` — the script fails loudly without it rather than skipping
silently.

---

## What the second update looks like

The next bundle you install on this site behaves differently, and it is worth
knowing before it happens: the manifest now exists, so `install.sh` prunes.
It removes **only** paths the previous bundle delivered and the new one no
longer ships. It never removes a file the site created, at any path — a
site-local file was never in any manifest, so it can never be a deletion
candidate.

Expect this line instead of the legacy warning:

```
▶ pruning tree paths this bundle no longer ships
  removed N path(s) no longer shipped by this bundle
```

→ **verify:** `N` is small and explicable (retired overlays). A large `N` on
a routine update means the two bundles disagree about far more than you
expected — investigate before deploying.

---

## Things that will bite you

- **The site checkout is not a git clone.** It is `git archive` output,
  knowingly detached from `origin`. `git pull`, `git log`, `git status` on it
  are meaningless. `AIRGAP_VERSION` is the only record of what the site runs.
- **Never `git reset --hard`, never a bare `cp -r`** on the site tree. Both
  have already destroyed untracked site state on real installs.
- **Never run `scripts/uninstall.sh`.** It removes the stack, its secrets,
  every `${ENV}-*` volume — the databases — the network and the generated
  files. It asks for confirmation at each step; that is not the same as
  being safe. `install.sh` exposes no flag that reaches it.
- **Keep the previous bundle on site.** Rollback *is* replaying the previous
  bundle's `install.sh`; delete the directory and you have no rollback.
- **A Grafana plugin version bump makes the update mandatory, not optional.**
  `GF_PLUGINS_PREINSTALL_SYNC` is boot-blocking: if Grafana starts looking
  for a plugin version that was never seeded, it does not start at all.

---

## Verification status of this procedure

Stated honestly, because a runbook that overclaims is worse than none:

| Step | Status |
|---|---|
| Bundle build, verify, transport, image load | Exercised on a genuinely isolated VM (no default route, DNS dead) |
| Fresh install of the full platform | Exercised — 37 services, 35 at 1/1 |
| Tree sync preserving site state, manifest-diff pruning | Covered by `tests/airgap/test_install_sync.sh`, including the two data-loss regressions that were found the hard way |
| **The legacy-site update above (steps 5–6)** | Exercised on the isolated VM against a genuine pre-airgap tree plus 10 files of site-local state: the warning printed, nothing was pruned, all 10 files verified byte-for-byte, and the manifest was written with 279 entries |
| **The second update, with pruning active** | Exercised on the same site: `removed 1 path(s)` — the retired file and only it; the site's own file at an excluded path survived |
| The procedure against a real customer site | **Not yet run.** The bench proves the mechanics; a customer site has state no bench invents. Do steps 3 and 6 for real. |
| `check-signals.sh` | **Has never produced a verdict on any install** |
| CDN packages actually served to a FlowMaker box | **Not verified** — "the packages are in the bundle" and "the boxes resolve" are two different claims |
