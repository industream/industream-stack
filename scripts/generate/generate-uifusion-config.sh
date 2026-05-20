#!/bin/bash
# Generate UIFusion configuration with dynamic domain substitution
# Conditionally includes applications based on deployment flags

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Parse arguments
FORCE=false
WITH_IRONSTREAM="${DEPLOY_IRONSTREAM:-false}"
DEPLOY_ENV="${ENV:-prod}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE=true
            shift
            ;;
        --with-ironstream)
            WITH_IRONSTREAM=true
            shift
            ;;
        --env)
            DEPLOY_ENV="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--force] [--with-ironstream] [--env <env>]"
            echo ""
            echo "Options:"
            echo "  --force, -f         Force regeneration even if config exists"
            echo "  --with-ironstream   Include IronStream application entry"
            echo "  --env <env>         Deployment environment (prod|dev|staging, default: prod)"
            echo ""
            echo "Conditional entries:"
            echo "  IronStream      Included only with --with-ironstream"
            echo "  Backup Monitor  Included only when --env prod"
            echo ""
            echo "By default, skips generation if config/uifusion/config.json exists."
            echo "This allows local modifications to be preserved."
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

echo -e "${BLUE}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   UIFusion Configuration Generator                ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════╝${NC}"
echo ""

# Load environment variables
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

DOMAIN=${INDUSTREAM_DOMAIN:-industream.platform.lan}

# -----------------------------------------------------------------------------
# Service introspection
# -----------------------------------------------------------------------------
# The caller (deploy-swarm.sh) sets UIFUSION_STACK_FILES to the space-separated
# list of docker-stack.*.yml files that will actually be deployed. We grep
# them to detect which services exist so the nav only contains live links.
#
# If the env var is unset (someone runs the generator manually), we fall back
# to scanning every docker-stack.*.yml in the repo root — best-effort coverage.
UIFUSION_STACK_FILES="${UIFUSION_STACK_FILES:-$(ls docker-stack.*.yml 2>/dev/null | tr '\n' ' ')}"

has_service() {
    local service="$1"
    [ -n "$UIFUSION_STACK_FILES" ] || return 1
    # Match "  <service>:" at column 2 (Compose service definition).
    grep -qE "^  ${service}:[[:space:]]*$" $UIFUSION_STACK_FILES 2>/dev/null
}

# Check if config exists and skip unless forced
CONFIG_FILE="config/uifusion/config.json"
if [ -f "$CONFIG_FILE" ] && [ "$FORCE" = false ]; then
    echo -e "${YELLOW}⏭ Config file already exists: $CONFIG_FILE${NC}"
    echo -e "${YELLOW}  Skipping generation to preserve local modifications.${NC}"
    echo -e "${YELLOW}  Use --force to regenerate.${NC}"
    echo ""
    exit 0
fi

echo -e "${BLUE}Generating UIFusion configuration for domain: ${GREEN}${DOMAIN}${NC}"
echo -e "${BLUE}  Environment: ${GREEN}${DEPLOY_ENV}${NC}"
echo -e "${BLUE}  IronStream:  ${GREEN}${WITH_IRONSTREAM}${NC}"
echo ""

# Create config directory if it doesn't exist
mkdir -p config/uifusion

# Fix ownership on existing files if they're owned by root
if [ -f config/uifusion/config.json ] && [ ! -w config/uifusion/config.json ]; then
    sudo chown $USER:$USER config/uifusion/config.json 2>/dev/null || true
fi
if [ -f config/uifusion/config-finder.json ] && [ ! -w config/uifusion/config-finder.json ]; then
    sudo chown $USER:$USER config/uifusion/config-finder.json 2>/dev/null || true
fi

# Generate config.json using grouped heredocs for conditional sections
{
# Header: oauth, branding, navigation groups, locales
cat << HEADEREOF
{
  "oauth": {
    "clientId": "uifusion",
    "realm": "industream",
    "endpoint": "https://${DOMAIN}/auth/"
  },
  "header": {
    "brandName": "industream ",
    "appName": " UIFusion",
    "logo": "&nbsp;&nbsp;<span class=\"material-symbols-outlined\">\napps\n</span>"
  },
  "sideNavGroups": {
    "01-grp": "Main Group",
    "02-mon": "Monitoring",
    "03-ext": "Admin"
  },
  "locales": {
    "en_EN": { "name": "English", "isDefault": true },
    "de_DE": { "name": "Deutsch" },
    "fr_FR": { "name": "Français" }
  },
  "applications": {
HEADEREOF

# -----------------------------------------------------------------------------
# Collect every nav entry into a temp file. We omit a trailing comma here and
# add them via `paste`/`sed` at the end so conditional sections stay clean.
# -----------------------------------------------------------------------------
APPS_TMP=$(mktemp)
trap 'rm -f "$APPS_TMP"' EXIT

emit() { cat >> "$APPS_TMP"; }

# --- Main Group ---
if has_service grafana; then
    emit << EOF
    "01-01-dashboards": {
      "url": "https://dashboard.${DOMAIN}?auth_token=\$TOKEN",
      "label": "Dashboards",
      "appShort": "DASH",
      "loading": { "instanceId": "angular-instance-1" },
      "iconClass": "leaderboard",
      "sideNavGroup": "01-grp",
      "route": "dashboards"
    }
EOF
fi

if has_service flowmaker-frontend; then
    emit << EOF
    "01-02-flowmaker": {
      "url": "https://flowmaker.${DOMAIN}",
      "label": "FlowMaker",
      "appShort": "FLOW",
      "loading": { "instanceId": "angular-instance-2" },
      "iconClass": "account_tree",
      "sideNavGroup": "01-grp",
      "route": "flowmaker"
    }
EOF
fi

if has_service datacatalog-ui; then
    emit << EOF
    "01-04-datacatalog": {
      "url": "https://datacatalog-ui.${DOMAIN}",
      "label": "DataCatalog",
      "appShort": "DCAT",
      "loading": { "instanceId": "angular-instance-4" },
      "iconClass": "storage",
      "sideNavGroup": "01-grp",
      "route": "datacatalog"
    }
EOF
fi

# IronStream is opt-in via --with-ironstream AND must exist in the deployed stack.
if [ "$WITH_IRONSTREAM" = "true" ] && has_service ironstream-demo; then
    emit << EOF
    "01-05-ironstream": {
      "url": "https://ironstream.${DOMAIN}",
      "label": "IronStream",
      "appShort": "IRON",
      "loading": { "instanceId": "angular-instance-23" },
      "iconClass": "precision_manufacturing",
      "sideNavGroup": "01-grp",
      "route": "ironstream"
    }
EOF
fi

# --- Monitoring ---
if has_service prometheus; then
    emit << EOF
    "02-01-prometheus": {
      "url": "https://prometheus.${DOMAIN}",
      "label": "Prometheus",
      "loading": { "instanceId": "angular-instance-10" },
      "iconClass": "monitoring",
      "sideNavGroup": "02-mon",
      "route": "prometheus",
      "rolesRequired": ["admin"]
    }
EOF
fi

# Grafana dashboards depend on both grafana AND cadvisor/node-exporter for data.
if has_service grafana && has_service cadvisor; then
    emit << EOF
    "02-02-grafana-containers": {
      "url": "https://dashboard.${DOMAIN}/d/docker-cadvisor/docker-container-monitoring-cadvisor",
      "label": "Container Metrics",
      "loading": { "instanceId": "angular-instance-11" },
      "iconClass": "inventory_2",
      "sideNavGroup": "02-mon",
      "route": "container-metrics",
      "rolesRequired": ["admin"]
    }
EOF
fi

if has_service grafana; then
    emit << EOF
    "02-03-grafana-swarm": {
      "url": "https://dashboard.${DOMAIN}/d/docker-swarm-services/docker-swarm-services",
      "label": "Swarm Services",
      "loading": { "instanceId": "angular-instance-12" },
      "iconClass": "hub",
      "sideNavGroup": "02-mon",
      "route": "swarm-services",
      "rolesRequired": ["admin"]
    }
EOF
fi

if has_service grafana && has_service node-exporter; then
    emit << EOF
    "02-04-grafana-node": {
      "url": "https://dashboard.${DOMAIN}/d/node-exporter-full/node-exporter-full",
      "label": "Node Metrics",
      "loading": { "instanceId": "angular-instance-13" },
      "iconClass": "dns",
      "sideNavGroup": "02-mon",
      "route": "node-metrics",
      "rolesRequired": ["admin"]
    }
EOF
fi

if has_service alertmanager; then
    emit << EOF
    "02-05-alertmanager": {
      "url": "https://alertmanager.${DOMAIN}",
      "label": "Alertmanager",
      "loading": { "instanceId": "angular-instance-14" },
      "iconClass": "notifications_active",
      "sideNavGroup": "02-mon",
      "route": "alertmanager",
      "rolesRequired": ["admin"]
    }
EOF
fi

if has_service ntfy; then
    emit << EOF
    "02-06-ntfy": {
      "url": "https://ntfy.${DOMAIN}/industream-backups",
      "label": "Notifications",
      "appShort": "NTFY",
      "loading": { "instanceId": "angular-instance-16" },
      "iconClass": "campaign",
      "sideNavGroup": "02-mon",
      "route": "notifications",
      "rolesRequired": ["admin"]
    }
EOF
fi

# Backup monitor only ships in prod stacks AND must be actually deployed.
if [ "$DEPLOY_ENV" = "prod" ] && has_service backup-monitor; then
    emit << EOF
    "02-07-backups": {
      "url": "https://backups.${DOMAIN}?token=\$TOKEN",
      "label": "Backup Monitor",
      "appShort": "BKUP",
      "loading": { "instanceId": "angular-instance-15" },
      "iconClass": "backup",
      "sideNavGroup": "02-mon",
      "route": "backups",
      "rolesRequired": ["admin"]
    }
EOF
fi

# --- Admin ---
if has_service datacatalog-api; then
    emit << EOF
    "03-01-datacatalog-api": {
      "url": "https://datacatalog.${DOMAIN}/openapi",
      "label": "DataCatalog API",
      "loading": { "instanceId": "angular-instance-5" },
      "iconClass": "api",
      "sideNavGroup": "03-ext",
      "route": "datacatalogapi",
      "rolesRequired": ["admin"]
    }
EOF
fi

# DataBridge service was historically called "timeseries-api"; we keep the
# legacy route label to avoid breaking bookmarks but check the new name.
if has_service databridge; then
    emit << EOF
    "03-02-timeseries-api": {
      "url": "https://databridge.${DOMAIN}/swagger",
      "label": "DataBridge API",
      "loading": { "instanceId": "angular-instance-6" },
      "iconClass": "api",
      "sideNavGroup": "03-ext",
      "route": "timeseriesapi",
      "rolesRequired": ["admin"]
    }
EOF
fi

if has_service influxdb; then
    emit << EOF
    "03-03-influxdb": {
      "url": "https://influxdb.${DOMAIN}",
      "label": "InfluxDB",
      "appShort": "INFLX",
      "loading": { "instanceId": "angular-instance-20" },
      "iconClass": "query_stats",
      "sideNavGroup": "03-ext",
      "route": "influxdb",
      "rolesRequired": ["admin"]
    }
EOF
fi

# Keycloak is always part of the platform stack — but check anyway in case
# someone runs a stripped-down deployment.
if has_service keycloak; then
    emit << EOF
    "03-05-keycloak": {
      "url": "https://${DOMAIN}/auth/admin/master/console",
      "label": "Keycloak Admin",
      "loading": { "instanceId": "angular-instance-9" },
      "iconClass": "security",
      "sideNavGroup": "03-ext",
      "route": "keycloakadmin",
      "rolesRequired": ["admin"]
    }
EOF
fi

if has_service minio; then
    emit << EOF
    "03-06-minio": {
      "url": "https://minio.${DOMAIN}",
      "label": "Minio Console",
      "appShort": "S3",
      "loading": { "instanceId": "angular-instance-22" },
      "iconClass": "cloud_upload",
      "sideNavGroup": "03-ext",
      "route": "minio",
      "rolesRequired": ["admin"]
    }
EOF
fi

# -----------------------------------------------------------------------------
# Insert "," between entries (each entry ends with '}\n' here, except trailing
# whitespace). Sed adds comma to every '}' line except the LAST occurrence,
# yielding valid JSON regardless of which conditional blocks were emitted.
# -----------------------------------------------------------------------------
awk '
    { lines[NR] = $0; if ($0 == "    }") last = NR }
    END {
        for (i = 1; i <= NR; i++) {
            line = lines[i]
            if (line == "    }" && i != last) print line ","; else print line
        }
    }
' "$APPS_TMP"

# Footer
cat << 'FOOTEREOF'
  },
  "startupApplication": "01-01-dashboards"
}
FOOTEREOF
} > config/uifusion/config.json

# Generate config-finder.json
cat > config/uifusion/config-finder.json << 'FINDEREOF'
{
  "url": "assets/config/config.json"
}
FINDEREOF

# Fix permissions to avoid issues with Docker containers writing as root
chmod 666 config/uifusion/config-finder.json 2>/dev/null || true
chmod 666 config/uifusion/config.json 2>/dev/null || true

# Summary
INCLUDED_APPS=$(grep -c '"url"' config/uifusion/config.json)
echo -e "${GREEN}✓ UIFusion configuration generated successfully!${NC}"
echo -e "  ${BLUE}Applications included: ${GREEN}${INCLUDED_APPS}${NC}"
[ "$WITH_IRONSTREAM" = "true" ] && echo -e "  ${GREEN}✓ IronStream${NC}" || echo -e "  ${YELLOW}✗ IronStream (use --with-ironstream)${NC}"
[ "$DEPLOY_ENV" = "prod" ] && echo -e "  ${GREEN}✓ Backup Monitor${NC}" || echo -e "  ${YELLOW}✗ Backup Monitor (prod only)${NC}"
echo ""
echo -e "${BLUE}Configuration files:${NC}"
echo "  - config/uifusion/config.json"
echo "  - config/uifusion/config-finder.json"
echo ""
echo -e "${BLUE}OAuth endpoint:${NC} https://${DOMAIN}/auth/"
echo ""
echo -e "${YELLOW}Note:${NC} Restart UIFusion container to apply changes:"
echo "  docker stack deploy -c docker-stack.yml industream"
echo ""
