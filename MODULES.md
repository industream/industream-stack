# Industream Proprietary Modules

This file is the **authoritative list** of proprietary modules covered by
`LICENSE-PROPRIETARY` and referenced by the Third-Party Workers clause of
`LICENSE` (Business Source License 1.1).

The version of `MODULES.md` distributed alongside a given release of the
Licensed Work governs that release. Each Industream release is published
as a Git tag of the form `vX.Y.Z` in the official repository.

Last updated: 2026-04-28.

---

## Categories

The following categories of modules are proprietary, regardless of
whether a specific module is named below. Any future module developed
by Industream S.à r.l. that falls within one of these categories is
automatically covered by `LICENSE-PROPRIETARY`:

1. **Industrial protocol connectors** — software components that ingest
   data from, or write data to, industrial automation systems, ERPs,
   historians, or industry-specific data sources.

2. **AI/ML inference and analytics** — model training, inference,
   model registry, and advanced analytics modules.

3. **Signal processing libraries** — video, audio, statistical, and
   advanced signal processing modules.

4. **Domain monitoring packages** — vertical packages targeting specific
   industrial processes (e.g., metallurgy, batch processing, OEE/TRS).

5. **Platform tooling** — visual editors, worker orchestration, MCP
   servers, report generation, and digital twin simulation.

---

## Named modules (non-exhaustive)

### 1. Industrial protocol connectors
- OPC-UA
- Siemens S7
- RTSP
- GStreamer
- Audio
- Leneda
- OSIsoft PI
- SAP
- ODOO
- MS SQL Server

### 2. AI/ML inference and analytics
- ONNX Runtime
- AutoML
- Anomaly Detection
- Pattern Recognition
- Virtual Sensor
- Golden Batch
- Root Cause Analysis
- AI Studio (and all AI Studio modules)
- Edge AI Inference Engine
- AI Model Registry

### 3. Signal processing libraries
- Video Processing
- Sound Processing
- SPC (Statistical Process Control)
- Advanced Signal Processing

### 4. Domain monitoring packages
- FlowGuard (OEE/TRS monitoring)
- IronStream
- ArcStream
- Tuyere Monitoring
- IR Hot Spot Detection
- Free Roll Monitoring

### 5. Platform tooling
- FlowMaker Designer (visual editor)
- Worker Manager (dynamic worker deployment)
- MCP servers: FlowMaker, Visualization, Industream, DataCatalog
- Advanced Report Generation
- SimBridge (digital twin simulation)

---

## Adding new modules

When Industream publishes a new module, this file is updated and a new
release tag is cut. The new module is covered by `LICENSE-PROPRIETARY`
from the date of the release that includes it; prior releases continue
to be governed by their own `MODULES.md` snapshot.

For commercial licensing of any module listed above, contact:
license@industream.com
