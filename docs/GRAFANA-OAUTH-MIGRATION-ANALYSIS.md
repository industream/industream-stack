# Grafana: `auth.jwt` → OAuth/OIDC — Feasibility Analysis

**Status:** investigation only, nothing modified, committed or deployed.
**Date:** 2026-08-13
**Scope:** replacing Grafana's `auth.jwt` provider (Hub JWT injected by the `grafana-hub-wrapper` Service Worker) with `auth.generic_oauth` (or `auth.proxy`), so Grafana holds its own `grafana_session`.

---

## Evidence base and branch caveats

Everything below is cited `file:line`. Read this table first — several claims in the original brief are branch-dependent.

| Repo | Ref used | Note |
|---|---|---|
| `industream-stack` | **`origin/main`** @ `784af49` (2026-08-13) | The **local** `main` in this clone is stale (`07c4b45`, 2026-07-07). The checked-out branch is `feature/ironstream-integration`. |
| `industream-stack` | `feature/ironstream-integration` | Only for `unified/base/auth.yml` and `unified/base/grafana.yml`, which **do not exist on `origin/main`**. |
| `industream-hub` | `feature/asset-attachments-menu` ≡ `origin/dev` for all auth code | `git diff origin/dev HEAD -- packages/industream-hub-backend packages/industream-hub-backend-enterprise packages/hub-auth` is **empty**. `git diff origin/main origin/dev -- src/modules/auth src/config src/middleware` is also **empty** → every auth claim holds on `main`, `dev` and the working tree. |
| `grafana-hub-wrapper` | `master` @ `f049adc` | |

Corrections to the brief's premises:

- The Grafana service is defined in **`unified/base/monitoring.yml`** on `origin/main` (line 33 onward) — correct as stated. `unified/base/grafana.yml` is a **branch-only split** (`feature/ironstream-integration`), not merged.
- `GF_LIVE_MAX_CONNECTIONS=0` **is** present on `origin/main` at `unified/base/monitoring.yml:93`, but is **absent** from the `feature/ironstream-integration` split (`unified/base/grafana.yml` has no such line). If that branch merges as-is, Grafana Live comes back on.
- `unified/base/auth.yml` (oauth2-proxy) is **not on `origin/main`** — it exists only on `feature/ironstream-integration`. Treat "the stack already has oauth2-proxy" as *unmerged work*, not shipped behaviour.

---

## Executive summary

**Can it be done? Partly. It splits CE and EE, and it is not a half-day job.**

1. **CE cannot be migrated. Full stop.** The Hub is **not** an OAuth2/OIDC authorization server — it has no `/authorize`, no `/token`, no `/.well-known/openid-configuration`, no client registry (§A). CE ships **no** identity provider at all: Logto is Enterprise-only and `unified/scripts/deploy.sh:98-106` *hard-errors* if you ask for the `auth` group without `--edition ee`. `oauth2-proxy` needs an upstream OIDC provider, so `auth.proxy`-behind-oauth2-proxy is equally impossible in CE. CE keeps `auth.jwt`. **The migration therefore forks CE and EE behaviour permanently, or until someone builds an authorization server into the Hub.**

2. **EE is technically possible** — Grafana can `generic_oauth` directly against Logto at `https://auth.<domain>/oidc`. Logto already runs there (`unified/base/ee.yml:52-77`) and the hub repo already ships an *unwired* label-driven Logto app seeder whose own documentation uses a Grafana `generic_oauth` callback as its worked example (`packages/industream-hub-backend-enterprise/oidc-seeds/logto/seed-logto-stack.sh:13-14`). That is the single strongest signal that this was the intended direction.

3. **But EE-direct-to-Logto breaks the platform's stated auth invariant.** `unified/auth.env:1-12` is titled *"the Hub JWT contract. THE INVARIANT. NEVER CHANGES"*, and `unified/base/monitoring.yml:11-15` records it as **DECISION #4**. Today CE and EE mint the *same* Hub JWT and Grafana/DataCatalog/FlowMaker all verify it against one JWKS. Moving Grafana to Logto means Grafana becomes the one app on the platform whose identity source differs by edition, with a different role vocabulary and a different session lifetime. That is an architectural decision, not a config change.

4. **Three hard technical risks, in descending order of severity:**
   - **The iframe redirect is blocked by the wrapper's own CSP.** `grafana-hub-wrapper/wrapper/index.html:5` sets `frame-src 'self' <HUB_ORIGIN>; child-src 'self' <HUB_ORIGIN>`. A Grafana frame navigating to `https://auth.<domain>/oidc/auth` violates it. And even without that, Logto (Helmet-based, `frame-ancestors 'self'` by default) will refuse to render inside a **doubly-nested** frame. A top-level bounce or popup is mandatory (§E).
   - **Logout desync is real and currently unmitigated at the framework level.** The Hub broadcasts `logged-out` only to windows that have registered with the auth bridge (`packages/industream-menu/src/auth/shared-worker-bridge.ts:150-156,173`); `AppFrame.svelte` never registers, never reloads and never unmounts on logout (`packages/industream-menu/src/components/frames/AppFrame.svelte:6-7,66`; `app-frame.service.ts:64-66`). With `auth.jwt` this is harmless (no session to leak). With a `grafana_session` cookie, **User B logging into the Hub on the same browser sees Grafana as User A** until the cookie expires (§F).
   - **Role mapping regresses unless Logto is reconfigured by hand.** The `roles` claim only appears if the `roles` user scope is granted on the Logto application — and `installation-EE.md:250-258` documents that as a **manual console step that no seeder performs** (§D).

5. **Effort: 3–6 working days for EE only**, not counting the CE decision. Rough split: 0.5 d Logto app seeding, 0.5 d Grafana config, **1.5–2 d** for the iframe/top-level-bounce redesign in the wrapper, **1 d** for logout synchronisation (which needs a change in `industream-hub`, i.e. a second repo and a second PR), 0.5 d role mapping + Logto scope seeding, 1 d live validation across swarm + compose + CE/EE combinations. Add ~1 d if the wrapper Service Worker is actually removed rather than left in place.

6. **Recommendation:** do **not** do a wholesale migration. The realistic, defensible options in priority order are:
   - **Option 1 (recommended): keep `auth.jwt`, fix the two things OAuth was meant to fix.** Shareable deep links already work via the Hub tile format (`/@app/grafana/d/...`) and the wrapper's authenticated navigations (`wrapper/sw.js:130-147`). Grafana Live is the only genuinely blocked feature, and it needs a session cookie — which OAuth *would* provide. If Live matters, scope a narrow spike for that alone.
   - **Option 2: EE-only `generic_oauth`, CE stays on `auth.jwt`**, with the top-level bounce and logout sync built properly. This is the "real" migration and costs the 3–6 days above.
   - **Option 3 (largest, best long-term): make the Hub a real authorization server.** Every app then federates off one issuer in both editions and the invariant is preserved. This is a multi-week backend project in `industream-hub` and is out of scope here.

---

## A. Does the Hub expose what an OAuth client needs?

### A.1 Complete hub-backend route surface

`packages/industream-hub-backend/src/server.ts` starts **two** Express apps from the same factory (`src/app.ts:68-69`):

| App | Port | Factory call | `/apps`, `/groups`, `/layout` protected? |
|---|---|---|---|
| public | `IH_PUBLIC_PORT`, default **3050** (`src/config/env.ts:41`) | `createHubApp()` (`app.ts:68`) | yes, `requireJwt` (`app.ts:51-54`) |
| internal ("free-vend") | `IH_INTERNAL_PORT`, default **3051** (`env.ts:42`) | `createHubApp({protectApps:false})` (`app.ts:69`) | **no — unauthenticated CRUD** (`app.ts:55-59`) |

Full route table (public app):

| Method | Path | Handler | Auth |
|---|---|---|---|
| `OPTIONS` | `*` | inline `sendStatus(204)` | none — `app.ts:30-33` |
| `GET` | `/health` | inline | none — `app.ts:38-40` |
| `GET` | `/info` | inline → `{version: edition}` | none — `app.ts:42-44` |
| `POST` | `/auth/login` | `login` | none — `auth.routes.ts:12` |
| `POST` | `/auth/refresh` | `refresh` | none (token from header or body) — `auth.routes.ts:13` |
| `POST` | `/auth/oidc/exchange` | `oidcExchange` | none; **EE only** — `auth.routes.ts:14-15`, gated by `app.ts:47` |
| `POST` | `/auth/oidc/logout` | `oidcLogout` | none; **EE only** — `auth.routes.ts:16` |
| `GET` | `/auth/jwks` | `jwks` | **public** — `auth.routes.ts:18`, `auth.controller.ts:69-71` |
| `GET` | `/auth/userinfo` | `userinfo` | Bearer enforced in-handler — `auth.routes.ts:19`, `auth.controller.ts:73-88` |
| `GET` | `/openapi/openapi.json`, `/openapi/*` | Swagger | none — `openapi.routes.ts:7-12` |
| `GET` | `/origins` | `listOrigins` | **deliberately public** — `app.ts:49`, `app.controller.ts:25-29` |
| `GET/POST/PUT/DELETE` | `/apps`, `/apps/:id` | app CRUD | `requireJwt` — `app.ts:52`, `app.routes.ts:6-10` |
| `GET/POST/PUT/DELETE` | `/groups`, `/groups/:id` | group CRUD | `requireJwt` — `app.ts:53`, `group.routes.ts:5-8` — **not on `origin/main`** |
| `GET/PUT` | `/layout` | layout | `requireJwt` — `app.ts:54`, `group.routes.ts:11-12` — **not on `origin/main`** |

`packages/industream-hub-backend-enterprise` is **one 31-line file** (`src/server.ts`) that re-invokes the CE factory with `edition: 'enterprise-edition'` (`:6-7`) and starts the revocation worker (`:8`). It **defines zero routes of its own**. The only route-surface effect of EE is the two `/auth/oidc/*` endpoints.

### A.2 Is it an authorization server? **No.**

| OAuth2/OIDC provider endpoint | Present? | Evidence |
|---|---|---|
| `/.well-known/openid-configuration` | **NO** | Repo-wide, `well-known` appears 3 times, all **outbound**: `oidc.service.ts:128` (hub fetches *Logto's* discovery), `packages/industream-menu/src/auth/oidc-browser.ts:200` (browser fetches Logto's), `installation-EE.md:352` (documents Logto's URL). No `.well-known` route is registered. |
| `/authorize` | **NO** | No such route. The only `response_type=code` / `code_challenge` code is client-side and targets `discovery.authorization_endpoint` **of Logto** — `oidc-browser.ts:51-64`. |
| `/token` | **NO** | No route parses `grant_type`. `oidc.service.ts:374-397` POSTs `grant_type=refresh_token` **to Logto**; `oidc-browser.ts:121-136` POSTs `grant_type=authorization_code` **to Logto**. `client_credentials` appears nowhere. |
| `/userinfo` | **lookalike only** | `GET /auth/userinfo` exists (`auth.routes.ts:19`) but returns the Hub's `{data,error,meta}` envelope (§D.2), is not at the standard path, and is not advertised by any discovery document. |
| `/jwks` | **YES, `GET /auth/jwks`** | `auth.routes.ts:18` → `auth.controller.ts:69-71` → `auth.service.ts:247-256`. Public, unauthenticated, returned **raw** (not enveloped) so it is a spec-shaped JWKS document. This is what Grafana consumes today. |
| Client registration / `client_id`+`client_secret` store | **NO** | No client model, no store, no registration endpoint. `client_id`/`client_secret` exist only as *outbound* config: `env.ts:27-28`, consumed at `oidc.service.ts:382-387`. LMDB holds apps/groups/layout only (`db/lmdb-store.ts`); OIDC sessions are an in-memory `Map` (`oidc-session-store.ts:27`). |

The Hub is a **token bridge, not an authorization server**. Every OIDC interaction points *outward*:

- hub-backend → Logto: discovery (`oidc.service.ts:126-133`), remote JWKS for verifying *upstream* tokens (`:171-182`), userinfo (`:184-219`), refresh grant (`:366-432`).
- browser (menu SPA) → Logto: authorization-code + PKCE (`oidc-browser.ts:36-65`), code→token (`:87-136`), RP-initiated logout (`:67-85`).
- browser → hub-backend: `POST /auth/oidc/exchange` with the already-obtained upstream tokens (`auth.schema.ts:16-23`), which the hub verifies and swaps for its **own** RS256 JWT pair (`oidc.service.ts:277-308`).

A further tell: `iss` and `aud` are **opaque identifiers, not URLs** — `IH_ISSUER` default `industream-hub-backend`, overridden to `hub-backend` by `unified/auth.env:10`; `IH_AUDIENCE` default `industream-hub` (`env.ts:54-55`). An OIDC issuer must be an `https` URL that hosts discovery.

**Conclusion: Grafana cannot OAuth against the Hub. In EE it must go to Logto directly. In CE there is nothing to go to.**

### A.3 CORS — permissive, but irrelevant here

`app.ts:26-35` sets `Access-Control-Allow-Origin: *` on every route, without `Allow-Credentials`. So any web origin can call `POST /auth/login` and read the response. That enables the bridge model; it does **not** enable a redirect flow, because there is no redirect endpoint to hit.

---

## B. CE mode — the migration cannot happen

### B.1 CE has no identity provider

- CE uses `IH_AUTH_METHOD=BASIC` (default; `env.ts:9-11,21` — anything not `OAUTH` silently falls back to `BASIC`).
- BASIC is a **single hardcoded account**: `authService.login` compares `username !== auth.username || password !== auth.password` in plaintext against `IH_USERNAME`/`IH_PASSWORD` (`auth.service.ts:199-206`, `:88-94`). Non-constant-time.
- Its identity is synthesised from env vars, and its role array is always **exactly one element**: `roles: [config.auth.role || 'admin']` (`auth.service.ts:96-104`).
- Logto is Enterprise-only. `unified/base/ee.yml:4-6` states it appends *"ONLY when EDITION=ee"*; the assembly gate is `unified/scripts/deploy.sh:162-165`.

### B.2 `auth.proxy` behind oauth2-proxy is **not viable in CE**

`oauth2-proxy` is configured as an OIDC relying party — `OAUTH2_PROXY_PROVIDER=oidc`, `OAUTH2_PROXY_OIDC_ISSUER_URL=https://auth.${INDUSTREAM_DOMAIN}/oidc` (`unified/base/auth.yml:30,33`, branch-only). It **requires** an upstream OIDC provider. CE has none.

This is not an oversight — it is enforced. `unified/scripts/deploy.sh:98-106`:

```bash
EE_ONLY_GROUPS="timescale workers-premium ironstream data-simulator auth"
if [[ "$EDITION" != ee ]]; then
  for _g in $EE_ONLY_GROUPS; do
    if [[ " $GROUP_SET " == *" $_g "* ]]; then
      echo "✗ the '$_g' group is Enterprise-only — use --edition ee" >&2
      exit 1
```

with the rationale at `deploy.sh:87-89`: *"`auth` : the SSO edge (oauth2-proxy) fronting apps without native OIDC via Traefik forwardAuth → Logto. EE-only (needs Logto)."*

### B.3 Options for CE, stated plainly

| Option | Verdict |
|---|---|
| **Keep `auth.jwt`** | The only zero-cost answer. CE and EE Grafana configs diverge. |
| Ship a lightweight OIDC provider in CE (Dex, Logto CE, Zitadel) | Contradicts the licensing model (Logto is the EE differentiator) and adds a Postgres + a service to the CE footprint. Would need product sign-off. |
| Implement `/authorize` + `/token` + `/.well-known` in `industream-hub-backend` | Architecturally the right answer (§Gaps). It preserves the invariant in both editions. Multi-week backend project. |
| `auth.proxy` with a *header-injecting* shim that validates the Hub JWT | Technically feasible (a small proxy verifying against `/auth/jwks` and emitting `X-WEBAUTH-USER`), but it is a **new bespoke service**, and it gives Grafana a session *without* solving logout desync — it makes §F worse, not better. Not recommended. |

**Bottom line: yes, the migration splits CE and EE. CE stays on `auth.jwt`.**

---

## C. EE mode with Logto

### C.1 What runs today

Logto (`unified/base/ee.yml:52-77`), pinned `ghcr.io/logto-io/logto:${LOGTO_VERSION}` = `1.40.1` (`unified/versions.env:71`), with `ENDPOINT=https://auth.${INDUSTREAM_DOMAIN}` and `ADMIN_ENDPOINT=https://auth-admin.${INDUSTREAM_DOMAIN}` (`ee.yml:70-71`). Its own Postgres at `ee.yml:80-95`.

**Issuer is `https://auth.<domain>/oidc`** — never `logto.<domain>`. Three consumers: `ee.yml:24` (hub backend), `ee.yml:46` (SPA shell), `unified/base/auth.yml:33` (oauth2-proxy, branch-only).

Split-horizon is deliberate (`ee.yml:25-28`): browser-facing endpoints use the public issuer; container-to-container calls use `http://logto:3001/oidc` (`ee.yml:29,34,35,36`), because *"discovery via the public URL advertises browser endpoints unreachable from the container → refresh grant fails → … the user is logged out (~5 min)."*

### C.2 Existing OIDC applications

| # | App | Type | Client ID | Redirect URI | Post-logout | Created by | Runs? |
|---|---|---|---|---|---|---|---|
| 1 | `Industream Hub` | **SPA** | `industream-hub-app` (deterministic — it *is* the row `id`) | `https://<domain>/` | same as redirect | `industream-hub` `oidc-seeds/logto/seed-logto.sh:184-191` | **YES** — via `deploy.sh:365` |
| 2 | `IronStream Filebrowser` | **Traditional** | Logto-generated, read back via API | `https://filebrowser.<domain>/oauth2/callback` | `https://filebrowser.<domain>/` | `industream-stack` `scripts/setup/seed-filebrowser-sso.sh:43-47` | **NO — never invoked** (see C.4) |
| 3 | `industream-hub-app` (duplicate) | **Traditional** | `industream-hub-app` | `https://dashboard.<domain>/auth/callback` | same | `industream-stack` `scripts/setup/seed-logto.sh:203-224` | **NO** — needs hand-made M2M creds |
| 4..N | label-discovered | SPA/Traditional/M2M | from label | from label | same as redirect | `industream-hub` `oidc-seeds/logto/seed-logto-stack.sh:124-137` | **NO — never invoked** |

Grant types are never set explicitly — Logto derives them from `type`. App 1 forces refresh tokens via `custom_client_metadata = '{"alwaysIssueRefreshToken":true}'` (`seed-logto.sh:184-191`), because *"SPAs skip consent, so without it no refresh token is issued → the EE Hub can't refresh the upstream session → the user is logged out (~5 min)"* (`seed-logto.sh:180-183`).

**Latent conflict:** apps 1 and 3 share the name/id `industream-hub-app` but disagree on `type` (SPA vs Traditional) and redirect URI. They never run together today, but whichever ran last on a shared DB would win.

### C.3 What a Grafana app would need

A new Logto application:

```
name:         Grafana
client_id:    grafana
type:         Traditional        (confidential — Grafana holds a client_secret server-side)
redirectUris: ["https://dashboard.<domain>/grafana/login/generic_oauth"]
postLogoutRedirectUris: ["https://dashboard.<domain>/"]
scopes granted (User scopes, Logto console): openid, profile, email, roles, offline_access
```

The redirect URI is fixed by Grafana: it is `<root_url>/login/generic_oauth`, and `GF_SERVER_ROOT_URL=https://dashboard.${INDUSTREAM_DOMAIN}/grafana/` (`unified/base/monitoring.yml:67`). So **`https://dashboard.<domain>/grafana/login/generic_oauth`** — exactly the form the brief guessed, and exactly the form the existing seeder's documentation uses as its example.

### C.4 The seeding mechanism to extend — it already exists, unwired

`packages/industream-hub-backend-enterprise/oidc-seeds/logto/seed-logto-stack.sh` is a complete, idempotent, label-driven registrar. Its header (`:11-18`):

```
#   io.industream.logto.register: "true"
#   io.industream.logto.client_id: "<unique-id>"      e.g. "grafana"
#   io.industream.logto.redirect_uri: "<full URL>"    e.g. "https://dashboard.example/login/generic_oauth"
#   io.industream.logto.app_type: "SPA"|"Traditional"|"MachineToMachine"  (default: SPA)
#   io.industream.logto.name:    "<display name>"                          (default: client_id)
```

**Its worked example is literally a Grafana `generic_oauth` callback.** This is the hook to extend. It discovers services by inspecting swarm service / compose container labels (`:100-110`) and upserts into Logto's `applications` table (`:124-137`).

Two blockers before it can be used:

1. **It is never invoked.** `deploy.sh` calls `seed_menu_apps` (`:501`), `seed-confighub.sh` (`:504`) and `seed_ee` (`:511`); `seed_ee` (`:321-374`) only extracts and runs the *single-app* `seed-logto.sh`. And `grep -rn "io.industream.logto" industream-stack` → **zero hits**: no service in the stack tree carries the labels.
2. **It hardcodes a guessable secret.** `seed-logto-stack.sh:126`: `'unused-' || :'cid'` — i.e. a `Traditional` app registered this way would have client secret `unused-grafana`. Safe for a public SPA client, **a credential hole for a confidential client**. This must be fixed (generate a random secret, write it to a Docker/compose secret) before Grafana can use it as `Traditional`. Alternatively register Grafana as a public client with PKCE — but Grafana's `generic_oauth` requires `client_secret` to be set (it supports `use_pkce=true` but still sends a secret), so `Traditional` + a real secret is the correct shape.

`seed-filebrowser-sso.sh` (`industream-stack/scripts/setup/`) is the *other* candidate to extend — it uses the Logto **Management API** rather than raw SQL, reads the generated `client_id` back and injects it into the live service (`:66-71`). It is also **never called** by `deploy.sh`; the pipeline only pre-creates a literal `PLACEHOLDER` client secret (`deploy.sh:474-479`) and expects an operator to run the seeder by hand. Wiring Grafana in would inherit that gap.

**Recommendation:** extend `seed-logto-stack.sh` (fix the secret generation, add the labels to the `grafana` service, call it from `seed_ee`). It is the mechanism that was designed for this.

---

## D. Role mapping

### D.1 What Grafana does today

`unified/base/monitoring.yml:114`:

```
- GF_AUTH_JWT_ROLE_ATTRIBUTE_PATH=contains(roles, 'admin') && 'Admin' || 'Editor'
```

Against the **Hub-minted** JWT, whose full claim set is built at `auth.service.ts:152-167`:

```ts
return signJwt({
  ...user,                       // sub, email, username, firstname, lastname, roles[], accountName
  iss: config.auth.issuer,       // 'hub-backend'
  aud: config.auth.audience,     // 'industream-hub'
  iat, exp: iat + ttl,
  jti: randomUUID(),
  token_use: tokenUse,           // 'access' | 'refresh'
});
```

`roles` is a **flat top-level string array**. Access TTL is 900 s, refresh 30 days (`env.ts:56-57`). Signed RS256 with a deterministic `kid` (`auth.service.ts:81-84,106-113`).

The wrapper *also* reads the same claim client-side to pick the kiosk level (`wrapper/index.html:140-151`): `admin` → no kiosk, `viewer` → `kiosk=1`, anything else → `kiosk=tv`.

### D.2 `GET /auth/userinfo` shape (for reference)

`auth.service.ts:230-245` echoes the verified claims; `auth.controller.ts:73-88` wraps them:

```json
{"data":{"sub":"…","email":"…","username":"…","firstname":"…","lastname":"…","roles":["admin"],"accountName":null},"error":null,"meta":{}}
```

Note the OpenAPI spec declares `roles` as `enum:['admin']` (`openapi/spec.ts:630`) — stale under OAUTH mode.

### D.3 What Logto actually issues

Two **mutually incompatible** role vocabularies exist in the tree:

**Model A — what actually gets seeded** (`industream-hub` `oidc-seeds/logto/seed-logto.sh:195-199`):

```sql
INSERT INTO roles (tenant_id, id, name, description, type, is_default) VALUES
  (:'tenant', :'radmin',  'admin',  'Industream admin',  'User', false),
  (:'tenant', :'reditor', 'editor', 'Industream editor', 'User', false),
  (:'tenant', :'rviewer', 'viewer', 'Industream viewer', 'User', false)
ON CONFLICT (tenant_id, name) DO NOTHING;
```

Plain Logto `User` roles named **`admin` / `editor` / `viewer`**, with **no scopes and no API resources attached**. The bootstrap admin gets `admin` via `users_roles` (`seed-logto.sh:205-221`). `sub` is deliberately the username, not an opaque id (`seed-logto.sh:148-155`).

**Model B — `industream-stack/scripts/setup/seed-logto.sh`, never runs automatically:** creates 5 API resources (`:144-150`) and roles named **`industream-admin` / `industream-editor` / `industream-viewer`** (`:260-266`), with the explicit intent comment at `:229-231`: *"The `roles` claim drives Grafana (role_attribute_path) and the menu's per-app gating; the `scope` claim carries the fine-grained access."*

**`industream-admin` ≠ `admin`.** A `role_attribute_path` of `contains(roles, 'admin')` matches Model A only. Pick one before wiring Grafana, or Grafana will silently give everyone `Editor`.

### D.4 Can `role_attribute_path` work off the OAuth token?

**Yes, mechanically.** Grafana's generic OAuth evaluates `role_attribute_path` in this order: **ID token → UserInfo endpoint → access token** ([Grafana docs](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/generic-oauth/)). Logto's built-in `roles` claim is a flat array, so the *same expression works unchanged*:

```
GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(roles, 'admin') && 'Admin' || contains(roles, 'editor') && 'Editor' || 'Viewer'
```

### D.5 What must be configured in Logto — and is not

`installation-EE.md:250-258` (industream-hub):

> *"The Hub backend requests `openid profile email roles offline_access` scopes. Logto must be configured to return these claims. … Under **User scopes**, ensure the following are granted: … `roles` — returns `roles` claim with assigned Logto roles (e.g., `admin`). If not listed, click **Add permissions** → search for `profile`, `email`, and `roles`"*

**This is a manual console step that no seeder performs.** Neither `seed-logto.sh` nor `seed-logto-stack.sh` touches `applications_user_consent_scopes` or the equivalent. So today, on a freshly seeded EE stack, whether the Hub even sees `roles` depends on an operator having clicked through the Logto console — and it must be repeated for a new Grafana application.

No custom JWT claim script, no Logto organization, and no "user role" resource is configured anywhere (grep: no `custom_jwt` in either repo).

### D.6 The Keycloak residue

`oidc.service.ts:43-45,250-268` still merges Keycloak-shaped claims that Logto never emits:

```ts
const clientRoles = asStringArray(claims.resource_access?.[oidc.clientId]?.roles);
const roles = unique([
  ...asStringArray(claims.roles),
  ...asStringArray(claims.realm_access?.roles),
  ...clientRoles,
]);
```

Consistent with the fact that the platform previously ran Grafana `generic_oauth` **against Keycloak** — see §C-history below.

### D.7 Prior art: this was done before, against Keycloak

Recovered from `industream-stack` commit `114e538` (2026-05-27), file `docker-stack.monitoring.yml:45-60` (since deleted):

```yaml
- GF_AUTH_GENERIC_OAUTH_ENABLED=${GRAFANA_OAUTH_ENABLED:-true}
- GF_AUTH_GENERIC_OAUTH_NAME=Keycloak
- GF_AUTH_GENERIC_OAUTH_CLIENT_ID=${GRAFANA_OAUTH_CLIENT_ID:-uifusion}
- GF_AUTH_GENERIC_OAUTH_SCOPES=openid email profile offline_access roles
- GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://${INDUSTREAM_DOMAIN}/auth/realms/industream/protocol/openid-connect/auth
- GF_AUTH_GENERIC_OAUTH_TOKEN_URL=http://keycloak:8080/auth/realms/industream/protocol/openid-connect/token
- GF_AUTH_GENERIC_OAUTH_API_URL=http://keycloak:8080/auth/realms/industream/protocol/openid-connect/userinfo
- GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(realm_access.roles[*], 'grafanaadmin') && 'GrafanaAdmin' || contains(realm_access.roles[*], 'admin') && 'Admin' || contains(realm_access.roles[*], 'editor') && 'Editor' || 'Viewer'
- GF_AUTH_GENERIC_OAUTH_TLS_SKIP_VERIFY_INSECURE=${GF_OAUTH_TLS_SKIP_VERIFY:-true}
- GF_AUTH_GENERIC_OAUTH_USE_PKCE=true
- GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN=true
- GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP=true
```

Flagged as audit finding #9 (`docs/AUDIT-2026-04-18.md:89`) for `TLS_SKIP_VERIFY_INSECURE=true`. Note the split-horizon pattern (public `AUTH_URL`, container-internal `TOKEN_URL`/`API_URL`) — reusable verbatim for Logto.

**`GF_AUTH_PROXY` / `auth.proxy`: zero hits across every ref in the repo. Never attempted.**

---

## E. The iframe problem

### E.1 The current frame stack

```
top-level:  https://<domain>/                        Hub shell (industream-menu)
  └─ iframe: https://dashboard.<domain>/             grafana-wrapper (nginx + index.html)
       └─ iframe: https://dashboard.<domain>/grafana/  Grafana (nginx reverse-proxy, same-origin)
```

- Hub renders app tiles via `packages/industream-menu/src/components/frames/AppFrame.svelte:82-89` — **no `sandbox` attribute**, only `allow="clipboard-write; clipboard-read"`. `src` is set once imperatively (`:26-28`) so re-renders don't reload.
- The wrapper boots the Grafana frame at `wrapper/index.html:283`: `iframe.src = buildGrafanaUrl(currentToken, currentTheme, deepPath)` → `/grafana/?auth_token=<JWT>&kiosk=…&theme=…` (`:153-162`).
- The inner frame is **same-origin** with the wrapper (nginx `location /grafana/` proxies to `grafana:3000`, `wrapper/nginx.conf:33-46`), which is what makes the Service Worker at scope `/` able to control it.

### E.2 Two blockers, both concrete

**Blocker 1 — the wrapper's own CSP forbids the redirect.** `grafana-hub-wrapper/wrapper/index.html:5`:

```html
<meta http-equiv="Content-Security-Policy" content="default-src 'self' __INDUSTREAM_HUB_ORIGIN__; script-src 'self' 'unsafe-inline' __INDUSTREAM_HUB_ORIGIN__; style-src 'self' 'unsafe-inline'; frame-src 'self' __INDUSTREAM_HUB_ORIGIN__; child-src 'self' __INDUSTREAM_HUB_ORIGIN__; connect-src 'self' __INDUSTREAM_HUB_ORIGIN__ wss://__INDUSTREAM_HUB_ORIGIN_HOST__;">
```

`frame-src` governs navigations of nested browsing contexts, not just their initial load. A Grafana frame issuing `302 → https://auth.<domain>/oidc/auth` violates `frame-src 'self' <hub-origin>` and is blocked. Fixable (add `https://auth.<domain>`), but it must be a deliberate change, and `__INDUSTREAM_HUB_ORIGIN__` is the only value `entrypoint.sh:14-19` substitutes — a second placeholder and a second env var are needed.

**Blocker 2 — Logto will refuse to be framed.** Logto is a Node/Koa app; Helmet-style defaults ship `frame-ancestors 'self'` and `X-Frame-Options: SAMEORIGIN`. [MDN: `frame-ancestors`](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Content-Security-Policy/frame-ancestors) — the directive checks **every** ancestor, so a doubly-nested frame requires *both* `https://<domain>` and `https://dashboard.<domain>` in the allowlist. No Logto env var for this exists in the stack (grep: nothing sets a CSP on the `logto` service, `unified/base/ee.yml:68-71` sets only `TRUST_PROXY_HEADER`, `ENDPOINT`, `ADMIN_ENDPOINT`). *Unverified:* Logto's exact default headers were not measured against a live instance — this must be confirmed (see Open Questions). Even if Logto could be relaxed, framing a sign-in page is a clickjacking anti-pattern and would need a security sign-off.

### E.3 Three ways to trigger the dance

**Option E-1 — top-level bounce (recommended).**

The wrapper already knows how to reach the top-level context. `wrapper/index.html:171-179`:

```js
function redirectToHub() {
  try { window.top.location.href = HUB_ORIGIN; }
  catch { window.location.href = HUB_ORIGIN; }
}
```

Reuse that shape. Flow:

1. Wrapper detects no `grafana_session` (probe `GET /grafana/api/user` → 401).
2. Wrapper sets `window.top.location.href = 'https://dashboard.<domain>/?oauth_return=' + encodeURIComponent(currentHubPath)`.
3. `dashboard.<domain>` is now **top-level**. The wrapper page (or a small nginx `return 302`) redirects to `/grafana/login/generic_oauth`.
4. Grafana → Logto → back to `https://dashboard.<domain>/grafana/login/generic_oauth`. `grafana_session` is set as a **first-party** cookie.
5. Wrapper redirects `window.top` back to the Hub with the original deep path; the Hub re-frames the tile; the frame now carries the cookie.

Cost: the user is bounced out of the Hub shell and back. Every Hub navigation state (open tiles, layout) is torn down and rebuilt. It happens once per Grafana session, not per page load.

**Cookie viability — a key nuance the current design obscures.** `dashboard.<domain>` and `<domain>` are the **same site** (same registrable domain), only cross-origin. So the `grafana_session` cookie in the Hub iframe is **not a third-party cookie** and is not subject to Chrome's third-party cookie phase-out. `SameSite=Lax` (Grafana's default) is sufficient for a same-site cross-origin iframe. This is materially better than the general Grafana-embedding horror stories ([community thread](https://community.grafana.com/t/chrome-blocking-3rd-party-cookies-when-embedding/113302)) — but note that CHIPS has documented failure modes for **nested** frames and for new tabs opened from a frame ([privacycg/CHIPS#88](https://github.com/privacycg/CHIPS/issues/88), [#82](https://github.com/privacycg/CHIPS/issues/82)), and Grafana is doubly nested here. **This is the single most important thing to measure live before committing.** Note also the existing counter-evidence in this stack: a Next.js tile (Pirson Provisions) failed to keep a session cookie inside the Hub iframe even when served same-origin, which is why the Bearer-via-Service-Worker model was adopted there.

**Option E-2 — popup.** Wrapper opens `window.open('/grafana/login/generic_oauth')`; Logto renders top-level in the popup; Grafana sets the cookie; popup posts back and closes. Avoids destroying Hub state. But: popup blockers require a user gesture (a "Sign in to Grafana" button — acceptable UX, matches the existing `showHubLoginPrompt()` at `index.html:181-206`), and [privacycg/CHIPS#82](https://github.com/privacycg/CHIPS/issues/82) documents that a popup does **not** share the iframe's partitioned cookie jar under CHIPS. Same-site here means partitioning shouldn't apply — but this is exactly the untested edge.

**Option E-3 — pre-authenticated by the Hub (no redirect at all).** Keep Grafana on `auth.jwt` and have the Hub obtain the session for it. This is what happens today; there is no session to obtain, per grafana/grafana#90200. If Grafana ever restores `GF_AUTH_JWT_ENABLE_LOGIN_TOKEN` (already set at `unified/base/monitoring.yml:100`), this becomes the zero-work answer and the whole OAuth question evaporates. **Worth checking the upstream issue before spending days on E-1.**

**Also available: `grafana-direct.<domain>`.** A top-level Grafana router already exists as an admin back-door — `unified/runtime/swarm/monitoring.yml:67,72` (`Host('grafana-direct.${INDUSTREAM_DOMAIN}')`). It is a natural place to perform the OAuth dance top-level. Caveat: `GF_SERVER_ROOT_URL` points at `dashboard.<domain>/grafana/` (`monitoring.yml:67`), so Grafana's own redirects on that host are wrong today; it would need its own root_url or a rewrite.

---

## F. Session lifecycle / logout desync

### F.1 The problem, precisely

With `auth.jwt` Grafana is **stateless** — no session, so nothing to desync. With `generic_oauth` Grafana holds `grafana_session` (`GF_AUTH_LOGIN_COOKIE_NAME=grafana_session`, `unified/base/monitoring.yml:50`), independent of the Hub. Consequences:

- Hub logout leaves Grafana logged in. The frame keeps serving User A's dashboards.
- **User B logs into the Hub on the same browser → the Grafana tile still shows User A's identity, permissions and starred dashboards.** This is a security defect, not a cosmetic one.
- Grafana session lifetime is governed by `login_maximum_lifetime_duration` (7 d default) / `login_maximum_inactive_lifetime_duration` (7 d), not by the Hub's 900 s access token.

### F.2 What hooks exist today

**The Hub does broadcast `logged-out` — but not to `AppFrame` iframes.**

Protocol (`packages/industream-menu/src/auth/protocol.ts:66-71`):

```ts
export type AuthRuntimeEvent =
  | { type: 'state'; state: AuthState }
  | { type: 'authenticated'; state: AuthState }
  | { type: 'login-required'; reason: string | null; state: AuthState }
  | { type: 'logged-out'; reason: string | null; state: AuthState }
  | CustomRuntimeEvent;
```

Emitted by the SharedWorker (`auth/shared-worker.ts:478-487`):

```ts
private async logout(reason: string | null): Promise<LogoutResult> {
  const stored = await this.getStoredSession().catch((): null => null);
  await this.logoutHubSession(stored);
  await this.clearSession();
  this.runtime.status = 'unauthenticated';
  this.runtime.reason = reason;
  this.postToAll({ type: 'auth.event', event: { type: 'logged-out', reason, state: this.getState() } });
  return { state: this.getState(), upstreamIdToken: stored?.upstreamIdToken || null };
}
```

Fanned out by the bridge page (`auth/shared-worker-bridge.ts:123-128,150-156`) **only to windows already registered in `this.clients`** — and registration happens exclusively in `handleWindowMessage` (`:173`), i.e. only for app windows that have themselves posted an `industream.auth` message. `AppFrame.svelte` never does. The map is keyed by *origin* (`:35`), so with two windows on the same origin only the most recent receives events, and there is no cleanup on unload.

Meanwhile the Hub's own iframe channel has no auth vocabulary at all — `AppFrame.svelte:6-7`:

```ts
const ROUTE_MESSAGE_ID = 'industream-hub/v1/route';
const NAVIGATE_MESSAGE_ID = 'industream-hub/v1/navigate';
```

and the frames are never torn down on logout (`app-frame.service.ts:64-66` only nulls `focusedAppId`; the CSS just flips `visibility`, `AppFrame.svelte:99,106-109`).

There is **no `BroadcastChannel`, no `storage`-event listener and no ServiceWorker** anywhere in `packages/industream-menu/src` or `packages/hub-auth/src`. No server push. No idle timeout. A revoked refresh token is only discovered on the next `POST /auth/refresh` returning 401/403 (`shared-worker.ts:348-353`).

**The wrapper does listen — via a different path.** Because the wrapper page loads `industream-login.js` itself (`wrapper/index.html:53-64`) it *is* a bridge-registered client, so it does see the auth→unauth transition on `authClient.state$` (`index.html:90-104`) and forwards a synthetic message to the Grafana frame:

```js
iframe?.contentWindow?.postMessage(
  { id: 'industream-hub/v1/auth-logout' },
  window.location.origin
);
```

The Grafana plugin handles it by painting a full-screen overlay (`plugin/module.js:120-122,125-147`). On re-login the wrapper reloads the frame (`index.html:84-89`).

**So the logout signal already reaches inside Grafana. What is missing is an action that actually destroys the Grafana session.**

### F.3 `/logout` in Grafana

Grafana exposes `GET /logout` (here `https://dashboard.<domain>/grafana/logout` under `serve_from_sub_path=true`). It clears `grafana_session` and redirects. `GF_AUTH_DISABLE_SIGNOUT_MENU=false` is already set (`unified/base/monitoring.yml:49`), so the UI signout is enabled too. Grafana's generic OAuth also supports `signout_redirect_url` for RP-initiated logout at the IdP.

### F.4 Proposed synchronisation design

**Hub → Grafana (session kill), 3 layers, all needed:**

1. **Wrapper acts on the existing signal.** In `index.html:90-104`, in addition to posting `auth-logout`, call Grafana's logout in the frame:
   ```js
   await fetch('/grafana/logout', { credentials: 'include', redirect: 'manual' });
   ```
   Same-origin, so the cookie is sent and cleared. Then post `auth-logout` and set `needsReloadOnReauth = true` as today. Cheap and works for the common case (user clicks Logout with the tile open).
2. **Identity pinning against a stale cookie.** On every wrapper boot, compare the Hub JWT `sub` (already decoded at `index.html:128-138`) with Grafana's `GET /grafana/api/user` `login` field. On mismatch → force `/grafana/logout` then re-enter the OAuth flow. This is the layer that prevents "User B sees User A", including after a full page reload where layer 1 never ran.
3. **Configure `signout_redirect_url`** so a Grafana-initiated signout also ends the Logto session, keeping the two directions symmetric.

**Grafana → Hub:** post `industream-hub/v1/route`-style message upward. Today the wrapper only relays route/theme (`index.html:301-338`); a new `industream-hub/v1/request-logout` would need handling in the Hub shell — a change in `industream-hub`, i.e. a second repo/PR.

**Recommended framework fix (benefits every tile, not just Grafana):** add an auth message ID to the `AppFrame` protocol (`AppFrame.svelte:6-7,66`), driven by `userService.auth` / `loggedOut$`, and/or have `app-frame.service` drop and recreate frames when auth clears. This is the clean fix the current architecture is missing and would remove the wrapper's need to be a bridge client at all.

---

## G. What breaks / what can be deleted

Assuming EE `generic_oauth` lands **and** the `grafana_session` cookie is proven to survive the nested iframe:

| Artefact | Fate | Evidence / caveat |
|---|---|---|
| **Service Worker Bearer injection** (`wrapper/sw.js:93-118`, `applyToken` `:69-91`) | **Removable** — but only after the cookie is proven. It exists precisely because *"Grafana's auth.jwt is stateless (no session cookie), so every XHR/fetch made by the Grafana JS bundle must carry the JWT"* (`sw.js:11-15`). With a cookie, the browser attaches credentials automatically. **Do not remove until §Open Questions Q1 is answered live.** |
| **SW navigation rewriting** (`sw.js:130-147`) | **Removable.** Its whole purpose is that *"Grafana's redirects drop the ?auth_token= URL param and no session cookie is ever issued"* (`sw.js:121-128`). Moot with a cookie. |
| **`?auth_token=` boot** (`index.html:153-162`, `buildGrafanaUrl`) | **Removable for auth.** But `buildGrafanaUrl` also carries `kiosk` and `theme`, so the function stays — it just stops setting `auth_token`. Also removes the leak flagged in `grafana-hub-wrapper/README.md:360` (*"visible in nginx access logs and browser history"*). The Hub's defensive strip (`app-route.service.ts:66-71`) becomes dead but harmless. |
| **Synthetic 503s** (`sw.js:111-117`, `:141-146`) | **Stays if the SW stays; goes with the SW.** They are a generic "Grafana unreachable" nicety, not auth-specific. If the SW is deleted, a transient Grafana restart goes back to a raw `net::ERR` in the console. Mild regression. |
| **`GF_LIVE_MAX_CONNECTIONS=0`** (`unified/base/monitoring.yml:93`) | **Removable — this is the main functional win.** The comment says it exactly: *"a browser WebSocket can carry neither the Authorization header (not SW-interceptable) nor a session cookie (Grafana never issues one for JWT auth — upstream regression grafana/grafana#90200)"*. A cookie **is** sent on the WS handshake, so Live works again. Note the Traefik `grafana-live` router already exists (`unified/runtime/swarm/monitoring.yml:75-82`, priority 200) — the plumbing is in place. |
| `GF_AUTH_JWT_*` (11 vars, `monitoring.yml:99-114`) | **Removed in EE, kept in CE.** This is where the CE/EE fork becomes visible in the deploy tree — either a conditional block in `base/ee.yml` or a separate `runtime` overlay. |
| **JWKS-over-TLS trust plumbing** — `extra_hosts` `${INDUSTREAM_DOMAIN}:host-gateway`, `SSL_CERT_DIR=/etc/grafana/extra-cas`, the `./certs/${INDUSTREAM_DOMAIN}.crt` mount (`unified/runtime/swarm/monitoring.yml` equivalent of `runtime/swarm/grafana.yml:18-28`) | **Not removable — it moves.** Grafana still needs to trust the proxy cert, now for the Logto **token/userinfo** calls. Unless those go container-internal (`http://logto:3001/oidc/token`), following the Keycloak-era split-horizon pattern (§D.7) — which would let the cert plumbing go. That is the better design. |
| `GF_AUTH_DISABLE_LOGIN_FORM=true` (`monitoring.yml:48`) | **Keep**, plus add `GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN=true` so there is no click-through. |
| **Wrapper kiosk selection** (`index.html:140-151`) | **Unaffected.** It reads the *Hub* JWT, which the wrapper still holds. |
| **Wrapper `industream-login.js` load** (`index.html:53-64`) | **Keep.** Needed for kiosk, theme sync, and the logout signal (§F). The wrapper does not become auth-free. |
| **Hub Bridge plugin** (`plugin/module.js`, mounted at `monitoring.yml:126`) | **Keep.** Route/theme sync and the logout overlay are orthogonal to auth. |

**Net:** the wrapper does *not* disappear. It sheds its Service Worker and its `?auth_token=` boot, and gains a top-level-bounce state machine plus session-identity pinning. Roughly a wash in complexity, with Grafana Live and native deep links as the gains.

---

## Gaps in the Hub

Missing endpoints and capabilities, in the order they block this work:

| # | Gap | Impact | Where it would live |
|---|---|---|---|
| **1** | **No OAuth2/OIDC authorization server.** No `/.well-known/openid-configuration`, `/authorize`, `/token`, client registry (§A.2). | The Hub cannot be Grafana's IdP. **This is the single reason CE cannot migrate.** | `packages/industream-hub-backend/src/modules/auth/` — a new `oidc-provider` module. `node-oidc-provider` would fit, backed by the existing RSA key (`auth.service.ts:59-75`) and JWKS (`:247-256`). |
| **2** | **No `POST /auth/logout` in CE.** Only `POST /auth/oidc/logout`, EE-only (`auth.routes.ts:14-16`, gated by `app.ts:47`). | CE has no revocation at all — a Hub JWT is valid until `exp`, up to 30 days for a refresh token. | `auth.routes.ts` + a token denylist. |
| **3** | **No token revocation / introspection.** `IH_OIDC_INTROSPECTION_URL` is parsed (`env.ts:33`) and **never read**. OIDC sessions are an in-memory `Map` (`oidc-session-store.ts:27`) cleared on every restart. | No way for Grafana (or anything else) to ask "is this identity still valid?". Forces the polling/pinning design in §F.4. | `auth.service.ts` + a persistent session store. |
| **4** | **No logout broadcast to `AppFrame` iframes.** The event vocabulary is route/navigate only (`AppFrame.svelte:6-7`); frames are never reloaded or unmounted (`app-frame.service.ts:64-66`); `shared-worker-bridge.ts:150-156,173` reaches only self-registered windows. | Every tile that holds its own session desyncs on logout. Grafana would join Pirson Provisions in this class. | `AppFrame.svelte` + `app-frame.service.ts` + a new `industream-hub/v1/auth-logout` in the Hub→app protocol. |
| **5** | **`@industream/hub-auth` has no `onLogout` hook.** `loggedOut$` is *typed* (`packages/hub-auth/src/types.ts:73-74`) but never subscribed or re-exported; consumers must reach into `client.loggedOut$` or infer from `onAuthState` (`token-service.ts:53-63`). | Third-party tiles cannot cleanly react to logout. | `packages/hub-auth/src/token-service.ts`. |
| **6** | **Logto `roles` scope grant is not seeded** — documented as a manual console step (`installation-EE.md:250-258`); no seeder writes it (§D.5). | Role mapping silently degrades to the fallback branch. | `oidc-seeds/logto/seed-logto.sh`. |
| **7** | **`seed-logto-stack.sh` is built but unwired**, and assigns a guessable secret `'unused-' || client_id` (`:126`) — unsafe for confidential clients. | The intended registration path for a Grafana OAuth app cannot be used as-is. | `oidc-seeds/logto/seed-logto-stack.sh` + `deploy.sh` `seed_ee()`. |
| **8** | **`seed-filebrowser-sso.sh` is never invoked** — `deploy.sh:474-479` only pre-creates a literal `PLACEHOLDER` client secret. | Any Logto-app seeding added for Grafana inherits an operator-manual step. | `unified/scripts/deploy.sh`. |
| **9** | **Two conflicting role vocabularies** (`admin|editor|viewer` seeded vs `industream-admin|…` unseeded) and **two conflicting `industream-hub-app` definitions** (SPA vs Traditional, different redirects) — §C.2, §D.3. | Whichever seeder runs last wins. | Reconcile before adding a third app. |
| **10** | *Hygiene, adjacent:* internal app on **3051 is unauthenticated CRUD** on `/apps`, `/groups`, `/layout` (`app.ts:55-59`); `createApp`/`updateApp`/`deleteApp` and **all** group/layout handlers have no admin gate (`group.controller.ts:34-77`); BASIC-mode `/auth/refresh` accepts an **access** token as refresh input (`auth.service.ts:211-221`); `requireBasicJwt` is dead code (`middleware/auth.ts:48-55`). | Not blockers for this migration, but they are in the same files and should be flagged. | — |

---

## Phased implementation plan (EE only)

Effort is engineer-days, assuming one developer with an EE stack available for live testing. **Total 3–6 days, plus the CE product decision.**

### Phase 0 — Decision gate (0.5 d, no code)

- Confirm the product answer to §B: **CE stays on `auth.jwt`, permanently or until the Hub becomes an AS.** Get this in writing; it contradicts *"THE INVARIANT"* (`unified/auth.env:1-12`) and DECISION #4 (`unified/base/monitoring.yml:11-15`), so it needs an ADR.
- Check grafana/grafana#90200 upstream status. **If it has been fixed in a Grafana ≥ 13.x, stop here** — bump Grafana, re-enable Live, and skip the entire migration.

### Phase 1 — Live measurement spike (0.5 d) — **do this before anything else**

On a live EE stack, answer Q1–Q3 from Open Questions. Specifically: hand-create a `Grafana` app in the Logto console, hand-set the `GF_AUTH_GENERIC_OAUTH_*` vars on the running service, and see whether (a) Logto renders in the nested frame or not, (b) the `grafana_session` cookie survives the nested iframe, (c) Grafana Live connects. **If (b) fails, the migration is dead and the answer is Option 1.**

### Phase 2 — Logto app seeding (0.5–1 d)

- Fix `seed-logto-stack.sh:126` to generate a real random secret for `Traditional` apps and write it to a Docker secret / `.env.${ENV}`.
- Add `io.industream.logto.*` labels to the `grafana` service in `unified/runtime/{swarm,compose}/monitoring.yml`.
- Wire `seed-logto-stack.sh` into `deploy.sh` `seed_ee()` (`:321-374`) after `seed-logto.sh`.
- Seed the `roles` user-scope grant (gap #6) so `role_attribute_path` has something to read.
- Reconcile the role vocabulary (gap #9).

### Phase 3 — Grafana configuration (0.5 d)

Add to the EE-only path (a conditional block in `unified/base/ee.yml`, mirroring how it already overrides `industream-hub-backend`):

```yaml
- GF_AUTH_GENERIC_OAUTH_ENABLED=true
- GF_AUTH_GENERIC_OAUTH_NAME=Industream
- GF_AUTH_GENERIC_OAUTH_CLIENT_ID=grafana
- GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET__FILE=/run/secrets/${GRAFANA_OIDC_CLIENT_SECRET_NAME}
- GF_AUTH_GENERIC_OAUTH_SCOPES=openid profile email roles offline_access
- GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://auth.${INDUSTREAM_DOMAIN}/oidc/auth        # public — browser
- GF_AUTH_GENERIC_OAUTH_TOKEN_URL=http://logto:3001/oidc/token                       # internal — no cert plumbing
- GF_AUTH_GENERIC_OAUTH_API_URL=http://logto:3001/oidc/me                            # internal
- GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(roles, 'admin') && 'Admin' || contains(roles, 'editor') && 'Editor' || 'Viewer'
- GF_AUTH_GENERIC_OAUTH_USE_PKCE=true
- GF_AUTH_GENERIC_OAUTH_USE_REFRESH_TOKEN=true
- GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN=true
- GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP=true
- GF_AUTH_SIGNOUT_REDIRECT_URL=https://auth.${INDUSTREAM_DOMAIN}/oidc/session/end
```

Note the split-horizon (public `AUTH_URL`, container-internal `TOKEN_URL`/`API_URL`) — same pattern as `unified/base/ee.yml:24-36` and as the Keycloak-era config (§D.7). Do **not** set `TLS_SKIP_VERIFY_INSECURE=true` (audit finding #9). Remove `GF_AUTH_JWT_*` in the EE path only; keep it in CE.

### Phase 4 — Wrapper redesign (1.5–2 d) — the bulk of the work

- Add `https://auth.${INDUSTREAM_DOMAIN}` to the CSP at `wrapper/index.html:5` (or drop `frame-src` restrictions if the popup path is chosen), plus a second placeholder in `wrapper/entrypoint.sh:14-19` and a second env var in `unified/base/monitoring.yml`.
- Implement the top-level bounce state machine (§E.3, Option E-1): session probe, `window.top` navigation, `oauth_return` round-trip, re-entry into the Hub with the original deep path.
- Delete `wrapper/sw.js` and the SW registration (`index.html:219-231,240-257`) — **only if Phase 1 (b) passed.** Otherwise keep it as a belt-and-braces fallback.
- Stop appending `auth_token` in `buildGrafanaUrl` (`index.html:153-162`); keep `kiosk` and `theme`.
- Release a new `grafana-hub-wrapper` image and bump `GRAFANA_WRAPPER_IMAGE` in `unified/versions.env`.

### Phase 5 — Logout synchronisation (1 d, spans two repos)

- Wrapper: call `GET /grafana/logout` on the auth→unauth transition (`index.html:90-104`).
- Wrapper: identity pinning on boot — compare Hub JWT `sub` (`index.html:128-138`) against `GET /grafana/api/user`.
- `industream-hub` PR: add an auth message ID to the `AppFrame` protocol (`AppFrame.svelte:6-7,66`) and/or drop frames on logout in `app-frame.service.ts` (gap #4). Optionally re-export `loggedOut$` from `@industream/hub-auth` (gap #5).

### Phase 6 — Validation (1 d)

Four combinations must be exercised: **{swarm, compose} × {CE, EE}**. CE must be proven **unchanged** (still `auth.jwt`, still working). EE must be proven for: fresh login, deep-link tile, theme toggle, kiosk levels per role, Hub logout → Grafana session actually gone, second user login → no identity bleed, Grafana Live connects, token refresh over a long session.

Re-enable `GF_LIVE_MAX_CONNECTIONS` removal only after the Live WS is confirmed working.

---

## Open questions / to verify live

Each of these is a measurement, not a discussion. Q1 and Q2 are **go/no-go**.

| # | Question | Why it matters | How to answer |
|---|---|---|---|
| **Q1** | **Does `grafana_session` survive the doubly-nested iframe** (`<domain>` → `dashboard.<domain>` → `dashboard.<domain>/grafana/`)? | If not, OAuth buys nothing and the whole migration collapses. Theory says yes (same registrable domain ⇒ same-site ⇒ not a third-party cookie), but CHIPS has documented nested-frame failures, and a Next.js tile in this very stack failed to keep an iframe session cookie even same-origin. | Hand-configure `generic_oauth` on a live EE Grafana, log in, then reload the Hub tile and check DevTools → Application → Cookies for `dashboard.<domain>`. Test in Chrome **with third-party cookies blocked** as well as default. |
| **Q2** | **Is grafana/grafana#90200 still open?** Does `GF_AUTH_JWT_ENABLE_LOGIN_TOKEN=true` still fail to mint `grafana_session` on Grafana 13.0.1 and on the latest 13.x? | If fixed upstream, the entire migration is unnecessary — bump the image, re-enable Live, done. | Check the upstream issue; test on a scratch container with a forged Hub JWT (technique: sign in-container with the JWKS `kid` set, per prior debugging). |
| **Q3** | **What CSP / `X-Frame-Options` does self-hosted Logto 1.40.1 actually send** on `/oidc/auth` and the sign-in page? Is there an env var or reverse-proxy hook to relax `frame-ancestors`? | Determines whether E-1 (top-level bounce) is *mandatory* or whether an in-frame redirect is possible. §E.2 asserts it is blocked based on Helmet defaults — **this is unverified against a live instance.** | `curl -sI https://auth.<domain>/oidc/auth?...` and inspect. |
| **Q4** | **Which role vocabulary is authoritative** — `admin|editor|viewer` (seeded, Model A) or `industream-admin|…` (unseeded, Model B)? | Wrong choice ⇒ everyone silently lands on the `role_attribute_path` fallback. | Product/architecture decision. Then delete the loser. |
| **Q5** | **Is the `roles` user scope actually granted** on the live Logto tenant, or has an operator clicked it manually per-install? | Gap #6. Determines whether Phase 2 must seed it or merely verify it. | Query `applications_user_consent_scopes` on the live `logto` DB; test whether the current Hub session's JWT carries a non-`['user']` `roles` array. |
| **Q6** | **Does the Traefik `grafana-live` router work once a cookie exists?** (`unified/runtime/swarm/monitoring.yml:75-82`, priority 200) | The main functional payoff. The router bypasses the wrapper nginx (which is deliberately HTTP/1.0 with no Upgrade headers, `wrapper/nginx.conf:27-32`), so the WS goes straight to `grafana:3000` — the cookie must reach it. | Remove `GF_LIVE_MAX_CONNECTIONS=0` on a test stack and watch the WS handshake. |
| **Q7** | **Does the compose runtime's Caddy forward path behave the same as swarm's Traefik?** `unified/runtime/compose/auth.yml:8-11` explicitly warns *"⚠️ UNVERIFIED: the Caddy `forward_auth` → sign-in redirect UX has NOT been exercised on a live compose-EE stack"*. | Half the deployment matrix is unproven for OIDC redirects generally. | Stand up a compose-EE stack and exercise it. |
| **Q8** | **Does the popup path (E-2) share the cookie jar** with the embedded frame in Chrome, given same-site? | Determines whether E-2 is a viable, less-disruptive alternative to the top-level bounce. | Empirical, same test rig as Q1. |
| **Q9** | Should `grafana-direct.<domain>` (`unified/runtime/swarm/monitoring.yml:67,72`) become the official top-level OAuth entry point, and get its own `root_url`? | Would simplify E-1 substantially. Today its `root_url` points at `dashboard.<domain>/grafana/`, so redirects on it are wrong. | Design decision. |
| **Q10** | Is `unified/base/grafana.yml` on `feature/ironstream-integration` intended to merge? If so, note it **drops `GF_LIVE_MAX_CONNECTIONS=0` and the hubbridge plugin mount** that `origin/main` has. | Silent regression risk independent of this migration. | Ask the branch owner. Flag on the PR. |

---

## Sources (external)

- [Grafana — Configure generic OAuth authentication](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/generic-oauth/) — callback URL format, option list, `role_attribute_path` resolution order (ID token → UserInfo → access token), `signout_redirect_url`, `use_refresh_token`.
- [Grafana community — Chrome blocking 3rd party cookies when embedding](https://community.grafana.com/t/chrome-blocking-3rd-party-cookies-when-embedding/113302) — `grafana_*` cookies flagged by Chrome without `Partitioned`.
- [privacycg/CHIPS#88 — nested cross-origin iframes and partitioned auth cookies](https://github.com/privacycg/CHIPS/issues/88) — the "one frame logged in, one logged out" failure mode.
- [privacycg/CHIPS#82 — popups do not inherit the iframe's partition](https://github.com/privacycg/CHIPS/issues/82) — relevant to option E-2.
- [MDN — CSP `frame-ancestors`](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Content-Security-Policy/frame-ancestors) — every ancestor must be allowed; takes precedence over `X-Frame-Options`.
- [MDN — `X-Frame-Options`](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/X-Frame-Options) — `ALLOW-FROM` is ignored by modern browsers.
- grafana/grafana#90200 — `auth.jwt` + `url_login` no longer issues `grafana_session` (referenced throughout the stack's own comments, e.g. `unified/base/monitoring.yml:88-93`, `wrapper/sw.js:121-128`).
