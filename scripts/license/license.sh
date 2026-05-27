#!/usr/bin/env bash
# =============================================================================
# Industream license verification — OFFLINE, deploy-side. Source it or run it.
# =============================================================================
# Needs only the PUBLIC key. Verifies the Ed25519 signature, then checks expiry
# with a monotonic high-water mark (flags a backwards clock jump). Exposes the
# claims to the `ee` deploy gate: modules, add-ons, Harbor pull credentials.
#
# As a library:   source license.sh; license_verify acme.lic keys/license-public.pem
#                 then: license_module_enabled DATACATALOG / license_has_addon ADDON_BACKUP
#                       license_field '.customer' / license_harbor_login
# As a CLI:       ./license.sh verify <file> [pubkey]
#                 ./license.sh show   <file> [pubkey]
#                 ./license.sh check-addon <CODE> <file> [pubkey]
# =============================================================================
set -euo pipefail

LICENSE_PUBKEY_DEFAULT="${LICENSE_PUBKEY:-$(dirname "${BASH_SOURCE[0]}")/keys/license-public.pem}"
LICENSE_STATE="${LICENSE_STATE:-/var/lib/industream/license.state}"
LICENSE_GRACE_DAYS="${LICENSE_GRACE_DAYS:-14}"

# Populated by license_verify:
LICENSE_PAYLOAD=""   # decoded JSON claims
LICENSE_STATUS=""    # valid | expired | grace | clock-rollback | invalid

_lerr() { echo "✗ license: $*" >&2; }

# Verify signature and decode claims. Returns non-zero on a bad/absent signature.
license_verify() {
  local file="$1" pubkey="${2:-$LICENSE_PUBKEY_DEFAULT}"
  [ -f "$file" ]   || { _lerr "file not found: $file"; LICENSE_STATUS=invalid; return 1; }
  [ -f "$pubkey" ] || { _lerr "public key not found: $pubkey"; LICENSE_STATUS=invalid; return 1; }

  local payload_b64 sig_b64 raw
  raw="$(tr -d '[:space:]' < "$file")"
  payload_b64="${raw%%.*}"; sig_b64="${raw#*.}"
  [ -n "$payload_b64" ] && [ "$sig_b64" != "$raw" ] || { _lerr "malformed license (expected payload.signature)"; LICENSE_STATUS=invalid; return 1; }

  # Ed25519 -rawin is a oneshot op needing real files for both message and sig.
  local tmp_msg tmp_sig ok=1
  tmp_msg="$(mktemp)"; tmp_sig="$(mktemp)"
  printf '%s' "$payload_b64" > "$tmp_msg"
  printf '%s' "$sig_b64" | base64 -d > "$tmp_sig" 2>/dev/null || ok=0
  if [ "$ok" -eq 1 ] && openssl pkeyutl -verify -pubin -inkey "$pubkey" -rawin \
       -in "$tmp_msg" -sigfile "$tmp_sig" >/dev/null 2>&1; then ok=1; else ok=0; fi
  rm -f "$tmp_msg" "$tmp_sig"
  if [ "$ok" -eq 0 ]; then
    _lerr "signature verification FAILED (forged or wrong key)"
    LICENSE_STATUS=invalid; return 1
  fi

  LICENSE_PAYLOAD="$(printf '%s' "$payload_b64" | base64 -d 2>/dev/null)" \
    || { _lerr "payload decode failed"; LICENSE_STATUS=invalid; return 1; }
  jq -e . >/dev/null 2>&1 <<< "$LICENSE_PAYLOAD" \
    || { _lerr "payload is not valid JSON"; LICENSE_STATUS=invalid; return 1; }
  LICENSE_STATUS=valid
  return 0
}

# Read a jq path from the verified payload.
license_field() { jq -r "$1 // empty" <<< "$LICENSE_PAYLOAD"; }

license_module_enabled() { jq -e --arg m "$1" '.modules | has($m)' >/dev/null 2>&1 <<< "$LICENSE_PAYLOAD"; }
license_module_limit()   { jq -r --arg m "$1" --arg k "$2" '.modules[$m][$k] // empty' <<< "$LICENSE_PAYLOAD"; }
license_has_addon()      { jq -e --arg a "$1" '.addons | index($a)' >/dev/null 2>&1 <<< "$LICENSE_PAYLOAD"; }

# Print `docker login` material from the embedded Harbor robot creds (the
# revocable distribution gate). Empty if the license carries none.
license_harbor_login() {
  local u s; u="$(license_field '.harbor.username')"; s="$(license_field '.harbor.secret')"
  [ -n "$u" ] && printf '%s\t%s\n' "$u" "$s"
}

# Expiry + monotonic high-water mark. Sets LICENSE_STATUS, returns:
#   0 valid | 0 grace(with warn) | 1 expired | 1 clock-rollback
license_check_expiry() {
  local now exp grace_s hwm
  now="$(date -u +%s)"

  # High-water mark: detect a backwards clock jump (naive rollback attack).
  if [ -f "$LICENSE_STATE" ]; then
    hwm="$(cat "$LICENSE_STATE" 2>/dev/null || echo 0)"
    if [ "$now" -lt "$((hwm - 86400))" ]; then
      _lerr "system clock moved BACKWARDS (now < last-seen) — possible tampering"
      LICENSE_STATUS=clock-rollback; return 1
    fi
  else
    hwm=0
  fi
  [ "$now" -gt "$hwm" ] && { mkdir -p "$(dirname "$LICENSE_STATE")" 2>/dev/null || true; echo "$now" > "$LICENSE_STATE" 2>/dev/null || true; }

  local expiry; expiry="$(license_field '.expiry')"
  [ -z "$expiry" ] && { LICENSE_STATUS=valid; return 0; }   # perpetual

  exp="$(date -u -d "$expiry" +%s)"; grace_s="$((LICENSE_GRACE_DAYS * 86400))"
  if [ "$now" -le "$exp" ]; then LICENSE_STATUS=valid; return 0; fi
  if [ "$now" -le "$((exp + grace_s))" ]; then
    _lerr "EXPIRED on $expiry — in ${LICENSE_GRACE_DAYS}-day grace (renew to keep upgrades/EE)"
    LICENSE_STATUS=grace; return 0
  fi
  _lerr "EXPIRED on $expiry (grace elapsed)"; LICENSE_STATUS=expired; return 1
}

_license_show() {
  license_verify "$1" "${2:-$LICENSE_PUBKEY_DEFAULT}" || return 1
  license_check_expiry || true
  jq --arg st "$LICENSE_STATUS" '. + {_status: $st} | .harbor.secret = (if .harbor then "***" else null end)' <<< "$LICENSE_PAYLOAD"
}

# CLI dispatch (only when executed, not when sourced).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    verify) license_verify "$1" "${2:-}" && license_check_expiry
            echo "status: $LICENSE_STATUS" ;;
    show)   _license_show "$1" "${2:-}" ;;
    check-addon) license_verify "$2" "${3:-}" >/dev/null && license_has_addon "$1" \
                 && echo "yes" || { echo "no"; exit 1; } ;;
    *) echo "usage: license.sh {verify|show|check-addon <CODE>} <file> [pubkey]" >&2; exit 2 ;;
  esac
fi
