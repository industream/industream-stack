#!/bin/bash
# Generate CloudBeaver initial configuration with pre-configured database connections
# Connections are generated based on the deployed stack

set -e

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
NC="\033[0m"

FORCE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f) FORCE=true; shift ;;
        *) shift ;;
    esac
done

echo -e "${BLUE}Generating CloudBeaver initial configuration...${NC}"

# Load environment
if [ -f .env ]; then
    export $(grep -v "^#" .env | xargs)
fi

DOMAIN=${INDUSTREAM_DOMAIN:-industream.platform.lan}
ENV=${ENV:-prod}

CONFIG_DIR="config/cloudbeaver"
mkdir -p "$CONFIG_DIR"

# Generate initial data-sources.json with pre-configured connections
DATASOURCES="$CONFIG_DIR/data-sources.json"
if [ -f "$DATASOURCES" ] && [ "$FORCE" = false ]; then
    echo -e "${YELLOW}Data sources already exist, skipping (use --force to regenerate)${NC}"
else
    cat > "$DATASOURCES" << DSEOF
{
  "folders": {},
  "connections": {
    "pg-platform": {
      "provider": "postgresql",
      "driver": "postgres-jdbc",
      "name": "Platform PostgreSQL",
      "description": "Keycloak, DataCatalog, Grafana databases",
      "host": "postgres",
      "port": "5432",
      "database": "postgres",
      "url": "jdbc:postgresql://postgres:5432/postgres",
      "authModel": "native",
      "savePassword": true,
      "configuration": {
        "type": "BASIC",
        "properties": {}
      }
    },
    "pg-keycloak": {
      "provider": "postgresql",
      "driver": "postgres-jdbc",
      "name": "Keycloak DB",
      "description": "Identity & Access Management database",
      "host": "postgres",
      "port": "5432",
      "database": "keycloak",
      "url": "jdbc:postgresql://postgres:5432/keycloak",
      "authModel": "native",
      "savePassword": true,
      "configuration": {
        "type": "BASIC",
        "properties": {}
      }
    },
    "pg-datacatalog": {
      "provider": "postgresql",
      "driver": "postgres-jdbc",
      "name": "DataCatalog DB",
      "description": "DataCatalog metadata database",
      "host": "postgres",
      "port": "5432",
      "database": "DataCatalog",
      "url": "jdbc:postgresql://postgres:5432/DataCatalog",
      "authModel": "native",
      "savePassword": true,
      "configuration": {
        "type": "BASIC",
        "properties": {}
      }
    },
    "pg-grafana": {
      "provider": "postgresql",
      "driver": "postgres-jdbc",
      "name": "Grafana DB",
      "description": "Grafana dashboards database",
      "host": "postgres",
      "port": "5432",
      "database": "industream",
      "url": "jdbc:postgresql://postgres:5432/industream",
      "authModel": "native",
      "savePassword": true,
      "configuration": {
        "type": "BASIC",
        "properties": {}
      }
    },
    "pg-ironstream": {
      "provider": "postgresql",
      "driver": "postgres-jdbc",
      "name": "IronStream DB",
      "description": "IronStream business database",
      "host": "ironstream-postgres",
      "port": "5432",
      "database": "ironstream_demo",
      "url": "jdbc:postgresql://ironstream-postgres:5432/ironstream_demo",
      "authModel": "native",
      "savePassword": true,
      "configuration": {
        "type": "BASIC",
        "properties": {}
      }
    }
  }
}
DSEOF
    echo -e "${GREEN}  ✓ Data sources generated: $DATASOURCES${NC}"
fi

echo -e "${GREEN}✓ CloudBeaver configuration ready${NC}"
echo -e "${BLUE}  Admin URL: https://db.${DOMAIN}${NC}"
echo -e "${BLUE}  Admin user: cbadmin${NC}"
echo -e "${YELLOW}  Note: DB credentials must be entered on first connection${NC}"
