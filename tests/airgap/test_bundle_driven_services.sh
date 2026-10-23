#!/usr/bin/env bash
# The bundle (Release Forge) decides which Industream services a site runs: a
# service whose image the bundle does not provide is left out of the deploy,
# instead of reaching `stack deploy` with an empty image and aborting it. The
# platform base (Hub, FlowMaker core, DataCatalog, CDN) is not optional: a
# bundle missing one of those is still refused.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

KEY="forge-test-bundle-driven"
DIR="releases/bundle-platform-${KEY}"
GROUPS_ARG=(--groups "core flowmaker datacatalog workers workers-premium data monitoring")
# An EE deploy generates secrets/test/grafana_oidc_client_secret; remove it when
# this test created it, or a later test reads it as a --list-images side effect.
OIDC_SECRET="$REPO_ROOT/secrets/test/grafana_oidc_client_secret"
[[ -e "$OIDC_SECRET" ]] && had_secret=true || had_secret=false
cleanup() {
  rm -rf "${REPO_ROOT:?}/unified/$DIR"
  [[ "$had_secret" == true ]] || rm -f "$OIDC_SECRET"
}
trap cleanup EXIT

# A Webasto-like bundle: no RTSP / MinIO sink / luminosity / AI agent / DataBridge.
mkdir -p "$DIR"
cp releases/bundle-platform-1.0.2/.env.* "$DIR/"
sed -i -E '/^(WORKER_RTSP_CLIENT_IMAGE|WORKER_MINIO_SINK_IMAGE|WORKER_LUMINOSITY_BOX_IMAGE|AI_AGENT_IMAGE|DATABRIDGE_API_IMAGE)=/d' "$DIR"/.env.*

# --- The image list follows the bundle ---------------------------------------
set +e
images="$(with_docker_stub ./scripts/deploy.sh --runtime swarm --edition ee --env test \
  --bundle "$KEY" --stack t "${GROUPS_ARG[@]}" --list-images 2>"$DIR/stderr")"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "--list-images must succeed when only optional services are absent (rc=$rc)"
assert_contains "$images" "opc-ua-client" "a premium worker the bundle provides is kept"
for gone in rtsp-client minio-sink luminosity-box flowmaker-ai-agent timeseries/api:; do
  [[ "$images" != *"$gone"* ]] || fail "$gone is not in the bundle but is still listed"
done
pass "services the bundle does not provide are not listed"
assert_contains "$(cat "$DIR/stderr")" "worker-rtsp-client" "the skipped services are named on stderr"

# --- The deploy goes through without them ------------------------------------
DEPLOY_TIMEOUT=1 with_docker_stub ./scripts/deploy.sh --runtime swarm --edition ee --env test \
  --bundle "$KEY" --stack t "${GROUPS_ARG[@]}" >/dev/null 2>&1 || true
deploy_line="$(grep -E '^stack deploy ' "$DOCKER_LOG" || true)"
[[ -n "$deploy_line" ]] || fail "stack deploy was never reached"
pass "stack deploy is reached"
[[ "$deploy_line" != *" base/workers-premium.yml"* ]] || fail "the unpruned workers-premium file was deployed"
pass "files holding skipped services are swapped for pruned copies"
git -C "$REPO_ROOT" diff --quiet -- unified/base unified/runtime || fail "the tracked compose files were modified"
[[ -z "$(git -C "$REPO_ROOT" status --porcelain --ignored -- 'unified/base/.*' 'unified/runtime/*/.*')" ]] \
  || fail "pruned copies were left behind"
pass "tracked files untouched and pruned copies cleaned up"

# --- The platform base is not optional ---------------------------------------
sed -i -E '/^HUB_API_ENTERPRISE_IMAGE=/d' "$DIR"/.env.*
assert_fails with_docker_stub ./scripts/deploy.sh --runtime swarm --edition ee --env test \
  --bundle "$KEY" --stack t "${GROUPS_ARG[@]}" --list-images \
  "a bundle without the enterprise Hub is refused in EE"
