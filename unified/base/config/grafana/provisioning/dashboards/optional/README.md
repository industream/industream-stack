# Optional dashboards

Not provisioned. `dashboards.yaml` declares a single provider pointing at
`dashboards/json`, so anything here is shipped with the repo but **not** loaded
into Grafana.

To enable one, either copy the file into `dashboards/json/` or add a provider for
this directory in `dashboards.yaml`.

- **minio-images-viewer** — a single `volkovlabs-image-panel` showing the latest
  camera capture from MinIO. Useful only where a camera worker writes frames
  there; on every other install it renders one empty panel.
