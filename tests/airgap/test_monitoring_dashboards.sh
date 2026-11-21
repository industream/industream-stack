#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

python3 -B scripts/generate/generate-monitoring-dashboards.py --check
pass "the shipped dashboards and their legacy mirrors match the shared templates"
python3 -B - <<'PY'
import json
from pathlib import Path
import yaml

root = Path('unified/base/config/grafana/provisioning/dashboards')
paths = [*root.glob('json/*.json'), *root.glob('flowmaker/*.json'), root / 'optional/opc-ua/opc-ua.json']
count = 0
for path in paths:
    if 'minio' in path.name:
        continue
    dashboard = json.loads(path.read_text())
    panels = dashboard['panels']
    assert len({p['id'] for p in panels}) == len(panels), path
    assert panels[0]['description'] == 'Industream monitoring overview', path
    assert panels[0]['gridPos']['y'] == 0, path
    assert 'volkov' in dashboard['tags'], path
    for panel in panels:
        if panel['type'] == 'marcusolsson-dynamictext-panel':
            assert not panel['options']['externalStyles'], path
            assert panel['options']['renderMode'] == 'data', path
            count += 1
        if path.parent.name == 'flowmaker' and panel.get('targets'):
            assert panel['datasource'] == {'type': 'prometheus', 'uid': 'PBFA97CFB590B2093'}, path
            assert all(t['datasource'] == panel['datasource'] for t in panel['targets']), path
    assert any(p['type'] == 'timeseries' for p in panels), path
assert count == 49, count  # 43 metric panels and 6 common headers.
base = yaml.safe_load(Path('unified/base/monitoring.yml').read_text())
env = base['services']['grafana']['environment']
plugins = next(v for v in env if v.startswith('GF_PLUGINS_PREINSTALL_SYNC='))
assert 'marcusolsson-dynamictext-panel' in plugins
providers = yaml.safe_load((root / 'dashboards.yaml').read_text())['providers']
assert next(p for p in providers if p['name'] == 'FlowMaker Monitoring')['options']['path'] == '$GRAFANA_FLOWMAKER_DASHBOARDS'
print('  ✓ six monitoring views keep native diagnostics and ship their Volkov dependency')
PY

cd unified
KEY=forge-test-monitoring-dashboard
DIR="releases/bundle-platform-${KEY}"
cleanup() { rm -rf "${REPO_ROOT:?}/unified/$DIR"; }
trap cleanup EXIT
mkdir -p "$DIR"
cp releases/bundle-platform-1.0.2/.env.* "$DIR/"

deployed_path() (
  # The daemon is stubbed: do not wait two minutes for its nonexistent Hub.
  sleep() { :; }; export -f sleep
  local runtime="$1" groups="$2" target=(--stack t) deploy='^stack deploy '
  [[ "$runtime" == compose ]] && target=(--project t) deploy='^compose .* up -d'
  DOCKER_STUB_LOG_ENV=GRAFANA_FLOWMAKER_DASHBOARDS DEPLOY_TIMEOUT=1 with_docker_stub ./scripts/deploy.sh \
    --runtime "$runtime" --edition ce --env test --bundle "$KEY" "${target[@]}" --groups "$groups" >/dev/null 2>&1 || true
  grep -qE "$deploy" "$DOCKER_LOG" || { echo "no deploy reached"; return; }
  grep -A1 -E "$deploy" "$DOCKER_LOG" | sed -n 's/^env GRAFANA_FLOWMAKER_DASHBOARDS=//p' | head -1
)
ENABLED=/etc/grafana/provisioning/dashboards/flowmaker
DISABLED=/etc/grafana/provisioning/dashboards/optional/off
for runtime in swarm compose; do
  assert_eq "$(deployed_path "$runtime" 'core data monitoring flowmaker')" "$ENABLED" \
    "$runtime loads the FlowMaker dashboards with the scheduler"
  assert_eq "$(GRAFANA_FLOWMAKER_DASHBOARDS="$ENABLED" deployed_path "$runtime" 'core data monitoring')" "$DISABLED" \
    "$runtime disables FlowMaker views without the scheduler, also with an inherited export"
done
sed -i '/^LAUNCHER_IMAGE=/d' "$DIR/.env.flowmaker"
assert_eq "$(deployed_path swarm 'core data monitoring flowmaker')" "no deploy reached" \
  "a bundle without the mandatory scheduler image is refused before deployment"
