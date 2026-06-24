# Industream Platform - Quick Start Guide

From `git clone` to a running platform in 5 minutes.

## Prerequisites

| Requirement | Minimum | Check |
|-------------|---------|-------|
| Docker Engine | 20.10+ | `docker --version` |
| Docker Compose | v2+ | `docker compose version` |
| Python 3 + PyYAML | 3.8+ | `python3 -c "import yaml"` |
| OpenSSL | any | `openssl version` |
| RAM | 8 GB (16 GB for multi-env) | `free -h` |
| Disk | 20 GB per environment | `df -h` |

> **Docker network conflict?** If your LAN uses `172.x.x.x`, configure Docker to avoid conflicts:
> ```bash
> sudo tee /etc/docker/daemon.json <<'EOF'
> {"default-address-pools": [{"base": "10.10.0.0/16", "size": 24}]}
> EOF
> sudo systemctl restart docker
> ```

## Step 1: Clone and launch

```bash
git clone <repository-url>
cd industream-deployment/demo/industream-platform
industream menu
```

## Step 2: Configuration wizard (first run only)

If no `.env` file exists, the script automatically starts a setup wizard:

```
┌─ Initial Configuration
│
│  ⚠ No .env file found - starting setup wizard
│
│  ▶ Copying .env.example → .env
│  ✔ Template copied
│  ▶ Detecting server IP...
│  ✔ Detected IP: 192.168.1.50
│
│  Configuration Summary
│    INDUSTREAM_DOMAIN     industream.example.com
│    INDUSTREAM_SERVER_IP  192.168.1.50
│    TLS_MODE              selfsigned (set in .env.prod)
│    DOCKER_REGISTRY       842775dh.c1.gra9.container-registry.ovh.net
│
│  ? Configuration OK? [Y/n/e]
│    Y = continue, n = exit to edit manually, e = open in editor
```

- Press **Y** (or Enter) to accept the defaults
- Press **e** to open the `.env` file in your editor (change the domain, registry, etc.)
- Press **n** to exit and edit `.env` manually before re-running

> **Important**: Change `INDUSTREAM_DOMAIN` to your actual domain (e.g., `industream.mycompany.com`).

## Step 3: Deploy

After the wizard, the interactive menu appears. If Docker Swarm is not initialized:

```
│  Docker Swarm not initialized
│
│    1) Initialize Swarm and start first deployment
│    0) Exit
```

Choose **1** to launch the full first-deployment wizard, which handles:
- Docker Swarm initialization
- Docker registry login (for private images)
- Docker secrets creation (passwords auto-generated)
- Traefik shared infrastructure deployment
- Platform stack deployment
- Optional demo simulators (OPC-UA, MQTT, Modbus, S7, RTSP cameras)

If Swarm is already initialized, you'll see the deploy menu instead:

```
│    1) Deploy environment(s)
│    2) Run first deployment wizard
```

## Step 4: Configure DNS

After deployment, configure hostname resolution on **each client machine** that will access the platform:

```bash
# Generate the /etc/hosts entries
./scripts/setup/setup-subdomains-hosts.sh

# Or manually add to /etc/hosts (replace IP and domain):
192.168.1.50  industream.example.com
192.168.1.50  auth.industream.example.com
192.168.1.50  dashboard.industream.example.com
192.168.1.50  flowmaker.industream.example.com
192.168.1.50  datacatalog.industream.example.com
192.168.1.50  influxdb.industream.example.com
192.168.1.50  traefik.industream.example.com
```

## Step 5: Verify

```bash
# Check all stacks are running
docker stack ls

# Check services
docker stack services industream-prod

# Test access (self-signed cert → use -k)
curl -k https://industream.example.com/

# Or use the CLI
industream status
industream menu        # URLs are shown in the menu
```

## What's deployed

After a successful deployment, you have:

| Service | URL | Credentials |
|---------|-----|-------------|
| UIFusion (portal) | `https://<domain>/` | Keycloak SSO |
| Keycloak (auth) | `https://auth.<domain>/` | See Docker Secrets |
| Grafana (dashboards) | `https://dashboard.<domain>/` | See Docker Secrets |
| FlowMaker (workflows) | `https://flowmaker.<domain>/` | Keycloak SSO |
| DataCatalog | `https://datacatalog.<domain>/` | - |
| InfluxDB | `https://influxdb.<domain>/` | See Docker Secrets |
| Traefik Dashboard | `https://traefik.<domain>/` | - |

> **Secrets**: Passwords are stored as Docker Secrets and displayed at the end of the first deployment wizard. You can also find them with `docker secret ls`.

## Day-to-day usage

```bash
# Interactive management
industream menu

# Deploy/update
industream deploy --env prod
industream deploy --env dev --with-demo

# Stop an environment
industream stop --env dev

# View logs
industream logs <service-name>

# Show all URLs
industream menu        # URLs are shown in the menu

# Full help
industream --help
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `docker: command not found` | Install Docker: `https://docs.docker.com/engine/install/` |
| `Cannot connect to Docker daemon` | Start Docker: `sudo systemctl start docker` |
| Swarm init fails | Check firewall: ports 2377, 7946, 4789 must be open |
| Registry login fails | Ask your admin for registry credentials |
| Services stuck at 0/1 | Check logs: `docker service logs industream-prod_<service>` |
| Domain not resolving | Add entries to `/etc/hosts` (see Step 4) |
| SSL certificate errors | Expected with self-signed certs; use `-k` with curl |
| Port 80/443 already in use | Stop conflicting service: `sudo lsof -i :80` |

## Next steps

- **[README.md](./README.md)** - Full platform documentation
- **[SECURITY.md](./SECURITY.md)** - Security hardening and secrets management
- **[SWARM-DEPLOYMENT.md](./SWARM-DEPLOYMENT.md)** - Advanced Swarm deployment guide
