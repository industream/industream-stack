#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/swarm"
export JWT_TEST_STATE="$fixture/swarm" JWT_TEST_LOG="$fixture/docker.log"
cat > "$fixture/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$JWT_TEST_LOG"
[[ "${JWT_TEST_UNAVAILABLE:-0}" != 1 ]] || exit 1
case "$1 $2" in
  'secret inspect') [[ -f "$JWT_TEST_STATE/$3" ]] ;;
  'secret ls') : ;;
  'secret create') cp "$4" "$JWT_TEST_STATE/$3" ;;
  *) echo "Unexpected Docker call" >&2; exit 1 ;;
esac
STUB
chmod +x "$fixture/bin/docker"
export PATH="$fixture/bin:$PATH"
helper="$REPO_ROOT/scripts/setup/ensure-hub-jwt-key.sh"
run_key() { bash "$helper" --runtime swarm --env test --secrets-dir "$fixture/keys"; }
run_key >/dev/null
key="$fixture/keys/hub_jwt_signing_key"
openssl rsa -in "$key" -check -noout >/dev/null 2>&1 || fail "generated key is not RSA"
pass "fresh deploy provisions an RSA key"
assert_eq "$(stat -c %a "$key")" 600 "private key mode is 0600"
assert_eq "$(stat -c %a "$fixture/keys")" 700 "private key directory mode is 0700"
first="$(sha256sum "$key" | cut -d' ' -f1)"
run_key >/dev/null
assert_eq "$(sha256sum "$key" | cut -d' ' -f1)" "$first" "redeploy preserves the key file"
assert_eq "$(grep -c '^secret create' "$JWT_TEST_LOG")" 1 "redeploy does not recreate the Swarm secret"
rm "$key"
run_key >/dev/null
[[ ! -e "$key" ]] || fail "existing Swarm secret caused a replacement local key"
pass "existing Swarm key is authoritative when its local file is absent"
assert_eq "$(grep -c '^secret create' "$JWT_TEST_LOG")" 1 "missing local backup does not rotate the Swarm secret"

# A mounted Compose key is reusable as the source of a new Swarm secret.
calls="$(wc -l < "$JWT_TEST_LOG")"
bash "$helper" --runtime compose --env test --secrets-dir "$fixture/compose" >/dev/null
assert_eq "$(wc -l < "$JWT_TEST_LOG")" "$calls" "Compose key preparation does not call Docker"
compose="$fixture/compose/hub_jwt_signing_key"
second="$(sha256sum "$compose" | cut -d' ' -f1)"
bash "$helper" --runtime swarm --env other --secrets-dir "$fixture/migrated" --legacy-file "$compose" >/dev/null
assert_eq "$(sha256sum "$fixture/migrated/hub_jwt_signing_key" | cut -d' ' -f1)" "$second" "existing file migrates without changing the key"
mkdir "$fixture/invalid"
printf 'not a private key\n' > "$fixture/invalid/hub_jwt_signing_key"
assert_fails bash "$helper" --runtime swarm --env invalid --secrets-dir "$fixture/invalid" "invalid existing key is rejected"
assert_eq "$(cat "$fixture/invalid/hub_jwt_signing_key")" 'not a private key' "invalid key is never overwritten"
[[ ! -f "$fixture/swarm/invalid_hub_jwt_signing_key" ]] || fail "invalid key was provisioned"
pass "invalid key never reaches Swarm"
export JWT_TEST_UNAVAILABLE=1
assert_fails bash "$helper" --runtime swarm --env unreachable --secrets-dir "$fixture/unreachable" "unreachable Swarm does not look like a missing key"
[[ ! -e "$fixture/unreachable" ]] || fail "unreachable Swarm caused a local key to be generated"
pass "no misleading local key is created when Swarm is unavailable"
