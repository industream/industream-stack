#!/usr/bin/env bash
# =============================================================================
# Issue a signed Industream license file (Ed25519). RUN ON INDUSTREAM'S SIDE.
# =============================================================================
# Produces a compact, offline-verifiable license: `<payload_b64>.<sig_b64>`
#   - payload_b64 = base64 of the canonical (jq -c) JSON claims
#   - sig_b64     = base64 of the Ed25519 signature over the payload_b64 BYTES
#                   (JWT-style: we sign the encoded segment, so the verifier
#                   re-uses the exact same bytes — no JSON canonicalization trap)
#
# The license embeds the per-client Harbor robot credentials (the STRONG,
# revocable distribution gate — see create-customer.ts). Tampering with the
# claims breaks the signature; and even an untouched leaked license is useless
# once the matching Harbor robot is rotated server-side.
#
# Usage:
#   ./issue-license.sh \
#     --key keys/license-private.pem \
#     --customer "ACME GmbH" --site "Plant-Esch-1" \
#     --type subscription \
#     --module DATACATALOG:maxTags=1000 --module AI_STUDIO:maxModels=5 \
#     --addon ADDON_BACKUP --addon ADDON_DB_TIMESCALE \
#     --harbor-user 'robot$client-acme' --harbor-secret 'xxxx' \
#     --expiry 2027-05-27 \
#     --out acme.lic
#   # trial: --type trial --days 90   (sets expiry = today+90 and trial flag)
# =============================================================================
set -euo pipefail

KEY="" CUSTOMER="" SITE="" TYPE="subscription" EXPIRY="" DAYS=""
HARBOR_USER="" HARBOR_SECRET="" MAINT_EXPIRY="" OUT="/dev/stdout"
declare -a MODULES=() ADDONS=()

die() { echo "✗ $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)           KEY="$2"; shift 2 ;;
    --customer)      CUSTOMER="$2"; shift 2 ;;
    --site)          SITE="$2"; shift 2 ;;
    --type)          TYPE="$2"; shift 2 ;;
    --module)        MODULES+=("$2"); shift 2 ;;
    --addon)         ADDONS+=("$2"); shift 2 ;;
    --harbor-user)   HARBOR_USER="$2"; shift 2 ;;
    --harbor-secret) HARBOR_SECRET="$2"; shift 2 ;;
    --expiry)        EXPIRY="$2"; shift 2 ;;
    --maintenance)   MAINT_EXPIRY="$2"; shift 2 ;;
    --days)          DAYS="$2"; shift 2 ;;
    --out)           OUT="$2"; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[ -n "$KEY" ] && [ -f "$KEY" ] || die "--key <private.pem> required"
[ -n "$CUSTOMER" ] || die "--customer required"
[ -n "$TYPE" ] || die "--type required"

# trial: expiry = today + N days
if [ -n "$DAYS" ]; then
  EXPIRY="$(date -u -d "+${DAYS} days" +%Y-%m-%d)"
fi
[ "$TYPE" = "perpetual" ] || [ -n "$EXPIRY" ] || die "--expiry required (or --days for trial)"

# Build modules object: --module NAME:key=val[,key=val]
modules_json="{}"
for spec in "${MODULES[@]:-}"; do
  [ -z "$spec" ] && continue
  name="${spec%%:*}"; limits="${spec#*:}"
  obj="{}"
  if [ "$limits" != "$spec" ]; then
    IFS=',' read -ra kvs <<< "$limits"
    for kv in "${kvs[@]}"; do
      k="${kv%%=*}"; v="${kv#*=}"
      obj="$(jq -c --arg k "$k" --argjson v "$v" '. + {($k): $v}' <<< "$obj")"
    done
  fi
  modules_json="$(jq -c --arg n "$name" --argjson o "$obj" '. + {($n): $o}' <<< "$modules_json")"
done

addons_json="$(printf '%s\n' "${ADDONS[@]:-}" | jq -R . | jq -sc 'map(select(length>0))')"

payload="$(jq -cn \
  --arg lid "$(openssl rand -hex 8)" \
  --arg customer "$CUSTOMER" --arg site "$SITE" --arg type "$TYPE" \
  --argjson modules "$modules_json" --argjson addons "$addons_json" \
  --arg hu "$HARBOR_USER" --arg hs "$HARBOR_SECRET" \
  --arg issued "$(date -u +%Y-%m-%d)" --arg expiry "$EXPIRY" --arg maint "$MAINT_EXPIRY" \
  '{
     v: 1, license_id: $lid, customer: $customer, site: $site, type: $type,
     modules: $modules, addons: $addons,
     harbor: (if $hu == "" then null else {username: $hu, secret: $hs} end),
     issued: $issued,
     expiry: (if $expiry == "" then null else $expiry end),
     maintenance_expiry: (if $maint == "" then null else $maint end)
   }')"

payload_b64="$(printf '%s' "$payload" | base64 -w0)"
# Ed25519 -rawin is a oneshot op: openssl must size the input, so it needs a
# real file (a pipe fails with "unable to determine file size").
tmp_msg="$(mktemp)"; trap 'rm -f "$tmp_msg"' EXIT
printf '%s' "$payload_b64" > "$tmp_msg"
sig_b64="$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$tmp_msg" 2>/dev/null | base64 -w0)"
[ -n "$sig_b64" ] || die "signing failed (Ed25519 key + openssl 3.x required)"

printf '%s.%s\n' "$payload_b64" "$sig_b64" > "$OUT"
[ "$OUT" != "/dev/stdout" ] && echo "✓ License written: $OUT ($(echo "$payload" | jq -c '{customer,site,type,expiry}'))" >&2
