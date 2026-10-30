# Monitoring dashboards

The stack ships a common Volkov Business Text presentation for six monitoring
dashboards: servers, containers, Swarm, FlowMaker scheduler, FlowMaker workers,
and OPC-UA. Summary cards use Grafana's field display processors for units.
Business Text disables standard color/mapping/range options, so the generator
embeds those settings from the panel's field configuration. The helpers apply
value mappings, absolute thresholds and supported overrides explicitly. Each endpoint/worker remains a separate
card, including when several endpoints are selected. Missing values show **No
data**, without a healthy status color. Percentage gauges have a bounded display
meter; their numeric values are not clamped.

Native time-series panels, tables, pie charts and bar gauges retain their existing
queries, legends and diagnostic interactions. Dashboard UIDs, titles, variables,
refresh settings and links are preserved. Prometheus computes rates, ratios,
totals and percentiles; panel JavaScript only selects and formats values.
The newly enabled FlowMaker dashboards explicitly bind all metric panels and
targets to the provisioned Prometheus datasource, rather than the DataBridge
default.

## Deployment

Canonical files are under
`unified/base/config/grafana/provisioning/dashboards/`. They travel in the normal
deployment tree and airgap archives. Deployment does not run a generator or load
external JavaScript/CSS assets. Business Text is in Grafana's synchronous plugin
preinstall list and the existing airgap plugin harvest.

- Infrastructure always loads from `dashboards/json`.
- `deploy.sh` enables the FlowMaker provider when the scheduler survives bundle
  pruning, on Compose and Swarm. Without it, the provider reads `optional/off`.
- OPC-UA retains its existing selection: only with the deployed OPC-UA worker,
  on Swarm, where the Prometheus task discovery works.
- Portainer's per-group renderer enables FlowMaker for its complete group set,
  and OPC-UA for EE when the selected workers include the OPC-UA worker. The
  checked-in CE/EE monitoring artifacts carry the same selections. These
  Portainer artifacts assume their full generated group set is deployed; when
  deploying individual groups, adjust the two `GRAFANA_*_DASHBOARDS` values.

File provisioning can replace local Grafana edits on the next update. Keep
reviewed monitoring changes in the repository; normal Grafana database backups
remain the rollback source for site-specific UI edits.

## Editing and validation

Edit queries and field configuration in the canonical JSON files. Shared card
HTML, CSS and helpers are in `scripts/generate/monitoring/`. The generator updates
the presentation and the five existing legacy mirrors under
`config/grafana/provisioning/dashboards/`, without changing PromQL or data
configuration. It is idempotent. New non-value mappings, percentage thresholds or
unsupported field matchers cause generation to fail for explicit review, rather
than silently changing the presentation.

```bash
python3 scripts/generate/generate-monitoring-dashboards.py
python3 scripts/generate/generate-monitoring-dashboards.py --check
node tests/monitoring/cards.test.cjs
bash tests/airgap/test_monitoring_dashboards.sh
bash tests/airgap/test_opcua_monitoring.sh
```

Browser previews must use separate dashboard UIDs and label synthetic values as
demo data. Check light/dark themes, multiple endpoints, disconnected states,
missing data and long labels before deploying changes. Test synthetic values
locally; use the normal reviewed deployment process for real installations.
