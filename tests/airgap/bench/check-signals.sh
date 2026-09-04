#!/usr/bin/env bash
# Post-install signal checks for the airgap bundle bench (Task 11).
#
# Every check below queries an OBSERVABLE VALUE — a replica count, an HTTP
# status code, a response body — never "the container is running" or "the
# healthcheck is green". Run this on the bench VM itself, after install.sh
# has finished. Requires: docker, curl. Swarm only (matches the bench
# scenarios in README.md).
#
# Usage: check-signals.sh <domain> [stack]
#
#   domain  the platform's public hostname, e.g. bench.example (INDUSTREAM_DOMAIN)
#   stack   the swarm stack name (default: industream-prod)
#
# --- Retries: install.sh returning is not the same as "ready" -------------
# A Swarm task can report "running" before Grafana, DataCatalog, or the
# proxy in front of them have actually finished starting or before their
# routes have propagated. Each check below is retried for up to
# CHECK_TIMEOUT seconds (default 90), polling every CHECK_INTERVAL seconds
# (default 5), so a platform that is merely still converging doesn't read as
# a bundle defect. Override either via the environment if a slower/faster
# machine needs it:
#   CHECK_TIMEOUT=180 CHECK_INTERVAL=10 tests/airgap/bench/check-signals.sh ...
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

: "${CHECK_TIMEOUT:=90}"
: "${CHECK_INTERVAL:=5}"

# All scratch files live under one directory, removed on exit (including
# Ctrl-C) so a killed run doesn't leave temp files behind.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

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

# Runs probe_fn (which must return 0 on success, or 1 and set $DIAG on
# failure) every CHECK_INTERVAL seconds until it succeeds or CHECK_TIMEOUT
# is exhausted, then prints a single pass/fail line. Retrying is pointless
# for a precondition that retries can't fix (e.g. a missing bearer token) —
# callers that need an immediate, non-retried failure call `fail` directly
# instead of going through this.
DIAG=""
probe_with_retry() {
  local label="$1" probe_fn="$2"
  local waited=0
  while :; do
    if "$probe_fn"; then pass "$label"; return; fi
    waited=$((waited + CHECK_INTERVAL))
    (( waited >= CHECK_TIMEOUT )) && break
    sleep "$CHECK_INTERVAL"
  done
  fail "$label" "$DIAG (still failing after ${CHECK_TIMEOUT}s of retries)"
}

# --- 1. Every service at its desired replica count --------------------------
probe_replicas() {
  local out_file err_file raw errtext short
  out_file="$(mktemp -p "$tmp_dir")"; err_file="$(mktemp -p "$tmp_dir")"
  if ! docker stack services "$stack" --format '{{.Name}} {{.Replicas}}' >"$out_file" 2>"$err_file"; then
    DIAG="docker stack services failed: $(cat "$err_file")"
    return 1
  fi
  raw="$(cat "$out_file")"
  errtext="$(cat "$err_file")"
  if [[ -z "$raw" ]]; then
    # A nonexistent/undeployed stack exits 0 with an empty stdout and a
    # "Nothing found in stack: <name>" line on stderr — keep that separate
    # from real replica rows rather than feeding it to the awk parser below,
    # which would otherwise turn it into a nonsense "under-replicated" diagnostic.
    DIAG="docker stack services returned no rows for '$stack'${errtext:+ ($errtext)} — is '$stack' the right stack name, and is it deployed?"
    return 1
  fi
  # Name field never contains a space or '/'; Replicas is "current/desired".
  short="$(awk -F'[ /]' '$2 != $3 { print $1": "$2"/"$3 }' <<<"$raw")"
  if [[ -n "$short" ]]; then
    DIAG="under-replicated: $(paste -sd, <<<"$short")"
    return 1
  fi
  return 0
}
check_replicas() { probe_with_retry "every service in '$stack' is at its desired replica count" probe_replicas; }

# --- 2. Grafana lists the DataBridge datasource (proves plugin seeding) -----
probe_grafana_datasource() {
  local body; body="$(mktemp -p "$tmp_dir")"
  local code; code="$(http_get "$body" -H "Authorization: Bearer $HUB_BEARER_TOKEN" \
    "https://dashboard.${domain}/grafana/api/datasources")"
  if [[ "$code" != 200 ]]; then
    DIAG="HTTP $code from /grafana/api/datasources — body: $(head -c 200 "$body")"
    return 1
  fi
  # Match the datasource's own "type" field, not any field — a datasource
  # merely NAMED "databridge" but provisioned with the wrong plugin type
  # must not pass a check whose whole point is proving the plugin loaded.
  if ! grep -qiE '"type"[[:space:]]*:[[:space:]]*"[^"]*databridge[^"]*"' "$body"; then
    DIAG="got HTTP 200 but no datasource 'type' field contains 'databridge' — body: $(head -c 200 "$body")"
    return 1
  fi
  return 0
}
check_grafana_datasource() {
  local label="Grafana lists the DataBridge datasource"
  if [[ -z "${HUB_BEARER_TOKEN:-}" ]]; then
    fail "$label" "HUB_BEARER_TOKEN is not set — see README.md, 'Getting a bearer token'"
    return
  fi
  probe_with_retry "$label" probe_grafana_datasource
}

# --- 3. The CDN serves a box definition (proves Verdaccio is populated) -----
probe_cdn_package() {
  local cid; cid="$(docker ps -qf "name=${stack}_cdn-server" | head -1)"
  if [[ -z "$cid" ]]; then
    DIAG="no running container matches '${stack}_cdn-server'"
    return 1
  fi
  local listing
  if ! listing="$(docker exec "$cid" wget -qO- http://localhost:4873/-/verdaccio/data/packages 2>&1)"; then
    DIAG="wget against the container's own registry failed: $listing"
    return 1
  fi
  if ! grep -qi databridge <<<"$listing"; then
    DIAG="registry answered but lists no databridge package — CDN cache is likely empty (see the CDN-harvest gap in README.md)"
    return 1
  fi
  return 0
}
check_cdn_package() {
  probe_with_retry "the CDN serves a FlowMaker box definition (Verdaccio is populated, not merely running)" probe_cdn_package
}

# --- 4. The Hub returns launchpad tiles -------------------------------------
probe_hub_apps() {
  local body; body="$(mktemp -p "$tmp_dir")"
  local code; code="$(http_get "$body" "https://${domain}/api/uifusion/apps")"
  if [[ "$code" != 200 ]]; then
    DIAG="HTTP $code from /api/uifusion/apps — body: $(head -c 200 "$body")"
    return 1
  fi
  # Require the body to actually be array-shaped AND non-empty — a bare `[`
  # somewhere in the response (the brief's original check) is satisfied by
  # an empty `[]` too, i.e. a Hub with zero launchpad tiles (RBAC hiding
  # every app, or a seeding failure) reads as a pass.
  local trimmed; trimmed="$(tr -d '[:space:]' < "$body")"
  if [[ "$trimmed" != \[*\] ]]; then
    DIAG="got HTTP 200 but the body is not a JSON array: $(head -c 200 "$body")"
    return 1
  fi
  if [[ "$trimmed" == "[]" ]]; then
    DIAG="got HTTP 200 with an empty array — no launchpad tiles were returned: $(head -c 200 "$body")"
    return 1
  fi
  return 0
}
check_hub_apps() { probe_with_retry "the Hub returns launchpad tiles" probe_hub_apps; }

# --- 5. DataCatalog rejects an unauthenticated request ----------------------
probe_datacatalog_rejects_anonymous() {
  local body; body="$(mktemp -p "$tmp_dir")"
  local code; code="$(http_get "$body" "https://datacatalog-api.${domain}/api/assets")"
  if [[ "$code" != 401 ]]; then
    DIAG="got HTTP $code instead of 401 — body: $(head -c 200 "$body")"
    return 1
  fi
  return 0
}
check_datacatalog_rejects_anonymous() {
  probe_with_retry "DataCatalog rejects an unauthenticated request with 401" probe_datacatalog_rejects_anonymous
}

# --- 6. DataCatalog accepts a valid bearer -----------------------------------
probe_datacatalog_accepts_bearer() {
  local body; body="$(mktemp -p "$tmp_dir")"
  local code; code="$(http_get "$body" -H "Authorization: Bearer $HUB_BEARER_TOKEN" \
    "https://datacatalog-api.${domain}/api/assets")"
  if [[ "$code" != 200 ]]; then
    DIAG="got HTTP $code instead of 200 — body: $(head -c 200 "$body")"
    return 1
  fi
  return 0
}
check_datacatalog_accepts_bearer() {
  local label="DataCatalog answers 200 to the same request with a valid bearer"
  if [[ -z "${HUB_BEARER_TOKEN:-}" ]]; then
    fail "$label" "HUB_BEARER_TOKEN is not set — see README.md, 'Getting a bearer token'"
    return
  fi
  probe_with_retry "$label" probe_datacatalog_accepts_bearer
}

check_replicas
check_grafana_datasource
check_cdn_package
check_hub_apps
check_datacatalog_rejects_anonymous
check_datacatalog_accepts_bearer

exit "$rc"
