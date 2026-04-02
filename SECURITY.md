# 🔐 Security Configuration Guide

## Overview

This deployment uses environment variables stored in a `.env` file to manage sensitive credentials securely.

## ⚠️ IMPORTANT SECURITY NOTES

1. **NEVER commit `.env` to Git** - It contains sensitive passwords
2. The `.env` file has restrictive permissions (600) - only owner can read/write
3. All passwords are randomly generated using `openssl`
4. Change all passwords before production deployment

---

## 📋 Initial Setup

### 1. Generate Environment File

Run the generation script to create a new `.env` file with random passwords:

```bash
./scripts/generate-env.sh > .env
chmod 600 .env
```

### 2. Verify Permissions

Check that the file has correct permissions:

```bash
ls -la .env
# Should show: -rw------- (600)
```

### 3. Review Generated Passwords

```bash
cat .env
```

**Note**: These passwords are cryptographically secure (32 bytes base64 encoded = 43 characters).

---

## 🔑 Managed Credentials

The `.env` file manages the following credentials:

### PostgreSQL
- `POSTGRES_ADMIN_PASSWORD` - PostgreSQL superuser password
- `GRAFANA_DB_PASSWORD` - Grafana database password
- `DATACATALOG_DB_PASSWORD` - DataCatalog database password

### Keycloak
- `KEYCLOAK_ADMIN_PASSWORD` - Keycloak admin console password
- `KC_DB_PASSWORD` - Keycloak database password

### Grafana
- `GRAFANA_ADMIN_PASSWORD` - Grafana admin user password

### InfluxDB
- `INFLUX_ADMIN_PASSWORD` - InfluxDB admin password
- `INFLUX_ADMIN_TOKEN` - InfluxDB authentication token

---

## 🔄 Password Rotation

To rotate passwords:

### Option 1: Regenerate All (Destructive)

```bash
# Backup current .env
cp .env .env.backup.$(date +%Y%m%d)

# Generate new passwords
./scripts/generate-env.sh > .env
chmod 600 .env

# IMPORTANT: This will require recreating databases
docker-compose down -v  # ⚠️ Destroys data!
docker-compose up -d
```

### Option 2: Rotate Specific Passwords (Non-destructive)

```bash
# 1. Generate new password
NEW_PASSWORD=$(openssl rand -base64 32)

# 2. Edit .env and update the password
vim .env

# 3. Update the service
# For PostgreSQL:
docker-compose exec postgres psql -U postgres -c "ALTER USER postgres PASSWORD '$NEW_PASSWORD';"

# For Keycloak:
docker-compose restart keycloak

# For Grafana:
docker-compose restart grafana
```

---

## 🚀 Deployment to New Environment

### Step 1: Copy Template

```bash
# Copy the example file
cp .env.example .env
```

### Step 2: Generate New Passwords

```bash
./scripts/generate-env.sh > .env
chmod 600 .env
```

### Step 3: Customize Settings

Edit `.env` and adjust non-sensitive settings:
- `INDUSTREAM_DOMAIN`
- Version tags
- Organization settings

### Step 4: Deploy

```bash
docker-compose up -d
```

---

## 🔍 Security Checklist

Before going to production, verify:

- [ ] `.env` file has 600 permissions
- [ ] `.env` is in `.gitignore`
- [ ] No hardcoded passwords in `docker-compose.yml`
- [ ] All passwords are > 32 characters
- [ ] Passwords have been changed from defaults
- [ ] `.env` is backed up securely (encrypted)
- [ ] Password rotation schedule is defined
- [ ] Access to `.env` is logged/audited

---

## 📝 Environment Variables Reference

| Variable | Description | Example |
|----------|-------------|---------|
| `INDUSTREAM_DOMAIN` | Main domain | `industream.platform.lan` |
| `POSTGRES_ADMIN_PASSWORD` | PostgreSQL superuser password | `(random)` |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak admin password | `(random)` |
| `KC_DB_PASSWORD` | Keycloak DB password | `(random)` |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin password | `(random)` |
| `GRAFANA_DB_PASSWORD` | Grafana DB password | `(random)` |
| `DATACATALOG_DB_PASSWORD` | DataCatalog DB password | `(random)` |
| `INFLUX_ADMIN_PASSWORD` | InfluxDB admin password | `(random)` |
| `INFLUX_ADMIN_TOKEN` | InfluxDB token | `(random)` |

---

## 🔐 Backup Strategy

### Backing Up `.env`

```bash
# Encrypt and backup
gpg --symmetric --cipher-algo AES256 .env
# Creates .env.gpg (encrypted)

# Upload to secure location
aws s3 cp .env.gpg s3://secure-bucket/backups/
```

### Restoring `.env`

```bash
# Download encrypted file
aws s3 cp s3://secure-bucket/backups/.env.gpg .

# Decrypt
gpg --decrypt .env.gpg > .env
chmod 600 .env
```

---

## 🚨 Security Incident Response

### If `.env` is Compromised:

1. **Immediate Actions**:
   ```bash
   # Stop all services
   docker-compose down

   # Generate new passwords
   ./scripts/generate-env.sh > .env
   chmod 600 .env
   ```

2. **Reset Databases**:
   ```bash
   # Remove volumes (destroys data - backup first!)
   docker-compose down -v

   # Restart with new passwords
   docker-compose up -d
   ```

3. **Audit Access**:
   - Check Git history for `.env` commits
   - Review server access logs
   - Check who has SSH access
   - Rotate SSH keys if needed

4. **Documentation**:
   - Document incident
   - Update passwords in password manager
   - Notify team

---

## 📚 Additional Security Recommendations

### Production Deployment

For production, consider upgrading to:

1. **HashiCorp Vault**
   ```bash
   vault kv put secret/industream/postgres password="..."
   ```

2. **AWS Secrets Manager**
   ```bash
   aws secretsmanager create-secret --name industream/db
   ```

3. **Docker Secrets** (Swarm mode)
   ```bash
   echo "password" | docker secret create db_password -
   ```

### Monitoring

Add monitoring for:
- Failed login attempts
- Password changes
- `.env` file modifications
- Unauthorized access attempts

```bash
# File integrity monitoring
sudo apt-get install aide
aide --init
```

---

## 🔗 Related Documentation

- [Production Readiness Report](./PRODUCTION_READINESS_REPORT.md)
- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [OWASP Top 10](https://owasp.org/www-project-top-ten/)

---

## ❓ Troubleshooting

### Error: Permission denied reading .env

```bash
# Fix permissions
chmod 600 .env
```

### Error: Environment variable not found

```bash
# Verify .env is in correct directory
ls -la .env

# Check docker-compose can read it
docker-compose config
```

### Services failing to start after password rotation

```bash
# Check logs
docker-compose logs

# Verify .env format (no spaces around =)
cat .env | grep "POSTGRES_PASSWORD"
```

---

## 📞 Support

For security concerns, contact:
- Security Team: security@industream.com
- DevOps Team: devops@industream.com

**DO NOT** share passwords via:
- Email
- Slack
- Git commits
- Screenshots

Use a password manager or secure vault instead.
