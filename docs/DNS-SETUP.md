# DNS Configuration for Industream Platform

This guide explains how to configure DNS resolution to access the Industream platform without modifying `/etc/hosts`.

## DNS Architecture

The Industream stack includes a local DNS server (dnsmasq) that provides:
- Wildcard resolution for `*.industream.platform.lan`
- Forwarding of other requests to upstream DNS servers

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Client Browser │────▶│  dnsmasq (port   │────▶│  Upstream DNS   │
│  DNS: server:53 │     │  53 on server)   │     │  (1.1.1.1, etc) │
└─────────────────┘     └──────────────────┘     └─────────────────┘
         │                      │
         │                      ▼
         │              *.industream.platform.lan
         │              → Server IP
         │
         ▼
    Other domains
    → Upstream DNS
```

## Prerequisites

1. Know the IP address of the Industream server (e.g., `192.168.100.50`)
2. Have port 53 (TCP/UDP) accessible from clients

## Hostnames the BROWSER must resolve

The wildcard below covers everything automatically. If you instead declare
records one by one — or fall back to `/etc/hosts` — these must be present on
**every client machine**, not just on the server.

Do not work from a fixed list — it goes stale. Extract the real one from the
deployment, which is the only authoritative source:

```bash
# swarm: every hostname Traefik actually serves
docker service ls -q | while read s; do
  docker service inspect "$s" --format '{{json .Spec.Labels}}'
done | tr ',' '\n' | grep -o 'Host(`[^`]*`)' | sed 's/Host(`//;s/`)//' | sort -u
```

A real EE deployment returns around twenty names. The ones that matter most:

| Hostname | Edition | Why |
|---|---|---|
| `<domain>` | CE + EE | the Hub itself |
| `dashboard.<domain>` | CE + EE | Grafana, behind the wrapper |
| `flowmaker.<domain>` | CE + EE | FlowMaker |
| `datacatalog-ui.` **and** `datacatalog-api.` | CE + EE | the UI calls the API **from the browser** — both are needed |
| `databridge.` , `cdn.` , `minio.` , `s3.` , `logger.` | CE + EE | called from the browser by the apps that use them |
| **`auth.<domain>`** | **EE only** | **Logto — mandatory** |
| `auth-admin.<domain>` | EE, swarm only | Logto admin console; not needed by end users |

⚠️ **`auth.<domain>` is the one that gets missed.** In EE the Hub runs
`AUTH_METHOD=OAUTH` and the browser is redirected to Logto, so the *client* has to
resolve it — the server being healthy is not enough. When it is missing the Hub
login fails with a bare **`Failed to fetch`**, which points at nothing: the
network, the certificate and the stack are all fine.

The internal URLs (`http://logto:3001/oidc/...`) used by the Hub backend for
discovery, JWKS and userinfo are container-to-container and need no DNS entry —
only the two public names above do.

Whatever hostnames you use, the TLS certificate must cover them. A wildcard
(`*.<domain>`) does; a certificate issued for the apex alone does not.

## Server Configuration

### 1. Configure the Server IP

Modify the `.env` file:

```bash
# Replace with the accessible IP of the server
INDUSTREAM_SERVER_IP=192.168.100.50
```

### 2. Deploy the Stack

```bash
./industream.sh deploy
```

### 3. Verify that dnsmasq is Working

```bash
# From the server
dig @127.0.0.1 dashboard.industream.platform.lan
dig @127.0.0.1 flowmaker.industream.platform.lan
dig @127.0.0.1 anything.industream.platform.lan

# All should resolve to INDUSTREAM_SERVER_IP
```

## Client Configuration

### Option A: System DNS Configuration (recommended)

#### Windows

1. **Control Panel** → **Network and Internet** → **Network and Sharing Center**
2. Click on your active network connection
3. **Properties** → **Internet Protocol Version 4 (TCP/IPv4)** → **Properties**
4. Select "Use the following DNS server address"
5. **Preferred DNS**: `192.168.100.50` (IP of Industream server)
6. **Alternate DNS**: `1.1.1.1` (or corporate DNS)

#### Linux (NetworkManager)

```bash
# Temporary (until restart)
sudo nmcli con mod "Wired connection 1" ipv4.dns "192.168.100.50 1.1.1.1"
sudo nmcli con mod "Wired connection 1" ipv4.ignore-auto-dns yes
sudo nmcli con down "Wired connection 1" && sudo nmcli con up "Wired connection 1"
```

#### Linux (systemd-resolved)

```bash
# Edit /etc/systemd/resolved.conf
[Resolve]
DNS=192.168.100.50
FallbackDNS=1.1.1.1

# Restart
sudo systemctl restart systemd-resolved
```

#### macOS

1. **System Preferences** → **Network**
2. Select your connection → **Advanced** → **DNS**
3. Add `192.168.100.50` first
4. Add `1.1.1.1` as backup

### Option B: Browser-Only Configuration

#### Firefox (Proxy DNS)

1. **Settings** → **General** → **Network Settings**
2. Check "Enable DNS over HTTPS"
3. Or configure a SOCKS proxy with remote DNS resolution

#### Chrome with PAC File

Create a `proxy.pac` file:

```javascript
function FindProxyForURL(url, host) {
    // Resolve *.industream.platform.lan via the server
    if (shExpMatch(host, "*.industream.platform.lan")) {
        return "DIRECT";
    }
    return "DIRECT";
}
```

Deploy the file on an accessible web server and configure Chrome:
- `chrome://settings/system` → **Open proxy settings**
- Configure the PAC file URL

### Option C: Per-Application DNS Configuration

#### curl

```bash
# Use Industream DNS for requests
curl --dns-servers 192.168.100.50 https://dashboard.industream.platform.lan
```

#### Docker (on development machines)

```json
// /etc/docker/daemon.json
{
  "dns": ["192.168.100.50", "1.1.1.1"]
}
```

## Corporate / Air-gapped Configuration

### Scenario: No Internet Access

Modify `config/dnsmasq/dnsmasq.conf`:

```conf
# Replace the upstream DNS servers
# server=1.1.1.1
# server=8.8.8.8

# With corporate DNS servers
server=192.168.1.10
server=192.168.1.11
```

### Scenario: Conditional DNS (zone split)

If corporate DNS already exists and you cannot modify it, use a dedicated zone:

1. Change the domain in `.env`:
```bash
INDUSTREAM_DOMAIN=industream.factory.local
```

2. Configure clients to use dnsmasq only for `.factory.local`

## Troubleshooting

### DNS is Not Resolving

```bash
# Verify that dnsmasq is running
docker service ls | grep dnsmasq

# View logs
docker service logs industream_dnsmasq

# Test the resolution
nslookup dashboard.industream.platform.lan 192.168.100.50
```

### Port 53 Already in Use

```bash
# Identify the process using port 53
sudo lsof -i :53
sudo ss -tulpn | grep :53

# On Ubuntu, systemd-resolved often uses port 53
# Disable if necessary:
sudo systemctl disable systemd-resolved
sudo systemctl stop systemd-resolved
```

### Conflict with System dnsmasq

```bash
# If a system dnsmasq already exists
sudo systemctl stop dnsmasq
sudo systemctl disable dnsmasq
```

## Security

- dnsmasq listens on port 53 (all interfaces)
- In production, configure a firewall to limit access
- Only local network clients should be able to access DNS

```bash
# Example iptables (adapt to your network)
iptables -A INPUT -p udp --dport 53 -s 192.168.100.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 53 -s 192.168.100.0/24 -j ACCEPT
iptables -A INPUT -p udp --dport 53 -j DROP
iptables -A INPUT -p tcp --dport 53 -j DROP
```

## Validation Testing

Once configured, test from a client:

```bash
# All these domains should resolve to INDUSTREAM_SERVER_IP
nslookup industream.platform.lan
nslookup dashboard.industream.platform.lan
nslookup flowmaker.industream.platform.lan
nslookup workers.industream.platform.lan
nslookup grafana.industream.platform.lan

# HTTPS access (with self-signed certificate, accept warning)
curl -k https://dashboard.industream.platform.lan
```
