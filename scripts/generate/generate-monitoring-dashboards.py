#!/usr/bin/env python3
"""Refresh the shared Volkov presentation in the shipped monitoring dashboards.

Edit queries/field configuration in unified/base/config/grafana/provisioning/
dashboards, then run this script. It preserves them, refreshes presentation and
updates the legacy mirrors. --check exits nonzero if regeneration is needed.
No runtime generator, external assets or network access is needed at deployment.
"""

import argparse
import copy
import html
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TEMPLATES = Path(__file__).resolve().parent / "monitoring"
CANONICAL = ROOT / "unified/base/config/grafana/provisioning/dashboards"
LEGACY = ROOT / "config/grafana/provisioning/dashboards"
TEXT_PANEL = "marcusolsson-dynamictext-panel"
PROMETHEUS = {"type": "prometheus", "uid": "PBFA97CFB590B2093"}
SPECS = {
    "json/node-exporter-full.json": ("Servers", "CPU, memory, storage and network resources."),
    "json/docker-containers-cadvisor.json": ("Containers", "Container resources and network activity."),
    "json/docker-swarm-services.json": ("Swarm", "Cluster health, tasks and service resources."),
    "flowmaker/flowmaker-scheduler.json": ("FlowMaker scheduler", "Flow execution and message throughput."),
    "flowmaker/flowmaker-workers-metrics.json": ("FlowMaker workers", "Protocol connections, throughput and latency."),
    "optional/opc-ua/opc-ua.json": ("OPC-UA", "Connection health, acquisition, backpressure and tag validation."),
}


def text_options(content, styles, helpers=""):
    return {"renderMode": "data", "content": content, "defaultContent": content,
            "helpers": helpers, "styles": styles, "wrap": False,
            "editors": ["helpers", "styles"], "contentPartials": [],
            "externalStyles": [], "afterRender": ""}


def refresh(dashboard, title, subtitle):
    result = copy.deepcopy(dashboard)
    panels = result["panels"]
    header = next((p for p in panels if p.get("description") == "Industream monitoring overview"), None)
    used_ids = {p["id"] for p in panels if "id" in p}
    next_id = max(used_ids, default=0) + 1
    for panel in panels:
        if "id" not in panel:
            panel["id"] = next_id
            next_id += 1
        if header is None:
            panel["gridPos"]["y"] += 3
        # These dashboards used to be unprovisioned and relied on the default
        # datasource, which is DataBridge in a real stack. Their PromQL needs
        # the provisioned Prometheus datasource explicitly, including native plots.
        if result["uid"] in ("flowmaker-scheduler", "flowmaker-workers-metrics") and panel.get("targets"):
            panel.setdefault("datasource", copy.deepcopy(PROMETHEUS))
            for target in panel["targets"]:
                target.setdefault("datasource", copy.deepcopy(PROMETHEUS))
        managed_card = panel["type"] == TEXT_PANEL and "monitoring-cards" in panel.get("options", {}).get("content", "")
        if panel["type"] in ("stat", "gauge") or managed_card:
            if panel.get("options", {}).get("reduceOptions", {}).get("calcs", ["lastNotNull"]) != ["lastNotNull"]:
                raise ValueError(f"Review unsupported reducer in {result['uid']}: {panel['title']}")
            config = panel.get("fieldConfig", {"defaults": {}, "overrides": []})
            for override in config.get("overrides", []):
                if override["matcher"]["id"] not in ("byName", "byType", "byRegexp", "byFrameRefID"):
                    raise ValueError(f"Review unsupported field matcher in {result['uid']}: {panel['title']}")
            for properties in [config.get("defaults", {}),
                               *[{p["id"]: p["value"] for p in o["properties"]} for o in config.get("overrides", [])]]:
                if any(m["type"] != "value" for m in properties.get("mappings", [])):
                    raise ValueError(f"Review unsupported value mapping in {result['uid']}: {panel['title']}")
                if properties.get("thresholds", {}).get("mode", "absolute") != "absolute":
                    raise ValueError(f"Review unsupported threshold mode in {result['uid']}: {panel['title']}")
            panel["type"] = TEXT_PANEL
            panel.pop("pluginVersion", None)
            panel["options"] = text_options(
                (TEMPLATES / "cards.html").read_text(),
                (TEMPLATES / "cards.css").read_text(),
                "const monitoringFieldConfig = " + json.dumps(config, ensure_ascii=False) + ";\n" +
                (TEMPLATES / "cards.js").read_text(),
            )
    if header is None:
        header = {"id": next_id, "type": TEXT_PANEL, "title": "", "transparent": True,
                  "description": "Industream monitoring overview",
                  "gridPos": {"x": 0, "y": 0, "w": 24, "h": 3}, "targets": []}
        panels.insert(0, header)
        result["version"] = result.get("version", 0) + 1
    content = (f'<div class="monitoring-banner"><small>INDUSTREAM · OPERATIONS</small>'
               f'<strong>{html.escape(title)}</strong><p>{html.escape(subtitle)}</p></div>')
    header["options"] = text_options(content, (TEMPLATES / "banner.css").read_text())
    result["tags"] = list(dict.fromkeys([*result.get("tags", []), "monitoring", "volkov"]))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    stale = []
    for relative, (title, subtitle) in SPECS.items():
        path = CANONICAL / relative
        result = refresh(json.loads(path.read_text()), title, subtitle)
        rendered = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
        destinations = [path]
        if (LEGACY / relative).exists():
            destinations.append(LEGACY / relative)
        for destination in destinations:
            if destination.read_text() == rendered:
                continue
            stale.append(str(destination.relative_to(ROOT)))
            if not args.check:
                destination.write_text(rendered)
    for path in stale:
        print(("Stale: " if args.check else "Updated: ") + path)
    if args.check and stale:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
