#!/usr/bin/env bash
# =============================================================================
# render-bundles.sh — generate David-style release bundles from the single
# license-aware sources (versions.env + registries.env).
# =============================================================================
# Reconciles deployment-v2's full-ref bundles with the unified tree's
# license-aware split: the bundle keeps the `${X_IMAGE}=registry/repo:tag` UX,
# but the registry is chosen PER SERVICE by license class (community → GHCR,
# enterprise → ENTERPRISE_REGISTRY) instead of one hardcoded registry.
#
#   ./render-bundles.sh 1.0.1            # writes releases/bundle-platform-1.0.1/
#
# Output: .env.core / .env.workers / .env.workers-premium / .env.datacatalog —
# each `IMAGE_VAR=full-ref`.
# base/*.yml then reference ${X_IMAGE}; deploy.sh sources the chosen bundle.
# =============================================================================
set -eo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
VER="${1:?usage: render-bundles.sh <bundle-version>}"
set -a; source registries.env; source versions.env; set +a
OUT="releases/bundle-platform-${VER}"; mkdir -p "$OUT"

# Only INDUSTREAM-BUILT images go in the bundle (this is where the license-aware
# registry split matters). Third-party images (postgres, minio, grafana-oss,
# prometheus, logto, …) stay as direct `image:${VERSION}` refs in base/*.yml,
# sourced from versions.env — no registry/license decision to carry.
#
# image var | repo path | class(community|enterprise) | version var | group
TABLE='
# --- core ---
HUB_API_IMAGE|uifusion/api|community|UIFUSION_API_VERSION|core
HUB_API_ENTERPRISE_IMAGE|uifusion/api-enterprise|enterprise|UIFUSION_API_EE_VERSION|core
HUB_UI_IMAGE|uifusion/ui|community|UIFUSION_UI_VERSION|core
CDN_SERVER_IMAGE|flowmaker.core/cdn-server|community|CDN_SERVER_VERSION|core
CDN_CACHE_IMAGE|flowmaker.core/cdn-cache|community|CDN_CACHE_VERSION|core
# --- flowmaker ---
# Var names follow the Forge export contract (the source of truth): the Forge
# bundle ships these flowmaker.core refs UNPREFIXED, so base/*.yml and the local
# render both use LAUNCHER/CONFIGHUB/LOGGER/FRONTEND_IMAGE — a local bundle and a
# Forge bundle are then drop-in interchangeable.
LAUNCHER_IMAGE|flowmaker.core/flowmaker-launcher|community|FLOWMAKER_CORE_VERSION|flowmaker
CONFIGHUB_IMAGE|flowmaker.core/flowmaker-confighub-v2|community|FLOWMAKER_CORE_VERSION|flowmaker
LOGGER_IMAGE|flowmaker.core/flowmaker-logger|community|FLOWMAKER_LOGGER_VERSION|flowmaker
FRONTEND_IMAGE|flowmaker.core/flowmaker-front|community|FLOWMAKER_FRONTEND_VERSION|flowmaker
# --- datacatalog ---
DATACATALOG_API_IMAGE|datacatalog/api|community|DATACATALOG_API_VERSION|datacatalog
DATACATALOG_UI_IMAGE|datacatalog/ui|community|DATACATALOG_UI_VERSION|datacatalog
# --- data ---
DATABRIDGE_API_IMAGE|timeseries/api|community|DATABRIDGE_API_VERSION|data
# --- grafana (first-class app; split out of monitoring) ---
GRAFANA_WRAPPER_IMAGE|grafana-hub-wrapper|community|GRAFANA_WRAPPER_VERSION|grafana
# --- workers (community) ---
WORKER_DATA_LOGGER_IMAGE|flowmaker.boxes/data-logger|community|WORKER_DATA_LOGGER_VERSION|workers
WORKER_TIMER_IMAGE|flowmaker.boxes/timer|community|WORKER_TIMER_VERSION|workers
WORKER_JS_EXPRESSION_IMAGE|flowmaker.boxes/js-expression|community|WORKER_JS_EXPRESSION_VERSION|workers
WORKER_HTTP_IMAGE|flowmaker.boxes/http|community|WORKER_HTTP_VERSION|workers
WORKER_POSTGRES_CLIENT_IMAGE|flowmaker.boxes/postgres-client|community|WORKER_POSTGRES_CLIENT_VERSION|workers
WORKER_TIMESERIES_IMAGE|flowmaker.boxes/timeseries-workers|community|WORKER_TIMESERIES_VERSION|workers
WORKER_INFLUX_CLIENT_IMAGE|flowmaker.boxes/influx-client|community|WORKER_INFLUX_CLIENT_VERSION|workers
WORKER_NOTIFICATIONS_IMAGE|flowmaker.boxes/notification|community|WORKER_NOTIFICATIONS_VERSION|workers
WORKER_MQTT_CLIENT_IMAGE|flowmaker.boxes/mqtt-client|community|WORKER_MQTT_CLIENT_VERSION|workers
WORKER_MODBUS_TCP_IMAGE|flowmaker.boxes/modbus-tcp|community|WORKER_MODBUS_TCP_VERSION|workers
WORKER_TEST_DATA_GENERATOR_IMAGE|flowmaker.boxes/test-data-generator|community|WORKER_TEST_DATA_GENERATOR_VERSION|workers
WORKER_CONDITIONAL_DATASET_VALIDATOR_IMAGE|flowmaker.boxes/conditional-dataset-validator|community|WORKER_CONDITIONAL_DATASET_VALIDATOR_VERSION|workers
WORKER_ENQUEUE_IMAGE|flowmaker.boxes/enqueue|community|WORKER_ENQUEUE_VERSION|workers
WORKER_EQUATION_SOLVER_IMAGE|flowmaker.boxes/equation-solver|community|WORKER_EQUATION_SOLVER_VERSION|workers
WORKER_DATACATALOG_MAPPER_IMAGE|flowmaker.boxes/datacatalog-mapper|community|WORKER_DATACATALOG_MAPPER_VERSION|workers
# --- workers-premium (enterprise, opt-in EE-only group) ---
WORKER_OPC_UA_CLIENT_IMAGE|flowmaker.boxes/opc-ua-client|enterprise|WORKER_OPC_UA_CLIENT_VERSION|workers-premium
WORKER_RTSP_CLIENT_IMAGE|flowmaker.boxes/rtsp-client|enterprise|WORKER_RTSP_CLIENT_VERSION|workers-premium
WORKER_LUMINOSITY_BOX_IMAGE|flowmaker.boxes/luminosity-box|enterprise|WORKER_LUMINOSITY_BOX_VERSION|workers-premium
WORKER_MINIO_SINK_IMAGE|flowmaker.boxes/minio-sink|enterprise|WORKER_MINIO_SINK_VERSION|workers-premium
# --- ironstream (enterprise, opt-in EE-only group) ---
MATERIAL_CATALOG_API_IMAGE|ironstream/material-catalog/api|enterprise|MATERIAL_CATALOG_API_VERSION|ironstream
MATERIAL_CATALOG_UI_IMAGE|ironstream/material-catalog/ui|enterprise|MATERIAL_CATALOG_UI_VERSION|ironstream
MATERIAL_CATALOG_WORKER_IMAGE|ironstream/material-catalog/boxes|enterprise|MATERIAL_CATALOG_WORKER_VERSION|ironstream
RECIPE_MAKER_API_IMAGE|ironstream/recipe-maker/api|enterprise|RECIPE_MAKER_API_VERSION|ironstream
RECIPE_MAKER_UI_IMAGE|ironstream/recipe-maker/ui|enterprise|RECIPE_MAKER_UI_VERSION|ironstream
BURDEN_DESCENT_API_IMAGE|ironstream/burden-descent/api|enterprise|BURDEN_DESCENT_API_VERSION|ironstream
BURDEN_DESCENT_UI_IMAGE|ironstream/burden-descent/ui|enterprise|BURDEN_DESCENT_UI_VERSION|ironstream
BURDEN_LAYER_API_IMAGE|ironstream/burden-layer/api|enterprise|BURDEN_LAYER_API_VERSION|ironstream
RACEWAY_UI_IMAGE|ironstream/raceway/ui|enterprise|RACEWAY_UI_VERSION|ironstream
RACEWAY_WORKER_IMAGE|ironstream/raceway/worker|enterprise|RACEWAY_WORKER_VERSION|ironstream
# --- data-simulator (enterprise demo feed, opt-in EE-only group) ---
DATA_SIMULATOR_IMAGE|ironstream/data-simulator|enterprise|DATA_SIMULATOR_VERSION|data-simulator
'

emit() {  # $1=bundle file suffix
  local suffix="$1"
  local out="$OUT/.env.$suffix"
  { echo "# generated by render-bundles.sh — do not edit (source: versions.env + registries.env)"
    while IFS='|' read -r var repo class vervar grp; do
      [[ -z "${var:-}" || "$var" == \#* || "$grp" != "$suffix" ]] && continue
      local reg; case "$class" in
        community)  reg="$COMMUNITY_REGISTRY" ;;
        enterprise) reg="$ENTERPRISE_REGISTRY" ;;
        *)          reg="" ;;
      esac
      local tag="${!vervar:?missing $vervar in versions.env}"
      echo "${var}=${reg:+$reg/}${repo}:${tag}"
    done <<< "$TABLE"
  } > "$out"
  echo "  ✓ $out ($(grep -c '=' "$out") images)"
}
echo "▶ bundle-platform-${VER}  (community=$COMMUNITY_REGISTRY / enterprise=$ENTERPRISE_REGISTRY)"
emit core; emit flowmaker; emit datacatalog; emit data; emit monitoring; emit workers; emit workers-premium; emit ironstream; emit data-simulator
