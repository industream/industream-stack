#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"
out="$(mktemp -d)"

# The Grafana plugins are obtained by RUNNING the Grafana image with the exact
# preinstall list — never by re-implementing the download, which is what once
# left a 22MB fragment of a 25.8MB plugin in the volume. Under the recording
# docker stub nothing is actually installed, so the harvest necessarily dies
# on the empty-plugin guard before reaching the CDN step — that is fine here,
# this assertion only checks that the real preinstall list was ever handed to
# `docker run`. GRAFANA_HARVEST_TIMEOUT=1 keeps the (necessarily futile, under
# the stub) readiness poll short instead of waiting out the real default.
#
# `with_docker_stub … | tail -1` inside a single $(...) would run the stub
# setup (which exports $DOCKER_LOG) in a subshell, discarding the export
# before this script could read it back — so capture stdout to a file instead.
prepare_out="$(mktemp)"
GRAFANA_HARVEST_TIMEOUT=1 with_docker_stub ./scripts/airgap.sh prepare \
  --runtime swarm --edition ce --out "$out" --skip-images > "$prepare_out" 2>&1 || true
log="$(cat "$DOCKER_LOG")"
assert_contains "$log" "GF_PLUGINS_PREINSTALL_SYNC" "grafana is run with the real preinstall list"

# An empty CDN cache must abort: shipping one is the HO8 failure mode, and it
# surfaces later as FlowMaker boxes with no definition. This run uses the real
# docker daemon (no stub) so the Grafana harvest actually completes and the
# script reaches the CDN step; AIRGAP_FAKE_EMPTY_CDN forces that step's guard
# to fire regardless of what a real, unwarmed cdn-server volume holds.
assert_contains "$(bash -c "AIRGAP_FAKE_EMPTY_CDN=1 ./scripts/airgap.sh prepare \
  --runtime swarm --edition ce --out $out --skip-images 2>&1" || true)" \
  "CDN cache is empty" "an empty CDN cache aborts the build"
