#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

# --bundle is REQUIRED: two directories match releases/bundle-platform-*/ on this
# branch, so deploy.sh's auto-select exits 1 at line 139 before any flag is read.
BUNDLE_ARGS=(--bundle 1.0.1 --env test)

echo "=== Testing swarm runtime ==="
ce="$(with_docker_stub ./scripts/deploy.sh --runtime swarm --stack test-ce --edition ce "${BUNDLE_ARGS[@]}" --list-images)"
[[ -n "$ce" ]] || fail "CE list is empty"
pass "CE list is non-empty"

# --list-images stdout must be strictly the image list — no progress banner or
# other prose line. A real image reference never contains whitespace, so any
# whitespace on a line means non-image text leaked onto stdout.
if grep -q '[[:space:]]' <<<"$ce"; then fail "--list-images stdout contains non-image text (banner leaked to stdout)"; fi
pass "stdout is image-only (no banner leakage)"

# Every reference must be fully resolved: an unexpanded ${VAR} would silently
# become an empty image at deploy time.
if grep -q '\$' <<<"$ce"; then fail "unresolved variable in the image list"; fi
pass "no unresolved variables"

assert_contains "$ce" "postgres:" "third-party images are included"

# EE adds Logto and the enterprise Hub, so it must be a strict superset.
ee="$(with_docker_stub ./scripts/deploy.sh --runtime swarm --stack test-ee --edition ee "${BUNDLE_ARGS[@]}" --list-images)"
(( $(wc -l <<<"$ee") > $(wc -l <<<"$ce") )) || fail "EE list is not larger than CE"
pass "EE list is larger than CE"
assert_contains "$ee" "logto" "EE includes Logto"

# --groups must narrow the footprint.
core="$(with_docker_stub ./scripts/deploy.sh --runtime swarm --stack test-core --edition ce "${BUNDLE_ARGS[@]}" --groups core --list-images)"
(( $(wc -l <<<"$core") < $(wc -l <<<"$ce") )) || fail "--groups did not narrow the list"
pass "--groups narrows the list"

# No duplicates: a duplicate would be saved twice into the bundle.
assert_eq "$(sort <<<"$ce" | uniq -d | wc -l)" "0" "list has no duplicates"

# The flag must not deploy anything (check from the last invocation's docker log).
# The docker stub records all invocations to DOCKER_LOG during the with_docker_stub call.
# We need to verify it again with a fresh stub to check for stack deploy.
with_docker_stub ./scripts/deploy.sh --runtime swarm --stack test-check --edition ce "${BUNDLE_ARGS[@]}" --list-images >/dev/null
if grep -q "stack deploy" "$DOCKER_LOG" 2>/dev/null; then fail "--list-images deployed"; fi
pass "--list-images does not deploy"

echo ""
echo "=== Testing compose runtime ==="

# Compose also produces valid lists
compose_ce="$(with_docker_stub ./scripts/deploy.sh --runtime compose --project test-ce --edition ce "${BUNDLE_ARGS[@]}" --list-images)"
[[ -n "$compose_ce" ]] || fail "Compose CE list is empty"
pass "Compose CE list is non-empty"

# Same stdout-is-image-only check as the swarm runtime above.
if grep -q '[[:space:]]' <<<"$compose_ce"; then fail "Compose --list-images stdout contains non-image text (banner leaked to stdout)"; fi
pass "Compose stdout is image-only (no banner leakage)"

# Compose lists must be fully resolved
if grep -q '\$' <<<"$compose_ce"; then fail "unresolved variable in compose image list"; fi
pass "Compose list has no unresolved variables"

# Compose EE is a strict superset (includes logto, etc)
compose_ee="$(with_docker_stub ./scripts/deploy.sh --runtime compose --project test-ee --edition ee "${BUNDLE_ARGS[@]}" --list-images)"
(( $(wc -l <<<"$compose_ee") > $(wc -l <<<"$compose_ce") )) || fail "Compose EE list is not larger than CE"
pass "Compose EE list is larger than CE"
assert_contains "$compose_ee" "logto" "Compose EE includes Logto"

# Critical: --list-images EE must not trigger side effects (no secret file, no domain abort)
secrets_dir="$REPO_ROOT/secrets/test"
if [[ -f "$secrets_dir/grafana_oidc_client_secret" ]]; then
  fail "--list-images --edition ee created a secret file (side effect!)"
fi
pass "Compose EE --list-images does not create secrets"

# Compose must not deploy either
with_docker_stub ./scripts/deploy.sh --runtime compose --project test-check --edition ce "${BUNDLE_ARGS[@]}" --list-images >/dev/null
if grep -q "compose.*up" "$DOCKER_LOG" 2>/dev/null; then fail "Compose --list-images deployed"; fi
pass "Compose --list-images does not deploy"
