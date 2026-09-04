#!/usr/bin/env bash
# Post-install signal checks for the airgap bundle bench (Task 11).
#
# Every check below queries an OBSERVABLE VALUE — a replica count, an HTTP
# status code, a response body — never "the container is running" or "the
# healthcheck is green". Run this on the bench VM itself, after install.sh
# has finished and the stack has had time to converge. Requires: docker,
# curl. Swarm only (matches the bench scenarios in README.md).
#
# Usage: check-signals.sh <domain> [stack]
#
#   domain  the platform's public hostname, e.g. bench.example (INDUSTREAM_DOMAIN)
#   stack   the swarm stack name (default: industream-prod)
#
# --- Why two checks need HUB_BEARER_TOKEN -----------------------------------
# Grafana (GF_AUTH_ANONYMOUS_ENABLED=false, GF_AUTH_BASIC_ENABLED=false) and
# DataCatalog's frontend port (:8002, "ALWAYS JWT-protected" per
# unified/base/datacatalog.yml) both validate a Hub-issued JWT against the
# same JWKS (industream-hub-backend:.../auth/jwks). There is no headless way
# to mint that JWT from a script — the Hub only issues one through a real
# OIDC browser login — so this script cannot obtain it on its own.
#
# Export HUB_BEARER_TOKEN before running the two checks that need it (see
# README.md, "Getting a bearer token"). Without it, those checks FAIL LOUDLY
# with instructions rather than being silently skipped: a bundle that shipped
# a broken plugin and one nobody bothered to verify must not look the same
# from the outside.
set -uo pipefail

domain="${1:?usage: check-signals.sh <domain> [stack]}"
stack="${2:-industream-prod}"
rc=0

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "      → $2"; rc=1; }

# curl helper: writes the body to $1, echoes the HTTP status code. curl's own
# -w '%{http_code}' already prints "000" on a connection/TLS failure — that
# reads clearly in a failure message, so no extra fallback text is added on
# top of it.
http_get() {
  local out_file="$1"; shift
  local code
  code="$(curl -sk --max-time 10 -o "$out_file" -w '%{http_code}' "$@" 2>/dev/null)"
  echo "${code:-000}"
}

# --- 1. Every service at its desired replica count --------------------------
check_replicas() {
  local raw short
  if ! raw="$(docker stack services "$stack" --format '{{.Name}} {{.Replicas}}' 2>&1)"; then
    fail "every service in '$stack' is at its desired replica count" \
      "docker stack services failed: $raw"
    return
  fi
  if [[ -z "$raw" ]]; then
    fail "every service in '$stack' is at its desired replica count" \
      "docker stack services returned no rows — is '$stack' the right stack name?"
    return
  fi
  # Name field never contains a space or '/'; Replicas is "current/desired".
  short="$(awk -F'[ /]' '$2 != $3 { print $1": "$2"/"$3 }' <<<"$raw")"
  if [[ -z "$short" ]]; then
    pass "every service in '$stack' is at its desired replica count"
  else
    fail "every service in '$stack' is at its desired replica count" \
      "under-replicated: $(paste -sd, <<<"$short")"
  fi
}

# --- 2. Grafana lists the DataBridge datasource (proves plugin seeding) -----
check_grafana_datasource() {
  local label="Grafana lists the DataBridge datasource"
  if [[ -z "${HUB_BEARER_TOKEN:-}" ]]; then
    fail "$label" "HUB_BEARER_TOKEN is not set — see README.md, 'Getting a bearer token'"
    return
  fi
  local body; body="$(mktemp)"
  local code; code="$(http_get "$body" -H "Authorization: Bearer $HUB_BEARER_TOKEN" \
    "https://dashboard.${domain}/grafana/api/datasources")"
  if [[ "$code" != 200 ]]; then
    fail "$label" "HTTP $code from /grafana/api/datasources — body: $(head -c 200 "$body")"
  elif ! grep -qi databridge "$body"; then
    fail "$label" "got HTTP 200 but no datasource type contains 'databridge' — body: $(head -c 200 "$body")"
  else
    pass "$label"
  fi
  rm -f "$body"
}

# --- 3. The CDN serves a box definition (proves Verdaccio is populated) -----
check_cdn_package() {
  local label="the CDN serves a FlowMaker box definition (Verdaccio is populated, not merely running)"
  local cid; cid="$(docker ps -qf "name=${stack}_cdn-server" | head -1)"
  if [[ -z "$cid" ]]; then
    fail "$label" "no running container matches '${stack}_cdn-server'"
    return
  fi
  local listing
  if ! listing="$(docker exec "$cid" wget -qO- http://localhost:4873/-/verdaccio/data/packages 2>&1)"; then
    fail "$label" "wget against the container's own registry failed: $listing"
    return
  fi
  if grep -qi databridge <<<"$listing"; then
    pass "$label"
  else
    fail "$label" "registry answered but lists no databridge package — CDN cache is likely empty (see the CDN-harvest gap in README.md)"
  fi
}

# --- 4. The Hub returns launchpad tiles -------------------------------------
check_hub_apps() {
  local label="the Hub returns launchpad tiles"
  local body; body="$(mktemp)"
  local code; code="$(http_get "$body" "https://${domain}/api/uifusion/apps")"
  if [[ "$code" != 200 ]]; then
    fail "$label" "HTTP $code from /api/uifusion/apps — body: $(head -c 200 "$body")"
  elif ! grep -q '\[' "$body"; then
    fail "$label" "got HTTP 200 but the body is not a JSON array: $(head -c 200 "$body")"
  else
    pass "$label"
  fi
  rm -f "$body"
}

# --- 5. DataCatalog rejects an unauthenticated request ----------------------
check_datacatalog_rejects_anonymous() {
  local label="DataCatalog rejects an unauthenticated request with 401"
  local body; body="$(mktemp)"
  local code; code="$(http_get "$body" "https://datacatalog-api.${domain}/api/assets")"
  if [[ "$code" == 401 ]]; then
    pass "$label"
  else
    fail "$label" "got HTTP $code instead of 401 — body: $(head -c 200 "$body")"
  fi
  rm -f "$body"
}

# --- 6. DataCatalog accepts a valid bearer -----------------------------------
check_datacatalog_accepts_bearer() {
  local label="DataCatalog answers 200 to the same request with a valid bearer"
  if [[ -z "${HUB_BEARER_TOKEN:-}" ]]; then
    fail "$label" "HUB_BEARER_TOKEN is not set — see README.md, 'Getting a bearer token'"
    return
  fi
  local body; body="$(mktemp)"
  local code; code="$(http_get "$body" -H "Authorization: Bearer $HUB_BEARER_TOKEN" \
    "https://datacatalog-api.${domain}/api/assets")"
  if [[ "$code" == 200 ]]; then
    pass "$label"
  else
    fail "$label" "got HTTP $code instead of 200 — body: $(head -c 200 "$body")"
  fi
  rm -f "$body"
}

check_replicas
check_grafana_datasource
check_cdn_package
check_hub_apps
check_datacatalog_rejects_anonymous
check_datacatalog_accepts_bearer

exit "$rc"
