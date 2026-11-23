#!/usr/bin/env bash
# Offline, Grafana asked grafana.com for the latest version of each unversioned preinstall plugin:
# 10 s per plugin before it listened, so the health check killed it in a loop. An air-gapped deploy
# now disables the preinstall; the plugins seeded into the volume still load.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

grafana_env() {  # grafana_env <value or empty> → GF_PLUGINS_PREINSTALL_DISABLED rendered for the grafana service
  GRAFANA_PLUGINS_PREINSTALL_DISABLED="$1" ENV=prod docker stack config -c unified/base/monitoring.yml 2>/dev/null \
    | awk '/^  [a-z]/ {in_grafana = ($1 == "grafana:")} in_grafana && /GF_PLUGINS_PREINSTALL_DISABLED/ {print $2; exit}' | tr -d '"'
}
if docker stack config --help >/dev/null 2>&1; then
  assert_eq "$(grafana_env "")" "false" "a connected deploy keeps installing the plugins at boot"
  assert_eq "$(grafana_env true)" "true" "the deploy can disable the plugin preinstall"
else
  echo "  ⚠ docker stack config unavailable — rendering not checked"
fi

deploy="$(cat unified/scripts/deploy.sh)"
assert_contains "$deploy" '[[ "$AIRGAP" == true ]] && export GRAFANA_PLUGINS_PREINSTALL_DISABLED=true' \
  "an air-gapped deploy disables the Grafana plugin preinstall"
