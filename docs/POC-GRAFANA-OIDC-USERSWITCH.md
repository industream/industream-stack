# POC — Grafana `generic_oauth` + Logto: can a boot-time identity check prevent user-session carry-over?

**Date:** 2026-08-14
**Host:** swarm test VM `cdm@192.168.122.205`, stack `poc-grafana-oauth` (sandbox), Grafana `grafana-oss:13.0.1`, Logto `1.40.1` (`industream-prod`).
**Question:** with Grafana authenticating via Logto `generic_oauth` (not the Hub JWT), a `grafana_session` cookie appears. Does an on-load `/api/user` comparison + forced Grafana logout + reload actually swap the identity when the Hub switches user?

---

## Verdict

**The boot check works, and it is the only thing that works — but only in the exact form `GET /logout` *then* `GET /login/generic_oauth`, and only while the Logto browser session is alive.**

Proven on the VM, end to end:

1. `generic_oauth` **does** mint a real session cookie: `grafana_session=…; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=None` — a **30-day** session, completely independent of Logto. Confirmed (§2).
2. The carry-over bug is **real and reproducible**: after user A's Logto session is destroyed (RP-initiated `end_session`) and user B signs in at Logto, `GET /api/user` on Grafana **still returns A** (§4.2). Grafana never re-contacts the IdP: `use_refresh_token = false` and `validate_id_token = false` are the shipped defaults (§6.2).
3. The guard is **sufficient to swap identity**: `/logout` clears and **server-side revokes** the session, and the subsequent `/login/generic_oauth` completes as a **single 303 with no sign-in page and no consent page** — genuinely zero user interaction (§4.3, §5).
4. **The `/logout` step is mandatory, not cosmetic.** Calling `/login/generic_oauth` alone *does* switch the identity, but the **previous user's session token stays valid server-side** (`HTTP 200`, still user B, §6.1). Only `/logout` produces a `401` on replay (§5 H7). A guard that skips the logout leaves a live credential for the previous user behind.

**Where it breaks:** the guard is a *pull* with no trigger. It fires on frame load; nothing fires it when the Hub swaps user without re-mounting the iframe. And if the Logto browser session is *absent* rather than *different*, step 2 lands on Logto's rendered `/sign-in` page, which carries `frame-ancestors 'self' …` and **cannot render inside the Hub iframe** (§6.3). Full list in §7.

---

## Setup

### Configuration used — and why the *public* issuer URL

Grafana was pointed at the **external** Logto URL `https://auth.industream.platform.lan/oidc`, not the internal `http://logto:3001`.

Reason: the authorization endpoint is followed by the **browser**, so it must be the public URL anyway; and Logto is started with `ENDPOINT=https://auth.industream.platform.lan`, so its discovery document advertises the public issuer regardless of which URL you fetch it from. Using the internal URL for `token_url`/`api_url` would have produced an issuer/endpoint split for no benefit.

Two things had to be solved for that to work from inside the overlay network:

* **DNS** — the container cannot resolve `auth.industream.platform.lan`. Added a Swarm host entry (`--host-add auth.industream.platform.lan:192.168.122.205`, i.e. via the host IP → Traefik ingress).
* **TLS** — Traefik serves an internal cert the Grafana image does not trust. Used `GF_AUTH_GENERIC_OAUTH_TLS_SKIP_VERIFY_INSECURE=true` (POC only; in production ship the internal CA into the image/secret instead).

```
$ docker exec <poc-grafana> cat /etc/hosts
…
192.168.122.205	auth.industream.platform.lan

$ docker exec <poc-grafana> wget -qO- --no-check-certificate \
    https://auth.industream.platform.lan/oidc/.well-known/openid-configuration
{"authorization_endpoint":"https://auth.industream.platform.lan/oidc/auth", …
```

Applied to **`poc-grafana-oauth_poc-grafana` only** (`docker service update`):

```
GF_AUTH_PROXY_ENABLED=false                      # the previous POC's mechanism, disabled
GF_AUTH_GENERIC_OAUTH_ENABLED=true
GF_AUTH_GENERIC_OAUTH_NAME=Logto
GF_AUTH_GENERIC_OAUTH_CLIENT_ID=poc-grafana-app
GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=poc-grafana-secret-DO-NOT-REUSE-1234
GF_AUTH_GENERIC_OAUTH_SCOPES=openid profile email offline_access
GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://auth.industream.platform.lan/oidc/auth
GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://auth.industream.platform.lan/oidc/token
GF_AUTH_GENERIC_OAUTH_API_URL=https://auth.industream.platform.lan/oidc/me
GF_AUTH_GENERIC_OAUTH_TLS_SKIP_VERIFY_INSECURE=true
GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP=true
GF_AUTH_GENERIC_OAUTH_USE_PKCE=true
GF_AUTH_GENERIC_OAUTH_LOGIN_ATTRIBUTE_PATH=username
GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH=email
GF_AUTH_GENERIC_OAUTH_NAME_ATTRIBUTE_PATH=name
GF_LOG_FILTERS=authn.service:debug,oauth:debug,auth.proxy:debug
```

Reached from the VM only via `curl --resolve …:443:127.0.0.1` — no DNS record exists for `poc-grafana-raw.industream.platform.lan`.

### Logto objects added (add-only, `poc-` prefixed)

Registered by the same route the platform's own seeders use — direct SQL against `industream-prod_logto-postgres`, exactly the shape of
`packages/industream-hub-backend-enterprise/oidc-seeds/logto/seed-logto.sh` (Argon2i `time_cost=8, memory_cost=8192, parallelism=1, hash_len=32, salt_len=16, type=I`; `ON CONFLICT` upserts; tenant `default`).
The existing `industream-hub-app` application and the existing `admin` user were **not read for secrets, not modified and not deleted**. Because `admin`'s password is not available to this POC, **both** test users are new `poc-` users rather than reusing `admin`.

Difference from the Hub seeder: the app is `Traditional` (confidential client with a secret) rather than `SPA`, because Grafana's `generic_oauth` is a server-side client. Logto 1.40 keeps the secret in **two** places — `applications.secret` and a `application_secrets` row — so both were written.

```
       id        |           name            |    type     |                              oidc_client_metadata
-----------------+---------------------------+-------------+---------------------------------------------------------------------------------
 poc-grafana-app | POC Grafana generic_oauth | Traditional | {"redirectUris": ["https://poc-grafana-raw.industream.platform.lan/login/generic_oauth"], "postLogoutRedirectUris": ["https://poc-grafana-raw.industream.platform.lan/"]}
(1 row)

    id     | username  |    primary_email    |    name
-----------+-----------+---------------------+------------
 poc-usera | poc-usera | poc-usera@poc.local | POC User A
 poc-userb | poc-userb | poc-userb@poc.local | POC User B
(2 rows)
```

### How the browser was simulated

No browser was used. Logto's sign-in UI is an SPA over a JSON **Experience API**, which is drivable from `curl` with a cookie jar. The exact sequence (all inside one jar, i.e. one "browser"):

```
PUT  /api/experience                       {"interactionEvent":"SignIn"}          -> 204
POST /api/experience/verification/password {"identifier":{"type":"username",…},"password":…}
                                                                                  -> {"verificationId":"…"}
POST /api/experience/identification        {"interactionEvent":"SignIn","verificationId":…} -> 204
POST /api/experience/submit                {}                                     -> {"redirectTo":"…/oidc/auth/<uid>"}
POST /api/interaction/consent              {}      (first grant only)             -> {"redirectTo":"…"}
```

Scripts left on the VM in `~/poc-grafana-oidc-userswitch/`: `seed-poc.sh`, `update-grafana.sh`, `oidc.sh`, `guard.sh`.

---

## 1. The authorization request

```
$ curl -sk -c jarA.txt -D - -o /dev/null \
    --resolve poc-grafana-raw.industream.platform.lan:443:127.0.0.1 \
    https://poc-grafana-raw.industream.platform.lan/login/generic_oauth
HTTP/2 302
location: https://auth.industream.platform.lan/oidc/auth?client_id=poc-grafana-app&code_challenge=WF5ffKn9RmWfME3v8of9k7Hfj9PYJXmQHl0JIadRMDE&code_challenge_method=S256&redirect_uri=https%3A%2F%2Fpoc-grafana-raw.industream.platform.lan%2Flogin%2Fgeneric_oauth&response_type=code&scope=openid+profile+email+offline_access&state=aw1gG2czqPBdy7BGDnx8-MBKv8_t6p8SRSQc0a5nGzo%3D
set-cookie: oauth_state=18edc6362c4dba0c30a665f43e79786165f57255946d04d2bfea7dc64e7f1dfb; Path=/; Max-Age=600; HttpOnly; Secure; SameSite=None
set-cookie: redirectTo=; Path=/; Max-Age=600; HttpOnly; Secure; SameSite=None
set-cookie: oauth_code_verifier=GAbdcMCJ-0MyljS4tN5hXTHsfvY-YmbHJHKnZu25GsA7QasN5Lam5axhKnXGgG6So9GJgLHve5KME5hnA03TblCbiLgJqz2wQW96PIOA79JkbykZFLj4OUKMRdEMSROV; Path=/; Max-Age=600; HttpOnly; Secure; SameSite=None
```

PKCE S256 is in use. Note the three short-lived transaction cookies are also `SameSite=None` — they must survive the round trip in whatever framing context the flow runs in.

Following it to Logto:

```
--- [2] GET authorization endpoint
HTTP/2 303
location: /sign-in?app_id=poc-grafana-app
set-cookie: _logto={"appId":"poc-grafana-app"}; path=/; samesite=lax; secure
set-cookie: _interaction={"poc-grafana-app":"f1LnYujfHsE4PmAlqGDlm","_legacy":"f1LnYujfHsE4PmAlqGDlm"}; path=/; expires=Fri, 14 Aug 2026 11:22:41 GMT; samesite=lax; secure; httponly
set-cookie: _interaction.sig=Vn_9l8tKZFr3bNwtjSlvV-Zigsk; …
set-cookie: _interaction_resume=f1LnYujfHsE4PmAlqGDlm; path=/oidc/auth/f1LnYujfHsE4PmAlqGDlm; …
```

Logto's own cookies are `SameSite=Lax` — a second reason the sign-in leg cannot be driven from inside a cross-site iframe.

---

## 2. Does `generic_oauth` mint a `grafana_session`? — **YES**

Full flow as `poc-usera`, ending at the Grafana callback:

```
--- [1] GET https://poc-grafana-raw.industream.platform.lan/login/generic_oauth
HTTP/2 302
--- [2] GET authorization endpoint
HTTP/2 303
location: /sign-in?app_id=poc-grafana-app
--- [3] experience API sign-in as poc-usera
    PUT /api/experience -> 204
    verificationId=b947eixd9k8p34tg6oby2
    POST /api/experience/identification -> 204
    submit -> https://auth.industream.platform.lan/oidc/auth/9FTAz-u_TedAvB1rb38gr
--- [4.1] GET https://auth.industream.platform.lan/oidc/auth/9FTAz-u_TedAvB1rb38gr
HTTP/2 303
location: /consent?app_id=poc-grafana-app
--- [4.1-consent] POST /api/interaction/consent
    {"redirectTo":"https://auth.industream.platform.lan/oidc/auth/38KSKLOUDOc6RFIwxlJBV"}
--- [4.2] GET https://auth.industream.platform.lan/oidc/auth/38KSKLOUDOc6RFIwxlJBV
HTTP/2 303
location: https://poc-grafana-raw.industream.platform.lan/login/generic_oauth?code=gGxXvXA5-JAteRJZnGErYCzwAnRWCtjS3A7r3bXIq3R&state=oGWzEbUIkEYI_Ihwnzleg4FS8r4flNpngmwaXGLXUZI%3D&iss=https%3A%2F%2Fauth.industream.platform.lan%2Foidc
--- [5] GET Grafana callback
HTTP/2 302
location: /
set-cookie: oauth_state=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=None
set-cookie: oauth_code_verifier=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=None
set-cookie: grafana_session=f70599425db9dfbdaf384b0eecbc04ac; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=None
set-cookie: grafana_session_expiry=1786703700; Path=/; Max-Age=2592000; Secure; SameSite=None
set-cookie: redirectTo=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=None
```

### The cookie, in full

| attribute | value | consequence |
|---|---|---|
| name | `grafana_session` | (as configured by `GF_AUTH_LOGIN_COOKIE_NAME`) |
| `Max-Age` | `2592000` = **30 days** | Grafana's identity outlives any Logto session by design |
| `HttpOnly` | yes | JS in the frame cannot read or delete it — **the guard cannot clear it client-side; it must call `/logout`** |
| `Secure` | yes | fine, everything is HTTPS |
| `SameSite` | `None` | required for the iframe; also makes it a third-party cookie |
| `Path` | `/` | — |
| domain | host-only (`poc-grafana-raw.…`), no `Domain=` attribute | not shared with the Hub origin |

A companion `grafana_session_expiry` is set **without `HttpOnly`** — JS-readable, but it carries only an expiry timestamp, no identity. It is not a substitute for the `/api/user` call.

**This is the first and decisive difference from `auth.jwt`:** under `auth.jwt` Grafana holds nothing; here it holds a 30-day bearer credential that the IdP has no way to reach.

Identity confirmed:

```
$ curl -sk -b jarA2.txt … /api/user
{
    "id": 16,
    "email": "poc-usera@poc.local",
    "name": "POC User A",
    "login": "poc-usera",
    "isExternal": true,
    "isExternallySynced": true,
    "authLabels": ["Generic OAuth"],
    …
}
```

---

## 3. A second user, separate cookie jar

```
HTTP 200  login=poc-userb email=poc-userb@poc.local name=POC User B id=17 authLabels=['Generic OAuth']

=== A still A? ===
HTTP 200  login=poc-usera email=poc-usera@poc.local name=POC User A id=16 authLabels=['Generic OAuth']
```

Two distinct Grafana users auto-provisioned from Logto (`id=16`/`id=17`), `login` mapped from the Logto `username` claim.

---

## 4. The core test — one browser, Hub switches user

Single cookie jar `jarC` = one browser holding both the Grafana and the Logto cookies.

### 4.1 Ending user A's Logto session properly

`GET /oidc/session/end` alone is **not** a logout — with no `id_token_hint` it returns the oidc-provider confirmation page and even re-issues `_session`:

```
--- GET https://auth.industream.platform.lan/oidc/session/end
HTTP/2 200
set-cookie: _session=Fyw2bN8KA1BDtkPNU-FA1; path=/; samesite=lax; secure; httponly; expires=Fri, 28 Aug 2026 10:25:33 GMT
```

The page auto-submits a form; posting it is the real logout:

```
$ curl … https://auth.industream.platform.lan/oidc/session/end | head -c 2000
<body onload="document.getElementById('op.logoutForm').submit();">
  <form id="op.logoutForm" method="post" action="https://auth.industream.platform.lan/oidc/session/end/confirm"><input type="hidden" name="xsrf" value="9beadd1c8720692f984a05189c6d77648e7b9c930fe9e83e"/></form>
  <input type="hidden" form="op.logoutForm" value="yes" name="logout" />
</body>

### POST /oidc/session/end/confirm
HTTP/2 303
location: https://auth.industream.platform.lan/oidc/session/end/success
set-cookie: _session=; path=/; expires=Thu, 01 Jan 1970 00:00:00 GMT; samesite=lax; secure; httponly
set-cookie: _session.sig=xxXTbyFsOQWzguWtZX1_yF9qx24; path=/; expires=Thu, 01 Jan 1970 00:00:00 GMT; samesite=lax; secure; httponly

### Logto session state: request /oidc/auth again (no prompt) ###
HTTP/2 303
location: /sign-in?app_id=poc-grafana-app
```

Logto now has no session — the next authorization request is bounced to `/sign-in`.

### 4.2 Grafana does not care — carry-over confirmed

```
########## C4: /api/user with jarC after REAL Logto logout ##########
HTTP 200  login=poc-usera email=poc-usera@poc.local name=POC User A id=16 authLabels=['Generic OAuth']

########## C5: sign in as B at Logto ONLY (code discarded) ##########
    PUT /api/experience -> 204
    verificationId=6yzohp24nq2k9wzai4gvl
    POST /api/experience/identification -> 204
    submit -> https://auth.industream.platform.lan/oidc/auth/nDJ6BWNf76QpnIWipHCPi
--- [4.1] GET …/oidc/auth/nDJ6BWNf76QpnIWipHCPi
HTTP/2 303
location: /consent?app_id=poc-grafana-app
--- [4.1-consent] POST /api/interaction/consent
    {"redirectTo":"https://auth.industream.platform.lan/oidc/auth/qHunVpb0xgLIjWozsvbJF"}
--- [4.2] GET …/oidc/auth/qHunVpb0xgLIjWozsvbJF
HTTP/2 303
location: https://poc-grafana-raw.industream.platform.lan/login/generic_oauth?code=ojMakiYCyoZFIH5vv3MW9N177ZUtt0QJt7-dTOUYRk9&…
    (idponly mode: code DISCARDED, never delivered to Grafana)

########## C6: /api/user — Logto session is now B ##########
HTTP 200  login=poc-usera email=poc-usera@poc.local name=POC User A id=16 authLabels=['Generic OAuth']
```

**The browser's IdP session belongs to B; Grafana still serves A.** This is the failure the whole task is about, and it is real.

### 4.3 The guard

```
########## C7: GET /logout ##########
HTTP/2 302
location: /login
set-cookie: grafana_session=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=None
set-cookie: grafana_session_expiry=; Path=/; Max-Age=0; Secure; SameSite=None

########## C8: /api/user after GET /logout ##########
HTTP 401
```

`GET /logout` works (no CSRF token, no POST needed) and, because `signout_redirect_url` is empty, it stays **local** — it does *not* propagate to Logto, so it does not destroy B's brand-new IdP session. That is exactly the behaviour the guard needs.

```
########## C9: re-run /login/generic_oauth (Logto session = B) ##########
--- [1] GET https://poc-grafana-raw.industream.platform.lan/login/generic_oauth
HTTP/2 302
location: https://auth.industream.platform.lan/oidc/auth?client_id=poc-grafana-app&code_challenge=…
--- [2] GET authorization endpoint
HTTP/2 303
location: https://poc-grafana-raw.industream.platform.lan/login/generic_oauth?code=HxR_-rn1HJhEQoVbi0pKwzHypZ_O-P3WVVwBoiiowO6&state=…&iss=https%3A%2F%2Fauth.industream.platform.lan%2Foidc
    >>> CODE ISSUED (no sign-in, no consent - silent SSO)
--- [5] GET Grafana callback
HTTP/2 302
location: /
set-cookie: grafana_session=eadaf75d54e2757cd321f9e5dbccc28b; …

########## C10: /api/user ##########
HTTP 200  login=poc-userb email=poc-userb@poc.local name=POC User B id=17 authLabels=['Generic OAuth']
```

The re-authentication is **one 303**. No `/sign-in`, no `/consent`, no rendered Logto document, no typing. Two HTTP round trips.

---

## 5. Clean end-to-end rehearsal of the guard

`~/poc-grafana-oidc-userswitch/guard.sh`, single jar:

```
===== H1  user A signs in through Grafana generic_oauth =====
  grafana_session(A) = ea4f3a6588e49beecee4591cbfa35f12
HTTP 200  login=poc-usera email=poc-usera@poc.local name=POC User A id=16 authLabels=['Generic OAuth']

===== H2  Hub switches user: Logto session A ends, B signs in at Logto only =====
  end_session/confirm -> HTTP 303
  Logto browser session now belongs to poc-userb (code never delivered to Grafana)

===== H3  BEFORE the guard: what does Grafana think? =====
HTTP 200  login=poc-usera email=poc-usera@poc.local name=POC User A id=16 authLabels=['Generic OAuth']

===== H4  GUARD step 1: GET /logout =====
HTTP/2 302
location: /login
set-cookie: grafana_session=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=None
set-cookie: grafana_session_expiry=; Path=/; Max-Age=0; Secure; SameSite=None
  -> /api/user:
HTTP 401

===== H5  GUARD step 2: GET /login/generic_oauth (no user interaction) =====
HTTP/2 302
HTTP/2 303
    >>> CODE ISSUED (no sign-in, no consent - silent SSO): https://poc-grafana-raw.industream.platform.lan/login/generic_oauth?code=z3wfBpS52LoDMTdW1_huREJZQ47sCntNwes0n_45hJq&…
HTTP/2 302
set-cookie: grafana_session=5b86084ec80e28f97f72f263de5503e5; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=None
  grafana_session(B) = 5b86084ec80e28f97f72f263de5503e5

===== H6  AFTER the guard =====
HTTP 200  login=poc-userb email=poc-userb@poc.local name=POC User B id=17 authLabels=['Generic OAuth']

===== H7  is A's old session token still usable? =====
  replay grafana_session(A) -> HTTP 401
```

---

## 6. Secondary findings

### 6.1 Skipping `/logout` "works" — and leaves a live session behind

Re-running only `/login/generic_oauth`, with the stale session still present, *does* swap the identity:

```
########## F2: /api/user (still B, stale) ##########
HTTP 200  login=poc-userb … id=17
########## F3: hit /login/generic_oauth WITHOUT calling /logout ##########
    >>> CODE ISSUED (no sign-in, no consent - silent SSO): …
set-cookie: grafana_session=55c9fe6a8ed717ac136612ca09c8e11e; …
########## F4: /api/user after ##########
HTTP 200  login=poc-usera … id=16
```

But the **displaced** session token is not revoked:

```
########## G1: is user B's previous grafana_session (eadaf75d…) still valid after F3 re-login? ##########
{"id":17,"uid":"dfv5csafag7i8a","email":"poc-userb@poc.local","name":"POC User B","login":"poc-userb", …}
[200]
```

versus, after a real `/logout`:

```
########## D1: is A's pre-logout grafana_session still valid server-side? ##########
#HttpOnly_poc-grafana-raw.industream.platform.lan	FALSE	/	TRUE	1789295133	grafana_session	417d4e7e6d3063ae4192fe0309471fa2
HTTP 401
```

**Implementation rule: the guard must be `/logout` → `/login/generic_oauth`, in that order. Never the login alone.**

### 6.2 Grafana has no way to learn about the logout, and no way to notice on its own

`defaults.ini` in the running 13.0.1 image, confirmed again here:

```
$ docker exec <poc-grafana> grep -inE "backchannel|frontchannel|logout" /usr/share/grafana/conf/defaults.ini
$                       # (no output — zero matches)
```

And the shipped `[auth.generic_oauth]` defaults:

```
use_refresh_token = false
validate_id_token = false
signout_redirect_url =
…
```

Grafana never re-validates with the IdP after the callback. `token_rotation_interval_minutes = 10` rotates Grafana's *own* session, not the OIDC token. Combined with `Max-Age=2592000`, an abandoned identity survives up to `login_maximum_lifetime_duration` (30 d default) / 7 d inactivity.

Even turning `use_refresh_token = true` on would not close the window, because the access token lives an hour. Manual code exchange against Logto, using the PKCE verifier read out of Grafana's own cookie jar:

```
### POST /oidc/token (manual exchange, client_secret_basic) ###
{'access_token': '-kRLb8vGzaAE0cFtbZf6ET6c…', 'expires_in': 3600, 'id_token': 'eyJhbGciOiJFUzM4NCIsInR5…', 'scope': 'openid profile email', 'token_type': 'Bearer'}
```

Two things to note: **`expires_in: 3600`** (so a refresh-driven check would still allow up to an hour of stale identity), and **no `refresh_token` at all** despite `offline_access` being requested — Logto drops it (returned `scope` is `openid profile email`) unless the app carries `custom_client_metadata.alwaysIssueRefreshToken`, which the Hub's seeder sets for `industream-hub-app` and this POC app deliberately does not. Refresh-based invalidation is therefore not a drop-in alternative to the boot check.

### 6.3 The no-session case is not silent — and Logto cannot render in the frame

If the Logto browser session is *missing* rather than *different*, step 2 stops at a rendered page:

```
########## E1: fresh jar, no Logto session -> /login/generic_oauth ##########
--- [1] GET https://poc-grafana-raw.industream.platform.lan/login/generic_oauth
HTTP/2 302
--- [2] GET authorization endpoint
HTTP/2 303
location: /sign-in?app_id=poc-grafana-app
```

and that page refuses to be framed by the Hub:

```
########## E2: headers of Logto /sign-in (rendered document) ##########
content-security-policy: … frame-ancestors 'self' http://localhost:3002 https://auth-admin.industream.platform.lan; …
########## E3: headers of Logto /consent ##########
content-security-policy: … frame-ancestors 'self' http://localhost:3002 https://auth-admin.industream.platform.lan; …
```

`https://industream.platform.lan` is not in `frame-ancestors`. So the guard is silent **only** on the happy path (live Logto session + grant already given). Anything else needs a top-level bounce or a popup — the same constraint `POC-GRAFANA-AUTHPROXY-RESULTS.md` §4.1 already documented.

Note also that the **first ever login of a given user** goes through `/consent` (§2, `[4.1]`), a rendered Logto document. It auto-submits in a real browser, but it is a Logto document and therefore un-frameable. First login per user must happen outside the iframe.

---

## 7. Failure modes of the boot check

1. **No trigger.** The check runs on frame load. If the Hub swaps user while keeping the Grafana iframe mounted (SPA route change, hidden/cached tile, bfcache restore, background tab), nothing runs and A's dashboards stay on screen. Needs an explicit "identity changed" event from the Hub to the frame (postMessage / the existing SharedWorker bridge), not just an `onload` hook.
2. **Leak window before the check resolves.** The frame renders and starts firing dashboard queries as A while `/api/user` is still in flight. Data for A is fetched, and possibly painted, before the guard fires. The frame must be blocked (blank/overlay) until the check returns.
3. **Empty Logto session ⇒ visible breakage.** §6.3: `/sign-in` cannot render in the frame. The guard turns a wrong-identity bug into a blank iframe unless it detects the case and escalates to a top-level bounce.
4. **First login per user hits `/consent`.** Also un-frameable (§6.3).
5. **Third-party cookie / CHIPS.** `grafana_session` is `SameSite=None` and host-only. If Chrome partitions or drops it in the nested-iframe context, `/api/user` returns 401 on every boot and the guard loops through a full OIDC round trip on every frame load. Untested — no browser here.
6. **What identity do you compare?** Grafana's `/api/user.login` is the Logto `username` claim (`login_attribute_path=username`). The Hub's own notion of identity is the `sub`. These coincide for seeder-created users only because `seed-logto.sh` uses the username as the user id when it fits 12 chars — not a guarantee. Compare on `email`, or pin `login_attribute_path=sub`, and decide deliberately.
7. **`/logout` is unconditional.** It always costs a full re-auth. Comparing first (as designed) avoids that, but a mis-parsed comparison (e.g. `/api/user` returning 401 because of a dropped cookie) causes a logout+relogin storm.
8. **Nothing protects a non-boot path.** Direct links, opening Grafana in a new tab outside the Hub, or a bookmarked dashboard bypass the wrapper entirely and get the stale session. The 30-day cookie is reachable from any tab on that origin.
9. **Loop risk.** If the guard's own `/login/generic_oauth` lands back on a Grafana identity that still mismatches (e.g. Logto's session did not actually change, or the compare key is wrong), the check re-fires on the reload. Needs a one-shot marker in `sessionStorage` and a hard stop.

---

## 8. What could not be tested without a real browser

* **Everything about framing.** All results above are `curl`. Whether `grafana_session` (`SameSite=None`, host-only) survives inside a nested cross-site iframe under Chrome's third-party cookie restrictions and CHIPS partitioning is **unknown** — and it decides whether the guard is a rare corrective action or fires on every single load. Same unknown as `POC-GRAFANA-AUTHPROXY-RESULTS.md` §"remaining unknowns"; this POC does not close it.
* **Whether the silent 303 chain is actually allowed to run inside the iframe.** No Logto *document* is rendered on the happy path, so `frame-ancestors` should not bite, but redirect handling in a framed navigation was not observed in a browser.
* **Logto's `/consent` auto-submit.** Driven here by `POST /api/interaction/consent`; the real page does it with JS. Behaviour of that JS inside a frame is untested (and moot, since the page is un-frameable anyway).
* **Timing/paint.** Failure mode 2 (leak window) is reasoned from the architecture, not measured.
* **The expiry-driven path.** `expires_in: 3600` was read from a real token response, but no test waited an hour, and Logto issued no refresh token for this app, so `use_refresh_token=true` behaviour after an IdP logout is unverified.
* **Grafana's `role_attribute_path` / Logto `roles` claim.** Out of scope here; still unverified from the earlier POC.

---

## 9. Teardown

### Docker (sandbox stack only)

Either revert the service to its pre-POC configuration:

```bash
ssh cdm@192.168.122.205 'docker service update --detach=false \
  --host-rm "auth.industream.platform.lan:192.168.122.205" \
  --env-rm GF_AUTH_GENERIC_OAUTH_ENABLED \
  --env-rm GF_AUTH_GENERIC_OAUTH_NAME \
  --env-rm GF_AUTH_GENERIC_OAUTH_CLIENT_ID \
  --env-rm GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET \
  --env-rm GF_AUTH_GENERIC_OAUTH_SCOPES \
  --env-rm GF_AUTH_GENERIC_OAUTH_AUTH_URL \
  --env-rm GF_AUTH_GENERIC_OAUTH_TOKEN_URL \
  --env-rm GF_AUTH_GENERIC_OAUTH_API_URL \
  --env-rm GF_AUTH_GENERIC_OAUTH_TLS_SKIP_VERIFY_INSECURE \
  --env-rm GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP \
  --env-rm GF_AUTH_GENERIC_OAUTH_USE_PKCE \
  --env-rm GF_AUTH_GENERIC_OAUTH_LOGIN_ATTRIBUTE_PATH \
  --env-rm GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH \
  --env-rm GF_AUTH_GENERIC_OAUTH_NAME_ATTRIBUTE_PATH \
  --env-add GF_AUTH_PROXY_ENABLED=true \
  --env-add "GF_LOG_FILTERS=authn.service:debug,auth.proxy:debug,live:debug" \
  poc-grafana-oauth_poc-grafana'
```

or drop the whole sandbox (also disposes of the Grafana sqlite users `id=16`/`id=17`):

```bash
ssh cdm@192.168.122.205 'docker stack rm poc-grafana-oauth && docker volume rm poc-grafana-oauth_poc-grafana-data'
```

Scratch scripts: `rm -rf ~/poc-grafana-oidc-userswitch` on the VM.

### Logto SQL (removes exactly what this POC added)

```sql
-- container: docker ps --filter label=com.docker.swarm.service.name=industream-prod_logto-postgres
-- psql -U postgres -d logto
DELETE FROM application_secrets
 WHERE tenant_id = 'default' AND application_id = 'poc-grafana-app';

DELETE FROM applications
 WHERE id = 'poc-grafana-app';          -- cascades application_user_consent_* rows

DELETE FROM users
 WHERE tenant_id = 'default' AND username IN ('poc-usera', 'poc-userb');
```

Verify nothing `poc-` is left:

```sql
SELECT id, name, type FROM applications WHERE id LIKE 'poc-%';
SELECT id, username FROM users WHERE username LIKE 'poc-%';
```

Not deleted, and not necessary to delete: transient `oidc_model_instances` rows (sessions, grants, authorization codes) created during the runs — they carry their own expiry — and `logs` audit rows. Nothing under `industream-hub-app` or the `admin` user was touched.

---

## 10. Implications

* **`generic_oauth` genuinely introduces a second, independent 30-day identity.** That is the whole cost of leaving `auth.jwt`. Any move to OIDC must ship a session-reconciliation mechanism; it is not optional and it is not free.
* **The boot check is the right mitigation** — it is the only one available, since Grafana 13.0.1 cannot receive a backchannel logout and does not poll the IdP. It is cheap (one `/api/user`), works, and needs no Grafana patch.
* **Specify it precisely**: block the frame → `GET /api/user` → compare (on a claim you have deliberately chosen, §7.6) → if different **`GET /logout` first**, then `GET /login/generic_oauth`, then unblock. Add a `sessionStorage` one-shot guard against loops.
* **It is not sufficient on its own.** Add an explicit identity-changed signal from the Hub to the frame (failure mode 1), and a top-level-bounce escape hatch for the no-IdP-session and first-consent cases (failure modes 3 and 4).
* **The remaining showstopper is unchanged and is not this one**: whether the OIDC redirect chain and the `SameSite=None` cookies survive a real nested iframe in Chrome. That still needs a browser test before any of this is costed.
* **Do not ship the POC shortcuts.** `tls_skip_verify_insecure=true`, the host-entry hack, and the plaintext client secret exist only because this is a sandbox. Production needs the internal CA in the image (or a resolvable, trusted endpoint) and the secret in a Docker secret.
