#!/bin/bash
# =============================================================================
# GENERATE LEGACY WORKER SERVICES
# =============================================================================
# Detects worker version changes and generates docker-stack.workers-legacy.yml
# to keep old versions running alongside new ones.
#
# When a worker version changes in .env (e.g., 2.0.3 -> 2.0.4), this script
# adds the OLD version to the legacy list and generates services for ALL
# accumulated legacy versions. This ensures flows referencing any previous
# version keep working across multiple upgrades.
#
# Usage:
#   ./scripts/generate/generate-legacy-workers.sh                               # Detect & generate
#   ./scripts/generate/generate-legacy-workers.sh --cleanup                      # Remove ALL legacy
#   ./scripts/generate/generate-legacy-workers.sh --cleanup 2.0.3                # Remove version from all workers
#   ./scripts/generate/generate-legacy-workers.sh --cleanup worker-js-expression # Remove all legacy for one worker
#   ./scripts/generate/generate-legacy-workers.sh --cleanup worker-js-expression 2.0.3  # Surgical removal
#   ./scripts/generate/generate-legacy-workers.sh --check-flows                 # Scan etcd for flows using legacy versions
#   ./scripts/generate/generate-legacy-workers.sh --check-flows --ssh user@host # Scan remote server
#
# Prerequisites:
#   - python3 available
#   - .env sourced (worker version env vars set)
#   - config/worker-versions.json exists with previous versions
#
# Called automatically by deploy-swarm.sh
# =============================================================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../.."
VERSIONS_FILE="$PROJECT_DIR/config/worker-versions.json"
LEGACY_FILE="$PROJECT_DIR/docker-stack.workers-legacy.yml"

# Export for Python script
export PROJECT_DIR VERSIONS_FILE LEGACY_FILE

# Maximum legacy versions per worker before warning
LEGACY_WARNING_THRESHOLD=3
export LEGACY_WARNING_THRESHOLD

# =============================================================================
# Handle --check-flows flag
# =============================================================================
if [ "$1" = "--check-flows" ]; then
    # Optional --ssh argument for remote server
    SSH_CMD=""
    if [ "$2" = "--ssh" ] && [ -n "$3" ]; then
        SSH_CMD="ssh $3"
        echo -e "${BLUE}Scanning flows on remote server ($3)...${NC}"
    else
        echo -e "${BLUE}Scanning flows on local Docker...${NC}"
    fi
    export SSH_CMD

    # Detect stack name
    STACK_NAME="${STACK_NAME:-industream-${ENV:-prod}}"
    export STACK_NAME

    # FlowMaker v2 uses confighub API instead of etcd
    # Fetch flows from confighub v2 API
    STACK_NAME="${STACK_NAME:-industream-${ENV:-prod}}"
    CONFIGHUB_CONTAINER=$($SSH_CMD docker ps --format '{{.Names}}' | grep "${STACK_NAME}_flowmaker-confighub\." | head -1)
    if [ -z "$CONFIGHUB_CONTAINER" ]; then
        echo -e "${RED}✗ Could not find confighub container for stack ${STACK_NAME}${NC}"
        echo -e "${YELLOW}  Flow scanning requires a running FlowMaker v2 confighub service${NC}"
        exit 1
    fi

    echo -e "${BLUE}Reading flows from confighub API...${NC}"
    FLOWS_JSON=$($SSH_CMD docker exec "$CONFIGHUB_CONTAINER" wget -qO- http://localhost:4000/api/flows 2>/dev/null)
    if [ -z "$FLOWS_JSON" ]; then
        echo -e "${YELLOW}⚠ Could not read flows from confighub API${NC}"
        echo -e "${YELLOW}  Flow scanning not available — use --force to bypass${NC}"
        exit 1
    fi
    export FLOWS_JSON

    python3 << 'CHECK_FLOWS_SCRIPT'
import json
import os
import base64
import re
import sys

VERSIONS_FILE = os.environ["VERSIONS_FILE"]
FLOWS_JSON = os.environ["FLOWS_JSON"]

# Mapping: service name -> flowElement ID prefix (industream/{box-name})
SERVICE_TO_FLOW_ID = {
    "worker-data-logger": "industream/data-logger",
    "worker-timer": "industream/timer",
    "worker-js-expression": "industream/js-expression",
    "worker-http-client": "industream/http",
    "worker-postgres-client": "industream/postgres-client",
    "worker-timeseries": "industream/timeseries",
    "worker-influx-client-dc": "industream/influx-client",
    "worker-notifications": "industream/notification",
    "worker-mqtt-client": "industream/mqtt-client",
    "worker-modbus-tcp": "industream/modbus-tcp",
    "worker-opc-ua-client": "industream/opc-ua-client",
    "worker-test-data-generator": "industream/test-data-generator",
    "worker-conditional-validator": "industream/conditional-dataset-validator",
    "worker-enqueue": "industream/enqueue",
    "equation-solver": "industream/equation-solver",
}

# Reverse map: flowElement prefix -> service name
FLOW_ID_TO_SERVICE = {v: k for k, v in SERVICE_TO_FLOW_ID.items()}

# Read legacy versions
with open(VERSIONS_FILE) as f:
    versions_data = json.load(f)

# Build set of all legacy flowElement IDs (prefix/version)
legacy_ids = set()
for service_name, entry in versions_data.items():
    if not isinstance(entry, dict):
        continue
    prefix = SERVICE_TO_FLOW_ID.get(service_name)
    if not prefix:
        continue
    for version in entry.get("legacy", []):
        legacy_ids.add(f"{prefix}/{version}")

if not legacy_ids:
    print("\033[0;32m✓ No legacy versions tracked - nothing to check\033[0m")
    sys.exit(0)

print(f"\033[0;34m  Checking for {len(legacy_ids)} legacy worker version(s):\033[0m")
for lid in sorted(legacy_ids):
    print(f"\033[1;33m    - {lid}\033[0m")
print()

# Parse confighub API response (JSON array of flows)
flows_data = json.loads(FLOWS_JSON)
if isinstance(flows_data, dict):
    flows_list = flows_data.get("flows", flows_data.get("kvs", []))
else:
    flows_list = flows_data

# Parse each flow
flows_using_legacy = {}  # flow_name -> [(node_name, flowElement_id)]

for entry in flows_list:
    try:
        if isinstance(entry, dict) and "key" in entry and "value" in entry:
            # Legacy etcd format (base64 encoded)
            key = base64.b64decode(entry["key"]).decode("utf-8")
            if key.count("/") < 2:
                continue
            value = base64.b64decode(entry["value"]).decode("utf-8")
            flow_data = json.loads(value)
        elif isinstance(entry, dict):
            # Confighub v2 format (direct JSON)
            flow_data = entry
        else:
            continue
    except (json.JSONDecodeError, KeyError, UnicodeDecodeError):
        continue

    flow_name = flow_data.get("displayName", flow_data.get("name", "unknown"))
    flow_id = flow_data.get("id", key)

    definition = flow_data.get("definition", {})
    flow_def = definition.get("flow", {})
    nodes = flow_def.get("nodes", [])

    for node in nodes:
        flow_element = node.get("flowElement", {})
        element_id = flow_element.get("id", "")

        if element_id in legacy_ids:
            if flow_id not in flows_using_legacy:
                flows_using_legacy[flow_id] = {
                    "name": flow_name,
                    "version": flow_data.get("version", "?"),
                    "nodes": [],
                }
            node_name = flow_element.get("displayName") or flow_element.get("name", "?")
            flows_using_legacy[flow_id]["nodes"].append({
                "node": node_name,
                "element_id": element_id,
            })

# Report
if not flows_using_legacy:
    print("\033[0;32m✓ No flows reference legacy worker versions - safe to cleanup\033[0m")
else:
    total = len(flows_using_legacy)
    print(f"\033[0;31m⚠ {total} flow(s) still reference legacy worker versions:\033[0m")
    print()
    for flow_id, info in flows_using_legacy.items():
        print(f"\033[1;33m  📋 {info['name']} (v{info['version']})\033[0m")
        print(f"\033[0;34m     ID: {flow_id}\033[0m")
        for ref in info["nodes"]:
            print(f"\033[0;31m     ↳ {ref['node']}: {ref['element_id']}\033[0m")
        print()

    print(f"\033[1;33m  Migrate these flows before running --cleanup\033[0m")
CHECK_FLOWS_SCRIPT
    exit 0
fi

# =============================================================================
# Handle --cleanup flag
# =============================================================================
if [ "$1" = "--cleanup" ]; then
    # Parse cleanup arguments: --cleanup [worker] [version] [--ssh user@host] [--force]
    CLEANUP_WORKER=""
    CLEANUP_VERSION=""
    CLEANUP_SSH=""
    CLEANUP_FORCE=false
    shift  # remove --cleanup
    while [[ $# -gt 0 ]]; do
        case $1 in
            --ssh)
                CLEANUP_SSH="$2"
                shift 2
                ;;
            --force)
                CLEANUP_FORCE=true
                shift
                ;;
            *)
                if [[ "$1" =~ ^[0-9]+\.[0-9]+ ]]; then
                    CLEANUP_VERSION="$1"
                else
                    CLEANUP_WORKER="$1"
                fi
                shift
                ;;
        esac
    done
    export CLEANUP_WORKER CLEANUP_VERSION CLEANUP_FORCE

    echo -e "${BLUE}Cleaning up legacy workers...${NC}"

    # ---- Safety check: scan flows in etcd before cleanup ----
    if [ -n "$CLEANUP_SSH" ] && [ "$CLEANUP_FORCE" != "true" ]; then
        echo -e "${BLUE}Checking flows on remote server (${CLEANUP_SSH})...${NC}"
        STACK_NAME="${STACK_NAME:-industream-${ENV:-prod}}"
        CONFIGHUB_CONTAINER=$(ssh "$CLEANUP_SSH" "docker ps --format '{{.Names}}' | grep '${STACK_NAME}_flowmaker-confighub\.' | head -1" 2>/dev/null)
        if [ -n "$CONFIGHUB_CONTAINER" ]; then
            FLOWS_JSON=$(ssh "$CLEANUP_SSH" "docker exec $CONFIGHUB_CONTAINER wget -qO- http://localhost:4000/api/flows" 2>/dev/null)
            if [ -n "$FLOWS_JSON" ]; then
                export FLOWS_JSON
                # Python checks if any flows use the versions being cleaned up
                BLOCKED=$(python3 << 'SAFETY_CHECK'
import json
import os
import base64
import sys

VERSIONS_FILE = os.environ["VERSIONS_FILE"]
FLOWS_JSON = os.environ["FLOWS_JSON"]
CLEANUP_WORKER = os.environ.get("CLEANUP_WORKER", "")
CLEANUP_VERSION = os.environ.get("CLEANUP_VERSION", "")

SERVICE_TO_FLOW_ID = {
    "worker-data-logger": "industream/data-logger",
    "worker-timer": "industream/timer",
    "worker-js-expression": "industream/js-expression",
    "worker-http-client": "industream/http",
    "worker-postgres-client": "industream/postgres-client",
    "worker-timeseries": "industream/timeseries",
    "worker-influx-client-dc": "industream/influx-client",
    "worker-notifications": "industream/notification",
    "worker-mqtt-client": "industream/mqtt-client",
    "worker-modbus-tcp": "industream/modbus-tcp",
    "worker-opc-ua-client": "industream/opc-ua-client",
    "worker-test-data-generator": "industream/test-data-generator",
    "worker-conditional-validator": "industream/conditional-dataset-validator",
    "worker-enqueue": "industream/enqueue",
    "equation-solver": "industream/equation-solver",
}

with open(VERSIONS_FILE) as f:
    versions_data = json.load(f)

# Build set of flowElement IDs that would be removed by this cleanup
target_ids = set()

if CLEANUP_WORKER and CLEANUP_VERSION:
    prefix = SERVICE_TO_FLOW_ID.get(CLEANUP_WORKER)
    if prefix:
        target_ids.add(f"{prefix}/{CLEANUP_VERSION}")
elif CLEANUP_WORKER:
    prefix = SERVICE_TO_FLOW_ID.get(CLEANUP_WORKER)
    entry = versions_data.get(CLEANUP_WORKER, {})
    if prefix and isinstance(entry, dict):
        for v in entry.get("legacy", []):
            target_ids.add(f"{prefix}/{v}")
elif CLEANUP_VERSION:
    for svc, entry in versions_data.items():
        prefix = SERVICE_TO_FLOW_ID.get(svc)
        if prefix and isinstance(entry, dict) and CLEANUP_VERSION in entry.get("legacy", []):
            target_ids.add(f"{prefix}/{CLEANUP_VERSION}")
else:
    # Full cleanup - check all legacy versions
    for svc, entry in versions_data.items():
        prefix = SERVICE_TO_FLOW_ID.get(svc)
        if prefix and isinstance(entry, dict):
            for v in entry.get("legacy", []):
                target_ids.add(f"{prefix}/{v}")

if not target_ids:
    print("OK")
    sys.exit(0)

# Scan flows
flows_response = json.loads(FLOWS_JSON)
if isinstance(flows_response, dict):
    flows_list = flows_response.get("flows", flows_response.get("kvs", []))
else:
    flows_list = flows_response
blocked_flows = []

for entry in flows_list:
    try:
        if isinstance(entry, dict) and "key" in entry and "value" in entry:
            key = base64.b64decode(entry["key"]).decode("utf-8")
            if key.count("/") < 2:
                continue
            value = base64.b64decode(entry["value"]).decode("utf-8")
            flow_data = json.loads(value)
        elif isinstance(entry, dict):
            flow_data = entry
        else:
            continue
    except (json.JSONDecodeError, KeyError, UnicodeDecodeError):
        continue

    flow_name = flow_data.get("displayName", flow_data.get("name", "unknown"))
    flow_id = flow_data.get("id", "unknown")
    nodes = flow_data.get("definition", {}).get("flow", {}).get("nodes", [])

    for node in nodes:
        element_id = node.get("flowElement", {}).get("id", "")
        if element_id in target_ids:
            node_name = node.get("flowElement", {}).get("displayName") or node.get("flowElement", {}).get("name", "?")
            blocked_flows.append(f"{flow_name}|{flow_id}|{node_name}|{element_id}")

if blocked_flows:
    print("BLOCKED")
    for bf in blocked_flows:
        print(bf)
else:
    print("OK")
SAFETY_CHECK
                )

                FIRST_LINE=$(echo "$BLOCKED" | head -1)
                if [ "$FIRST_LINE" = "BLOCKED" ]; then
                    echo ""
                    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
                    echo -e "${RED}║  CLEANUP BLOCKED - Flows still use these worker versions!   ║${NC}"
                    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
                    echo ""
                    echo "$BLOCKED" | tail -n +2 | while IFS='|' read -r fname fid nname eid; do
                        echo -e "${YELLOW}  Flow: ${fname}${NC}"
                        echo -e "${BLUE}    ID: ${fid}${NC}"
                        echo -e "${RED}    Node '${nname}' uses: ${eid}${NC}"
                        echo ""
                    done
                    echo -e "${YELLOW}  Migrate these flows first, or use --force to bypass this check${NC}"
                    exit 1
                else
                    echo -e "${GREEN}✓ No flows reference the versions being removed${NC}"
                fi
            fi
        fi
    elif [ "$CLEANUP_FORCE" != "true" ]; then
        echo ""
        echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                    ⚠  WARNING  ⚠                           ║${NC}"
        echo -e "${RED}║  Cleaning up without flow check (no --ssh provided).        ║${NC}"
        echo -e "${RED}║  Flows referencing removed versions will BREAK!             ║${NC}"
        echo -e "${RED}║                                                             ║${NC}"
        echo -e "${RED}║  To check first:  --cleanup [...] --ssh user@host           ║${NC}"
        echo -e "${RED}║  To force:        --cleanup [...] --force                   ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -p "Continue anyway? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Cleanup aborted${NC}"
            exit 0
        fi
    fi

    python3 << 'CLEANUP_SCRIPT'
import json
import os

VERSIONS_FILE = os.environ["VERSIONS_FILE"]
LEGACY_FILE = os.environ["LEGACY_FILE"]
CLEANUP_WORKER = os.environ.get("CLEANUP_WORKER", "")
CLEANUP_VERSION = os.environ.get("CLEANUP_VERSION", "")

WORKERS = {
    "worker-data-logger": ("WORKER_DATA_LOGGER_VERSION", "2.0.3"),
    "worker-timer": ("WORKER_TIMER_VERSION", "2.0.3"),
    "worker-js-expression": ("WORKER_JS_EXPRESSION_VERSION", "2.0.3"),
    "worker-http-client": ("WORKER_HTTP_VERSION", "2.0.3"),
    "worker-postgres-client": ("WORKER_POSTGRES_CLIENT_VERSION", "2.0.3"),
    "worker-timeseries": ("WORKER_TIMESERIES_VERSION", "2.0.3"),
    "worker-influx-client-dc": ("WORKER_INFLUX_CLIENT_VERSION", "2.0.3"),
    "worker-notifications": ("WORKER_NOTIFICATIONS_VERSION", "2.0.3"),
    "worker-mqtt-client": ("WORKER_MQTT_CLIENT_VERSION", "2.0.3"),
    "worker-modbus-tcp": ("WORKER_MODBUS_TCP_VERSION", "2.0.3"),
    "worker-opc-ua-client": ("WORKER_OPC_UA_CLIENT_VERSION", "2.0.3"),
    "worker-test-data-generator": ("WORKER_TEST_DATA_GENERATOR_VERSION", "2.0.3"),
    "worker-conditional-validator": ("WORKER_CONDITIONAL_DATASET_VALIDATOR_VERSION", "2.0.3"),
    "worker-enqueue": ("WORKER_ENQUEUE_VERSION", "2.0.3"),
    "equation-solver": ("WORKER_EQUATION_SOLVER_VERSION", "2.0.3"),
}

with open(VERSIONS_FILE) as f:
    data = json.load(f)

# Validate worker name if provided
if CLEANUP_WORKER and CLEANUP_WORKER not in WORKERS:
    print(f"\033[0;31m\u2717 Unknown worker: {CLEANUP_WORKER}\033[0m")
    print("  Available workers:")
    for name in sorted(WORKERS):
        print(f"    - {name}")
    exit(1)

# Determine which workers to process
target_workers = [CLEANUP_WORKER] if CLEANUP_WORKER else list(WORKERS.keys())

if CLEANUP_WORKER and CLEANUP_VERSION:
    # Remove specific version from specific worker
    entry = data.get(CLEANUP_WORKER, {})
    if isinstance(entry, dict):
        legacy = entry.get("legacy", [])
        if CLEANUP_VERSION in legacy:
            legacy.remove(CLEANUP_VERSION)
            entry["legacy"] = legacy
            data[CLEANUP_WORKER] = entry
            print(f"\033[0;32m  \u2713 Removed {CLEANUP_VERSION} from {CLEANUP_WORKER}\033[0m")
        else:
            print(f"\033[1;33m  {CLEANUP_WORKER} has no legacy version {CLEANUP_VERSION}\033[0m")
            if legacy:
                print(f"\033[1;33m  Available legacy versions: {legacy}\033[0m")

elif CLEANUP_WORKER:
    # Remove all legacy versions from specific worker
    entry = data.get(CLEANUP_WORKER, {})
    if isinstance(entry, dict):
        legacy = entry.get("legacy", [])
        if legacy:
            print(f"\033[0;32m  \u2713 Cleared {len(legacy)} legacy version(s) from {CLEANUP_WORKER}: {legacy}\033[0m")
            entry["legacy"] = []
            data[CLEANUP_WORKER] = entry
        else:
            print(f"\033[1;33m  {CLEANUP_WORKER} has no legacy versions\033[0m")

elif CLEANUP_VERSION:
    # Remove specific version from all workers
    removed_count = 0
    for service_name in target_workers:
        entry = data.get(service_name, {})
        if isinstance(entry, dict):
            legacy = entry.get("legacy", [])
            if CLEANUP_VERSION in legacy:
                legacy.remove(CLEANUP_VERSION)
                entry["legacy"] = legacy
                data[service_name] = entry
                removed_count += 1
                print(f"\033[0;32m  \u2713 Removed {CLEANUP_VERSION} from {service_name}\033[0m")

    if removed_count == 0:
        print(f"\033[1;33m  No workers had legacy version {CLEANUP_VERSION}\033[0m")
    else:
        print(f"\033[0;32m\u2713 Removed version {CLEANUP_VERSION} from {removed_count} worker(s)\033[0m")

else:
    # Full cleanup: remove all legacy versions, sync current to .env
    for service_name, (env_var, default) in WORKERS.items():
        current = os.environ.get(env_var, default)
        data[service_name] = {"current": current, "legacy": []}

    if os.path.exists(LEGACY_FILE):
        os.remove(LEGACY_FILE)
        print("\033[0;32m\u2713 Removed docker-stack.workers-legacy.yml\033[0m")

    print("\033[0;32m\u2713 All legacy versions cleared\033[0m")

# Check if any legacy versions remain
has_legacy = any(
    isinstance(data.get(s), dict) and data[s].get("legacy")
    for s in WORKERS
)
if not has_legacy and os.path.exists(LEGACY_FILE):
    os.remove(LEGACY_FILE)
    print("\033[0;32m\u2713 No legacy versions remain, removed legacy file\033[0m")

with open(VERSIONS_FILE, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print("\033[0;32m\u2713 Worker versions file updated\033[0m")
CLEANUP_SCRIPT

    echo -e "${GREEN}✓ Legacy cleanup complete${NC}"
    echo -e "${YELLOW}  Deploy again to apply changes to the stack${NC}"
    exit 0
fi

# =============================================================================
# Check prerequisites
# =============================================================================
if [ ! -f "$VERSIONS_FILE" ]; then
    echo -e "${YELLOW}⚠ No worker-versions.json found (first deployment)${NC}"
    echo -e "${BLUE}  Initializing from current .env versions...${NC}"

    # Generate initial worker-versions.json from current .env values
    python3 << 'INIT_VERSIONS'
import json
import os

VERSIONS_FILE = os.environ["VERSIONS_FILE"]

# Worker name -> env var name
WORKERS = {
    "worker-data-logger": "WORKER_DATA_LOGGER_VERSION",
    "worker-timer": "WORKER_TIMER_VERSION",
    "worker-js-expression": "WORKER_JS_EXPRESSION_VERSION",
    "worker-http-client": "WORKER_HTTP_VERSION",
    "worker-postgres-client": "WORKER_POSTGRES_CLIENT_VERSION",
    "worker-timeseries": "WORKER_TIMESERIES_VERSION",
    "worker-influx-client-dc": "WORKER_INFLUX_CLIENT_VERSION",
    "worker-notifications": "WORKER_NOTIFICATIONS_VERSION",
    "worker-mqtt-client": "WORKER_MQTT_CLIENT_VERSION",
    "worker-modbus-tcp": "WORKER_MODBUS_TCP_VERSION",
    "worker-opc-ua-client": "WORKER_OPC_UA_CLIENT_VERSION",
    "worker-test-data-generator": "WORKER_TEST_DATA_GENERATOR_VERSION",
    "worker-conditional-validator": "WORKER_CONDITIONAL_DATASET_VALIDATOR_VERSION",
    "worker-enqueue": "WORKER_ENQUEUE_VERSION",
    "equation-solver": "WORKER_EQUATION_SOLVER_VERSION",
}

data = {}
for service_name, env_var in WORKERS.items():
    version = os.environ.get(env_var, "2.0.3")
    data[service_name] = {"current": version, "legacy": []}

os.makedirs(os.path.dirname(VERSIONS_FILE), exist_ok=True)
with open(VERSIONS_FILE, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(f"\033[0;32m✓ Created {VERSIONS_FILE} with {len(data)} workers\033[0m")
INIT_VERSIONS

    echo -e "${GREEN}✓ No legacy workers needed (first deployment)${NC}"
    exit 0
fi

echo -e "${BLUE}Checking worker version changes...${NC}"

# =============================================================================
# Detect changes and generate legacy YAML (Python)
# =============================================================================
python3 << 'GENERATE_SCRIPT'
import json
import os
import sys

VERSIONS_FILE = os.environ["VERSIONS_FILE"]
LEGACY_FILE = os.environ["LEGACY_FILE"]
LEGACY_WARNING_THRESHOLD = int(os.environ.get("LEGACY_WARNING_THRESHOLD", "3"))

# Worker definitions: service_name -> (env_var, image_name, default_version)
WORKERS = {
    "worker-data-logger": ("WORKER_DATA_LOGGER_VERSION", "flow-box-data-logger", "2.0.3"),
    "worker-timer": ("WORKER_TIMER_VERSION", "flow-box-timer", "2.0.3"),
    "worker-js-expression": ("WORKER_JS_EXPRESSION_VERSION", "flow-box-js-expression", "2.0.3"),
    "worker-http-client": ("WORKER_HTTP_VERSION", "flow-box-http", "2.0.3"),
    "worker-postgres-client": ("WORKER_POSTGRES_CLIENT_VERSION", "flow-box-postgres-client", "2.0.3"),
    "worker-timeseries": ("WORKER_TIMESERIES_VERSION", "flow-box-timeseries-workers", "2.0.3"),
    "worker-influx-client-dc": ("WORKER_INFLUX_CLIENT_VERSION", "flow-box-influx-client", "2.0.3"),
    "worker-notifications": ("WORKER_NOTIFICATIONS_VERSION", "flow-box-notification", "2.0.3"),
    "worker-mqtt-client": ("WORKER_MQTT_CLIENT_VERSION", "flow-box-mqtt-client", "2.0.3"),
    "worker-modbus-tcp": ("WORKER_MODBUS_TCP_VERSION", "flow-box-modbus-tcp", "2.0.3"),
    "worker-opc-ua-client": ("WORKER_OPC_UA_CLIENT_VERSION", "flow-box-opc-ua-client", "2.0.3"),
    "worker-test-data-generator": ("WORKER_TEST_DATA_GENERATOR_VERSION", "flow-box-test-data-generator", "2.0.3"),
    "worker-conditional-validator": ("WORKER_CONDITIONAL_DATASET_VALIDATOR_VERSION", "flow-box-conditional-dataset-validator", "2.0.3"),
    "worker-enqueue": ("WORKER_ENQUEUE_VERSION", "flow-box-enqueue", "2.0.3"),
    "equation-solver": ("WORKER_EQUATION_SOLVER_VERSION", "flow-box-equation-solver", "2.0.3"),
}

REGISTRY_DEFAULT = "842775dh.c1.gra9.container-registry.ovh.net"


def read_versions():
    """Read and normalize worker-versions.json (handles both old flat and new structured format)."""
    with open(VERSIONS_FILE) as f:
        raw = json.load(f)

    normalized = {}
    for service_name in WORKERS:
        entry = raw.get(service_name)
        if entry is None:
            # Worker not tracked yet
            _, _, default = WORKERS[service_name]
            normalized[service_name] = {"current": default, "legacy": []}
        elif isinstance(entry, str):
            # Old flat format: migrate to structured
            normalized[service_name] = {"current": entry, "legacy": []}
        elif isinstance(entry, dict):
            normalized[service_name] = {
                "current": entry.get("current", WORKERS[service_name][2]),
                "legacy": entry.get("legacy", []),
            }

    return normalized


# ---- Read previous versions ----
versions = read_versions()

# ---- Detect changes ----
new_changes = []

for service_name, (env_var, image_name, default) in WORKERS.items():
    tracked_current = versions[service_name]["current"]
    env_version = os.environ.get(env_var, default)

    if tracked_current != env_version:
        # Version changed: move old current to legacy, set new current
        if tracked_current not in versions[service_name]["legacy"]:
            versions[service_name]["legacy"].append(tracked_current)
        versions[service_name]["current"] = env_version
        new_changes.append({
            "service": service_name,
            "old_version": tracked_current,
            "new_version": env_version,
        })

# ---- Report new changes ----
if new_changes:
    for c in new_changes:
        print(f"\033[1;33m  \u26a1 {c['service']}: {c['old_version']} \u2192 {c['new_version']}\033[0m")

# ---- Collect all legacy services to generate ----
all_legacy = []
warnings = []

for service_name, (env_var, image_name, default) in WORKERS.items():
    legacy_versions = versions[service_name]["legacy"]

    for version in legacy_versions:
        all_legacy.append({
            "service": service_name,
            "image": image_name,
            "version": version,
        })

    # Warning if too many legacy versions
    count = len(legacy_versions)
    if count >= LEGACY_WARNING_THRESHOLD:
        warnings.append((service_name, count, legacy_versions))

# ---- Warnings ----
for service_name, count, legacy_list in warnings:
    versions_str = ", ".join(legacy_list)
    print(f"\033[0;31m  \u26a0 {service_name} has {count} legacy version(s): [{versions_str}]\033[0m")
    print(f"\033[0;31m    Consider migrating flows and running: --cleanup {legacy_list[0]}\033[0m")

if not all_legacy:
    print("\033[0;32m\u2713 No legacy worker services needed\033[0m")
    if os.path.exists(LEGACY_FILE):
        os.remove(LEGACY_FILE)
        print("\033[0;32m\u2713 Removed stale legacy file\033[0m")

    # Still save versions (in case we migrated from flat format)
    with open(VERSIONS_FILE, "w") as f:
        json.dump(versions, f, indent=2)
        f.write("\n")
    sys.exit(0)


# ---- Generate legacy YAML ----
def version_to_slug(version):
    """Convert '2.0.3' to 'v2-0-3' for service naming."""
    return "v" + version.replace(".", "-")


def generate_legacy_service(entry):
    """Generate a single legacy worker service YAML block."""
    service = entry["service"]
    image = entry["image"]
    version = entry["version"]
    slug = version_to_slug(version)
    legacy_name = f"{service}-{slug}"
    registry = REGISTRY_DEFAULT

    template = """  {legacy_name}:
    image: ${{DOCKER_REGISTRY:-{registry}}}/flowmaker.boxes/{image}:{version}
    environment:
    - FM_WORKER_ID={legacy_name}-001
    - FM_RUNTIME_HTTP_ADDRESS=http://flowmaker-scheduler:3120
    - FM_ROUTER_TRANSPORT_ADDRESS=tcp://*:5560
    - FM_WORKER_TRANSPORT_ADV_ADDRESS=tcp://{legacy_name}:5560
    - FM_WORKER_LOG_SOCKET_IO_ENDPOINT=http://flowmaker-logging:3000
    - FM_CDN_REGISTRY_URL=${{CDN_REGISTRY_URL:-http://cdn-server:4873}}
    - FM_DATACATALOG_URL=${{DATACATALOG_URL:-http://datacatalog-api:8080}}
    networks:
    - ${{ENV}}-platform
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 128M
        reservations:
          cpus: '0.03'
          memory: 64M
      restart_policy:
        condition: any
        delay: 10s
        window: 120s
"""
    return template.format(
        legacy_name=legacy_name,
        registry=registry,
        image=image,
        version=version,
    )


yaml_content = """# =============================================================================
# LEGACY WORKER SERVICES (AUTO-GENERATED - DO NOT EDIT)
# =============================================================================
# Generated by scripts/generate/generate-legacy-workers.sh
# These services keep old worker versions running for backward compatibility
# with flows that reference specific versions.
#
# To remove all legacy workers after migrating flows:
#   ./scripts/generate/generate-legacy-workers.sh --cleanup
#
# To remove a specific version from all workers:
#   ./scripts/generate/generate-legacy-workers.sh --cleanup 2.0.3
# =============================================================================

services:
"""

for entry in all_legacy:
    yaml_content += generate_legacy_service(entry)

yaml_content += """
# =============================================================================
# NETWORKS
# =============================================================================
networks:
  ${ENV}-platform:
"""

with open(LEGACY_FILE, "w") as f:
    f.write(yaml_content)

total = len(all_legacy)
new_count = len(new_changes)
if new_changes:
    print(f"\033[0;32m\u2713 Generated docker-stack.workers-legacy.yml with {total} legacy service(s) ({new_count} new)\033[0m")
else:
    print(f"\033[0;32m\u2713 Generated docker-stack.workers-legacy.yml with {total} legacy service(s)\033[0m")

# ---- Update versions file ----
with open(VERSIONS_FILE, "w") as f:
    json.dump(versions, f, indent=2)
    f.write("\n")

print(f"\033[0;32m\u2713 Updated config/worker-versions.json\033[0m")
GENERATE_SCRIPT
