# Secret Rotation Guide for Industream Stack

This document describes how to manage and rotate secrets in the Industream Docker Swarm deployment.

## Table of Contents

1. [Overview](#overview)
2. [Required Secrets](#required-secrets)
3. [Initial Setup](#initial-setup)
4. [Secret Rotation Procedures](#secret-rotation-procedures)
5. [Emergency Procedures](#emergency-procedures)

---

## Overview

The Industream stack uses Docker Secrets for sensitive data management. This approach provides:

- **Encrypted storage**: Secrets are encrypted at rest in the Swarm Raft log
- **Limited exposure**: Secrets are only mounted into containers that need them
- **Access control**: Only authorized services can access specific secrets
- **Audit trail**: Secret access can be logged and monitored

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Docker Swarm Manager                     │
│  ┌─────────────────────────────────────────────────────────┤
│  │           Raft Log (Encrypted)                          │
│  │  ┌─────────────────┐  ┌─────────────────┐              │
│  │  │ postgres_admin_ │  │ keycloak_admin_ │  ...         │
│  │  │ password        │  │ password        │              │
│  │  └────────┬────────┘  └────────┬────────┘              │
│  └───────────┼────────────────────┼─────────────────────────┤
│              │                    │                         │
│  ┌───────────▼────────┐  ┌───────▼───────────┐            │
│  │   PostgreSQL       │  │    Keycloak       │            │
│  │  /run/secrets/...  │  │  /run/secrets/... │            │
│  └────────────────────┘  └───────────────────┘            │
└─────────────────────────────────────────────────────────────┘
```

---

## Required Secrets

| Secret Name | Used By | Description |
|-------------|---------|-------------|
| `postgres_admin_password` | postgres, postgres-exporter, backup-postgres | PostgreSQL admin password |
| `keycloak_admin_password` | keycloak | Keycloak admin console password |
| `keycloak_db_password` | keycloak, postgres | Keycloak database password |
| `grafana_admin_password` | grafana | Grafana admin password |
| `grafana_db_password` | grafana, postgres | Grafana database password |
| `datacatalog_db_password` | datacatalog-api, postgres | DataCatalog database password |
| `influx_admin_password` | influxdb | InfluxDB admin password |
| `influx_admin_token` | influxdb, timeseries-api | InfluxDB API token |

---

## Initial Setup

### 1. Generate Secure Passwords

```bash
# Generate a random 32-character password
openssl rand -base64 32

# Or use pwgen
pwgen -s 32 1
```

### 2. Create Docker Secrets

Use the provided script:

```bash
./scripts/create-secrets.sh
```

Or manually create each secret:

```bash
# Create from stdin (recommended - no trace in history)
echo -n "your-secure-password" | docker secret create postgres_admin_password -

# Create from file
echo -n "your-secure-password" > /tmp/secret.txt
docker secret create keycloak_admin_password /tmp/secret.txt
rm /tmp/secret.txt

# List existing secrets
docker secret ls
```

### 3. Verify Secrets

```bash
# List all secrets
docker secret ls

# Inspect a secret (metadata only, not the value)
docker secret inspect postgres_admin_password
```

---

## Secret Rotation Procedures

### General Rotation Process

Docker Secrets are **immutable**. To rotate a secret:

1. Create a new secret with a different name
2. Update the service to use the new secret
3. Remove the old secret

### PostgreSQL Password Rotation

**Estimated downtime**: 1-2 minutes

```bash
# 1. Generate new password
NEW_PASS=$(openssl rand -base64 32)

# 2. Create new secret
echo -n "$NEW_PASS" | docker secret create postgres_admin_password_v2 -

# 3. Connect to postgres and change the password
docker exec -it $(docker ps -q -f name=industream_postgres) \
  psql -U postgres -c "ALTER USER postgres PASSWORD '$NEW_PASS';"

# 4. Update docker-stack.yml to reference new secret
# Change: postgres_admin_password -> postgres_admin_password_v2

# 5. Redeploy affected services
docker stack deploy -c docker-stack-resolved.yml industream

# 6. Verify services are running
docker service ls | grep -E "postgres|grafana|keycloak|datacatalog"

# 7. Remove old secret (after confirming everything works)
docker secret rm postgres_admin_password
```

### Keycloak Password Rotation

```bash
# 1. Create new admin password secret
NEW_PASS=$(openssl rand -base64 32)
echo -n "$NEW_PASS" | docker secret create keycloak_admin_password_v2 -

# 2. Update Keycloak via Admin API (before changing secret)
# Login to Keycloak admin console and change password manually
# Or use kcadm.sh CLI tool

# 3. Update docker-stack.yml and redeploy
docker stack deploy -c docker-stack-resolved.yml industream

# 4. Remove old secret
docker secret rm keycloak_admin_password
```

### InfluxDB Token Rotation

**Important**: All services using the token must be updated simultaneously.

```bash
# 1. Generate new token
NEW_TOKEN=$(openssl rand -base64 32)

# 2. Create new token in InfluxDB
docker exec -it $(docker ps -q -f name=industream_influxdb) \
  influx auth create \
    --org industream \
    --all-access \
    --description "New admin token $(date +%Y%m%d)"

# 3. Create new Docker secret
echo -n "$NEW_TOKEN" | docker secret create influx_admin_token_v2 -

# 4. Update docker-stack.yml for all affected services:
#    - timeseries-api
#    - Any FlowMaker workers using InfluxDB

# 5. Redeploy stack
docker stack deploy -c docker-stack-resolved.yml industream

# 6. Revoke old token in InfluxDB
docker exec -it $(docker ps -q -f name=industream_influxdb) \
  influx auth delete --id <OLD_TOKEN_ID>

# 7. Remove old secret
docker secret rm influx_admin_token
```

### Grafana Password Rotation

```bash
# 1. Create new secret
NEW_PASS=$(openssl rand -base64 32)
echo -n "$NEW_PASS" | docker secret create grafana_admin_password_v2 -

# 2. Reset password via Grafana CLI
docker exec -it $(docker ps -q -f name=industream_grafana) \
  grafana-cli admin reset-admin-password "$NEW_PASS"

# 3. Update stack and remove old secret
docker stack deploy -c docker-stack-resolved.yml industream
docker secret rm grafana_admin_password
```

---

## Emergency Procedures

### Compromised Secret Response

If you suspect a secret has been compromised:

1. **Immediately rotate the affected secret** using the procedures above
2. **Check audit logs** for unauthorized access:
   ```bash
   docker service logs industream_<service_name>
   ```
3. **Review Traefik access logs** for suspicious activity
4. **Check Keycloak audit logs** for unauthorized logins
5. **Document the incident** and timeline

### Lost Secret Recovery

If you lose access to a secret:

1. For **database passwords**: You may need to reset via direct database access
2. For **API tokens**: Generate new tokens via the service's admin interface
3. For **admin passwords**: Most services have password reset mechanisms

### Backup Recommendations

1. **Never store secrets in version control**
2. **Use a secure password manager** for backup copies
3. **Consider using HashiCorp Vault** for production environments
4. **Document secret locations** in a secure location (not in this repo)

---

## Automation Script

A helper script is provided at `scripts/create-secrets.sh`:

```bash
#!/bin/bash
# Create all required Docker secrets

SECRETS=(
  "postgres_admin_password"
  "keycloak_admin_password"
  "keycloak_db_password"
  "grafana_admin_password"
  "grafana_db_password"
  "datacatalog_db_password"
  "influx_admin_password"
  "influx_admin_token"
)

for secret in "${SECRETS[@]}"; do
  if docker secret ls --format '{{.Name}}' | grep -q "^${secret}$"; then
    echo "Secret $secret already exists, skipping..."
  else
    echo "Creating secret: $secret"
    openssl rand -base64 32 | docker secret create "$secret" -
  fi
done

echo "All secrets created. Remember to save them securely!"
```

---

## Best Practices

1. **Rotate secrets regularly** (at least every 90 days for production)
2. **Use strong passwords** (minimum 32 characters, random)
3. **Limit secret access** to only services that need them
4. **Monitor secret access** via service logs
5. **Test rotation procedures** in staging before production
6. **Document all rotations** with timestamps and reasons

---

## Related Documentation

- [Docker Secrets Documentation](https://docs.docker.com/engine/swarm/secrets/)
- [Keycloak Admin Guide](https://www.keycloak.org/docs/latest/server_admin/)
- [InfluxDB Token Management](https://docs.influxdata.com/influxdb/v2/admin/tokens/)
- [Grafana Configuration](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/)
