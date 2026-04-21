# Industream Complete Stack

Complete Docker Swarm deployment of the Industream platform with multi-environment support.

## Table of Contents

- [Overview](#overview)
- [Multi-Environment Architecture](#multi-environment-architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Applications & Services](#applications--services)
- [Network Architecture](#network-architecture)
- [Configuration](#configuration)
- [Maintenance](#maintenance)
- [Troubleshooting](#troubleshooting)

> **Notice (April 2026)** — Community (BSL 1.1) images have moved to a new public Harbor at `39t88114.c1.gra9.container-registry.ovh.net` with anonymous pull. The legacy Harbor `842775dh.c1.gra9.container-registry.ovh.net` still hosts premium add-ons. See [`industream-cli/docs/HARBOR-MIGRATION.md`](../industream-cli/docs/HARBOR-MIGRATION.md) for the full inventory, exclusions and consumer rewiring status. Existing `.env` files keep working until producers are flipped.

## Overview

This deployment provides a complete Industream ecosystem with support for multiple isolated environments (production, development, staging) on the same machine.

Key features:

- **UIFusion**: Main user interface and portal
- **Keycloak**: SSO and authentication provider
- **Grafana Dashboard**: Visualization and monitoring
- **DataCatalog**: Data asset management
- **Timeseries**: Time-series data storage and API (InfluxDB)
- **FlowMaker**: Workflow orchestration engine
- **CDN Cache**: NPM registry (Verdaccio) and ESM.sh
- **Monitoring**: Prometheus, Alertmanager, Node Exporter, cAdvisor
- **Traefik**: Shared reverse proxy and SSL termination

## Multi-Environment Architecture

The platform supports deploying multiple isolated environments on the same machine with a shared Traefik instance.

### Environment Isolation

```
                    Traefik (ports 80/443) - traefik-shared
                           │
          ┌────────────────┼────────────────┐
          │                │                │
   industream.platform.lan    dev.industream.platform.lan  staging.industream.platform.lan
          │                │                │
   Stack: industream-prod  │         Stack: industream-staging
   Network: prod-platform  │         Network: staging-platform
   Volumes: prod-*         │         Volumes: staging-*
   Secrets: prod_*         │         Secrets: staging_*
   + Backups ✓             │         - Backups ✗
                           │
                   Stack: industream-dev
                   Network: dev-platform
                   Volumes: dev-*
                   Secrets: dev_*
                   - Backups ✗
```

### Environment Domains

| Environment | Main Domain | Example Subdomains |
|-------------|-------------|-------------------|
| **Production** | `industream.platform.lan` | `dashboard.industream.platform.lan`, `flowmaker.industream.platform.lan` |
| **Development** | `dev.industream.platform.lan` | `dashboard.dev.industream.platform.lan`, `flowmaker.dev.industream.platform.lan` |
| **Staging** | `staging.industream.platform.lan` | `dashboard.staging.industream.platform.lan`, `flowmaker.staging.industream.platform.lan` |

### Resource Isolation

Each environment has completely isolated:
- **Networks**: `${ENV}-platform` (e.g., `prod-platform`, `dev-platform`)
- **Volumes**: `${ENV}-*` prefix (e.g., `prod-postgres-data`, `dev-influxdb-data`)
- **Secrets**: `${ENV}_*` prefix (e.g., `prod_postgres_admin_password`)
- **Stack name**: `industream-${ENV}` (e.g., `industream-prod`)

### Stack Files

| Stack File | Description | Prod | Dev | Staging |
|------------|-------------|:----:|:---:|:-------:|
| `docker-stack.traefik.yml` | Shared Traefik, DNS | ✓ | ✓ | ✓ |
| `docker-stack.yml` | Core services (Postgres, Keycloak, etcd, UIFusion) | ✓ | ✓ | ✓ |
| `docker-stack.flowmaker.yml` | FlowMaker orchestration | ✓ | ✓ | ✓ |
| `docker-stack.workers.yml` | FlowMaker workers (17 workers) | ✓ | ✓ | ✓ |
| `docker-stack.monitoring.yml` | Grafana, Prometheus, alerting | ✓ | ✓ | ✓ |
| `docker-stack.data.yml` | InfluxDB, Timeseries API, DataCatalog | ✓ | ✓ | ✓ |
| `docker-stack.backup.yml` | Automated backups | ✓ | ✗ | ✗ |
| `docker-stack.cdn.yml` | CDN cache (Verdaccio, ESM.sh) | ✓ | ✓ | ✓ |
| `docker-stack.demo.yml` | Industrial simulators (OPC-UA, MQTT, S7, Modbus) | opt | opt | opt |

## Prerequisites

- Docker Engine 20.10+ with **Swarm mode** enabled
- 8GB+ RAM recommended (16GB+ for multiple environments)
- 20GB+ disk space per environment
- Root/sudo access for DNS configuration

### Initialize Docker Swarm

```bash
# Initialize Swarm if not already done
docker swarm init
```

## Quick Start

### Interactive Setup (Recommended)

A single command handles the full setup:

```bash
./industream.sh
```

On first run, the script automatically:
1. Detects missing `.env` and launches a setup wizard
2. Copies `.env.example` → `.env` with auto-detected server IP
3. Asks for confirmation or lets you edit the configuration
4. Shows an interactive menu to deploy, stop, or manage environments

See **[QUICKSTART.md](./QUICKSTART.md)** for a complete step-by-step walkthrough.

### Manual Deployment

#### 1. Deploy Shared Traefik (once)

```bash
./scripts/deploy-traefik.sh
```

This deploys the shared infrastructure (Traefik, DNS, socket-proxy).

#### 2. Create Secrets for Environment

```bash
# For production
./scripts/setup/create-secrets.sh --env prod

# For development
./scripts/setup/create-secrets.sh --env dev

# For staging
./scripts/setup/create-secrets.sh --env staging

# Or all environments at once
./scripts/setup/create-secrets.sh --env all
```

#### 3. Deploy Environment

```bash
# Deploy production
./scripts/deploy-swarm.sh --env prod

# Deploy development
./scripts/deploy-swarm.sh --env dev

# Deploy staging
./scripts/deploy-swarm.sh --env staging

# With demo simulators
./scripts/deploy-swarm.sh --env prod --with-demo
```

### Command Line Interface

```bash
# Deploy specific environment
./industream.sh deploy --env prod
./industream.sh deploy --env dev

# Stop specific environment
./industream.sh stop --env prod

# Check status
./industream.sh status

# View logs
./industream.sh logs
```

### Access Applications

#### Production (`industream.platform.lan`)

| Application | URL | Credentials |
|-------------|-----|-------------|
| UIFusion | `https://industream.platform.lan/` | Via Keycloak |
| Keycloak | `https://auth.industream.platform.lan/` | See Docker Secrets |
| Grafana | `https://dashboard.industream.platform.lan/` | See Docker Secrets |
| InfluxDB | `https://influxdb.industream.platform.lan/` | See Docker Secrets |
| DataCatalog | `https://datacatalog.industream.platform.lan/` | - |
| Timeseries API | `https://timeseries.industream.platform.lan/` | - |
| Flowmaker | `https://flowmaker.industream.platform.lan/` | - |
| Traefik Dashboard | `https://traefik.industream.platform.lan/` | - |

#### Development (`dev.industream.platform.lan`)

| Application | URL |
|-------------|-----|
| UIFusion | `https://dev.industream.platform.lan/` |
| Keycloak | `https://auth.dev.industream.platform.lan/` |
| Grafana | `https://dashboard.dev.industream.platform.lan/` |
| Flowmaker | `https://flowmaker.dev.industream.platform.lan/` |

#### Staging (`staging.industream.platform.lan`)

| Application | URL |
|-------------|-----|
| UIFusion | `https://staging.industream.platform.lan/` |
| Keycloak | `https://auth.staging.industream.platform.lan/` |
| Grafana | `https://dashboard.staging.industream.platform.lan/` |
| Flowmaker | `https://flowmaker.staging.industream.platform.lan/` |

## Applications & Services

### Core Services

#### Traefik
- **Role**: Reverse proxy and load balancer
- **Ports**: 80 (HTTP), 443 (HTTPS), 8081 (Dashboard)
- **Configuration**: `traefik-dynamic.yml`

#### PostgreSQL (Shared)
- **Role**: Centralized database for Keycloak, Grafana, and DataCatalog
- **Databases**:
  - `keycloak` - Keycloak configuration
  - `industream` - Grafana configuration
  - `DataCatalog` - DataCatalog metadata
- **Initialization**: `init-postgres.sh` (auto-creates databases and users)

#### Keycloak
- **Role**: Single Sign-On and Identity Management
- **Path**: `/auth`
- **Database**: `keycloak` (in shared PostgreSQL)

### Data & Analytics

#### Grafana Dashboard
- **Role**: Data visualization and dashboards
- **Path**: `/dashboard`
- **Database**: `industream` (in shared PostgreSQL)
- **Features**:
  - OAuth integration with Keycloak
  - Image renderer for PDF exports
  - Custom Industream plugins

#### DataCatalog
- **Role**: Data asset catalog and metadata management
- **Paths**:
  - API: `/api/datacatalog`
- **Database**: `DataCatalog` (in shared PostgreSQL)

#### Timeseries
- **Role**: Time-series data storage and querying
- **Components**:
  - InfluxDB 2.x
  - Timeseries API
- **Paths**:
  - InfluxDB UI: `/influxdb`
  - API: `/api/timeseries`

### Interface Builder

- **Role**: Visual interface builder and configuration tool
- **Paths**:
- **Storage**: Persistent volumes for projects, storage, and resources

### Workflow Engine

#### Flowmaker
- **Role**: Workflow orchestration and automation
- **Architecture**:
  - **etcd**: Distributed configuration store
  - **Scheduler**: Workflow execution engine
  - **ConfigHub**: Configuration API
  - **Frontend**: Workflow designer UI
  - **Workers**: Execution nodes (datalogger, timer, etc.)
  - **SocketIO**: Real-time logging
- **Paths**:
  - Main UI: `/flowmaker`
  - ConfigHub: `/flowmaker/confighub`

#### UIFusion
- **Role**: Main application portal and user interface
- **Path**: `/` (root)
- **Authentication**: Keycloak OAuth

## Network Architecture

### Port Mapping

| Service | Internal Port | External Port | Purpose |
|---------|--------------|---------------|---------|
| Traefik | 80 | 80 | HTTP (redirects to HTTPS) |
| Traefik | 443 | 443 | HTTPS |

All other services are accessible only through Traefik reverse proxy.

> **Note**: DNS resolution is handled via static `/etc/hosts` entries on client machines. Use `./scripts/setup/setup-subdomains-hosts.sh` to generate the hosts file entries.

### Docker Networks

The platform uses overlay networks for service communication:

| Network | Scope | Purpose |
|---------|-------|---------|
| `traefik-public` | Shared (external) | Traefik routing to all environments |
| `socket-proxy` | Traefik stack only | Docker socket access |
| `prod-platform` | Production stack | Inter-service communication |
| `dev-platform` | Development stack | Inter-service communication |
| `staging-platform` | Staging stack | Inter-service communication |

```bash
# View all networks
docker network ls | grep -E "traefik|platform"
```

## Configuration

### Environment Files

The platform uses layered configuration:

| File | Purpose |
|------|---------|
| `.env` | Base configuration (shared across all environments) |
| `.env.prod` | Production overrides |
| `.env.dev` | Development overrides |
| `.env.staging` | Staging overrides |

### Key Environment Variables

**Base `.env`:**
```bash
# Docker Registry
# Legacy Harbor — hosts premium add-ons; community BSL images are moving to
# 39t88114.c1.gra9.container-registry.ovh.net (anonymous pull). See
# industream-cli/docs/HARBOR-MIGRATION.md.
DOCKER_REGISTRY=842775dh.c1.gra9.container-registry.ovh.net

# Service versions
UIFUSION_VERSION=1.0.8
KEYCLOAK_VERSION=26.1.0
POSTGRES_VERSION=17.2
FLOWMAKER_CORE_VERSION=1.6.11-rc1

# PostgreSQL
POSTGRES_ADMIN_USER=postgres

# Keycloak
KEYCLOAK_ADMIN=admin

# Grafana
GRAFANA_ADMIN_USER=admin

# InfluxDB
INFLUX_ADMIN_USERNAME=admin
```

**Environment-specific (e.g., `.env.prod`):**
```bash
# Environment identifier
ENV=prod

# Domain
INDUSTREAM_DOMAIN=industream.platform.lan

# Stack name
STACK_NAME=industream-prod

# Backup (only in prod)
BACKUP_ENABLED=true
```

### Secrets Management

Secrets are managed per environment with Docker Swarm secrets:

```bash
# List secrets
docker secret ls

# Secrets naming convention
${ENV}_postgres_admin_password
${ENV}_keycloak_admin_password
${ENV}_keycloak_db_password
${ENV}_grafana_admin_password
${ENV}_grafana_db_password
${ENV}_influx_admin_password
${ENV}_influx_admin_token
${ENV}_datacatalog_db_password
```

> **Note**: Passwords are generated automatically by `./scripts/setup/create-secrets.sh`.
> Never commit passwords to version control.

### PostgreSQL Database Initialization

The `init-postgres.sh` script automatically creates multiple databases and users on first startup. The script is executed only once when the PostgreSQL container is first created.

Format in `docker-compose.yml`:
```yaml
POSTGRES_MULTIPLE_DATABASES: "db1:user1:password1,db2:user2:password2,..."
```

### Traefik SSL Configuration

Edit `traefik-dynamic.yml` to configure SSL certificates:

```yaml
tls:
  certificates:
    - certFile: /etc/certs/cert.pem
      keyFile: /etc/certs/key.pem
```

## Maintenance

### Stack Management

```bash
# List all stacks
docker stack ls

# List services in an environment
docker stack services industream-prod
docker stack services industream-dev

# Remove an environment
docker stack rm industream-dev

# Remove Traefik (WARNING: stops all environments)
docker stack rm traefik-shared
```

### Backup

Production environments have automated backups via `docker-stack.backup.yml`.

#### Manual PostgreSQL Backup
```bash
# Find the postgres container
docker ps | grep postgres

# Backup all databases (replace with actual container name)
docker exec industream-prod_postgres.1.xxx pg_dumpall -U postgres > backup_$(date +%Y%m%d).sql

# Backup specific database
docker exec industream-prod_postgres.1.xxx pg_dump -U postgres keycloak > keycloak_backup_$(date +%Y%m%d).sql
```

#### Manual InfluxDB Backup
```bash
# Backup InfluxDB
docker exec industream-prod_influxdb.1.xxx influx backup /tmp/influx-backup
docker cp industream-prod_influxdb.1.xxx:/tmp/influx-backup ./influx-backup_$(date +%Y%m%d)
```

### Updates

```bash
# Update service image
docker service update --image NEW_IMAGE industream-prod_uifusion

# Or redeploy the entire stack
./scripts/deploy-swarm.sh --env prod

# Remove old images
docker image prune
```

### Logs

```bash
# View service logs
docker service logs industream-prod_postgres
docker service logs industream-prod_keycloak -f

# View last 100 lines
docker service logs --tail=100 industream-prod_uifusion

# Or use industream.sh
./industream.sh logs
```

### Scaling

Scale Flowmaker workers in Swarm mode:

```bash
# Scale a specific worker
docker service scale industream-prod_flowmaker-worker-timer=3

# Check scaling
docker service ls | grep worker
```

## Troubleshooting

### Common Issues

#### Traefik Not Deployed

**Problem**: Environment deployment fails with "Traefik not deployed"

**Solution**:
```bash
# Deploy Traefik first
./scripts/deploy-traefik.sh

# Verify
docker stack ls | grep traefik-shared
```

#### Secrets Not Found

**Problem**: Deployment fails with missing secrets

**Solution**:
```bash
# Create secrets for the environment
./scripts/setup/create-secrets.sh --env prod

# Verify secrets exist
docker secret ls | grep prod_
```

#### PostgreSQL Connection Errors

**Problem**: Services can't connect to PostgreSQL

**Solution**:
```bash
# Check PostgreSQL logs
docker service logs industream-prod_postgres

# Check if service is running
docker service ps industream-prod_postgres

# Verify network connectivity
docker exec -it $(docker ps -qf name=industream-prod_postgres) psql -U postgres -l
```

#### Traefik 404 Errors

**Problem**: Services return 404 Not Found

**Solution**:
```bash
# Check Traefik logs
docker service logs traefik-shared_traefik

# Verify service is attached to traefik-public network
docker service inspect industream-prod_uifusion | grep Networks

# Check Traefik dashboard
# https://traefik.industream.platform.lan/
```

#### DNS Resolution Issues

**Problem**: Domains not resolving

**Solution**:
```bash
# Verify /etc/hosts entries are configured
cat /etc/hosts | grep industream

# If missing, generate hosts entries
./scripts/setup/setup-subdomains-hosts.sh

# Or generate a client setup kit for deployment on other machines
./scripts/generate/generate-client-setup.sh
```

#### SSL Certificate Issues

**Problem**: SSL certificate errors

**Solution**:
```bash
# Verify certificates exist
ls -l ./certs/

# Check Traefik TLS configuration
docker service logs traefik-shared_traefik 2>&1 | grep -i tls

# Regenerate certificates if needed
./scripts/setup/generate-certificates.sh
```

#### Service Won't Start

**Problem**: Service fails to start

**Solution**:
```bash
# Check service status and errors
docker service ps industream-prod_keycloak --no-trunc

# Check service logs
docker service logs industream-prod_keycloak

# Force update the service
docker service update --force industream-prod_keycloak
```

### Health Checks

```bash
# Check all stacks
docker stack ls

# Check all services in an environment
docker stack services industream-prod

# Test connectivity
curl -k https://industream.platform.lan/
curl -k https://auth.industream.platform.lan/

# Check service health
docker service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Healthcheck}}' industream-prod_postgres
```

### Reset Environment

```bash
# Remove a specific environment (keeps data in volumes)
docker stack rm industream-dev

# Remove secrets for an environment
docker secret rm $(docker secret ls -q -f name=dev_)

# Remove volumes (WARNING: DELETES ALL DATA)
docker volume rm $(docker volume ls -q -f name=dev-)

# Full reset: remove everything
docker stack rm industream-prod
docker stack rm industream-dev
docker stack rm industream-staging
docker stack rm traefik-shared
```

## Production Considerations

### Security

1. **Secrets Management**: Secrets are automatically generated per environment
2. **SSL Certificates**: Use valid certificates from Let's Encrypt or your CA
3. **Firewall**: Restrict access to ports 80, 443, 53 (DNS) only
4. **Network Isolation**: Each environment has its own isolated network
5. **Environment Separation**: Dev/staging have no access to production data

### Performance

1. **Resource Limits**: Memory and CPU limits are configured in stack files
2. **Volume Drivers**: Use appropriate volume drivers for production
3. **Database Tuning**: Optimize PostgreSQL and InfluxDB configurations
4. **Monitoring**: Prometheus and Grafana are included for monitoring

### High Availability

1. **Docker Swarm**: Services can be scaled across multiple nodes
2. **Database Replication**: Setup PostgreSQL streaming replication
3. **Backup Strategy**: Automated backups enabled for production only
4. **Health Checks**: All services have configured health checks

### Multi-Environment Best Practices

1. **Test in Dev/Staging First**: Always test changes in dev before prod
2. **Separate Secrets**: Each environment has unique passwords
3. **Backup Prod Only**: Saves resources, dev/staging are reproducible
4. **Same Stack Files**: All environments use identical configurations

## Support & Resources

- **Industream Documentation**: [Link to docs]
- **Docker Swarm Reference**: [docs.docker.com/engine/swarm](https://docs.docker.com/engine/swarm/)
- **Traefik Documentation**: [doc.traefik.io/traefik](https://doc.traefik.io/traefik/)

## License

Not yet defined
