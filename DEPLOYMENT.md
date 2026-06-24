# UIFusion Stack - Deployment Guide

> **NOTE**: This document covers the legacy **Docker Compose** single-machine deployment.
> For the current **Docker Swarm** multi-environment deployment, see:
> - [README.md](./README.md) - Full documentation
> - [SWARM-DEPLOYMENT.md](./SWARM-DEPLOYMENT.md) - Swarm-specific guide
> - Quick start: `./industream.sh` or `./scripts/deploy-swarm.sh --env prod`

Step-by-step guide to deploy the complete UIFusion stack on a new machine using Docker Compose (single environment, no Swarm).

## Prerequisites

Before starting, ensure you have:

- Docker 20.10 or later
- Docker Compose v2.0 or later
- sudo/root access
- Available ports: 80, 443
- Internet connection to pull Docker images

### Check Docker Installation

```bash
docker --version
docker-compose --version
```

If Docker is not installed:

**Ubuntu/Debian:**
```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
```

**Arch Linux:**
```bash
sudo pacman -S docker docker-compose
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

Log out and back in for group changes to take effect.

## Automated Deployment (Recommended)

### Step 1: Copy the project files

Transfer the `uifusion-complete` folder to the target machine:

```bash
# Using scp
scp -r uifusion-complete/ user@target-machine:~/

# Or using rsync
rsync -av uifusion-complete/ user@target-machine:~/uifusion-complete/
```

### Step 2: Run the deployment script

```bash
cd ~/uifusion-complete
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

The script will:
1. ✅ Check Docker installation
2. ✅ Configure `/etc/hosts` with `industream.platform.lan` and subdomains
3. ✅ Generate SSL certificates (valid 10 years)
4. ✅ Install SSL certificates in the system trust store
5. ✅ Initialize UIFusion configuration
6. ✅ Pull Docker images from registry
7. ✅ Start all services

### Step 3: Access the services

Open your browser:

- **UIFusion UI**: https://industream.platform.lan
- **Keycloak Admin**: https://industream.platform.lan/auth
  - Username: `admin`
  - Password: `admin`

**Important:** You may need to restart your browser completely for the SSL certificate to be recognized.

Chrome users: Type `chrome://restart` in the address bar.

## Manual Deployment

If you prefer to run each step manually:

### Step 1: Configure /etc/hosts

```bash
./setup-hosts.sh
```

This adds:
```
127.0.0.1 industream.platform.lan
127.0.0.1 smartcamera.industream.platform.lan
```

### Step 2: Check certificates

SSL certificates should already be in the `certs/` folder:
- `industream.platform.lan.crt` (wildcard: *.industream.platform.lan)
- `industream.platform.lan.key`

If missing, generate them:
```bash
./generate-certs.sh
```

### Step 3: Install SSL certificate

```bash
./install-cert-system.sh
```

Restart your browser after installation.

### Step 4: Initialize UIFusion configuration

```bash
./init-uifusion-config.sh
```

This copies `uifusion.json` and `config-finder.json` into the Docker volume.

### Step 5: Start services

```bash
docker-compose up -d
```

Wait 30-60 seconds for Keycloak to initialize.

### Step 6: Check status

```bash
docker-compose ps
```

All services should show "Up" status.

### Step 7: View logs (optional)

```bash
docker-compose logs -f
```

Press Ctrl+C to exit.

## Post-Deployment

### Login to UIFusion

1. Open https://industream.platform.lan in your browser
2. You'll be redirected to Keycloak login
3. Use the credentials from your Keycloak realm (configured in `industream-realm.json`)

### Verify all services

```bash
# Check UIFusion
curl -k -I https://industream.platform.lan

# Check Keycloak
curl -k -I https://industream.platform.lan/auth

# Check SmartCamera (example service)
curl -k -I https://smartcamera.industream.platform.lan

# Check Traefik Dashboard
curl -I http://localhost:8081/dashboard/
```

All should return `HTTP 200` or `HTTP 301/302`.

## Production hardening

### DataCatalog backend auth (`DATACATALOG_AUTH_ENABLED`)

Since datacatalog-api **1.9.8**, auth is **opt-in**:

| `DATACATALOG_AUTH_ENABLED` | Frontend `:8002` | Backend `:8003` |
|---|---|---|
| `false` (**default**) | JWT enforced | **OPEN** (anonymous) |
| `true` | JWT enforced | `X-Api-Key` enforced |

The default keeps the **internal** backend port open so service callers (FlowMaker
workers, Grafana DataBridge plugin) work out of the box without distributing the
key — convenient for demos/internal clusters.

> **⚠️ In production, set `DATACATALOG_AUTH_ENABLED=true`** in your site env so the
> backend port also requires the `X-Api-Key`. Then make sure every caller carries
> the key: workers via `FM_DATACATALOG_API_KEY`, Grafana via the DataBridge
> datasource key (both sourced from the `datacatalog_api_key` secret). The frontend
> port (`:8002`) is JWT-protected regardless of this flag.

## Deploy paths & custom overlays

There are **two** deploy paths — do **not** mix them on the same install:

| Path | Script | Custom overlays dir | Status |
|---|---|---|---|
| **Unified (recommended)** | `industream deploy` → `unified/scripts/deploy.sh` | **`unified/custom/`** | current |
| Legacy | `./scripts/deploy-swarm.sh` | `custom/` (root) | **DEPRECATED** |

- The unified path names volumes `<name>`; the legacy path names them
  `${ENV}-<name>`. **Running the legacy script on a unified install creates new,
  empty volumes and loses data.** Stick to `industream deploy`.
- Put your own overlays (extra services, FlowMaker workers, env/label overrides)
  in **`unified/custom/*.yml`** — `deploy.sh` merges them **last** so they always
  win. See `unified/custom/README.md`.
- Premium worker boxes (opc-ua, luminosity, rtsp, minio-sink) deploy via the
  `workers-premium` group, persisted in `.env` as `GROUPS` at install time so
  `industream deploy` keeps them (EE installs fall back to the full EE group set).

## Customization

### Change domain name

Edit `.env` file:
```bash
INDUSTREAM_DOMAIN=mycompany.local
```

Then redeploy:
```bash
./redeploy.sh
```

### Change Keycloak admin password

Edit `.env` file:
```bash
HUB_BACKEND_ADMIN_PASSWORD=your-secure-password
```

Then restart:
```bash
docker-compose restart uifusion-api
```

### Add users in Keycloak

1. Go to https://industream.platform.lan/auth
2. Login as admin
3. Select "industream" realm (top-left dropdown)
4. Go to Users → Add User
5. Set username, email, and save
6. Go to Credentials tab → Set password

### Add a new service

See [ADDING_SERVICES.md](ADDING_SERVICES.md) for complete guide.

Quick steps:
1. Edit `docker-compose.yml` - add your service
2. Edit `uifusion.json` - add application entry
3. Run `./redeploy.sh`

## Troubleshooting

### Port already in use

Check what's using the ports:
```bash
sudo netstat -tlnp | grep -E ':(80|443|8081)'
```

Stop conflicting services:
```bash
sudo systemctl stop nginx    # or apache2
sudo systemctl stop httpd
```

### Docker permission denied

Add your user to docker group:
```bash
sudo usermod -aG docker $USER
```

Log out and back in.

### Services not starting

Check logs:
```bash
docker-compose logs
```

Common issues:
- **Keycloak**: Wait 30-60 seconds for database initialization
- **PostgreSQL**: Check if port 5432 is available
- **Traefik**: Check if ports 80, 443, 8081 are available

### SSL certificate not trusted

1. Run installation script:
   ```bash
   ./install-cert-system.sh
   ```

2. Restart browser completely

3. If still not working, import manually in Chrome:
   - Go to `chrome://settings/certificates`
   - Click "Authorities" tab
   - Click "Import"
   - Select `certs/industream.platform.lan.crt`
   - Check "Trust this certificate for identifying websites"
   - Click OK

### Can't access Keycloak admin

Default credentials:
- Username: `admin`
- Password: `admin`

If these don't work, check `.env` file for configured credentials.

### UIFusion shows blank page

1. Check if config was initialized:
   ```bash
   docker exec uifusion-ui ls -la /opt/frontend/uifusion/assets/config/
   ```

2. Re-initialize:
   ```bash
   ./init-uifusion-config.sh
   docker-compose restart uifusion
   ```

3. Clear browser cache (Ctrl+F5)

## Maintenance

### Update a service

```bash
# Edit docker-compose.yml to change image version
docker-compose pull [service-name]
docker-compose up -d [service-name]
```

### Backup data

```bash
# Backup volumes
docker run --rm -v uifusion-complete_keycloak-postgres:/data \
  -v $(pwd)/backup:/backup alpine \
  tar czf /backup/keycloak-db-$(date +%Y%m%d).tar.gz -C /data .

# Backup configuration
tar czf uifusion-config-backup-$(date +%Y%m%d).tar.gz \
  uifusion.json config-finder.json industream-realm.json .env
```

### Stop all services

```bash
docker-compose down
```

### Remove everything (including data)

```bash
docker-compose down -v
```

⚠️ **Warning:** This will delete all data including Keycloak users and configurations!

## Security Recommendations

For production deployments:

1. **Change default passwords** in `.env`:
   - `HUB_BACKEND_ADMIN_PASSWORD`
   - `KC_DB_PASSWORD`

2. **Use Let's Encrypt** for SSL certificates:
   - Uncomment Let's Encrypt section in `docker-compose.yml`
   - Configure your domain DNS to point to the server
   - Remove self-signed certificates

3. **Disable Traefik dashboard** or protect it:
   - Remove `--api.insecure=true` from Traefik command
   - Add authentication middleware

4. **Use environment-specific realm** configuration:
   - Don't use the demo realm in production
   - Export a production-ready realm configuration

5. **Enable firewall**:
   ```bash
   sudo ufw allow 80/tcp
   sudo ufw allow 443/tcp
   sudo ufw enable
   ```

## Next Steps

- ✅ Read [ADDING_SERVICES.md](ADDING_SERVICES.md) to add your services
- ✅ Configure users and roles in Keycloak
- ✅ Customize `uifusion.json` with your applications
- ✅ Set up backup automation
- ✅ Configure monitoring and logging
