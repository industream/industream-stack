# Grafana Live, and how to get it back

Grafana Live is **disabled** via `GF_LIVE_MAX_CONNECTIONS=0` in
`unified/base/monitoring.yml`, set in `7250cf7` (2026-07-15). This note records why, and
what has to change before it can be switched back on.

> **Do not reach for `GF_LIVE_ENABLED`.** Grafana 13's `[live]` section has no `enabled`
> key — only `max_connections`, where `0` disables Live and `-1` means unlimited. An
> unknown setting is ignored silently, so `GF_LIVE_ENABLED=false` looks applied
> (`printenv` shows it) while Live keeps running. Verified on 13.0.1: with that variable
> set, `logger=live … "Initialized channel handler"` still appears in the logs.

## Symptom

Every browser console, on every dashboard:

```
WebSocket connection to 'wss://dashboard.<domain>/grafana/api/live/ws' failed:
  initialize @ index.mjs:1442
  _startReconnecting @ index.mjs:2912   (repeats forever)
```

`initGrafanaLive` runs at Grafana app boot unconditionally, so the loop happens
even on dashboards that stream nothing.

## Why it fails

Grafana runs behind the Hub with `[auth.jwt]`. Every request must carry the Hub
JWT, and the grafana-hub-wrapper's **service worker** injects it — because
Grafana is third-party and cannot embed `@industream/hub-auth` the way our own
apps do.

A WebSocket handshake defeats that scheme twice over:

1. **A service worker cannot intercept a WebSocket handshake.** The browser's
   `WebSocket` API also cannot set custom headers, so nothing can put the
   `Authorization: Bearer` on it.
2. **There is no session cookie to fall back on.** A cookie *would* ride the
   handshake — and `dashboard.<domain>` is same-site with the Hub, so even
   `SameSite=Lax` would be sent. But no cookie exists.

That second point is the one worth remembering, because the configuration
suggests otherwise. `GF_AUTH_JWT_ENABLE_LOGIN_TOKEN=true` is set, which is meant
to make Grafana mint `grafana_session` after validating a JWT. **It does not
fire.** Measured against Grafana 13.0.1, querying the container directly so no
proxy is involved:

```
GET http://localhost:3000/grafana/api/user
Authorization: Bearer <valid hub JWT>
→ HTTP/1.1 200 OK          (no Set-Cookie)
```

Same result through the URL-login path (`?auth_token=`) and with a browser-like
`Accept: text/html`. This is upstream **grafana/grafana#90200** — JWT login stopped
setting `grafana_session` somewhere between 10.1.10 and 10.2.8, still tagged
`triage/needs-confirmation`. The companion issue **#48846** reports the same for
`[auth.proxy]`: *"the grafana_session cookie is not set, and the
`enable_login_token` setting does not seem to have any effect"*.

Note this is the same upstream bug that makes direct Grafana deep links
impossible through the wrapper. One root cause, two visible failures.

## What does NOT fix it

- **`GF_SECURITY_COOKIE_SAMESITE=none` / `cookie_secure=true`.** Tempting, and
  wrong: there is no cookie to relax. Also unnecessary — Hub and Grafana share a
  registrable domain, so they are same-site already.
- **Traefik `forwardAuth` on the live route.** It can inject a header
  server-side, but it first has to identify the caller from what the browser
  sends spontaneously on a handshake — i.e. a cookie. Same dead end.
- **`?auth_token=` on the WS URL.** It would work, and it puts a JWT in a URL
  (logs, history, referrers). The Hub deliberately strips `auth_token` from
  mirrored routes for exactly that reason. Don't reintroduce it here.

## The way back: front Grafana with oauth2-proxy

Stop making the browser carry the credential. Let a proxy hold the session and
inject the identity server-side.

The pieces are already deployed — `logto`, `oauth2-proxy` (v7.15.3), and a
Traefik middleware `prod-oauth-auth` emitting `X-Auth-Request-Email`,
`X-Auth-Request-User`, `X-Auth-Request-Preferred-Username`. Today they protect
only filebrowser (`unified/base/auth.yml`).

Sketch:

1. Attach the `prod-oauth-auth` forwardAuth middleware to the Grafana routers,
   including `prod-grafana-live-*`.
2. Switch Grafana from `auth.jwt` to `[auth.proxy]`:
   `enabled=true`, `header_name=X-Auth-Request-Preferred-Username`,
   `header_property=username`, `auto_sign_up=true`, and a `headers` mapping for
   email.
3. Drop the JWT plumbing that becomes redundant (`GF_AUTH_JWT_*`), and stop the
   wrapper from injecting a Bearer into Grafana requests.
4. Raise `GF_LIVE_MAX_CONNECTIONS` back to a real value (`100` is the Grafana default).

Why it works: oauth2-proxy keeps its session in a **cookie**, cookies ride
WebSocket handshakes, and the header is added by Traefik rather than by the
page. `#90200` becomes irrelevant — we no longer need Grafana to mint anything.
It also generalises: the same middleware is the planned path for MinIO,
Prometheus and Alertmanager.

**Cost, honestly.** This is not a flag flip; budget half a day with testing. The
non-obvious part is **role mapping**: today `GF_AUTH_JWT_ROLE_ATTRIBUTE_PATH`
derives Admin/Editor from the roles claim in the Hub JWT. oauth2-proxy does not
forward roles by default, so Admin/Editor has to come from somewhere else —
either oauth2-proxy passing a groups header from Logto, or Grafana's
`[auth.proxy] headers` plus an org/role mapping. Get that wrong and everyone
lands as Viewer, or worse, as Admin.

## Meanwhile

Nothing user-facing is lost. Dashboard **auto-refresh is unaffected** — it
re-runs the panel queries over plain HTTP, which the service worker signs
normally. Grafana Live only matters for genuinely pushed data (`/api/live/push`,
streaming data sources, live alert state). Ask whether a client needs *pushed*
data before spending the half day; periodic refresh covers most industrial
dashboards.

## References

- grafana/grafana#90200 — JWT URL login no longer sets `grafana_session`
- grafana/grafana#48846 — same for `auth.proxy`; `enable_login_token` has no effect
- https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-authentication/jwt/
