#!/usr/bin/env bash
# The Hub launchpad tiles are built as https://<subdomain>.<domain>/, and the
# domain came from `${INDUSTREAM_DOMAIN:-localhost}` followed by an unqualified
# "✓ Hub menu apps seeded". When the variable was missing, every tile was seeded
# pointing at *.localhost and the deploy still reported success — the Hub then
# looks configured and every link on it is dead.
#
# Seeding localhost is legitimate on a dev box (*.localhost resolves there), so
# the fallback stays. What must not stay is it being invisible. The domain is
# therefore named on the banner, which is printed before any early return: the
# seeder's own "(domain=…)" line goes to /dev/null in deploy.sh, so it cannot be
# the thing an operator relies on.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

# unified/.env.test sets INDUSTREAM_DOMAIN=test.lan; there is no .env.prod in the
# repo, so --env prod is exactly the case where the fallback fires.
run_deploy() {  # run_deploy <out-file> <env>
  local out="$1" env_name="$2"
  DEPLOY_TIMEOUT=1 with_docker_stub ./scripts/deploy.sh \
    --runtime swarm --edition ce --env "$env_name" --bundle 1.0.1 \
    --stack test-tiles >"$out" 2>&1 || true
}

f_domain="$(mktemp)"; f_fallback="$(mktemp)"
run_deploy "$f_domain" test &
run_deploy "$f_fallback" prod &
wait

out_domain="$(cat "$f_domain")"
out_fallback="$(cat "$f_fallback")"

assert_contains "$out_domain" "domain: test.lan" \
  "the configured domain is named in the deploy output"

assert_contains "$out_fallback" "INDUSTREAM_DOMAIN is not set" \
  "a missing INDUSTREAM_DOMAIN is reported, not silently replaced by localhost"

assert_contains "$out_fallback" "domain: localhost" \
  "the fallback domain is named too, not just warned about"

# The warning must not cry wolf on a correctly configured deploy.
[[ "$out_domain" != *"INDUSTREAM_DOMAIN is not set"* ]] \
  || fail "a configured deploy must not warn about a missing domain"
pass "a configured deploy does not warn"

# The banner must be printed BEFORE the hub-backend lookup: under the stub no
# container is ever found, and that early return is precisely when an operator
# most needs to know which domain would have been used.
assert_contains "$out_fallback" "hub-backend container not found" \
  "the run did return early — so the banner above it is what is being asserted"
