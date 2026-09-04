# Isolated-VM bench

This is the bench that proves the offline airgap bundle (built by
`unified/scripts/airgap.sh prepare`, installed by a bundle's `install.sh`)
actually works end to end, on a machine with genuinely no internet — not
just under the mocked `docker` stubs the rest of `tests/airgap/` uses.

**Status as of 2026-09-04: apparatus only, not yet run.** There is currently
no VM on this workstation sized and network-placed to run either scenario
below. Nothing here has touched Docker, Swarm, or any VM. See "What has and
hasn't been executed" at the end of this file.

---

## The isolated network

`ho8-airgap` already exists as a libvirt network on this workstation:
`10.20.154.0/24`, bridge `virbr-ho8`. Verify with:

```bash
virsh -c qemu:///system net-dumpxml ho8-airgap
```

Its XML has **no `<forward>` element and no `<dhcp>` block** — no NAT, no
route out, no DHCP leases. That is what makes it genuinely airgapped: a
guest on it has no path to the internet, but the host still reaches guests
directly over `virbr-ho8` (`10.20.154.1`), so SSH from the workstation to the
bench VM works while the internet does not.

Reuse this network. **Do not define a new one, and do not reconfigure this
one** — `ho8-rehearsal` is already attached to it and carries unrelated
rehearsal state that must not be disturbed.

---

## What the bench VM needs

Neither existing VM on this workstation serves as the bench as-is:

| VM                    | Network                          | Free disk on `/` | Why it doesn't work |
|-----------------------|-----------------------------------|-------------------|----------------------|
| `industream-cli-test` | `default` (NAT — has internet)    | ~3.3 GB            | Has internet (defeats the point), too small, and `/var/lib/docker` + `/var/lib/containerd` share that same 3.3 GB filesystem while already running 5 stacks incl. a 54-service `industream-prod`. |
| `ho8-rehearsal`       | `ho8-airgap` (correct network)     | unknown, not sized for this | Carries HO8 compose/Portainer rehearsal state worth preserving — do not repurpose it. |

So the bench needs **its own VM** (either newly built, or `industream-cli-test`
grown and re-homed — that is an infrastructure decision for whoever owns
these VMs, not something this task performs):

- **Attached to `ho8-airgap`**, not `default`. Confirm after boot that the
  guest has no default route (`ip route` shows nothing via a gateway) —
  a VM that still holds one from a previous NAT interface passes tests it
  should fail.
- **A static address in `10.20.154.0/24`.** There is no DHCP on this
  network. `.20` is HO8's; use **`.30`**.
- **~50 GB free**, checked on **both** `/var/lib/containerd` and
  `/var/lib/docker` — on Docker 29 the former holds the actual image
  content (22 GB vs 4 KB measured on a real delivery) and checking only the
  latter is how a machine froze mid-install. If they're on the same
  filesystem, that filesystem alone needs the full ~50 GB.
- Docker + swarm mode active, otherwise blank — the whole point is that
  `install.sh`'s own preflight (docker present, swarm active, disk on both
  paths, clock, `airgap.sh verify`) is what validates the machine, not a
  hand-prepared one.

---

## Scenario 1: cold install

On the blank bench VM, with a bundle copied over (scp, or a mounted image —
anything that doesn't require internet):

```bash
cd ~/industream-airgap-<commit>-ee-swarm
./install.sh --target ~/industream-platform --stack industream-prod --yes
```

Then, from the workstation (or on the VM itself if `docker`/`curl` are
available there):

```bash
tests/airgap/bench/check-signals.sh bench.<domain> industream-prod
```

Expected: every signal ✓ (see "Getting a bearer token" below — two of the
six need one). **Any ✗ is a bundle defect.** Fix it in `airgap.sh` or
`airgap-install.sh`, rebuild the bundle, copy it over again, and re-run.
**Never fix it by hand on the VM** — a hand-fixed VM proves nothing about
the bundle; the next real customer install would still ship broken.

---

## Scenario 2: update

On the same VM, after scenario 1 has converged:

1. Install bundle **N-1** (if scenario 1 didn't already leave it there).
2. Write a measurement through DataBridge (any value that round-trips
   through the platform's normal ingestion path — not a direct DB insert).
3. Snapshot `.env.<env>`, `secrets/`, and `unified/custom/` under the
   existing install (`tar` or `cp -a` to a scratch path outside `--target`).
4. Apply bundle **N**:
   ```bash
   ./install.sh --target ~/industream-platform --stack industream-prod
   ```
5. Verify:
   - Services reconverge (`check-signals.sh` again).
   - `diff -r` the pre-update snapshot of `.env.<env>`, `secrets/`, and
     `unified/custom/` against the post-update tree — byte-identical.
   - The Grafana plugin directory reports the new `GRAFANA_DATABRIDGE_PLUGIN`
     version (bundle N's `versions.env`).
   - The measurement written before the update is still readable through
     DataBridge/Grafana after it.

Same rule: any defect gets fixed in the bundle scripts, not patched on the
VM, then re-run from a fresh bundle N.

---

## Getting a bearer token

Two of the six `check-signals.sh` checks — Grafana's datasource list and
DataCatalog's authenticated response — need a Hub-issued JWT. Grafana runs
with `GF_AUTH_ANONYMOUS_ENABLED=false` and `GF_AUTH_BASIC_ENABLED=false`, and
DataCatalog's public frontend port (`:8002`) is, per
`unified/base/datacatalog.yml`, "ALWAYS JWT-protected" regardless of
`DATACATALOG_AUTH_ENABLED`. Both validate the same Hub JWT against the same
JWKS (`industream-hub-backend`'s `/auth/jwks`), so one token covers both
checks.

There is no headless way to mint this token — the Hub only issues it through
a real OIDC browser login. To get one:

1. Log into the Hub at `https://<domain>/` as the bootstrap admin
   (`secrets/<env>/hub_backend_admin_user` / `..._admin_password` on the
   installed tree).
2. Open the browser's devtools Network tab, find any authenticated XHR to
   `/api/uifusion/...` or `/grafana/...`, and copy the `Authorization:
   Bearer <token>` request header value (just the token, not the `Bearer `
   prefix).
3. Export it before running the checks:
   ```bash
   export HUB_BEARER_TOKEN='<token>'
   tests/airgap/bench/check-signals.sh bench.<domain> industream-prod
   ```

Without `HUB_BEARER_TOKEN` set, those two checks fail loudly with this same
instruction rather than being silently skipped — a bundle that shipped a
broken plugin and one nobody bothered to verify must not look the same from
the outside.

---

## 🔴 The CDN-harvest gap — read this before trusting a green bench

**The single most consequential untested path in this whole project is the
"CDN copy succeeds and yields real packages" case.** `airgap.sh prepare`
harvests FlowMaker's box definitions from a warmed, already-used
`cdn-server` (Verdaccio) instance via `docker cp` (optionally through
`--harvest-from` against a remote Docker context). **This path has never
actually been exercised** — no warmed instance was available while tasks
1-10 were built. Only the *other* path is proven: an empty cache correctly
makes `prepare` `die` with `CDN cache is empty — harvest from a warmed
instance...` rather than silently shipping nothing.

If the bench VM's install is verified against a bundle built from a build
machine that was never pointed at a live platform, `check-signals.sh`'s CDN
check will legitimately fail (empty cache, correctly caught) — that is
`prepare` working as designed, not a bench pass. To actually validate the
harvest-succeeds path, `--harvest-from` needs to point at a genuinely warmed
source: `industream-cli-test` on this workstation runs `industream-prod`
with populated `prod-cdn-server-storage` / `prod-cdn-cache-storage` volumes
(and has internet, which the harvest step needs) — or a colleague's demo
instance, from before any cutover. Until this has been run once with real
output inspected, treat the harvest step itself as unverified: **an empty
CDN cache ships FlowMaker boxes with no definitions, and on a real delivery
this surfaced far from its actual cause.**

---

## What has and hasn't been executed

- **Executed:** nothing against a live platform. `check-signals.sh` was
  syntax-checked (`bash -n`) and exercised against fake `docker`/`curl`
  stubs covering every branch — pass, each individual ✗ with its reason,
  the missing-`HUB_BEARER_TOKEN` path, a connection failure (curl's own
  `000`), and an under-replicated service being named rather than just
  reported as "something failed". That confirms the script's control flow
  and diagnostics are sound; it does not confirm the checks are correct
  against a real deployment, which only running scenario 1 can do.
- **Not executed:** scenario 1 (cold install) and scenario 2 (update) — no
  VM on this workstation currently meets the requirements above (see the
  table). Building or re-homing one is an infrastructure decision, not made
  here; no VM, network, or Docker state was started, stopped, or
  reconfigured while writing this bench.
- **Not executed, separately:** the CDN-harvest-succeeds path (see the
  section above) — this needs a warmed source regardless of which VM
  ends up hosting the bench.

## Recording results

Once scenario 1 has actually run, append to `docs/runbook/airgap.md`
(pointer left there): bundle size, uncompressed size, install duration, and
disk actually consumed on `/var/lib/containerd` — these are what size a
customer's VM. Do not fill these in from estimates.
