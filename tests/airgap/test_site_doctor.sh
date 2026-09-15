#!/usr/bin/env bash
# site-doctor.sh runs on customer production sites, often by someone who did not
# write it. Its contract — read-only unless asked, destructive only when asked
# twice, and a usage error that never looks like a healthy site — is what this
# covers. The per-check logic needs a real stack and is exercised on the bench.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DOCTOR="$REPO_ROOT/scripts/ops/site-doctor.sh"

[[ -x "$DOCTOR" ]] || fail "scripts/ops/site-doctor.sh is missing or not executable"
pass "the script exists and is executable"

bash -n "$DOCTOR" || fail "the script does not parse"
pass "the script parses"

# Exit codes are part of the contract: 0 healthy, 1 issues, 2 cannot run. A
# usage error returning 1 would read as "issues found" to a caller, and a
# wrapper would report a broken site instead of a typo.
run_code() { bash "$DOCTOR" "$@" >/dev/null 2>&1; echo $?; }

assert_eq "$(run_code --help)" "0" "--help exits 0"
assert_eq "$(run_code --not-an-option)" "2" "an unknown option exits 2 (usage), not 1"
assert_eq "$(run_code --stack)" "2" "a flag missing its value exits 2, not 1 from set -u"

# The destructive path must be unreachable without --fix: someone pasting a
# command from a runbook must not drop a customer's users on a diagnostic run.
assert_eq "$(run_code --reset-logto-db)" "2" "--reset-logto-db alone is refused"

help="$(bash "$DOCTOR" --help 2>&1)"
assert_contains "$help" "--fix" "help documents --fix"
assert_contains "$help" "Exit codes" "help documents the exit codes"

# ---- read-only by default -------------------------------------------------
# Asserted on BEHAVIOUR, not on the source: a grep for a mutating verb cannot
# tell whether the line sits inside a `if [[ $FIX == true ]]` block, and reports
# a guarded call as unguarded.
#
# A stub rich enough for the doctor to walk every check: one service, one
# volume owned by the wrong uid, one pinned digest. A read-only run must SEE
# all of that and still not issue a single mutating command.
doctor_stub() {
  local stub_dir; stub_dir="$(mktemp -d)"
  DOCKER_LOG="$(mktemp)"; export DOCKER_LOG
  cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
case "$1 $2" in
  "info ")            echo "active"; exit 0 ;;
  "service ls")       echo "teststack_web"; exit 0 ;;
  "service inspect")  # image, then the volume-mount template
                      if [[ "$*" == *Mounts* ]]; then echo "datavol"; else
                      echo "registry.example/web:1.0@sha256:deadbeef"; fi; exit 0 ;;
  "image inspect")    echo "1000"; exit 0 ;;
  "volume inspect")   exit 0 ;;
  "stack services")   echo "teststack_web 1/1"; exit 0 ;;
  "ps -qf")           exit 0 ;;          # no logto-postgres → that section is skipped
  "run --rm")         echo "0"; exit 0 ;; # the volume reports uid 0, image wants 1000
esac
exit 0
STUB
  chmod +x "$stub_dir/docker"
  PATH="$stub_dir:$PATH" "$@"
}

doctor_stub bash "$DOCTOR" --stack teststack --target /nonexistent >/dev/null 2>&1
log="$(cat "$DOCKER_LOG" 2>/dev/null)"

[[ -n "$log" ]] || fail "the stub recorded nothing — the doctor never inspected the stack"
pass "a read-only run does inspect the stack"

for verb in "service update" "service scale" "service rm" "volume rm" "stack rm"; do
  if grep -q -- "$verb" <<<"$log"; then
    fail "a read-only run issued 'docker ${verb}'"
  fi
done
pass "a read-only run issues no mutating docker command"

if grep -q -- "chown" <<<"$log"; then
  fail "a read-only run chowned a volume"
fi
pass "a read-only run never chowns a volume"

# Never chown TO root: a root process reads any ownership, and rewriting would
# undo the ownership a running service depends on.
assert_contains "$(cat "$DOCTOR")" '"$user" == 0' "an image running as root is skipped, never chowned"
