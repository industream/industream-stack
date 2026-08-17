# Release notes — August 2026

Grafana authentication becomes an EE differentiator, plus three deployment
defects that broke fresh installs.

Read the **Upgrading** section before deploying to an existing server: two
changes alter behaviour on a running installation.

---

## Grafana SSO in Enterprise Edition

Grafana is now an OIDC client of Logto in EE (`generic_oauth`). One sign-in for
the Hub and Grafana, real single sign-on.

**CE is unchanged and keeps a separate Grafana login.** SSO requires an identity
provider, and Logto is EE-only — the `auth` group is refused outside EE. The
double login in CE is deliberate: it is the visible difference between editions.

One image serves both. `base/ee.yml` sets `INDUSTREAM_OIDC_ORIGIN`, the wrapper's
entrypoint substitutes it, and the page turns it into `IS_OIDC_EDITION`. Nothing
OIDC-specific runs when it is absent.

What this unlocks in EE: user switching in the Hub now swaps Grafana's identity
without a manual refresh, and Grafana Live works again (`max_connections` 0 → 100
on swarm).

### Security hardening that came with it

- Certificate verification is no longer disabled on the token exchange and
  userinfo call. Those now use the internal `http://logto:3001` endpoints;
  only `auth_url`, which the browser follows, stays public.
- The client secret is generated per install and delivered by file. It was a
  committed literal derivable from the public `client_id`, identical everywhere.
- PKCE is enabled.
- The default Grafana role is `Viewer`. It was `Editor` for everyone.

## Fixes

**Fresh EE installs could not log in to Grafana.** `seed_ee` aligns Logto's client
secret with the one Grafana presents, but the statement was passed through
`psql -c`, which does **not** perform `:'var'` interpolation — Postgres rejected
it. The step failed on every new install and login died with an opaque
`invalid_client`.

**A truncated plugin download silently produced a dead datasource.** Plugins are
now installed with `GF_PLUGINS_PREINSTALL_SYNC`, before startup, and a failed
install aborts the boot. The deprecated `GF_INSTALL_PLUGINS` only warned: a
partial download left a 22 MB fragment of the 25.8 MB DataBridge binary in the
volume, the plugin segfaulted on every load, and Grafana reported only
"Could not load plugin". The same install had also silently dropped
`yesoreyeram-infinity-datasource`.

**Bumping a version had no effect.** `deploy.sh` sources the *bundle* for image
refs, not `versions.env`. The bundle had drifted, so a freshly released
`grafana-hub-wrapper 1.2.0` still deployed as `1.0.4`. The bundle is re-rendered;
**a release is not finished until `render-bundles.sh` has run.**

**IronStream services never started.** The group definitions probed port 8080
while the .NET images listen on 9501, passed the database password as an
environment variable instead of injecting it from a mounted secret, and used
healthchecks that assume `bash` in images that ship only `wget`.

## Upgrading an existing installation

**A new hostname must resolve on every client machine.** In EE the browser is
redirected to Logto, so `auth.<domain>` has to resolve *for the client*, not just
on the server. A wildcard DNS record covers it; explicit records and
`/etc/hosts` do not unless you add it. When it is missing, the Hub login fails
with a bare `Failed to fetch` that points at nothing. See `DNS-SETUP.md`.

**Grafana fails to start if a plugin cannot be installed.** This is intentional —
a Grafana without its datasource plugin is not usefully up — but on a flaky link
the first boot may now fail where it previously started half-broken.

**Existing EE Grafana accounts.** Users created under `auth.jwt` have
`login = sub` (a Logto user id), which will not match the `username` the OIDC
mapping produces. Expect one "identity mismatch → sign out → re-authenticate"
cycle per user on first load, after which it settles. There is **no migration
script**.

**Escape hatch.** `auth.jwt` is one variable away:
`GF_AUTH_GENERIC_OAUTH_ENABLED=false` + `GF_AUTH_JWT_ENABLED=true`. Keep it in
mind until EE is stable in the field.

## Known gaps

- The Portainer render omits the Grafana blocks entirely — the generator applies
  `base/ee.yml` to the `core` group only, where `grafana` is an image-less stub
  that the orphan-fragment filter drops. Deploy through `deploy.sh` or
  `industream install`, not the Portainer artifacts, for EE Grafana.
- Nothing verifies generated artifacts against their source. The stale bundle
  above and the Portainer render are the same class of defect.
- The Service Worker still injects the Hub JWT as a `Bearer` header on EE. It is
  inert — Grafana authenticates from its session cookie — but it writes the token
  into nginx and Grafana logs.
- The CE path of wrapper 1.2.0 has been reasoned about and unit-tested, **not**
  exercised in a browser. EE has been validated end to end on a fresh install.
