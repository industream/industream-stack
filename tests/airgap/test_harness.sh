#!/usr/bin/env bash
# The harness must record docker invocations and must fail loudly.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

with_docker_stub bash -c 'docker pull alpine:3 >/dev/null; docker stack deploy -c f.yml s >/dev/null'
assert_contains "$(cat "$DOCKER_LOG")" "pull alpine:3" "stub records a pull"
assert_contains "$(cat "$DOCKER_LOG")" "stack deploy" "stub records a stack deploy"
assert_fails false "assert_fails accepts a failing command"
pass "harness"
