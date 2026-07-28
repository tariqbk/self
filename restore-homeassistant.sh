#!/bin/bash
# Restore Home Assistant from a backup tarball.
# Stops Home Assistant, replaces config files, then restarts it.
#
# Usage:
#   bash ~/docker/restore-homeassistant.sh <path-to-backup.tar.gz>
#   bash ~/docker/restore-homeassistant.sh <path-to-backup.tar.gz> -f   # skip confirmation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HA_CONFIG="${SCRIPT_DIR}/homeassistant/config"
COMPOSE_FILE="${SCRIPT_DIR}/homeassistant/docker-compose.yml"
LOG_PREFIX="[homeassistant-restore]"

log()  { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $*"; }
fail() { log "ERROR: $*"; exit 1; }

# ── Arguments ─────────────────────────────────────────────────────────────────

BACKUP_FILE="${1:-}"
FORCE=false
for arg in "$@"; do [[ "$arg" == "-f" ]] && FORCE=true; done

[[ -z "$BACKUP_FILE" ]] && fail "No backup file specified.\nUsage: $0 <path-to-backup.tar.gz> [-f]"
[[ ! -f "$BACKUP_FILE" ]] && fail "Backup file not found: ${BACKUP_FILE}"

# ── Pre-flight checks ─────────────────────────────────────────────────────────

if ! mountpoint -q /mnt/nas/backups; then
  fail "/mnt/nas/backups is not mounted. Mount the NAS first."
fi

BACKUP_FILE="$(realpath "$BACKUP_FILE")"

# ── Confirmation ──────────────────────────────────────────────────────────────

echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │  HOME ASSISTANT RESTORE                                     │"
echo "  │                                                             │"
echo "  │  This will:                                                 │"
echo "  │    1. Stop the Home Assistant container                     │"
echo "  │    2. Replace all config files                              │"
echo "  │    3. Restore from: $(basename "$BACKUP_FILE")"
echo "  │    4. Restart Home Assistant                                │"
echo "  │                                                             │"
echo "  │  Current config will be REPLACED. This cannot be undone    │"
echo "  │  unless you have another backup.                            │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""

if [[ "$FORCE" != true ]]; then
  read -rp "  Type 'yes' to proceed: " CONFIRM
  [[ "$CONFIRM" != "yes" ]] && { echo "  Aborted."; exit 0; }
  echo ""
fi

# ── Stop Home Assistant ───────────────────────────────────────────────────────

log "Stopping Home Assistant..."
docker compose -f "$COMPOSE_FILE" stop homeassistant
log "Home Assistant stopped."

# ── Restore config files ──────────────────────────────────────────────────────
# Extracts directly into the bind mount directory, preserving file ownership.

log "Restoring config files to: ${HA_CONFIG}"
# Remove existing config files but preserve the history database and logs
# in case they are useful for debugging after restore.
find "$HA_CONFIG" \
  -mindepth 1 \
  ! -name "home-assistant_v2.db" \
  ! -name "home-assistant.log" \
  ! -name "logs" \
  -maxdepth 1 \
  -exec rm -rf {} + 2>/dev/null || true

tar -xzf "$BACKUP_FILE" -C "$HA_CONFIG"
log "Config files restored."

# ── Restart Home Assistant ────────────────────────────────────────────────────

log "Starting Home Assistant..."
docker compose -f "$COMPOSE_FILE" up -d homeassistant

# Wait up to 15 seconds for the container to become running
for i in $(seq 1 15); do
  STATUS="$(docker inspect -f '{{.State.Status}}' homeassistant 2>/dev/null || echo 'unknown')"
  [[ "$STATUS" == "running" ]] && break
  sleep 1
done

STATUS="$(docker inspect -f '{{.State.Status}}' homeassistant 2>/dev/null || echo 'unknown')"
if [[ "$STATUS" == "running" ]]; then
  log "Home Assistant is running."
  echo ""
  echo "  Restore complete. Verify Home Assistant at http://ha.home:8123"
  echo ""
else
  fail "Home Assistant did not come up (status: ${STATUS}). Check logs: docker logs homeassistant"
fi
