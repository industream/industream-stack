# POC — Grafana `[auth.proxy]` behind oauth2-proxy: does it mint `grafana_session`, and does Grafana Live work?

**Date:** 2026-08-13
**Where:** swarm test VM `192.168.122.205`, isolated stack **`poc-grafana-oauth`** (3 services, left running)
**Images:** `grafana/grafana-oss:13.0.1`, `quay.io/oauth2-proxy/oauth2-proxy:v7.15.3` (both already on the host, nothing pulled)
**Blast radius:** zero. `industream-prod` (54 svc), `industream-eaf`, `pattern-studio`, `pattern-studio-dev`, `traefik-shared` were never updated, scaled or restarted; all still at full replicas at the end of the run. No prune, no image/volume deletion, disk unchanged at 95 %.

---

## Verdict

**Yes — and the migration premise is partly wrong in a way that makes this *easier* than expected.**

`grafana_session` **is** minted under `[auth.proxy]`, but **only on `GET /login`, and only when `enable_login_token = true`** — an option the brief's proposed config does not include and whose Grafana default is `false`. Measured cookie: `grafana_session=…; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=None`, **no `Domain` attribute** (host-only; Grafana exposes no knob to set one). With that cookie and nothing else, `GET /api/live/ws` upgrades: `HTTP/1.1 101 Switching Protocols`. Without it: `401`.

The bigger finding is that **the cookie turns out not to be the thing that unblocks Live.** Because oauth2-proxy injects the identity header *server-side* via Traefik `forwardAuth`, the WebSocket handshake carries the oauth2-proxy session cookie, the proxy authenticates it, and Grafana's auth-proxy client authenticates the upgrade request from the header alone — **`101 Switching Protocols` with the oauth2-proxy cookie only, no `grafana_session` at all.** The reason Live 401s today is not "there is no cookie", it is "a Service Worker cannot inject `Authorization` into a WS handshake". Any server-side header-injecting hop in front of Grafana fixes that. The session cookie is an optimisation (skips per-request user sync), not the mechanism.

Two configuration landmines were found and defused, both caused by Grafana parsing two adjacent settings with **different separators**: `[security] csrf_trusted_origins` is **space**-separated and `[live] allowed_origins` is **comma**-separated. Getting either wrong yields an indistinguishable `403 Forbidden` on the WS upgrade.

The unavoidable bad news is unchanged: an unauthenticated request through the chain gets a **`302` straight to `https://auth.industream.platform.lan/oidc/auth`**, including on the WebSocket path — a top-level bounce is mandatory. And **role mapping is genuinely missing**: `[auth.proxy]` has no `role_attribute_path` equivalent, it needs a header whose literal value is `Admin`/`Editor`/`Viewer` (case-sensitive), and oauth2-proxy has no mapping capability to produce one.

---

## 1. Does `grafana_session` get minted?

### 1.1 Baseline — the header authenticates, but no cookie on ordinary routes

Config at this point: `enabled=true`, `header_name=X-Auth-Request-Preferred-Username`, `header_property=username`, `auto_sign_up=true`, `enable_login_token` **not set** (Grafana default `false`).

```
### T1a: NO header (expect 401)
HTTP/2 401
cache-control: no-store
content-type: application/json; charset=UTF-8
...
{"extra":null,"message":"Unauthorized","messageId":"auth.unauthorized","statusCode":401,"traceID":""}

### T1b: WITH X-Auth-Request-Preferred-Username, enable_login_token=false
HTTP/2 200
cache-control: no-store
content-type: application/json
date: Thu, 13 Aug 2026 11:02:23 GMT
vary: Accept-Encoding
x-content-type-options: nosniff
x-xss-protection: 1; mode=block

{"id":2,"uid":"cfv1vn2hxuyo0f","email":"pocuser@industream.lan","name":"Poc User","login":"pocuser","theme":"","orgId":1,"isGrafanaAdmin":false,"isDisabled":false,"isExternal":true,"isExternallySynced":false,"isGrafanaAdminExternallySynced":false,"authLabels":["Auth Proxy"],"updatedAt":"2026-08-13T11:02:23Z","createdAt":"2026-08-13T11:02:23Z","avatarUrl":"/avatar/377c64f6a9f68c11bd02cde5153a2ab0","isProvisioned":false}
```

`auto_sign_up` works (`"authLabels":["Auth Proxy"]`, user created on the fly). **No `Set-Cookie` in the 200.** Same result on `GET /` with a full browser `Accept`/`User-Agent`, and same after flipping `enable_login_token=true` — the cookie is *not* emitted on ordinary routes either way.

### 1.2 The cookie appears at `GET /login`

```
### GET /login ###
HTTP/2 302
cache-control: no-store
content-type: text/html; charset=utf-8
date: Thu, 13 Aug 2026 11:04:26 GMT
location: /
set-cookie: grafana_session=e2e1c0c060dd604f25ca7f77383ab91c; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=None
set-cookie: grafana_session_expiry=1786619661; Path=/; Max-Age=2592000; Secure; SameSite=None
vary: Accept-Encoding
x-content-type-options: nosniff
x-xss-protection: 1; mode=block
```

### 1.3 Control — the same request with `enable_login_token=false`

```
### CONTROL: set enable_login_token=false, hit /login
HTTP/2 302
location: /
(no set-cookie line above = cookie NOT minted)
```

**So the cookie is strictly gated on `enable_login_token = true`, and is only issued by the `/login` handler.** Grafana confirms the option is live in the running instance (`GET /api/admin/settings`):

```json
"auth.proxy": {
  "auto_sign_up": "true",
  "enable_login_token": "true",
  "enabled": "true",
  "header_name": "X-Auth-Request-Preferred-Username",
  "header_property": "username",
  "headers": "Email:X-Auth-Request-Email Name:X-Auth-Request-User Role:X-Auth-Request-Role Groups:X-Auth-Request-Groups",
  "headers_encoded": "false",
  "sync_ttl": "60",
  "whitelist": ""
}
```

Upstream default confirmed in `pkg/setting/setting_auth_proxy.go`:
`authProxySettings.EnableLoginToken = authProxy.Key("enable_login_token").MustBool(false)`.
This is consistent with grafana/grafana#78602 quoted in the brief — the cookie was *narrowed* to the AuthProxy path, and within AuthProxy it is opt-in and login-route-only.

### 1.4 The cookie alone is a valid credential

```
### STEP 2: /api/user with COOKIE ONLY (no proxy header) ###
HTTP/2 200
...
{"id":2,...,"login":"pocuser",...,"authLabels":["Auth Proxy"],...}
```

### 1.5 End-to-end through a real oauth2-proxy session (not hand-forged headers)

Real oauth2-proxy session (htpasswd provider, so a genuine proxy-issued session cookie) → Traefik `forwardAuth` → `authResponseHeaders` → Grafana:

```
### FULL CHAIN (real oauth2-proxy session -> Traefik forwardAuth -> Grafana auth.proxy): GET /login
HTTP/2 302
cache-control: no-store
content-type: text/html; charset=utf-8
date: Thu, 13 Aug 2026 11:20:30 GMT
location: /
set-cookie: grafana_session=ba9c393a7d95040b63b4146f6cdfdb2f; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=None
set-cookie: grafana_session_expiry=1786620625; Path=/; Max-Age=2592000; Secure; SameSite=None

### FULL CHAIN: GET /api/user
{"id":2,"uid":"cfv1vn2hxuyo0f","email":"pocuser@industream.lan","name":"pocuser@industream.lan","login":"pocuser@industream.lan",...,"authLabels":["Auth Proxy"],...}
```

---

## 2. Cookie attributes

| Attribute | Observed | Consequence |
|---|---|---|
| Name | `grafana_session` (+ companion `grafana_session_expiry`) | as configured by `GF_AUTH_LOGIN_COOKIE_NAME` |
| `Domain` | **absent** | **host-only cookie.** Sent only to the exact Grafana host. Grafana has no `cookie_domain` setting — `pkg/setting/setting_auth_proxy.go` and the `[security]` section expose only `cookie_samesite` and `cookie_secure`. It will **never** be shared with a sibling subdomain. |
| `Path` | `/` | fine under `serve_from_sub_path` too |
| `Secure` | yes | mandatory, and required by `SameSite=None` |
| `HttpOnly` | yes on `grafana_session`; **no** on `grafana_session_expiry` | JS can read the expiry (by design, for the frontend's rotation logic) but not the token |
| `SameSite` | `None` (from `GF_SECURITY_COOKIE_SAMESITE=none`) | **this is the setting that lets it ride a cross-site request from a nested iframe.** Default in the current prod Grafana is Grafana's default `lax`, which would *not* be sent on a third-party iframe subresource. |
| `Max-Age` | `2592000` (30 d) — matches `login_maximum_lifetime_duration=30d`; inactivity cap `login_maximum_inactive_lifetime_duration=7d` | long-lived; see the logout-desync risk in `GRAFANA-OAUTH-MIGRATION-ANALYSIS.md` §F |

Verified as host-only by the curl cookie jar (`FALSE` in the *tailmatch/domain-flag* column, i.e. no domain wildcard):

```
# Netscape HTTP Cookie File
poc-grafana-raw.industream.platform.lan	FALSE	/	TRUE	1789211101	grafana_session_expiry	1786619696
#HttpOnly_poc-grafana-raw.industream.platform.lan	FALSE	/	TRUE	1789211101	grafana_session	d7d5a8c232ea6372fdc8ed32b5d5a27d
```

For contrast, oauth2-proxy **does** set a `Domain` and therefore *is* shared across the whole apex:

```
set-cookie: _poc_hp_proxy=…; Path=/; Domain=industream.platform.lan; Max-Age=604800; HttpOnly; Secure
```

Note oauth2-proxy logs `samesite:` **empty** by default — for a third-party-iframe deployment it must be set explicitly (`--cookie-samesite=none`), or the *proxy's* cookie becomes the thing that gets dropped:

```
[oauthproxy.go:186] Cookie settings: name:_poc_oauth2_proxy secure(https):true httponly:true expiry:168h0m0s domains:.industream.platform.lan path:/ samesite: refresh:disabled
```

---

## 3. Does the Live WebSocket authenticate?

`GF_LIVE_ENABLED=true`, `GF_LIVE_MAX_CONNECTIONS=100` (left at the default, not 0).

### 3.1 Cookie vs. no cookie

```
### A: WS, NO auth at all
HTTP/1.1 401 Unauthorized

### B: WS with grafana_session cookie ONLY, Origin=same host
HTTP/1.1 101 Switching Protocols
Connection: Upgrade
Sec-Websocket-Accept: rJ8zgFlcMhbnhpdx9oldI3nSjH8=
Upgrade: websocket
```

**The cookie unblocks Live.** That is the direct answer to the question the POC was built for.

### 3.2 …but the header alone also unblocks it, which changes the plan

```
### F: proxy HEADER only, no cookie
HTTP/1.1 101 Switching Protocols
```

and through the real chain:

```
### WS through FULL CHAIN, both cookies, Origin=self
HTTP/1.1 101 Switching Protocols
### WS through FULL CHAIN, grafana_session ONLY (proxy cookie missing)
HTTP/1.1 403 Forbidden          <- oauth2-proxy rejects at the edge, never reaches Grafana
### WS through FULL CHAIN, oauth2-proxy cookie ONLY (no grafana_session)
HTTP/1.1 101 Switching Protocols
```

A WebSocket handshake *is* an HTTP GET, so the browser attaches cookies to it — including oauth2-proxy's. Traefik's `forwardAuth` therefore runs on the upgrade request, oauth2-proxy validates its own session, and Traefik copies `X-Auth-Request-*` onto the upgrade before it reaches Grafana. Grafana's auth-proxy client authenticates it. **No `grafana_session` needed.** Conversely, once the request is behind `forwardAuth`, `grafana_session` alone is *not* sufficient — the edge rejects first.

### 3.3 Two `403` traps on the upgrade, both separator bugs

Initially every cross-origin upgrade returned `403`. There are two distinct gates, returning bodies of different length:

**Gate 1 — Grafana's CSRF middleware** (body: `origin not allowed`, 19 bytes). From `pkg/middleware/csrf/csrf.go`: CSRF is skipped when there is no login cookie, and the "safe methods" list is `HEAD, OPTIONS, TRACE` — **`GET` is deliberately excluded**. So the moment `grafana_session` exists, *every* cross-origin GET (including the WS upgrade) is origin-checked. The allow-list is read as:

```go
trustedOrigins := cfg.SectionWithEnvOverrides("security").Key("csrf_trusted_origins").Strings(" ")
...
origin := originURL.Hostname()   // hostname, no scheme, no port
```

**Space-separated, bare hostnames.** Comma-separated and scheme-prefixed forms both silently fail:

```
csrf_trusted_origins = "industream.platform.lan,dashboard.industream.platform.lan"   -> 403
csrf_trusted_origins = "https://industream.platform.lan"                             -> 403
csrf_trusted_origins = "industream.platform.lan dashboard.industream.platform.lan"   -> 200
```

```
GET /api/user  Origin=https://industream.platform.lan (trusted) -> 200
GET /api/user  Origin=https://evil.example.com (untrusted)     -> 403
```

**Gate 2 — Grafana Live's own origin check** (body: `Forbidden`, 10 bytes). `[live] allowed_origins` is **comma-separated** and matched against the full origin *including scheme*. Space-separated fails, and Grafana says so in the log:

```
logger=live level=warn msg="Request Origin is not authorized" origin=https://dashboard.industream.platform.lan host=poc-grafana-raw.industream.platform.lan appUrl=https://poc-grafana-raw.industream.platform.lan/ allowedOrigins="https://industream.platform.lan https://*.industream.platform.lan"
```

Note also that `https://*.industream.platform.lan` does **not** match the apex `https://industream.platform.lan` — the apex must be listed separately.

With `GF_LIVE_ALLOWED_ORIGINS=https://industream.platform.lan,https://*.industream.platform.lan` and space-separated `csrf_trusted_origins`, the final matrix:

```
https://poc-grafana-raw.industream.platform.lan      -> HTTP/1.1 101 Switching Protocols
https://industream.platform.lan                      -> HTTP/1.1 101 Switching Protocols
https://dashboard.industream.platform.lan            -> HTTP/1.1 101 Switching Protocols
https://evil.example.com                             -> HTTP/1.1 403 Forbidden
```

In the real deployment the WS is opened by JS *inside* the Grafana iframe, so its `Origin` equals the Grafana origin and both gates pass trivially. These settings only matter if anything ever opens a Grafana WS from the Hub's own origin.

---

## 4. Unauthenticated behaviour

Through `poc-oauth2-proxy` (real Logto issuer `https://auth.industream.platform.lan/oidc`, `--skip-provider-button`) with Traefik `forwardAuth`:

### 4.1 Browser-like navigation → 302 to Logto

```
### Q4a: unauthenticated GET / (browser-like)
HTTP/2 302
cache-control: no-cache, no-store, must-revalidate, max-age=0
content-type: text/html; charset=utf-8
expires: Thu, 01 Jan 1970 00:00:00 UTC
location: https://auth.industream.platform.lan/oidc/auth?approval_prompt=force&client_id=poc-grafana-authproxy&redirect_uri=https%3A%2F%2Fpoc-grafana-oidc.industream.platform.lan%2Foauth2%2Fcallback&response_type=code&scope=openid+email+profile&state=1OcF2iWwb3TJ4L_Ft9v4OCIe3QC-o3vk9NqqRY4Rzhc%3Ahttps%3A%2F%2Fpoc-grafana-oidc.industream.platform.lan%2F
set-cookie: _poc_oauth2_proxy_csrf=…; Path=/; Domain=industream.platform.lan; Max-Age=900; HttpOnly; Secure
x-accel-expires: 0
content-length: 387
```

No interstitial page — a direct cross-origin `302`. **Inside the Grafana iframe this is fatal**: it is a top-level-style navigation to `auth.industream.platform.lan`, which (a) violates the wrapper's own `frame-src 'self' <HUB_ORIGIN>` CSP (`grafana-hub-wrapper/wrapper/index.html:5`) and (b) Logto is Helmet-based with `frame-ancestors 'self'`. **A top-level bounce or popup is unavoidable**, exactly as `GRAFANA-OAUTH-MIGRATION-ANALYSIS.md` §E predicted.

### 4.2 The WebSocket path gets the same 302

```
### Q4d: unauthenticated WS handshake through oauth2-proxy chain
HTTP/1.1 302 Found
Location: https://auth.industream.platform.lan/oidc/auth?...&state=kuamJj1pNgZ0GERnJXNHHbBYgxuzD7_bSLsrw6pdoHg%3A%2Fapi%2Flive%2Fws
Set-Cookie: _poc_oauth2_proxy_csrf=…; Path=/; Domain=industream.platform.lan; Max-Age=900; HttpOnly; Secure
```

A `WebSocket` client cannot follow a redirect — the browser surfaces this as a generic connection failure with no diagnostic. Worth an explicit `--skip-auth-route` or a clean 401 for `/api/live/ws` so the frontend can distinguish "session expired" from "server down".

### 4.3 XHR-style requests get a clean 401, not a redirect

```
### Q4c: unauthenticated XHR-style GET /api/user (Accept: application/json)
HTTP/2 401
content-type: application/json
content-length: 2
```

oauth2-proxy content-negotiates: `Accept: application/json` → `401 {}`. Useful — in-iframe API calls fail loudly instead of chasing an opaque redirect, so the wrapper can detect expiry and trigger the top-level bounce itself.

### 4.4 Logto is capable of what is needed

```json
{
 "issuer": "https://auth.industream.platform.lan/oidc",
 "authorization_endpoint": "https://auth.industream.platform.lan/oidc/auth",
 "token_endpoint": "https://auth.industream.platform.lan/oidc/token",
 "userinfo_endpoint": "https://auth.industream.platform.lan/oidc/me",
 "end_session_endpoint": "https://auth.industream.platform.lan/oidc/session/end",
 "scopes_supported": ["openid","offline_access","profile","email","phone","address","custom_data","identities","roles","urn:logto:scope:organizations","urn:logto:scope:organization_roles","urn:logto:scope:sessions"],
 "claims_supported": ["sub","name","family_name","given_name","middle_name","nickname","preferred_username",...,"roles","organizations","organization_data","organization_roles","sid","auth_time","iss"]
}
```

`roles` is both a supported scope and a supported claim, and `end_session_endpoint` exists (needed for logout sync).

---

## 5. Roles — what oauth2-proxy actually forwards, and why it is not enough

### 5.1 oauth2-proxy forwards far less than the config suggests

Raw `forwardAuth` response from oauth2-proxy with `--set-xauthrequest=true` and a valid session, dumped from inside the overlay network:

```
### raw forwardAuth response headers from oauth2-proxy:
HTTP/1.1 202 Accepted
Gap-Auth: pocuser@industream.lan
X-Auth-Request-User: pocuser@industream.lan
Date: Thu, 13 Aug 2026 11:16:16 GMT
Content-Length: 13
Content-Type: text/plain; charset=utf-8
Connection: close
```

Only `X-Auth-Request-User`. **`X-Auth-Request-Preferred-Username` was not emitted at all** — oauth2-proxy only sets it when the session's `PreferredUsername` is non-empty, which comes from the IdP's `preferred_username` claim. Listing a header in Traefik's `authResponseHeaders` does not conjure it.

Consequence, measured: with the brief's `header_name=X-Auth-Request-Preferred-Username`, the *whole working chain* returns 401 because the header is simply absent:

```
### FULL CHAIN: GET /api/user
{"extra":null,"message":"Unauthorized","messageId":"auth.unauthorized","statusCode":401,"traceID":""}
```

Switching to `header_name=X-Auth-Request-User` fixed it immediately (§1.5). **In Logto, `preferred_username` is only present if the user has a `username` set** — so `X-Auth-Request-Preferred-Username` is a fragile choice unless Logto user provisioning guarantees it. Use `X-Auth-Request-User`, or pin the claim explicitly with `--oidc-email-claim` / `--user-id-claim`.

### 5.2 Grafana's role mapping works — but needs a literal role string

`[auth.proxy] headers = "… Role:X-Auth-Request-Role …"`, measured against `GET /api/org/users`:

```
Role header Admin          -> Admin
Role header Editor         -> Editor
Role header Viewer         -> Viewer
Role header GrafanaAdmin   -> Viewer
Role header bogus-role     -> Viewer
Role header NONE           -> Viewer
Role header admin          -> Viewer
Role header ADMIN          -> Viewer
Role header editor         -> Viewer
```

**Case-sensitive, exact match on `Admin`/`Editor`/`Viewer`. Everything else silently degrades to `Viewer`** — no error, no log. `GrafanaAdmin` (server admin) is not reachable this way.

### 5.3 What is missing

`pkg/setting/setting_auth_proxy.go` is the complete surface:

```go
type AuthProxySettings struct {
	Enabled          bool
	HeaderName       string
	HeaderProperty   string
	AutoSignUp       bool
	EnableLoginToken bool
	Whitelist        string
	Headers          map[string]string
	HeadersEncoded   bool
	SyncTTL          int
}
```

There is **no `role_attribute_path`** — the JMESPath expression the platform relies on today (`GF_AUTH_JWT_ROLE_ATTRIBUTE_PATH=contains(roles, 'admin') && 'Admin' || 'Editor'`) has **no equivalent under `auth.proxy`**. And oauth2-proxy has no mapping/expression engine either: its alpha `injectResponseHeaders` can forward a claim verbatim, but cannot turn `["admin"]` into `Admin`.

So closing the role gap requires one of:
1. Logto emits a custom claim whose literal value is already `Admin`/`Editor`/`Viewer` (custom_data or a naming convention on roles) — cheapest, but couples Logto's role vocabulary to Grafana's;
2. a tiny header-rewriting middleware between oauth2-proxy and Grafana (Traefik plugin or a sidecar) — the honest fix, and reusable for other apps;
3. accept everyone as `Viewer` and manage roles inside Grafana — regression vs. today.

Also note `pkg/services/authn/clients/proxy.go` caches the synced user with a key derived from the header values (`sync_ttl`, default 15 min), and `Groups` is only consumed for Enterprise team sync when `IDUseExternalGroupsForGroupsClaim` is set — it does **not** feed org roles.

### 5.4 Security: the `whitelist` is not optional

With `[auth.proxy] whitelist` empty (the default, and what the brief implies), **any client that can reach Grafana can spoof the identity header and become any user**. Demonstrated throughout this POC — every §1–§3 test authenticated by simply setting the header from curl.

```
### set whitelist to a WRONG CIDR (203.0.113.0/24)
raw router, spoofed header, wrong whitelist -> 401

### whitelist=10.0.2.0/24 (Traefik overlay)
raw router, header, whitelist=10.0.2.0/24 (Traefik overlay) -> 200
```

Traefik's address on `traefik-shared_traefik-public` is `10.0.2.117`; Grafana's is `10.0.2.175`.

**This is a live risk for the real migration**, because prod Grafana currently has a second router that would bypass `forwardAuth` entirely:

```
traefik.http.routers.prod-grafana-live-secure.rule = Host(`dashboard.industream.platform.lan`) && PathPrefix(`/grafana/api/live`)
traefik.http.routers.prod-grafana-live-secure.middlewares = allow-iframe@file
```

If `auth.proxy` is switched on without setting `whitelist`, and any router reaches Grafana without the oauth2-proxy middleware, that is a full authentication bypass. `whitelist` must be pinned to the Traefik overlay CIDR **and** every router must carry the forwardAuth middleware.

---

## What could NOT be tested here

- **Real browser cookie behaviour.** Everything above is curl. `SameSite=None; Secure` is necessary but not sufficient in 2026 — Chrome's third-party cookie restrictions and **storage partitioning (CHIPS)** may still drop a host-only cookie for `dashboard.industream.platform.lan` inside an iframe embedded by `industream.platform.lan`. If it is dropped, the `grafana_session` half is lost — but per §3.2 Live still works via oauth2-proxy's own cookie, which *is* domain-scoped to `.industream.platform.lan` and therefore also third-party in that context. **Both cookies need a real Chrome/Firefox test in a nested iframe.** This is the single largest remaining unknown.
- **A completed Logto login.** The Logto app `poc-grafana-authproxy` does not exist; the only registered oauth2-proxy redirect URI on this tenant is `https://filebrowser.industream.platform.lan/oauth2/callback` (`pass show industream/logto/filebrowser-oidc`), and I had no Logto admin credentials and deliberately did not modify prod Logto data. So §4 proves the **authorization request** (the `302` and its exact `Location`) but not the callback, the token exchange, or the real claim contents. The end-to-end session in §1.5/§3.2 used oauth2-proxy's **htpasswd** provider instead — a genuine oauth2-proxy session and genuine `forwardAuth` header injection, but with a local credential store rather than Logto. To finish: register `https://poc-grafana-oidc.industream.platform.lan/oauth2/callback` as a redirect URI on a Logto app and re-run §4.
- **Which claims Logto actually emits.** `roles` is advertised in discovery, but per `installation-EE.md:250-258` granting the `roles` user scope on the application is a manual console step no seeder performs. Unverified here.
- **Logout / session desync.** Not exercised. The 30-day `grafana_session` makes the §F risk in `GRAFANA-OAUTH-MIGRATION-ANALYSIS.md` real: signing out of the Hub does not invalidate it.
- **Grafana behind `serve_from_sub_path`.** The POC served Grafana at `/`; prod uses `root_url=…/grafana/` + `serve_from_sub_path=true`. The oauth2-proxy `/oauth2/*` routes and the `/login` cookie-minting route both need re-checking under the sub-path.
- **Concurrency / `max_connections`.** Single-client tests only.

---

## Teardown

```bash
ssh cdm@192.168.122.205 'docker stack rm poc-grafana-oauth'
```

That removes the 3 services, the router/middleware labels and the `poc_htpasswd` config. Then, to remove the leftovers (swarm does not delete volumes with the stack):

```bash
ssh cdm@192.168.122.205 'docker volume rm poc-grafana-oauth_poc-grafana-data; rm -rf /home/cdm/poc-grafana-oauth'
```

Nothing else was created. No prod secret, service, volume or image was touched; `industream-prod`, `industream-eaf`, `pattern-studio*` and `traefik-shared` are untouched.

**Stack currently left RUNNING.** Reachable only via `curl --resolve …:443:127.0.0.1` from the VM (no DNS records exist for these hostnames):
`poc-grafana-raw.industream.platform.lan` (no auth middleware), `poc-grafana-oidc.…` (oauth2-proxy → Logto), `poc-grafana-hp.…` (oauth2-proxy htpasswd, `pocuser@industream.lan` / `pocpass123`). Grafana admin `admin` / `pocadmin123` — POC-only credentials, basic auth was enabled purely to query the admin API.

---

## What this implies for the migration estimate

**It gets cheaper, and the shape of the work changes.**

1. **Scope collapses if Live is the only goal.** Per §3.2, Live does not need `grafana_session` — it needs a server-side header-injecting hop. That is `auth.proxy` + oauth2-proxy + `forwardAuth`, i.e. `unified/base/auth.yml` (already written on `feature/ironstream-integration`) plus ~15 Grafana env vars, plus removing `GF_LIVE_ENABLED=false` and `GF_LIVE_MAX_CONNECTIONS=0` (`unified/base/monitoring.yml:93`). **This is Option 1 in `GRAFANA-OAUTH-MIGRATION-ANALYSIS.md` — "keep the Hub JWT, fix Live only" — and it is now a ~1 day config change for EE, not a 3–6 day migration.** It does not touch the Hub JWT invariant for the other apps.
2. **The iframe redirect problem is confirmed and unchanged.** §4.1: a hard `302` to Logto on every unauthenticated request. Budget the **1.5–2 days for the top-level bounce / wrapper redesign** unchanged — this is still the single largest line item and it lands in `grafana-hub-wrapper`.
3. **Add ~0.5–1 day for role mapping that the original estimate priced at 0.5 d.** §5.3: there is no `role_attribute_path` under `auth.proxy`, so it is not a config line — it is either a Logto claim-vocabulary decision or a new header-rewriting middleware. The 0.5 d "role mapping + Logto scope seeding" line is optimistic; call it 1 d, and it may need a design decision first.
4. **Add ~0.5 day of hardening that was not in the estimate at all.** `[auth.proxy] whitelist` pinned to the Traefik CIDR, audit of every Grafana router for a missing forwardAuth middleware (§5.4 — the `prod-grafana-live-secure` router is a concrete instance), and `--cookie-samesite=none` on oauth2-proxy.
5. **Add ~0.5 day for the browser/iframe cookie spike.** The untestable-here question in §"could NOT be tested". If third-party cookies are partitioned away, oauth2-proxy's own cookie is lost too and the whole chain needs a different embedding strategy — this should be de-risked *first*, before any of the above.
6. **The logout-desync day stands, and is now worse.** A 30-day `SameSite=None` `grafana_session` plus a 7-day oauth2-proxy cookie means user B can inherit user A's Grafana session on a shared browser. Still needs a change in `industream-hub`.
7. **CE is unaffected and unchanged.** oauth2-proxy still needs an upstream OIDC provider that CE does not ship. CE keeps `auth.jwt` and keeps having no Live. The CE/EE fork is real, but under "Option 1 scoped to Live" it degrades to "EE has Live, CE does not" rather than "the two editions authenticate differently".

**Revised: ~4–5 days for EE Live-via-auth.proxy** (0.5 spike + 1 config + 2 wrapper + 1 roles + 0.5 hardening), of which the wrapper redesign is the irreducible core and the spike in item 5 should be done before committing to any of it.
