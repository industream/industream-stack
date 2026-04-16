#!/bin/bash
# =============================================================================
# GENERATE SANs
# =============================================================================
# Extracts all subdomain prefixes used in Host(`<prefix>.${INDUSTREAM_DOMAIN}`)
# rules across docker-stack.*.yml files and traefik-dynamic.yml.template.
#
# Output: one subdomain prefix per line on stdout (sorted, unique).
#
# Used by deploy-traefik.sh to build the SAN list for the Let's Encrypt
# defaultGeneratedCert — one certificate covering all hostnames instead of
# one per service, to stay under Let's Encrypt's 50-certs-per-week-per-
# registered-domain rate limit.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../.."

cd "$PROJECT_DIR"

# Match Host(`<prefix>.${INDUSTREAM_DOMAIN...`) and extract <prefix>
# - Only subdomain prefixes (exclude bare ${INDUSTREAM_DOMAIN} which would
#   match starting with a non-alphanumeric character).
# - Supports multi-part prefixes with dots (e.g. databridge-pg).
grep -hoE 'Host\(`[a-zA-Z0-9_-]+\.' docker-stack*.yml traefik-dynamic/*.template 2>/dev/null \
  | sed -E 's/^Host\(`([^.]+)\..*/\1/' \
  | sort -u
