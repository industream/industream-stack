#!/usr/bin/env bash
# Minimal assertion helpers. Plain bash on purpose: this repo has no test
# framework, and the bench VM is air-gapped so nothing can be installed there.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

fail() { echo "  ✗ $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
  pass "$3"
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3: '$2' not found in output"
  pass "$3"
}

assert_fails() {
  local label="${*: -1}"
  if "${@:1:$#-1}" >/dev/null 2>&1; then fail "$label: command unexpectedly succeeded"; fi
  pass "$label"
}

# Runs a command with a `docker` stub first on PATH. Every invocation appends
# its argv to $DOCKER_LOG, so a test can assert what the script WOULD have run
# without a daemon — and, just as importantly, what it did NOT run.
with_docker_stub() {
  local stub_dir; stub_dir="$(mktemp -d)"
  DOCKER_LOG="$(mktemp)"; export DOCKER_LOG
  cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
case "$1" in
  info)   echo "active" ;;
  image)  exit 1 ;;          # `image inspect` → absent, so callers pull
  volume) echo "vol" ;;
  load)   cat >/dev/null ;;  # a real `docker load` reads its whole stdin —
                              # not draining it here made `zstd`'s write take
                              # SIGPIPE against a reader that already exited
esac
exit 0
STUB
  chmod +x "$stub_dir/docker"
  PATH="$stub_dir:$PATH" "$@"
}
