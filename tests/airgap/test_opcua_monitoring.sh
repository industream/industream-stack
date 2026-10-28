#!/usr/bin/env bash
# The OPC-UA worker serves Prometheus metrics on :8080/metrics (2.7.1). Prometheus
# scrapes every replica, and Grafana loads the OPC-UA dashboard only where the bundle
# deploys the OPC-UA worker: elsewhere it would be a folder of empty panels.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

DASHBOARDS=base/config/grafana/provisioning/dashboards
DASHBOARD="$DASHBOARDS/optional/opc-ua/opc-ua.json"
ENABLED=/etc/grafana/provisioning/dashboards/optional/opc-ua
DISABLED=/etc/grafana/provisioning/dashboards/optional/off

# --- Prometheus ---------------------------------------------------------------
job="$(python3 -B - <<'PY'
import yaml
config = yaml.safe_load(open("base/config/prometheus/prometheus.yml"))
jobs = [job for job in config["scrape_configs"] if job["job_name"] == "opcua-client"]
print(jobs[0]["dns_sd_configs"] if jobs else "")
PY
)"
assert_eq "$job" "[{'names': ['tasks.worker-opc-ua-client'], 'type': 'A', 'port': 8080}]" \
  "Prometheus scrapes every OPC-UA worker task on :8080"

# --- Dashboard ----------------------------------------------------------------
[[ -f "$DASHBOARD" ]] || fail "the OPC-UA dashboard is shipped"
summary="$(python3 -B - "$DASHBOARD" <<'PY'
import json, re, sys
dashboard = json.load(open(sys.argv[1]))
# Families the 2.7.1 worker exports (HealthCheckServiceTests.ExpectedFamilies).
families = {
    "reads_total", "nodes_read_total", "errors_total", "connection_attempts_total", "reconnects_total",
    "sessions_created_total", "endpoint_discoveries_total", "read_duration_seconds",
    "connection_duration_seconds", "connection_status", "nodes_configured", "uptime_seconds",
    "reconnect_delay_ms", "last_successful_read_timestamp", "active_subscriptions",
    "subscription_notifications_total", "polling_cycles_total", "polling_duration_seconds", "writes_total",
    "write_duration_seconds", "values_dropped_total", "triggered_reads_total",
    "triggered_read_duration_seconds", "triggered_read_latency_seconds", "triggered_reads_dropped_total",
    "downstream_waits_total", "downstream_wait_seconds", "polling_overruns_total",
    "polling_skipped_cycles_total", "heartbeat_paused", "outage_markers_total", "outage_duration_seconds",
    "read_requests_per_cycle", "tag_check_invalid_nodeids", "tag_check_name_collisions",
}
histograms = {name for name in families if name.endswith("_seconds")}
def panels(items):
    for panel in items:
        yield panel
        yield from panels(panel.get("panels", []))
exprs = [target["expr"] for panel in panels(dashboard["panels"]) for target in panel.get("targets", [])]
used = set()
for expr in exprs:
    for name in re.findall(r"flowmaker_opcua_(\w+)", expr):
        base = re.sub(r"_(bucket|sum|count)$", "", name)
        if base not in families or (base != name and base not in histograms):
            print("unknown metric flowmaker_opcua_" + name)
        used.add(base)
# Counts held per worker task add up across replicas; a max would show one replica's.
for expr in exprs:
    for name in ("active_subscriptions", "nodes_configured", "heartbeat_paused"):
        if "flowmaker_opcua_" + name in expr and not expr.startswith("sum by"):
            print("not summed across replicas: " + name)
for name in sorted(families - used - {"endpoint_discoveries_total", "sessions_created_total"}):
    print("not shown: " + name)
print("uid=%s title=%s exprs=%d" % (dashboard["uid"], dashboard["title"], len(exprs)))
with open(sys.argv[1] + ".rules.yml", "w") as rules:
    rules.write("groups:\n  - name: dashboard\n    rules:\n")
    for index, expr in enumerate(exprs):
        expr = expr.replace("$__rate_interval", "1m").replace("$endpoint", ".*")
        rules.write("      - record: dashboard:expr%d\n        expr: %s\n" % (index, json.dumps(expr)))
PY
)"
trap 'rm -f "$DASHBOARD.rules.yml"' EXIT
[[ "$summary" != *"unknown metric"* ]] || fail "the dashboard queries a metric the worker does not export: $summary"
[[ "$summary" != *"not shown"* ]] || fail "a worker metric has no panel: $summary"
[[ "$summary" != *"not summed"* ]] || fail "a count gauge must add up its replicas: $summary"
assert_contains "$summary" "uid=opcua-client title=OPC-UA" "the dashboard is the OPC-UA one, over metrics the worker exports"

if docker info >/dev/null 2>&1; then
  source versions.env
  promtool() {
    docker run --rm --entrypoint promtool -v "$PWD/base/config/prometheus:/etc/prometheus:ro" \
      -v "$PWD/$DASHBOARDS/optional/opc-ua:/dashboard:ro" "prom/prometheus:${PROMETHEUS_VERSION}" "$@" >/dev/null 2>&1
  }
  promtool check config /etc/prometheus/prometheus.yml || fail "promtool rejects prometheus.yml"
  pass "promtool accepts prometheus.yml"
  promtool check rules /dashboard/opc-ua.json.rules.yml || fail "promtool rejects a dashboard query"
  pass "every dashboard query is valid PromQL"
else
  echo "  ⚠ docker unavailable — promtool not run"
fi

# --- Grafana loads it only with the OPC-UA worker -----------------------------
provider="$(cat "$DASHBOARDS/dashboards.yaml")"
assert_contains "$provider" 'path: $GRAFANA_OPCUA_DASHBOARDS' "a provider reads the OPC-UA dashboard directory from Grafana's env"
assert_contains "$(cat base/monitoring.yml)" "GRAFANA_OPCUA_DASHBOARDS=\${GRAFANA_OPCUA_DASHBOARDS:-$DISABLED}" \
  "without the deploy's say-so, Grafana reads an empty directory"
[[ -d "$DASHBOARDS/optional/off" && -z "$(find "$DASHBOARDS/optional/off" -name '*.json')" ]] \
  || fail "the disabled directory exists and holds no dashboard"
pass "the disabled directory exists and holds no dashboard"

KEY="forge-test-opcua-dashboard"
DIR="releases/bundle-platform-${KEY}"
OIDC_SECRET="$REPO_ROOT/secrets/test/grafana_oidc_client_secret"
[[ -e "$OIDC_SECRET" ]] && had_secret=true || had_secret=false
cleanup() {
  rm -f "$DASHBOARD.rules.yml"
  rm -rf "${REPO_ROOT:?}/unified/$DIR"
  [[ "$had_secret" == true ]] || rm -f "$OIDC_SECRET"
}
trap cleanup EXIT
mkdir -p "$DIR"
cp releases/bundle-platform-1.0.2/.env.* "$DIR/"

deployed_path() {  # deployed_path <runtime> <groups> → GRAFANA_OPCUA_DASHBOARDS as the deploy command sees it
  local target=(--stack t) deploy='^stack deploy '
  [[ "$1" == compose ]] && target=(--project t) deploy='^compose .* up -d'
  # The stub never converges: the deploy's exit status says nothing, the logged deploy command does.
  DOCKER_STUB_LOG_ENV=GRAFANA_OPCUA_DASHBOARDS DEPLOY_TIMEOUT=1 with_docker_stub ./scripts/deploy.sh \
    --runtime "$1" --edition ee --env test --bundle "$KEY" "${target[@]}" --groups "$2" >/dev/null 2>&1 || true
  grep -qE "$deploy" "$DOCKER_LOG" || { echo "no deploy reached"; return; }
  grep -A1 -E "$deploy" "$DOCKER_LOG" | sed -n 's/^env GRAFANA_OPCUA_DASHBOARDS=//p' | head -1
}
WITH_OPCUA="core flowmaker datacatalog workers workers-premium data monitoring"
assert_eq "$(deployed_path swarm "$WITH_OPCUA")" "$ENABLED" "a bundle with the OPC-UA worker loads the dashboard"
assert_eq "$(deployed_path swarm "core flowmaker datacatalog workers data monitoring")" "" \
  "without the premium workers, the dashboard stays off"
# Compose has no tasks.<service> name: Prometheus would find no target, so no dashboard either.
assert_eq "$(deployed_path compose "$WITH_OPCUA")" "" "on compose the dashboard stays off"
sed -i -E '/^WORKER_OPC_UA_CLIENT_IMAGE=/d' "$DIR"/.env.*
assert_eq "$(deployed_path swarm "$WITH_OPCUA")" "" "a bundle without the OPC-UA worker leaves the dashboard off"
