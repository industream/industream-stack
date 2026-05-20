#!/bin/bash
# =============================================================================
# OFF-SITE BACKUP SYNC
# =============================================================================
# Rsyncs the local /backups tree to a remote SSH host so that a primary-host
# loss doesn't wipe out all the backups too. Designed to run *after* all the
# per-component backup jobs have completed for the day.
#
# Expected env (set in docker-stack.backup.yml or .env):
#   OFFSITE_ENABLED       — "true" to enable; anything else exits 0 cleanly.
#   OFFSITE_HOST          — DNS or IP of the remote
#   OFFSITE_USER          — SSH user
#   OFFSITE_PATH          — remote directory (created if missing)
#   OFFSITE_PORT          — SSH port (default 22)
#   OFFSITE_SSH_KEY_FILE  — path to the private key (mounted via secret)
#   OFFSITE_BANDWIDTH_KBPS — optional rsync --bwlimit value, in KB/s
#
# Operates in additive mode (no --delete) so a corrupted source can't wipe
# the remote. Retention on the remote is the responsibility of the remote
# host's own housekeeping (or a separate cleanup script).
# =============================================================================

set -uo pipefail

OFFSITE_ENABLED="${OFFSITE_ENABLED:-false}"
OFFSITE_HOST="${OFFSITE_HOST:-}"
OFFSITE_USER="${OFFSITE_USER:-}"
OFFSITE_PATH="${OFFSITE_PATH:-}"
OFFSITE_PORT="${OFFSITE_PORT:-22}"
OFFSITE_SSH_KEY_FILE="${OFFSITE_SSH_KEY_FILE:-/run/secrets/offsite_ssh_key}"
OFFSITE_BANDWIDTH_KBPS="${OFFSITE_BANDWIDTH_KBPS:-0}"

BACKUP_DIR="${BACKUP_DIR:-/backups}"
NTFY_URL="${NTFY_URL:-http://ntfy:80}"
NTFY_TOPIC="${NTFY_TOPIC:-industream-backups}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

notify() {
    local title="$1" body="$2" priority="${3:-default}" tags="${4:-}"
    if [ -n "$NTFY_URL" ] && [ -n "$NTFY_TOPIC" ]; then
        wget -qO- --post-data="$body" \
            --header="Title: ${title}" \
            --header="Priority: ${priority}" \
            --header="Tags: ${tags}" \
            "${NTFY_URL}/${NTFY_TOPIC}" >/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
if [ "$OFFSITE_ENABLED" != "true" ]; then
    log "OFFSITE_ENABLED!=true — off-site sync disabled, skipping."
    exit 0
fi

for var in OFFSITE_HOST OFFSITE_USER OFFSITE_PATH; do
    if [ -z "${!var}" ]; then
        log_error "$var is empty but OFFSITE_ENABLED=true. Aborting."
        notify "Off-site sync misconfigured" "missing $var" urgent "rotating_light,backup"
        exit 1
    fi
done

if [ ! -f "$OFFSITE_SSH_KEY_FILE" ]; then
    log_error "SSH key not mounted at $OFFSITE_SSH_KEY_FILE"
    notify "Off-site sync FAILED" "missing SSH key secret" urgent "rotating_light,backup"
    exit 1
fi

# Copy the key into a writable location with the right perms (secrets are
# mounted read-only with broad perms which OpenSSH refuses to use).
KEY_TMP="$(mktemp)"
cp "$OFFSITE_SSH_KEY_FILE" "$KEY_TMP"
chmod 600 "$KEY_TMP"
trap 'rm -f "$KEY_TMP"' EXIT

SSH_OPTS=(
    -i "$KEY_TMP"
    -p "$OFFSITE_PORT"
    -o StrictHostKeyChecking=accept-new
    -o BatchMode=yes
    -o ConnectTimeout=15
)

# -----------------------------------------------------------------------------
# Ensure remote path exists
# -----------------------------------------------------------------------------
log "Ensuring remote path '${OFFSITE_PATH}' exists on ${OFFSITE_HOST}"
if ! ssh "${SSH_OPTS[@]}" "${OFFSITE_USER}@${OFFSITE_HOST}" "mkdir -p '${OFFSITE_PATH}'"; then
    log_error "Failed to reach ${OFFSITE_USER}@${OFFSITE_HOST}:${OFFSITE_PORT}"
    notify "Off-site sync FAILED" "cannot SSH to ${OFFSITE_HOST}" urgent "rotating_light,backup"
    exit 1
fi

# -----------------------------------------------------------------------------
# Sync
# -----------------------------------------------------------------------------
START=$(date +%s)
RSYNC_OPTS=(
    -avh
    --partial
    --stats
    -e "ssh ${SSH_OPTS[*]}"
)
if [ "$OFFSITE_BANDWIDTH_KBPS" -gt 0 ]; then
    RSYNC_OPTS+=(--bwlimit="${OFFSITE_BANDWIDTH_KBPS}")
fi

log "Starting rsync ${BACKUP_DIR}/ → ${OFFSITE_USER}@${OFFSITE_HOST}:${OFFSITE_PATH}/"
if rsync "${RSYNC_OPTS[@]}" "${BACKUP_DIR}/" "${OFFSITE_USER}@${OFFSITE_HOST}:${OFFSITE_PATH}/"; then
    DURATION=$(( $(date +%s) - START ))
    SIZE_H=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    log "Off-site sync OK in ${DURATION}s (${SIZE_H} on-disk source)"
    notify "Off-site sync OK" \
        "Synced ${SIZE_H} to ${OFFSITE_HOST}:${OFFSITE_PATH} in ${DURATION}s" \
        low "white_check_mark,backup"
    exit 0
else
    log_error "rsync exited with non-zero"
    notify "Off-site sync FAILED" "rsync exit != 0 — check container logs" urgent "rotating_light,backup"
    exit 1
fi
