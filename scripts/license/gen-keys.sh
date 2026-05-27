#!/usr/bin/env bash
# =============================================================================
# Generate the Ed25519 signing keypair for Industream licenses.
# Run ONCE, on Industream's side. The PRIVATE key never leaves Industream and
# never ships to a customer. Only the PUBLIC key is embedded in the deployment
# (so the platform can verify licenses offline, but cannot forge them).
# =============================================================================
set -euo pipefail

OUT_DIR="${1:-./keys}"
PRIVATE="$OUT_DIR/license-private.pem"
PUBLIC="$OUT_DIR/license-public.pem"

mkdir -p "$OUT_DIR"
if [ -f "$PRIVATE" ]; then
  echo "✗ $PRIVATE already exists — refusing to overwrite the signing key." >&2
  exit 1
fi

umask 077
openssl genpkey -algorithm ed25519 -out "$PRIVATE"
openssl pkey -in "$PRIVATE" -pubout -out "$PUBLIC"
chmod 600 "$PRIVATE"
chmod 644 "$PUBLIC"

echo "✓ Private key (KEEP SECRET, store in 'pass' / vault): $PRIVATE"
echo "✓ Public  key (ship with the platform):              $PUBLIC"
echo
echo "  Public key fingerprint:"
openssl pkey -in "$PUBLIC" -pubin -outform DER | openssl dgst -sha256 | sed 's/^/    /'
