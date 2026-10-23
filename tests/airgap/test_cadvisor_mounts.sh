#!/usr/bin/env bash
# cAdvisor runs the Docker handler (no --containerd), so it must not bind-mount
# the containerd socket: swarm rejects a bind whose host path is missing, and
# openSUSE's Docker keeps its containerd at /run/docker/containerd/ — the task
# was "Rejected" there and every infrastructure dashboard showed no data.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

mounts="$(python3 -B - <<'PY'
import yaml
spec = yaml.safe_load(open("base/monitoring.yml"))["services"]["cadvisor"]
print("\n".join(spec.get("volumes", [])))
PY
)"
[[ "$mounts" != *containerd.sock* ]] || fail "cAdvisor still bind-mounts containerd.sock"
pass "cAdvisor does not bind-mount the containerd socket"
assert_contains "$mounts" "/var/run/docker.sock" "cAdvisor keeps the Docker socket it reads from"
