#!/usr/bin/env bash
# The provisioned Grafana datasource pointed at http://databridge:8080, but a TimescaleDB deploy only runs
# databridge-timescaledb: dashboards could not reach DataBridge. The URL now follows the deployed store.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

datasources="$(cat unified/base/config/grafana/provisioning/datasources/industream-datasources.yaml)"
assert_contains "$datasources" 'dataBridgeApiUrl: $GRAFANA_DATABRIDGE_URL' "the datasource reads the DataBridge URL from Grafana's env"

grafana_env() {  # grafana_env <url or empty> → the GRAFANA_DATABRIDGE_URL value rendered for the grafana service
  GRAFANA_DATABRIDGE_URL="$1" ENV=prod docker stack config -c unified/base/monitoring.yml 2>/dev/null \
    | awk '/^  [a-z]/ {in_grafana = ($1 == "grafana:")} in_grafana && /GRAFANA_DATABRIDGE_URL/ {print $2; exit}'
}
if docker stack config --help >/dev/null 2>&1; then
  assert_eq "$(grafana_env "")" "http://databridge:8080" "without the env, Grafana keeps the InfluxDB DataBridge"
  assert_eq "$(grafana_env http://databridge-timescaledb:8080)" "http://databridge-timescaledb:8080" \
    "the deploy can point Grafana at the TimescaleDB DataBridge"
else
  echo "  ⚠ docker stack config unavailable — rendering not checked"
fi

deploy="$(cat unified/scripts/deploy.sh)"
assert_contains "$deploy" 'GRAFANA_DATABRIDGE_URL="${GRAFANA_DATABRIDGE_URL:-http://databridge-timescaledb:8080}"' \
  "a deploy with the timescale group points Grafana at databridge-timescaledb"
assert_contains "$deploy" '! grep -qs '"'"'^GRAFANA_DATABRIDGE_URL='"'"' ".env.${ENV}"' \
  "a URL set in .env.<env> wins over the timescale default, also in compose mode (an exported default beats --env-file)"
