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

# --- Core applications (always included) ---
cat << COREEOF
    "01-01-dashboards": {
      "url": "https://dashboard.${DOMAIN}?auth_token=\$TOKEN",
      "label": "Dashboards",
      "appShort": "DASH",
      "loading": { "instanceId": "angular-instance-1" },
      "iconClass": "leaderboard",
      "sideNavGroup": "01-grp",
      "route": "dashboards"
    },
    "01-02-flowmaker": {
      "url": "https://flowmaker.${DOMAIN}",
      "label": "FlowMaker",
      "appShort": "FLOW",
      "loading": { "instanceId": "angular-instance-2" },
      "iconClass": "account_tree",
      "sideNavGroup": "01-grp",
      "route": "flowmaker"
    },
    "01-04-datacatalog": {
      "url": "https://datacatalog-ui.${DOMAIN}",
      "label": "DataCatalog",
      "appShort": "DCAT",
      "loading": { "instanceId": "angular-instance-4" },
      "iconClass": "storage",
      "sideNavGroup": "01-grp",
      "route": "datacatalog"
    },
COREEOF

# --- IronStream (only with --with-ironstream) ---
if [ "$WITH_IRONSTREAM" = "true" ]; then
cat << IRONEOF
    "01-05-ironstream": {
      "url": "https://ironstream.${DOMAIN}",
      "label": "IronStream",
      "appShort": "IRON",
      "loading": { "instanceId": "angular-instance-23" },
      "iconClass": "precision_manufacturing",
      "sideNavGroup": "01-grp",
      "route": "ironstream"
    },
IRONEOF
fi

# --- Monitoring applications (always included) ---
cat << MONEOF
    "02-01-prometheus": {
      "url": "https://prometheus.${DOMAIN}",
      "label": "Prometheus",
      "loading": { "instanceId": "angular-instance-10" },
      "iconClass": "monitoring",
      "sideNavGroup": "02-mon",
      "route": "prometheus",
      "rolesRequired": ["admin"]
    },
    "02-02-grafana-containers": {
      "url": "https://dashboard.${DOMAIN}/d/docker-cadvisor/docker-container-monitoring-cadvisor",
      "label": "Container Metrics",
      "loading": { "instanceId": "angular-instance-11" },
      "iconClass": "inventory_2",
      "sideNavGroup": "02-mon",
      "route": "container-metrics",
      "rolesRequired": ["admin"]
    },
    "02-03-grafana-swarm": {
      "url": "https://dashboard.${DOMAIN}/d/docker-swarm-services/docker-swarm-services",
      "label": "Swarm Services",
      "loading": { "instanceId": "angular-instance-12" },
      "iconClass": "hub",
      "sideNavGroup": "02-mon",
      "route": "swarm-services",
      "rolesRequired": ["admin"]
    },
    "02-04-grafana-node": {
      "url": "https://dashboard.${DOMAIN}/d/node-exporter-full/node-exporter-full",
      "label": "Node Metrics",
      "loading": { "instanceId": "angular-instance-13" },
      "iconClass": "dns",
      "sideNavGroup": "02-mon",
      "route": "node-metrics",
      "rolesRequired": ["admin"]
    },
    "02-05-alertmanager": {
      "url": "https://alertmanager.${DOMAIN}",
      "label": "Alertmanager",
      "loading": { "instanceId": "angular-instance-14" },
      "iconClass": "notifications_active",
      "sideNavGroup": "02-mon",
      "route": "alertmanager",
      "rolesRequired": ["admin"]
    },
    "02-06-ntfy": {
      "url": "https://ntfy.${DOMAIN}/industream-backups",
      "label": "Notifications",
      "appShort": "NTFY",
      "loading": { "instanceId": "angular-instance-16" },
      "iconClass": "campaign",
      "sideNavGroup": "02-mon",
      "route": "notifications",
      "rolesRequired": ["admin"]
    },
MONEOF

# --- Backup Monitor (only for production) ---
if [ "$DEPLOY_ENV" = "prod" ]; then
cat << BACKUPEOF
    "02-07-backups": {
      "url": "https://backups.${DOMAIN}?token=\$TOKEN",
      "label": "Backup Monitor",
      "appShort": "BKUP",
      "loading": { "instanceId": "angular-instance-15" },
      "iconClass": "backup",
      "sideNavGroup": "02-mon",
      "route": "backups",
      "rolesRequired": ["admin"]
    },
BACKUPEOF
fi

# --- Admin applications (always included, last entry has no trailing comma) ---
cat << ADMINEOF
    "03-01-datacatalog-api": {
      "url": "https://datacatalog.${DOMAIN}/openapi",
      "label": "DataCatalog API",
      "loading": { "instanceId": "angular-instance-5" },
      "iconClass": "api",
      "sideNavGroup": "03-ext",
      "route": "datacatalogapi",
      "rolesRequired": ["admin"]
    },
    "03-02-timeseries-api": {
      "url": "https://databridge.${DOMAIN}/swagger",
      "label": "Timeseries API",
      "loading": { "instanceId": "angular-instance-6" },
      "iconClass": "api",
      "sideNavGroup": "03-ext",
      "route": "timeseriesapi",
      "rolesRequired": ["admin"]
    },
    "03-03-influxdb": {
      "url": "https://influxdb.${DOMAIN}",
      "label": "InfluxDB",
      "appShort": "INFLX",
      "loading": { "instanceId": "angular-instance-20" },
      "iconClass": "query_stats",
      "sideNavGroup": "03-ext",
      "route": "influxdb",
      "rolesRequired": ["admin"]
    },
    "03-04-cloudbeaver": {
      "url": "https://db.${DOMAIN}",
      "label": "CloudBeaver",
      "appShort": "DBVR",
      "loading": { "instanceId": "angular-instance-21" },
      "iconClass": "database",
      "sideNavGroup": "03-ext",
      "route": "cloudbeaver",
      "rolesRequired": ["admin"]
    },
    "03-05-keycloak": {
      "url": "https://${DOMAIN}/auth/admin/master/console",
      "label": "Keycloak Admin",
      "loading": { "instanceId": "angular-instance-9" },
      "iconClass": "security",
      "sideNavGroup": "03-ext",
      "route": "keycloakadmin",
      "rolesRequired": ["admin"]
    },
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
ADMINEOF

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
