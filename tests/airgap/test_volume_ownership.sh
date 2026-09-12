#!/usr/bin/env bash
# An image that changes the user it runs as cannot read the volume the previous
# version wrote as root. That breaks ONLY on an update — a fresh install creates
# the volume empty and Docker gives it the right owner — so it never shows up in
# testing and lands on a customer site instead.
#
# It happened for real on the core 2.1.0 → 2.2.2 update: confighub and the
# scheduler went from root to uid 1000 and crash-looped on
# "Permission denied: Attempting to setup locks", taking twelve workers down
# with them.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

SCRIPT="$REPO_ROOT/scripts/setup/fix-volume-ownership.sh"
[[ -x "$SCRIPT" ]] || fail "fix-volume-ownership.sh must exist and be executable"
pass "the script exists and is executable"

fixture="$(mktemp -d)"
cat > "$fixture/stack.yml" <<'YAML'
services:
  needs-fixing:
    image: ${SOME_IMAGE}
    volumes:
      - data-vol:/data
  no-volume:
    image: ${SOME_IMAGE}
volumes:
  data-vol:
    name: prod-data-vol
YAML

# The stub answers the two questions the script must ask: what user does the
# image run as, and who owns the volume. It records the chown so the test can
# assert on the uid actually applied rather than on the script's own wording.
stub_dir="$(mktemp -d)"; CHOWN_LOG="$(mktemp)"; export CHOWN_LOG
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "image inspect")
    # --format '{{.Config.User}}' → the new image runs as uid 1000
    echo "1000" ;;
  "volume inspect")
    # the volume exists
    echo "[{}]" ;;
  "run --rm")
    # stat → owned by root; chown → record it
    if [[ "$*" == *chown* ]]; then
      echo "$*" | grep -oE 'chown -R [0-9]+:[0-9]+' >> "$CHOWN_LOG"
    else
      echo "0:0"
    fi ;;
esac
exit 0
STUB
chmod +x "$stub_dir/docker"

SOME_IMAGE="example/app:1.0" PATH="$stub_dir:$PATH" \
  bash "$SCRIPT" --env prod "$fixture/stack.yml" >/dev/null 2>&1 \
  || fail "the script must succeed on a stack it can fix"
pass "the script runs over a stack file"

assert_contains "$(cat "$CHOWN_LOG")" "chown -R 1000:1000" \
  "the volume is chowned to the uid the NEW image declares, not a hardcoded one"

assert_eq "$(grep -c . "$CHOWN_LOG")" "1" \
  "only the service that actually mounts a volume is touched"

# Nothing to do must be a no-op, not a chown: rewriting ownership on every
# deploy would churn every file of a large volume for no reason.
: > "$CHOWN_LOG"
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "image inspect") echo "1000" ;;
  "volume inspect") echo "[{}]" ;;
  "run --rm")
    if [[ "$*" == *chown* ]]; then echo "$*" >> "$CHOWN_LOG"; else echo "1000:1000"; fi ;;
esac
exit 0
STUB
chmod +x "$stub_dir/docker"
SOME_IMAGE="example/app:1.0" PATH="$stub_dir:$PATH" \
  bash "$SCRIPT" --env prod "$fixture/stack.yml" >/dev/null 2>&1 || true
assert_eq "$(grep -c . "$CHOWN_LOG" || true)" "0" \
  "a volume already owned by the right uid is left alone"

# A volume that does not exist yet is a fresh install: there is nothing to
# migrate, and creating or touching it here would be wrong.
: > "$CHOWN_LOG"
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "image inspect") echo "1000" ;;
  "volume inspect") exit 1 ;;
  "run --rm") echo "$*" >> "$CHOWN_LOG" ;;
esac
exit 0
STUB
chmod +x "$stub_dir/docker"
SOME_IMAGE="example/app:1.0" PATH="$stub_dir:$PATH" \
  bash "$SCRIPT" --env prod "$fixture/stack.yml" >/dev/null 2>&1 \
  || fail "an absent volume must not fail the script — that is a fresh install"
assert_eq "$(grep -c . "$CHOWN_LOG" || true)" "0" \
  "a volume that does not exist yet is left alone"

# An image that runs as root reads any ownership, so there is nothing to fix —
# and "fixing" it would rewrite a volume another image legitimately owns. Seen
# for real: the first version of this script chowned influxdb's and cdn-server's
# data to root because their images declare no user, undoing ownership those
# services were running with happily.
: > "$CHOWN_LOG"
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "image inspect") echo "" ;;          # no declared user → root
  "volume inspect") echo "[{}]" ;;
  "run --rm")
    if [[ "$*" == *chown* ]]; then echo "$*" >> "$CHOWN_LOG"; else echo "1000:1000"; fi ;;
esac
exit 0
STUB
chmod +x "$stub_dir/docker"
SOME_IMAGE="example/app:1.0" PATH="$stub_dir:$PATH" \
  bash "$SCRIPT" --env prod "$fixture/stack.yml" >/dev/null 2>&1 || true
assert_eq "$(grep -c . "$CHOWN_LOG" || true)" "0" \
  "an image running as root never triggers a chown"

rm -rf "$fixture" "$stub_dir"
