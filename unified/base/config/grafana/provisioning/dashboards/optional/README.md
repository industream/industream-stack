# Optional dashboards

The infrastructure dashboards in `dashboards/json` are always provisioned.
`deploy.sh` enables the FlowMaker provider only when the scheduler is deployed,
and the OPC-UA provider only when the OPC-UA worker is deployed on Swarm.
Disabled providers read `optional/off`, which contains no dashboard JSON.

Other optional dashboards stay unloaded. To enable one, add a provider for its
own directory or copy the file into `dashboards/json/`.

- **minio-images-viewer** — a single `volkovlabs-image-panel` showing the latest
  camera capture from MinIO. Useful only where a camera worker writes frames
  there; on every other install it renders one empty panel.
- **opc-ua/opc-ua.json** — protocol monitoring, with Volkov summary cards and
  native time-series diagnostics. Enabled through `GRAFANA_OPCUA_DASHBOARDS`.
