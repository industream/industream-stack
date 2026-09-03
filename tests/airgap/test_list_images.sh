#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

# --bundle is REQUIRED: two directories match releases/bundle-platform-*/ on this
# branch, so deploy.sh's auto-select exits 1 at line 139 before any flag is read.
BUNDLE_ARGS=(--bundle 1.0.1 --env test)

ce="$(with_docker_stub ./scripts/deploy.sh --runtime swarm --stack test-ce --edition ce "${BUNDLE_ARGS[@]}" --list-images)"
[[ -n "$ce" ]] || fail "CE list is empty"
pass "CE list is non-empty"

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
