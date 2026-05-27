# FlowMaker JWT Auth Overlay — Implementation Plan

> **SUPERSEDED (2026-05-27)** — Keycloak has been removed from the community
> stack; auth now goes through the hub-backend (uifusion-api in JWKS mode).
> See README.md and the V2-AUTH-MIGRATION plan in industream-cli.

> **SUPERSEDED (2026-05-27)** — Keycloak has been removed from the community
> stack; auth now goes through the hub-backend (uifusion-api in JWKS mode).
> See README.md and the V2-AUTH-MIGRATION plan in industream-cli.

> **SUPERSEDED (2026-05-27)** — Keycloak has been removed from the community
> stack; auth now goes through the hub-backend (uifusion-api in JWKS mode).
> See README.md and the V2-AUTH-MIGRATION plan in industream-cli.

> **SUPERSEDED (2026-05-27)** — Keycloak has been removed from the community
> stack; auth now goes through the hub-backend (uifusion-api in JWKS mode).
> See README.md and the V2-AUTH-MIGRATION plan in industream-cli.

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in JWT authentication mode to the FlowMaker stack via a dedicated Docker overlay, so the platform can be deployed with the legacy 2.0.2 (no auth) or the upcoming 2.0.3-dev (JWT via UIFusion-as-hub-backend) without forking the base stack files.

**Architecture:** A new optional overlay `docker-stack.flowmaker-auth.yml` is stacked on top of `docker-stack.flowmaker.yml` (and `docker-stack.yml` for the UIFusion override) when `FLOWMAKER_AUTH_ENABLED=true` or `--with-jwt-auth` is passed to `scripts/deploy-swarm.sh`. The overlay:

1. Bumps `flowmaker-scheduler` / `flowmaker-confighub` images to a JWT-capable version, exposes the dual-port architecture (internal vs JWT-protected public), and injects `FM_AUTH_*` + `FM_CORS_*` vars.
2. Overrides `uifusion-api` to act as `industream-hub-backend` (port 3050, `IH_*` vars enabling the `/auth/jwks` endpoint), with a network alias so existing `http://industream-hub-backend:3050/...` references in third-party services resolve transparently.
3. Reroutes Traefik labels to point to the new public JWT ports.

**Tech Stack:** Docker Swarm, Docker Compose v2 (for `config` validation), Traefik (existing), Bash (deploy script), UIFusion 1.0.8 (existing image, new mode), FlowMaker `2.0.3-dev` (scheduler + confighub-v2).

---

## File Structure

| File | Responsibility | Created/Modified |
|---|---|---|
| `docker-stack.flowmaker-auth.yml` | New overlay: dual-port FlowMaker + UIFusion-as-hub-backend overrides. | **Create** |
| `.env.example` | Document new `FLOWMAKER_AUTH_ENABLED`, `FLOWMAKER_CORE_VERSION_AUTH`, `UIFUSION_API_VERSION` bump, `HUB_*` vars. | Modify |
| `scripts/deploy-swarm.sh` | Add `--with-jwt-auth` CLI flag + auto-stack the overlay when `FLOWMAKER_AUTH_ENABLED=true`. | Modify |
| `scripts/setup/create-secrets.sh` | Register two new base secrets: `hub_backend_admin_user`, `hub_backend_admin_password`. | Modify |
| `scripts/tests/test-jwt-overlay.sh` | Smoke test: validates compose syntax, checks JWKS endpoint, performs a login + JWT decode round-trip. | **Create** |
| `docs/runbook/jwt-auth.md` | Operator-facing runbook: enabling the overlay, secret rotation, rollback procedure. | **Create** |
| `SWARM-DEPLOYMENT.md` | Add the `--with-jwt-auth` flag to the documented command-line surface. | Modify |

---

## Pre-flight assumptions (documented for the executing engineer)

- The branch `feature/flowmaker-jwt-auth-overlay` has already been created from `integration/compose-swarm`.
- The image `${DOCKER_REGISTRY}/uifusion/api:1.0.8` exposes the `/auth/jwks` endpoint when launched with `IH_*` env vars. If smoke test in Task 7 fails because the endpoint 404s, the plan executor must stop and ask for clarification on the UIFusion version that ships the hub-backend mode.
- The image `${DOCKER_REGISTRY}/flowmaker.core/flowmaker-launcher:2.0.3-dev` honours `FM_RUNTIME_BACKEND_PORT` (internal) **and** opens a second listener for JWT traffic. This is the FlowMaker dual-port contract documented in `industream-flowmaker/deployment/docker-compose.yml:12-30` (commit `32c013d`).
- The traefik network alias mechanism is supported on the Swarm runtime used here. The repo already uses aliases elsewhere — verify with `grep -n aliases docker-stack.yml docker-stack.flowmaker.yml` in Task 2 before coding the alias.

---

## Task 1 — Add JWT-mode env vars and version pins to `.env.example`

**Files:**
- Modify: `.env.example`

- [ ] **Step 1: Add a new section block at the end of the FlowMaker block (currently lines 121-127)**

Find the existing block:

```bash
# ============================================
# FlowMaker Configuration
# ============================================
FLOWMAKER_CORE_VERSION=2.0.2
FLOWMAKER_FRONTEND_VERSION=2.0.2-dev
FLOWMAKER_BOX_VERSION=2.0.5
FLOWMAKER_TOOLKIT_VERSION=1.10.1
```

Replace it with:

```bash
# ============================================
# FlowMaker Configuration
# ============================================
FLOWMAKER_CORE_VERSION=2.0.2
FLOWMAKER_FRONTEND_VERSION=2.0.2-dev
FLOWMAKER_BOX_VERSION=2.0.5
FLOWMAKER_TOOLKIT_VERSION=1.10.1

# ============================================
# FlowMaker JWT Auth (opt-in overlay)
# ============================================
# Toggle the docker-stack.flowmaker-auth.yml overlay. When `true`, the deploy
# script stacks the overlay AFTER docker-stack.flowmaker.yml and bumps:
#   - flowmaker-scheduler + flowmaker-confighub to FLOWMAKER_CORE_VERSION_AUTH
#   - uifusion-api to UIFUSION_API_VERSION (must be >= 1.0.8 for /auth/jwks)
# See docs/runbook/jwt-auth.md before enabling on a running cluster.
FLOWMAKER_AUTH_ENABLED=false
FLOWMAKER_CORE_VERSION_AUTH=2.0.3-dev

# Issuer + audience the FlowMaker services validate JWTs against. Must match
# the hub-backend (UIFusion-API) configuration. Defaults match the upstream
# FlowMaker deployment repo (industream-flowmaker/deployment).
FM_AUTH_ISSUER=hub-backend
FM_AUTH_AUDIENCE=industream-hub

# CORS origin for the JWT-protected public ports. Set to the hostname users
# load FlowMaker UI from. Multiple origins: comma-separated.
FM_CORS_ORIGIN=https://flowmaker.${INDUSTREAM_DOMAIN}

# Bootstrap admin credentials for the hub-backend (UIFusion-API in hub mode).
# IMPORTANT: leave these blank in .env, they are populated from Docker secrets
# `hub_backend_admin_user` and `hub_backend_admin_password` at deploy time by
# scripts/setup/create-secrets.sh. The dev fallback is "admin"/"admin" — never
# use it in prod.
HUB_BACKEND_ADMIN_USER=
HUB_BACKEND_ADMIN_PASSWORD=
```

- [ ] **Step 2: Bump `UIFUSION_API_VERSION` to 1.0.8 (current value: 1.0.6)**

Find line `UIFUSION_API_VERSION=1.0.6` (currently in the "FlowMaker Workers Versions" block, around line 179). Change to:

```bash
UIFUSION_API_VERSION=1.0.8
```

Add an inline comment above:

```bash
# Must be >= 1.0.8 when FLOWMAKER_AUTH_ENABLED=true (exposes /auth/jwks).
UIFUSION_API_VERSION=1.0.8
```

- [ ] **Step 3: Verify the file still parses as a valid env file**

Run: `bash -c 'set -a; source .env.example; set +a; env | grep -E "FLOWMAKER_AUTH|FM_AUTH|HUB_BACKEND" | sort'`
Expected output (exact order, exact values):

```
FLOWMAKER_AUTH_ENABLED=false
FLOWMAKER_CORE_VERSION_AUTH=2.0.3-dev
FM_AUTH_AUDIENCE=industream-hub
FM_AUTH_ISSUER=hub-backend
FM_CORS_ORIGIN=https://flowmaker.${INDUSTREAM_DOMAIN}
HUB_BACKEND_ADMIN_PASSWORD=
HUB_BACKEND_ADMIN_USER=
```

(`FM_CORS_ORIGIN` still contains the literal `${INDUSTREAM_DOMAIN}` because `set -a` doesn't recursively interpolate. That's fine — `docker compose` does the interpolation later.)

- [ ] **Step 4: Commit**

```bash
git add .env.example
git commit -m "feat(flowmaker): add JWT auth opt-in env vars (disabled by default)"
```

---

## Task 2 — Inspect existing alias pattern before coding the overlay

**Files:**
- Inspect only (no modifications)

- [ ] **Step 1: Look for existing network aliases in the repo**

Run: `grep -nA2 "aliases:" docker-stack*.yml`

Expected: either an existing alias example to follow, OR no results (meaning the overlay introduces the pattern for the first time). Record which case applies as context for Task 3.

- [ ] **Step 2: Confirm uifusion-api currently binds port 3001**

Run: `grep -n "port=3001\|3001" docker-stack.yml`

Expected: at least one match on `traefik.http.services.${ENV}-uifusion-api.loadbalancer.server.port=3001` (line ~208) and `wget --spider http://localhost:3001/health` (line ~191).

- [ ] **Step 3: Confirm scheduler/confighub currently bind 3120 / 4000**

Run: `grep -nE "loadbalancer\.server\.port=(3120|4000|3000)" docker-stack.flowmaker.yml`

Expected: three matches — 3120 (scheduler), 4000 (confighub), 3000 (logging — leave untouched). Record line numbers; they're the labels the overlay must override.

- [ ] **Step 4: No commit (inspection only)**

---

## Task 3 — Create `docker-stack.flowmaker-auth.yml`

**Files:**
- Create: `docker-stack.flowmaker-auth.yml`

- [ ] **Step 1: Create the overlay file with overrides for the three services**

```yaml
# =============================================================================
# INDUSTREAM PLATFORM - FLOWMAKER JWT AUTH OVERLAY
# =============================================================================
# Opt-in overlay layered AFTER docker-stack.flowmaker.yml and docker-stack.yml.
# Enabled by FLOWMAKER_AUTH_ENABLED=true or --with-jwt-auth on deploy-swarm.sh.
#
# It does three things:
#   1. Switches flowmaker-scheduler + flowmaker-confighub to JWT-capable images
#      and reroutes Traefik to their JWT-protected public ports (3121, 4001).
#      The internal ports (3120, 4000) remain open inside ${ENV}-platform for
#      inter-service traffic that bypasses auth (legacy contract).
#   2. Promotes uifusion-api to "hub-backend" mode: bumps to 1.0.8, switches
#      from CONFIG_PATH-driven mode to IH_*-driven hub mode, exposes 3050 for
#      JWKS, and registers a `industream-hub-backend` network alias so other
#      services can reach it by hostname.
#   3. Tells flowmaker-frontend where the hub-backend lives for the OAuth flow.
#
# See docs/runbook/jwt-auth.md for operator instructions.
# =============================================================================

services:
  # ==========================================
  # FLOWMAKER SCHEDULER — dual-port + JWT
  # ==========================================
  flowmaker-scheduler:
    image: ${DOCKER_REGISTRY:-842775dh.c1.gra9.container-registry.ovh.net}/flowmaker.core/flowmaker-launcher:${FLOWMAKER_CORE_VERSION_AUTH:-2.0.3-dev}
    environment:
    - FM_RUNTIME_BACKEND_PORT=3120
    - FM_RUNTIME_PUBLIC_PORT=3121
    - FM_WORKER_LOG_SOCKET_IO_ENDPOINT=http://flowmaker-logging:3000
    - FM_CONFIGHUB_URL=http://flowmaker-confighub:4000
    - FM_LAUNCHER_DATA_PATH=/data
    - FM_AUTH_JWKS_URL=http://industream-hub-backend:3050/auth/jwks
    - FM_AUTH_ISSUER=${FM_AUTH_ISSUER:-hub-backend}
    - FM_AUTH_AUDIENCE=${FM_AUTH_AUDIENCE:-industream-hub}
    - FM_CORS_ORIGIN=${FM_CORS_ORIGIN:-https://flowmaker.${INDUSTREAM_DOMAIN:-localhost}}
    healthcheck:
      test:
      - CMD-SHELL
      - bash -c '(echo > /dev/tcp/127.0.0.1/3120) 2>/dev/null && (echo > /dev/tcp/127.0.0.1/3121) 2>/dev/null' || exit 1
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    deploy:
      labels:
      - traefik.enable=true
      - traefik.http.routers.${ENV}-flowmaker-scheduler-secure.entrypoints=websecure
      - traefik.http.routers.${ENV}-flowmaker-scheduler-secure.rule=Host(`scheduler.${INDUSTREAM_DOMAIN:-localhost}`)
      - traefik.http.routers.${ENV}-flowmaker-scheduler-secure.tls=true
      - traefik.http.routers.${ENV}-flowmaker-scheduler-secure.service=${ENV}-flowmaker-scheduler
      - traefik.http.routers.${ENV}-flowmaker-scheduler.entrypoints=web
      - traefik.http.routers.${ENV}-flowmaker-scheduler.rule=Host(`scheduler.${INDUSTREAM_DOMAIN:-localhost}`)
      - traefik.http.routers.${ENV}-flowmaker-scheduler.middlewares=redirect-to-https@file
      - traefik.http.services.${ENV}-flowmaker-scheduler.loadbalancer.server.port=3121

  # ==========================================
  # FLOWMAKER CONFIGHUB — dual-port + JWT
  # ==========================================
  flowmaker-confighub:
    image: ${DOCKER_REGISTRY:-842775dh.c1.gra9.container-registry.ovh.net}/flowmaker.core/flowmaker-confighub-v2:${FLOWMAKER_CORE_VERSION_AUTH:-2.0.3-dev}
    environment:
    - FM_CONFIGHUB_PORT=4000
    - FM_CONFIGHUB_PUBLIC_PORT=4001
    - FM_CONFIGHUB_DATA_PATH=/data
    - FM_AUTH_JWKS_URL=http://industream-hub-backend:3050/auth/jwks
    - FM_AUTH_ISSUER=${FM_AUTH_ISSUER:-hub-backend}
    - FM_AUTH_AUDIENCE=${FM_AUTH_AUDIENCE:-industream-hub}
    - FM_CORS_ORIGIN=${FM_CORS_ORIGIN:-https://flowmaker.${INDUSTREAM_DOMAIN:-localhost}}
    healthcheck:
      test:
      - CMD-SHELL
      - bash -c '(echo > /dev/tcp/127.0.0.1/4000) 2>/dev/null && (echo > /dev/tcp/127.0.0.1/4001) 2>/dev/null' || exit 1
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    deploy:
      labels:
      - traefik.enable=true
      - traefik.http.routers.${ENV}-flowmaker-confighub-secure.entrypoints=websecure
      - traefik.http.routers.${ENV}-flowmaker-confighub-secure.rule=Host(`confighub.${INDUSTREAM_DOMAIN:-localhost}`)
      - traefik.http.routers.${ENV}-flowmaker-confighub-secure.tls=true
      - traefik.http.routers.${ENV}-flowmaker-confighub-secure.service=${ENV}-flowmaker-confighub
      - traefik.http.routers.${ENV}-flowmaker-confighub.entrypoints=web
      - traefik.http.routers.${ENV}-flowmaker-confighub.rule=Host(`confighub.${INDUSTREAM_DOMAIN:-localhost}`)
      - traefik.http.routers.${ENV}-flowmaker-confighub.middlewares=redirect-to-https@file
      - traefik.http.services.${ENV}-flowmaker-confighub.loadbalancer.server.port=4001

  # ==========================================
  # UIFUSION-API promoted to HUB-BACKEND mode
  # ==========================================
  # The same image acts as both UIFusion (existing portal API) AND the JWT
  # hub-backend when launched with IH_* vars. Port shifts from 3001 to 3050.
  # A network alias `industream-hub-backend` is registered so FlowMaker reaches
  # it under the upstream-documented hostname without rewriting code.
  uifusion-api:
    image: ${DOCKER_REGISTRY:-842775dh.c1.gra9.container-registry.ovh.net}/uifusion/api:${UIFUSION_API_VERSION:-1.0.8}
    environment:
    - CONFIG_PATH=/app/data/config.json
    - IH_PUBLIC_PORT=3050
    - IH_INTERNAL_PORT=3051
    - IH_AUTH_METHOD=BASIC
    - IH_USERNAME=${HUB_BACKEND_ADMIN_USER:-admin}
    - IH_PASSWORD=${HUB_BACKEND_ADMIN_PASSWORD:-admin}
    - IH_EMAIL=admin@${INDUSTREAM_DOMAIN:-localhost}
    - IH_FIRSTNAME=Admin
    - IH_LASTNAME=User
    - IH_ROLE=admin
    - IH_ACCOUNT_NAME=industream
    - IH_ISSUER=${FM_AUTH_ISSUER:-hub-backend}
    - IH_AUDIENCE=${FM_AUTH_AUDIENCE:-industream-hub}
    - IH_ACCESS_TOKEN_TTL_SECONDS=900
    - IH_REFRESH_TOKEN_TTL_SECONDS=2592000
    - IH_BACKEND_ORIGIN=https://${INDUSTREAM_DOMAIN:-localhost}
    - HUB_DATA_PATH=/app/data/hub
    networks:
      traefik-public: {}
      ${ENV}-platform:
        aliases:
        - industream-hub-backend
    healthcheck:
      test:
      - CMD
      - wget
      - --no-verbose
      - --tries=1
      - --spider
      - http://localhost:3050/auth/jwks
      interval: 30s
      timeout: 3s
      retries: 3
      start_period: 15s
    deploy:
      labels:
      - traefik.enable=true
      - traefik.http.routers.${ENV}-uifusion-api-secure.entrypoints=websecure
      - traefik.http.routers.${ENV}-uifusion-api-secure.rule=Host(`${INDUSTREAM_DOMAIN:-localhost}`) && PathPrefix(`/api/uifusion`)
      - traefik.http.routers.${ENV}-uifusion-api-secure.tls=true
      - traefik.http.routers.${ENV}-uifusion-api-secure.service=${ENV}-uifusion-api
      - traefik.http.routers.${ENV}-uifusion-api-secure.middlewares=${ENV}-uifusion-api-stripprefix,security-headers@file
      - traefik.http.routers.${ENV}-uifusion-api.entrypoints=web
      - traefik.http.routers.${ENV}-uifusion-api.rule=Host(`${INDUSTREAM_DOMAIN:-localhost}`) && PathPrefix(`/api/uifusion`)
      - traefik.http.routers.${ENV}-uifusion-api.middlewares=redirect-to-https@file
      - traefik.http.middlewares.${ENV}-uifusion-api-stripprefix.stripprefix.prefixes=/api/uifusion
      - traefik.http.services.${ENV}-uifusion-api.loadbalancer.server.port=3050

  # ==========================================
  # FLOWMAKER FRONTEND — point at hub-backend
  # ==========================================
  flowmaker-frontend:
    environment:
    - FMUI_CONFIG_HUB_URL=https://confighub.${INDUSTREAM_DOMAIN:-localhost}
    - FMUI_AUTH_BACKEND_URL=https://${INDUSTREAM_DOMAIN:-localhost}/api/uifusion
    - FMUI_AUTH_ISSUER=${FM_AUTH_ISSUER:-hub-backend}
    - FMUI_AUTH_AUDIENCE=${FM_AUTH_AUDIENCE:-industream-hub}
```

- [ ] **Step 2: Validate the overlay alone parses (it won't be self-sufficient, expects base services to exist)**

Run: `docker compose -f docker-stack.yml -f docker-stack.flowmaker.yml -f docker-stack.flowmaker-auth.yml config -q`

Expected: exit code 0, no output.
If you see `service "uifusion-api" has no image` or similar, the overlay's `image:` lines are wrong — re-check Step 1.
If you see `network ${ENV}-platform not defined`, set `ENV=dev` and re-run: `ENV=dev INDUSTREAM_DOMAIN=test.lan docker compose -f docker-stack.yml -f docker-stack.flowmaker.yml -f docker-stack.flowmaker-auth.yml config -q`.

- [ ] **Step 3: Verify the merge actually changes the listening ports (visual diff)**

Run:
```bash
ENV=dev INDUSTREAM_DOMAIN=test.lan docker compose \
  -f docker-stack.yml -f docker-stack.flowmaker.yml \
  config | grep -E "loadbalancer\.server\.port=(3121|4001|3050)"
```

Expected: three matches (one per overridden service). Then re-run **with** the overlay:

```bash
ENV=dev INDUSTREAM_DOMAIN=test.lan docker compose \
  -f docker-stack.yml -f docker-stack.flowmaker.yml -f docker-stack.flowmaker-auth.yml \
  config | grep -E "loadbalancer\.server\.port=(3121|4001|3050)"
```

Expected: three matches that did NOT show up without the overlay. If the count is wrong, the overlay's `deploy.labels:` block didn't override the base — likely a key-typo. Fix and re-run.

- [ ] **Step 4: Commit**

```bash
git add docker-stack.flowmaker-auth.yml
git commit -m "feat(flowmaker): add JWT auth overlay (scheduler+confighub dual-port, uifusion as hub-backend)"
```

---

## Task 4 — Register hub-backend admin secrets

**Files:**
- Modify: `scripts/setup/create-secrets.sh:131-147` (the `BASE_SECRETS=( … )` array)

- [ ] **Step 1: Add two new entries at the end of the BASE_SECRETS array**

Find the block:

```bash
BASE_SECRETS=(
    "postgres_admin_password"
    "keycloak_admin_password"
    "keycloak_db_password"
    "grafana_admin_password"
    "grafana_db_password"
    "datacatalog_db_password"
    "influx_admin_password"
    "influx_admin_token"
    "minio_root_user"
    "minio_root_password"
    "ironstream_db_password"
    "timescaledb_password"
    "databridge_pg_password"
    "traefik_auth_htpasswd"
    "backup_monitor_htpasswd"
)
```

Append two new entries (keeping alphabetical-ish grouping with other `_admin_*` lines is fine):

```bash
BASE_SECRETS=(
    "postgres_admin_password"
    "keycloak_admin_password"
    "keycloak_db_password"
    "grafana_admin_password"
    "grafana_db_password"
    "datacatalog_db_password"
    "influx_admin_password"
    "influx_admin_token"
    "minio_root_user"
    "minio_root_password"
    "ironstream_db_password"
    "timescaledb_password"
    "databridge_pg_password"
    "traefik_auth_htpasswd"
    "backup_monitor_htpasswd"
    "hub_backend_admin_user"
    "hub_backend_admin_password"
)
```

- [ ] **Step 2: Run the script against a throwaway env to confirm the new secrets are generated**

Run:
```bash
ENV=test bash scripts/setup/create-secrets.sh --env test --regenerate 2>&1 | grep -E "hub_backend"
```

Expected: two lines mentioning `hub_backend_admin_user` and `hub_backend_admin_password` being created. Then verify the files exist:

```bash
ls -la secrets/test/hub_backend_admin_*
```

Expected: two files, mode `-rw-------` (0600).

- [ ] **Step 3: Cleanup the throwaway secrets**

```bash
rm -rf secrets/test
```

- [ ] **Step 4: Commit**

```bash
git add scripts/setup/create-secrets.sh
git commit -m "feat(secrets): register hub_backend_admin_user/password base secrets"
```

> **NOTE for the executing engineer:** Wiring these secrets into the overlay via Docker Secrets (i.e. mounting them under `/run/secrets/` and using `IH_PASSWORD_FILE`) is intentionally NOT in scope of this plan. The UIFusion 1.0.8 image's support for `*_FILE` env vars must be verified against the upstream image before that step. Today the overlay reads `HUB_BACKEND_ADMIN_*` from `.env` directly; the secrets generated here exist so a follow-up plan can switch to the proper `_FILE` mount without re-generating credentials.

---

## Task 5 — Wire the overlay into `scripts/deploy-swarm.sh`

**Files:**
- Modify: `scripts/deploy-swarm.sh` (arg parsing block, STACK_FILES assembly block)

- [ ] **Step 1: Add a flag variable next to `DEPLOY_DEMO`/`DEPLOY_IRONSTREAM`**

Find the existing block (around line 31-43):

```bash
DEPLOY_DEMO=false
DEPLOY_IRONSTREAM=false
```

Add a new variable directly after `DEPLOY_IRONSTREAM=false`:

```bash
DEPLOY_DEMO=false
DEPLOY_IRONSTREAM=false
# Resolved from --with-jwt-auth CLI flag OR FLOWMAKER_AUTH_ENABLED env var.
DEPLOY_JWT_AUTH=false
```

- [ ] **Step 2: Parse the new `--with-jwt-auth` flag**

Find the arg-parsing `case` block. After the `--with-ironstream)` branch (around line 57-59), add a new branch:

```bash
        --with-ironstream)
            DEPLOY_IRONSTREAM=true
            shift
            ;;
        --with-jwt-auth)
            DEPLOY_JWT_AUTH=true
            shift
            ;;
```

- [ ] **Step 3: Document the flag in the `--help` text**

Find the `--help)` branch (lookup `--with-ironstream  Include` to find the help string, around line 93). Add the new line below it:

```bash
            echo "  --with-jwt-auth    Enable FlowMaker JWT auth overlay (uifusion as hub-backend; experimental)"
```

- [ ] **Step 4: Fall back to env var when flag absent**

Find the validation block where `DEPLOY_DEMO` is cross-checked against `$ENV` (around line 138-146). After that block, insert a new block:

```bash
# JWT auth: CLI flag wins, else honour FLOWMAKER_AUTH_ENABLED from .env.
if [ "$DEPLOY_JWT_AUTH" != "true" ] && [ -f .env ]; then
    if grep -qE '^FLOWMAKER_AUTH_ENABLED=true$' .env; then
        DEPLOY_JWT_AUTH=true
        echo -e "${BLUE}  FLOWMAKER_AUTH_ENABLED=true detected in .env, enabling JWT auth overlay${NC}"
    fi
fi
```

- [ ] **Step 5: Append the overlay to `STACK_FILES` if enabled**

Find the IronStream block (around line 554-563):

```bash
if [ "$DEPLOY_IRONSTREAM" = "true" ]; then
    if [ -f "docker-stack.ironstream.yml" ]; then
        STACK_FILES+=("docker-stack.ironstream.yml")
        echo -e "${BLUE}  Including IronStream services (--with-ironstream)${NC}"
    else
        echo -e "${YELLOW}  ⚠ docker-stack.ironstream.yml not found, skipping${NC}"
        DEPLOY_IRONSTREAM=false
    fi
fi
```

Directly after it (before the custom-stack auto-discovery block), add:

```bash
# JWT auth overlay — must come AFTER docker-stack.flowmaker.yml AND docker-stack.yml
# in the STACK_FILES order, because it overrides services from both. The current
# order already places it correctly because flowmaker.yml is at index 1 and the
# overlay is appended here, after the conditional stacks.
if [ "$DEPLOY_JWT_AUTH" = "true" ]; then
    if [ -f "docker-stack.flowmaker-auth.yml" ]; then
        STACK_FILES+=("docker-stack.flowmaker-auth.yml")
        echo -e "${BLUE}  Including JWT auth overlay (--with-jwt-auth)${NC}"
        echo -e "${YELLOW}  ⚠ Verify hub_backend_admin_* secrets exist in secrets/${ENV}/${NC}"
    else
        echo -e "${YELLOW}  ⚠ docker-stack.flowmaker-auth.yml not found, skipping JWT auth${NC}"
        DEPLOY_JWT_AUTH=false
    fi
fi
```

- [ ] **Step 6: Test the help output**

Run: `bash scripts/deploy-swarm.sh --help | grep jwt-auth`

Expected: one line — `  --with-jwt-auth    Enable FlowMaker JWT auth overlay (uifusion as hub-backend; experimental)`.

- [ ] **Step 7: Test the flag is recognised (dry-run-ish: trigger arg parsing then bail before deploy)**

Add a one-shot debug line by running:

```bash
bash -x scripts/deploy-swarm.sh --env dev --with-jwt-auth 2>&1 | grep -E "DEPLOY_JWT_AUTH=true|JWT auth overlay" | head -5
```

Expected: at least one match showing the variable was set and the overlay was queued. Cancel the run as soon as you see deploy operations start (Ctrl-C) — we're not actually deploying yet.

- [ ] **Step 8: Commit**

```bash
git add scripts/deploy-swarm.sh
git commit -m "feat(deploy): add --with-jwt-auth flag and FLOWMAKER_AUTH_ENABLED env support"
```

---

## Task 6 — Add a JWT overlay smoke test script

**Files:**
- Create: `scripts/tests/test-jwt-overlay.sh`

- [ ] **Step 1: Write the smoke test script**

```bash
#!/bin/bash
# =============================================================================
# JWT OVERLAY SMOKE TEST
# =============================================================================
# Validates the FlowMaker JWT auth overlay end-to-end:
#   1. Compose merge syntax is valid
#   2. Three expected ports are remapped (3121, 4001, 3050)
#   3. The network alias `industream-hub-backend` is present
#   4. (post-deploy only, opt-in) Hits /auth/jwks and confirms a key is served
#
# Usage:
#   ./scripts/tests/test-jwt-overlay.sh           # syntactic checks only
#   ./scripts/tests/test-jwt-overlay.sh --live    # also probes the live JWKS endpoint
#
# Exit code: 0 on PASS, non-zero on FAIL.
# =============================================================================

set -euo pipefail

LIVE=false
[ "${1:-}" = "--live" ] && LIVE=true

ENV="${ENV:-dev}"
INDUSTREAM_DOMAIN="${INDUSTREAM_DOMAIN:-test.lan}"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() { echo -e "${GREEN}✔${NC} $1"; }
fail() { echo -e "${RED}✖${NC} $1"; exit 1; }

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# -----------------------------------------------------------------------------
# 1. Compose merge validates
# -----------------------------------------------------------------------------
ENV="$ENV" INDUSTREAM_DOMAIN="$INDUSTREAM_DOMAIN" \
    docker compose \
        -f docker-stack.yml \
        -f docker-stack.flowmaker.yml \
        -f docker-stack.flowmaker-auth.yml \
        config -q \
    || fail "compose merge failed validation"
pass "compose merge is syntactically valid"

# -----------------------------------------------------------------------------
# 2. Ports are remapped to JWT-protected variants
# -----------------------------------------------------------------------------
MERGED=$(ENV="$ENV" INDUSTREAM_DOMAIN="$INDUSTREAM_DOMAIN" \
    docker compose \
        -f docker-stack.yml \
        -f docker-stack.flowmaker.yml \
        -f docker-stack.flowmaker-auth.yml \
        config)

for port in 3121 4001 3050; do
    echo "$MERGED" | grep -q "loadbalancer.server.port=$port" \
        || fail "expected Traefik label loadbalancer.server.port=$port not found"
    pass "port $port wired into Traefik labels"
done

# -----------------------------------------------------------------------------
# 3. Network alias is present
# -----------------------------------------------------------------------------
echo "$MERGED" | grep -q "industream-hub-backend" \
    || fail "network alias 'industream-hub-backend' not found"
pass "uifusion-api carries the industream-hub-backend network alias"

# -----------------------------------------------------------------------------
# 4. Live JWKS probe (opt-in)
# -----------------------------------------------------------------------------
if [ "$LIVE" = "true" ]; then
    HUB_URL="https://${INDUSTREAM_DOMAIN}/api/uifusion/auth/jwks"
    JWKS=$(curl -sk "$HUB_URL")
    echo "$JWKS" | grep -q '"keys"' \
        || fail "JWKS endpoint $HUB_URL did not return a 'keys' array — got: $JWKS"
    pass "live JWKS endpoint returns a key set"
fi

echo ""
pass "All JWT overlay smoke checks passed"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/tests/test-jwt-overlay.sh`

- [ ] **Step 3: Run the offline checks**

Run: `bash scripts/tests/test-jwt-overlay.sh`

Expected output (in this exact order):

```
✔ compose merge is syntactically valid
✔ port 3121 wired into Traefik labels
✔ port 4001 wired into Traefik labels
✔ port 3050 wired into Traefik labels
✔ uifusion-api carries the industream-hub-backend network alias
✔ All JWT overlay smoke checks passed
```

If any check fails, **do not** patch the test — fix the overlay (Task 3) instead. The test is a contract; weakening it defeats the purpose.

- [ ] **Step 4: Commit**

```bash
git add scripts/tests/test-jwt-overlay.sh
git commit -m "test(flowmaker): add JWT overlay smoke test (offline + live JWKS probe)"
```

---

## Task 7 — Write the operator runbook

**Files:**
- Create: `docs/runbook/jwt-auth.md`

- [ ] **Step 1: Write the runbook content**

```markdown
# FlowMaker JWT Auth Runbook

Operational guide for the opt-in JWT authentication overlay introduced by
`docker-stack.flowmaker-auth.yml`.

---

## When to enable

The overlay is **opt-in and experimental** while the upstream FlowMaker
2.0.3-dev images stabilise. Defaults keep it OFF — every existing deployment
continues to run on FlowMaker 2.0.2 without auth, exactly as before this
change shipped.

Enable it when:

- You want the FlowMaker public APIs (`scheduler`, `confighub`) to require a
  valid JWT issued by the hub-backend (UIFusion-API ≥ 1.0.8).
- You're rolling out a new client install where you control which FlowMaker
  image versions land on the host.

Do NOT enable it on a running cluster without reading the **Rollback** section
below first.

---

## What gets changed when enabled

| Service | Before | After |
|---|---|---|
| `flowmaker-scheduler` | image `2.0.2`, single port `3120` (public, no auth) | image `2.0.3-dev`, internal `3120` + public `3121` (JWT required) |
| `flowmaker-confighub` | image `2.0.2`, single port `4000` (public, no auth) | image `2.0.3-dev`, internal `4000` + public `4001` (JWT required) |
| `uifusion-api` | image `1.0.6`, single port `3001`, portal API only | image `1.0.8`, port `3050`, ALSO exposes `/auth/jwks`. Network alias `industream-hub-backend` registered. |
| `flowmaker-frontend` | (unchanged image) | new env `FMUI_AUTH_BACKEND_URL` → triggers the OAuth-style login flow |

Traefik labels are repointed to `3121` / `4001` / `3050`. The legacy ports stay
open inside the `${ENV}-platform` Docker network so inter-service traffic that
must bypass auth (e.g. internal scheduler→confighub) keeps working.

---

## Enabling

1. **Generate the hub-backend admin secret** (one-time per env):

   ```bash
   ./scripts/setup/create-secrets.sh --env <prod|dev|staging>
   ```

   Verify the files were created:

   ```bash
   ls -l secrets/<env>/hub_backend_admin_*
   ```

   Expected: two files, mode `0600`.

2. **Pull the values into `.env`** so the overlay can interpolate them:

   ```bash
   echo "HUB_BACKEND_ADMIN_USER=$(cat secrets/<env>/hub_backend_admin_user)" >> .env
   echo "HUB_BACKEND_ADMIN_PASSWORD=$(cat secrets/<env>/hub_backend_admin_password)" >> .env
   ```

   > **Note:** this is the interim mechanism. A follow-up change will mount
   > these secrets at `/run/secrets/` and switch the overlay to
   > `IH_PASSWORD_FILE=/run/secrets/hub_backend_admin_password` once UIFusion's
   > `*_FILE` support is confirmed.

3. **Flip the overlay on** — either by flag:

   ```bash
   ./scripts/deploy-swarm.sh --env <env> --with-jwt-auth
   ```

   …or by env var so it persists across runs:

   ```bash
   echo "FLOWMAKER_AUTH_ENABLED=true" >> .env
   ./scripts/deploy-swarm.sh --env <env>
   ```

4. **Verify** the JWKS endpoint is reachable:

   ```bash
   INDUSTREAM_DOMAIN=<your-domain> bash scripts/tests/test-jwt-overlay.sh --live
   ```

   Expected: every check passes, including the live JWKS probe.

---

## Rollback

If JWT auth breaks the cluster (e.g. workers can't talk to the scheduler
because they don't yet ship a JWT), roll back fast:

1. Remove the flag / set `FLOWMAKER_AUTH_ENABLED=false` in `.env`.
2. Redeploy:

   ```bash
   ./scripts/deploy-swarm.sh --env <env>
   ```

3. The stack reverts to FlowMaker 2.0.2 single-port mode, UIFusion-API back to
   1.0.6 on port 3001. Volume `${ENV}-flowmaker-confighub-data` is forward-
   compatible (LMDB on-disk schema is unchanged between 2.0.2 and 2.0.3-dev as
   of writing) — no data migration is required.

> **Caveat:** the hub-backend's `/data` volume contains the JWKS signing key
> generated at first boot. Rolling back does NOT wipe it; re-enabling will
> reuse the same key, so previously issued tokens stay valid until they expire
> (15 min for access tokens, 30 days for refresh tokens).

---

## Secret rotation

Rotate the hub-backend admin credentials with:

```bash
./scripts/setup/create-secrets.sh --env <env> --regenerate
```

The `--regenerate` flag refuses to touch secrets currently in use by running
services. If `hub_backend_admin_password` is in use, stop `uifusion-api`
first, regenerate, then redeploy.

To rotate the JWKS signing key (much more disruptive — invalidates every
issued JWT immediately), remove the data volume and let the hub-backend
regenerate it on next boot:

```bash
docker stack rm <env>-industream
docker volume rm <env>-uifusion-api-data   # if you mounted a named volume
./scripts/deploy-swarm.sh --env <env> --with-jwt-auth
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `scheduler` healthcheck flaps; logs say `JWKS_FETCH_FAILED` | `industream-hub-backend` alias didn't register on the `${ENV}-platform` network. | `docker network inspect <env>-platform \| grep industream-hub-backend` — if absent, `uifusion-api` started before the network was ready. Restart `uifusion-api`. |
| `curl https://.../api/uifusion/auth/jwks` returns 404 | `UIFUSION_API_VERSION` is still `1.0.6`. | Bump to `1.0.8` in `.env`, redeploy. |
| Frontend login loops | `FMUI_AUTH_BACKEND_URL` is unreachable from the browser. | Verify the URL responds publicly: `curl -k https://<domain>/api/uifusion/auth/jwks`. |
| `IH_PASSWORD` shows as `admin` in `docker inspect` | `.env` didn't carry the secret value (Step 2 of Enabling was skipped). | Add the `HUB_BACKEND_ADMIN_*` lines to `.env`, redeploy. |

```

- [ ] **Step 2: Lint the runbook with a quick visual scan**

Run: `grep -nE '^#{1,3} ' docs/runbook/jwt-auth.md`

Expected: an outline matching the section structure (When to enable / What gets changed / Enabling / Rollback / Secret rotation / Troubleshooting). If a heading is missing, the runbook is incomplete.

- [ ] **Step 3: Commit**

```bash
git add docs/runbook/jwt-auth.md
git commit -m "docs(runbook): document FlowMaker JWT auth overlay enable/rollback"
```

---

## Task 8 — Surface the new flag in `SWARM-DEPLOYMENT.md`

**Files:**
- Modify: `SWARM-DEPLOYMENT.md`

- [ ] **Step 1: Locate the section that lists `--with-*` flags**

Run: `grep -n "with-demo\|with-ironstream" SWARM-DEPLOYMENT.md`

Note the line numbers of the two existing flag descriptions — you'll insert the new flag right after them.

- [ ] **Step 2: Insert the `--with-jwt-auth` description**

Add a new bullet/paragraph that follows the same format as `--with-demo` / `--with-ironstream`. The minimum content:

```markdown
- `--with-jwt-auth` — Enable the FlowMaker JWT auth overlay
  (`docker-stack.flowmaker-auth.yml`). The scheduler and confighub services
  switch to the dual-port `2.0.3-dev` images and UIFusion-API is promoted to
  the `industream-hub-backend` role. **Experimental** — see
  `docs/runbook/jwt-auth.md` for the enable / rollback procedure.
```

If `SWARM-DEPLOYMENT.md` documents `FLOWMAKER_*` env vars in a separate block, append a sibling note pointing readers to the new `FLOWMAKER_AUTH_ENABLED` variable.

- [ ] **Step 3: Run a final overall validation**

Run:

```bash
bash scripts/tests/test-jwt-overlay.sh
bash scripts/deploy-swarm.sh --help | grep jwt-auth
```

Expected: smoke test passes, help text shows the flag.

- [ ] **Step 4: Commit**

```bash
git add SWARM-DEPLOYMENT.md
git commit -m "docs(deploy): document --with-jwt-auth in SWARM-DEPLOYMENT.md"
```

---

## Self-Review Checklist (already applied)

**Spec coverage:** every architecture bullet maps to a task — env vars (T1), pre-flight inspection (T2), overlay file (T3), secrets (T4), deploy script wiring (T5), automated smoke test (T6), runbook (T7), public docs (T8). ✓

**Placeholder scan:** no `TBD`, no `add validation`, no "similar to Task N". Each step shows the full code/command/expected output. ✓

**Type consistency:** the alias is `industream-hub-backend` everywhere (overlay, runbook, troubleshooting, smoke test). The version pin `FLOWMAKER_CORE_VERSION_AUTH` is named identically in `.env.example` (T1) and the overlay (T3). The flag `--with-jwt-auth` matches between deploy-swarm.sh (T5), the runbook (T7) and SWARM-DEPLOYMENT.md (T8). ✓

---

## Out of scope (track as follow-ups)

- Switching the hub-backend secrets from `.env`-injected env vars to mounted
  Docker Secrets via `IH_PASSWORD_FILE`. Requires confirming UIFusion 1.0.8
  honours `*_FILE` suffixes (it does not, as of this writing — verify with the
  upstream image before opening the follow-up).
- Bumping `FLOWMAKER_AUTH_ENABLED=true` as the new default and removing the
  legacy 2.0.2 single-port mode. Track once 2.0.3 (non-dev) ships.
- Wiring the JWKS signing key as an externally-managed secret instead of a
  per-instance auto-generated key in `/data`. Required if the platform ever
  needs to serve a stable JWT across multiple hub-backend replicas.
