#!/usr/bin/env bash
# Prepare the stable Hub RS256 key. Existing Swarm secrets are authoritative:
# Docker cannot export them, so never invent a replacement local key for one.
set -euo pipefail
umask 077
runtime= env_name= secrets_dir= legacy_file=
while (($#)); do
  case "$1" in
    --runtime) runtime="$2"; shift 2 ;;
    --env) env_name="$2"; shift 2 ;;
    --secrets-dir) secrets_dir="$2"; shift 2 ;;
    --legacy-file) legacy_file="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
[[ "$runtime" == swarm || "$runtime" == compose ]] && [[ "$env_name" =~ ^[a-zA-Z0-9_-]+$ ]] && [[ -n "$secrets_dir" ]] \
  || { echo "Usage: ensure-hub-jwt-key.sh --runtime swarm|compose --env ENV --secrets-dir DIR [--legacy-file FILE]" >&2; exit 1; }
secret="${env_name}_hub_jwt_signing_key"
if [[ "$runtime" == swarm ]] && docker secret inspect "$secret" >/dev/null 2>&1; then
  echo "  ✓ reusing Swarm secret $secret"
  exit 0
fi
if [[ "$runtime" == swarm ]]; then
  # A failed inspect may mean an unreachable daemon or a non-manager, not a
  # missing key. Do not create a misleading local backup in that situation.
  docker secret ls --format '{{.Name}}' >/dev/null \
    || { echo "✗ cannot read Swarm secrets; no signing key was generated" >&2; exit 1; }
fi

mkdir -p "$secrets_dir"
chmod 700 "$secrets_dir"
key="$secrets_dir/hub_jwt_signing_key"
if [[ ! -e "$key" ]]; then
  temporary="$(mktemp "$secrets_dir/.hub-jwt.XXXXXX")"
  trap 'rm -f "$temporary"' EXIT
  if [[ -n "$legacy_file" && -s "$legacy_file" ]]; then
    cp "$legacy_file" "$temporary"
  else
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$temporary" 2>/dev/null
  fi
  # No overwrite, including concurrent invocations on the same secret store.
  ln "$temporary" "$key" 2>/dev/null || [[ -f "$key" ]]
fi
openssl rsa -in "$key" -check -noout >/dev/null 2>&1 \
  || { echo "✗ $key is not a valid RSA private key; refusing to replace it" >&2; exit 1; }
chmod 600 "$key"
if [[ "$runtime" == swarm ]]; then
  docker secret create "$secret" "$key" >/dev/null
  echo "  ✓ created Swarm secret $secret from the persistent key file"
else
  echo "  ✓ using persistent Hub signing-key file"
fi
