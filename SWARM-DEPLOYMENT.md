# Docker Swarm Deployment Guide - Industream Platform (OBSOLETE)

> ## ⚠️ OBSOLETE — this guide describes the REMOVED legacy deploy
> `scripts/deploy-swarm.sh` and the root application `docker-stack.*.yml` it used
> **no longer exist**. Do not follow the commands below.
>
> **Deploy with the unified tree instead:**
> - CLI (recommended): `industream deploy` — see [`DEPLOYMENT.md`](./DEPLOYMENT.md)
> - Direct: `unified/scripts/deploy.sh` — see [`unified/README.md`](./unified/README.md)
> - Custom overlays go in [`unified/custom/`](./unified/custom) (not the old root `custom/`).
>
> Kept from the swarm era: `docker-stack.traefik.yml` (reverse proxy) +
> `scripts/deploy-traefik.sh`, `docker-stack.backup.yml` + `scripts/backups/`.
> The rest of this file is retained for historical reference only.

## Quick Start

The easiest way to deploy Industream is using the unified deployment tool:

```bash
./industream.sh
```

This interactive tool will guide you through the entire deployment process, automatically detecting your current state and providing appropriate options.

## Available Commands

```bash
./industream.sh                    # Interactive mode - auto-detects state
./industream.sh deploy --env prod  # Deploy specific environment
./industream.sh stop --env prod    # Stop specific environment
./industream.sh status             # Show deployment status
./industream.sh services           # List all running services
./industream.sh urls               # Show access URLs
./industream.sh logs <svc>         # View service logs
./industream.sh help               # Show all commands
```

## Prerequisites

1. Docker Engine 20.10+ installed
2. Docker Swarm initialized (`docker swarm init`)
3. `.env` + `.env.<env>` files configured
4. SSL certificates in `certs/`

## Deployment Options

### Option 1: Interactive Deployment (Recommended)

```bash
./industream.sh
```

The tool will:

- Check if Docker is installed
- Check if Swarm is initialized
- Guide you through `.env` configuration
- Create Docker secrets
- Deploy the platform
- Optionally deploy demo simulators

### Option 2: First-Time Deployment Script

For a guided first-time setup with detailed progress:

```bash
./scripts/setup/first-deployment.sh
```

### Option 3: Manual Multi-Environment Deployment

```bash
# 1. Deploy shared Traefik (once)
./scripts/deploy-traefik.sh

# 2. Create secrets for the target environment
./scripts/setup/create-secrets.sh --env prod
./scripts/setup/create-secrets.sh --env dev
./scripts/setup/create-secrets.sh --env staging

# 3. Deploy the environment
./scripts/deploy-swarm.sh --env prod
./scripts/deploy-swarm.sh --env dev --with-demo
./scripts/deploy-swarm.sh --env staging
```

## Manual Deployment Steps

### 1. Configure environment files

```bash
# Copy example and customize
cp .env.example .env

# Create environment-specific overrides
# .env.prod, .env.dev, .env.staging
```

See `.env.example` for all available variables.

### 2. Create Docker Secrets

```bash
# Per environment
./scripts/setup/create-secrets.sh --env prod

# Or all at once
./scripts/setup/create-secrets.sh --env all
```

Required secrets per environment (prefixed with `${ENV}_`):
- `postgres_admin_password`
- `hub_backend_admin_password`
- `hub_backend_admin_user`
- `grafana_admin_password`
- `grafana_db_password`
- `datacatalog_db_password`
- `influx_admin_password`
- `influx_admin_token`

### 3. Deploy the Stack

The `deploy-swarm.sh` script handles everything automatically:

```bash
./scripts/deploy-swarm.sh --env prod
```

Under the hood it:
1. Loads `.env` + `.env.${ENV}`
2. Validates all secrets exist
3. Pre-processes stack files with `envsubst`
4. Merges all stack files (core, flowmaker, workers, monitoring, data, cdn, backup)
5. Generates `docker-stack-resolved-${ENV}.yml`
6. Deploys via `docker stack deploy`
7. Waits for core services and restarts workers

### 4. Configure client DNS

DNS is handled via static `/etc/hosts` entries (no DNSmasq):

```bash
# Generate hosts entries for the server
./scripts/setup/setup-subdomains-hosts.sh

# Generate a client setup kit (hosts + certs) for USB deployment
./scripts/generate/generate-client-setup.sh
```

## Demo Simulators

When deployed with `--with-demo`, the following simulators are available:

| Protocol   | Endpoint                         | Description       |
|------------|----------------------------------|-------------------|
| OPC-UA     | `opc.tcp://localhost:50000`      | OPC-UA Server     |
| MQTT       | `localhost:1883`                 | MQTT Broker       |
| S7         | `localhost:102`                  | Siemens S7 PLC    |
| Modbus TCP | `localhost:5020`                 | Modbus TCP Server |
| RTSP Cam 1 | `rtsp://localhost:8554/stream`   | Video Stream 1    |
| RTSP Cam 2 | `rtsp://localhost:8555/stream`   | Video Stream 2    |

## Daily Operations

### Check Status

```bash
# Quick overview
./industream.sh status

# Detailed service list
./industream.sh services

# Or using docker directly
docker stack services industream-prod
docker stack services industream-dev
docker stack ps industream-prod | grep keycloak
```

### View Logs

```bash
# Using industream.sh
./industream.sh logs keycloak

# Or docker directly
docker service logs -f industream-prod_uifusion-api
docker service logs --tail=100 industream-prod_postgres
```

### Update a Service

```bash
# Update a single service image
docker service update --image NEW_IMAGE industream-prod_uifusion

# Force restart
docker service update --force industream-prod_uifusion-api

# Scale workers
docker service scale industream-prod_worker-timer=3

# Or redeploy the entire environment
./scripts/deploy-swarm.sh --env prod
```

### Secrets Management

```bash
# List all secrets
docker secret ls

# List secrets for a specific environment
docker secret ls | grep prod_

# Inspect (does NOT show value)
docker secret inspect prod_hub_backend_admin_user

# Secrets are managed per environment via:
./scripts/setup/create-secrets.sh --env prod
```

## Troubleshooting

### Service Won't Start

```bash
# View failed attempts
docker service ps industream-prod_uifusion-api --no-trunc

# Detailed logs
docker service logs industream-prod_uifusion-api --tail 100

# Inspect configuration
docker service inspect industream-prod_uifusion-api --pretty
```

### PostgreSQL Issues

```bash
POSTGRES_CONTAINER=$(docker ps --filter "name=industream-prod_postgres" --format "{{.Names}}" | head -1)

# Check users
docker exec $POSTGRES_CONTAINER psql -U postgres -c "\du"

# Check databases
docker exec $POSTGRES_CONTAINER psql -U postgres -c "\l"
```

### Clean and Redeploy

```bash
# Stop a specific environment
docker stack rm industream-prod

# Wait for everything to stop
watch docker service ls

# Remove Traefik (WARNING: stops all environments)
docker stack rm traefik-shared

# Remove volumes for an environment (WARNING: DELETES ALL DATA)
docker volume rm $(docker volume ls -q -f name=prod-)

# Redeploy
./scripts/deploy-traefik.sh
./scripts/deploy-swarm.sh --env prod
```

## Secrets Rotation

```bash
# 1. Create new secret with different name
echo "new-password" | docker secret create prod_hub_backend_admin_user_v2 -

# 2. Update PostgreSQL with new password
POSTGRES_CONTAINER=$(docker ps --filter "name=industream-prod_postgres" --format "{{.Names}}" | head -1)
docker exec $POSTGRES_CONTAINER psql -U postgres -c "ALTER USER keycloak WITH PASSWORD 'new-password';"

# 3. Update service
docker service update \
  --secret-rm prod_hub_backend_admin_user \
  --secret-add source=prod_hub_backend_admin_user_v2,target=prod_hub_backend_admin_user \
  industream-prod_uifusion-api

# 4. Remove old secret (after verification)
docker secret rm prod_hub_backend_admin_user
```

## Architecture

Each environment deploys the following stack (prefixed by `industream-${ENV}`):

```text
traefik-shared (Stack) - Shared infrastructure
├── traefik (1 replica) - Ports: 80/443
└── docker-socket-proxy (1 replica)

industream-${ENV} (Stack) - Per-environment
├── Core (docker-stack.yml)
│   ├── postgres - Databases: keycloak, industream, DataCatalog
│   ├── keycloak - SSO & authentication
│   ├── etcd - Key-value store for FlowMaker
│   ├── etcd-browser - etcd Web UI
│   ├── uifusion - Main portal UI
│   └── uifusion-api - Portal API
├── FlowMaker (docker-stack.flowmaker.yml)
│   ├── flowmaker-scheduler - Workflow execution engine
│   ├── flowmaker-confighub - Configuration API
│   ├── flowmaker-logging - Real-time logging (Socket.IO)
│   ├── flowmaker-frontend - Workflow designer UI
│   ├── flowmaker-uimaker-backend - Interface builder API
│   ├── flowmaker-uimaker-frontend - Interface builder (edit)
│   └── flowmaker-uimaker-frontend-ro - Interface builder (read-only)
├── Workers (docker-stack.workers.yml) - 17 FlowMaker workers
│   ├── worker-datalogger, worker-timer, worker-js-expression
│   ├── worker-http-client, worker-postgres-client, worker-influx-client
│   ├── worker-mqtt-client, worker-modbus-tcp, worker-opc-ua-client
│   ├── worker-s7-client, worker-timeseries, worker-notifications
│   ├── worker-toolkit, worker-test-data-generator
│   └── worker-conditional-dataset-validator, worker-equation-solver, worker-enqueue
├── Data (docker-stack.data.yml)
│   ├── influxdb - Time-series database
│   ├── timeseries-api - Time-series REST API
│   ├── datacatalog-api - Data catalog backend
│   └── datacatalog-ui - Data catalog frontend
├── Monitoring (docker-stack.monitoring.yml)
│   ├── grafana + grafana-renderer - Dashboards & PDF export
│   ├── prometheus - Metrics collection
│   ├── node-exporter, cadvisor, postgres-exporter - Exporters
│   └── alertmanager - Alert routing
├── CDN (docker-stack.cdn.yml)
│   ├── verdaccio - NPM registry proxy/cache
│   └── esm-server - ESM.sh CDN
├── Backup (docker-stack.backup.yml) - Production only
│   ├── backup-postgres - Automated DB backups
│   └── backup-volumes - Automated volume backups
└── Demo (docker-stack.demo.yml) - Optional (--with-demo)
    ├── industrial-simulator (OPC-UA, S7, Modbus)
    └── mqtt-broker
```

## Deployment Checklist

- [ ] Docker installed and running
- [ ] Docker Swarm initialized (`docker swarm init`)
- [ ] `.env` and `.env.${ENV}` files configured
- [ ] Docker secrets created (`./scripts/setup/create-secrets.sh --env ${ENV}`)
- [ ] SSL certificates in `certs/` (auto-generated if missing)
- [ ] Traefik deployed (`./scripts/deploy-traefik.sh`)
- [ ] Environment deployed (`./scripts/deploy-swarm.sh --env ${ENV}`)
- [ ] All services showing 1/1 (`docker stack services industream-${ENV}`)
- [ ] Client DNS configured (`/etc/hosts` or `setup-subdomains-hosts.sh`)

## Production URLs

| Service           | Production URL                          | Dev URL                                 |
|-------------------|-----------------------------------------|-----------------------------------------|
| UIFusion          | `https://industream.platform.lan`                | `https://dev.industream.platform.lan`            |
| Keycloak          | `https://industream.platform.lan/auth`           | `https://dev.industream.platform.lan/auth`       |
| Grafana           | `https://dashboard.industream.platform.lan`      | `https://dashboard.dev.industream.platform.lan`  |
| FlowMaker         | `https://flowmaker.industream.platform.lan`      | `https://flowmaker.dev.industream.platform.lan`  |
| DataCatalog API   | `https://datacatalog.industream.platform.lan`    | `https://datacatalog.dev.industream.platform.lan`|
| DataCatalog UI    | `https://datacatalog-ui.industream.platform.lan` | `https://datacatalog-ui.dev.industream.platform.lan` |
| Timeseries API    | `https://timeseries.industream.platform.lan`     | `https://timeseries.dev.industream.platform.lan` |
| Prometheus        | `https://prometheus.industream.platform.lan`     | `https://prometheus.dev.industream.platform.lan` |
| Traefik Dashboard | `https://traefik.industream.platform.lan`        | `https://traefik.industream.platform.lan`        |

---

**Maintained by**: Industream Dev Team
**Last update**: 2026-02-09
**Version**: Docker Swarm with Secrets + Multi-Environment + Unified Deployment Tool
