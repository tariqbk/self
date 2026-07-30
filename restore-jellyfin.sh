#!/bin/bash
# Restore Jellyfin from a native backup zip (created by Jellyfin's backup API).
# Stops Jellyfin, restores the zip into the config volume, then restarts it.
#
# Usage:
#   bash ~/docker/restore-jellyfin.sh <path-to-backup.zip>
#   bash ~/docker/restore-jellyfin.sh <path-to-backup.zip> -f   # skip confirmation

set -euo pipefail

VOLUME="tunnel-stack_jellyfin_config"
COMPOSE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tunnel-stack/docker-compose.yml"
LOG_PREFIX="[jellyfin-restore]"

log()  { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $*"; }
fail() { log "ERROR: $*"; exit 1; }

# ── Arguments ─────────────────────────────────────────────────────────────────

BACKUP_FILE="${1:-}"
FORCE=false
for arg in "$@"; do [[ "$arg" == "-f" ]] && FORCE=true; done

[[ -z "$BACKUP_FILE" ]] && fail "No backup file specified.\nUsage: $0 <path-to-backup.zip> [-f]"
[[ ! -f "$BACKUP_FILE" ]] && fail "Backup file not found: ${BACKUP_FILE}"

BACKUP_FILE="$(realpath "$BACKUP_FILE")"

# ── Confirmation ──────────────────────────────────────────────────────────────

echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │  JELLYFIN RESTORE                                           │"
echo "  │                                                             │"
echo "  │  This will:                                                 │"
echo "  │    1. Stop the Jellyfin container                           │"
echo "  │    2. Place the backup zip into the config volume           │"
echo "  │    3. Restart Jellyfin (it will restore on startup)         │"
echo "  │    3. Restore from: $(basename "$BACKUP_FILE")"
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

# ── Stop Jellyfin ─────────────────────────────────────────────────────────────

log "Stopping Jellyfin..."
docker compose -f "$COMPOSE_FILE" stop jellyfin
log "Jellyfin stopped."

# ── Place zip into volume for Jellyfin to restore on startup ──────────────────
# Jellyfin's native restore works by placing the zip back into /config/data/backups/
# and then using the dashboard to trigger restore — OR by resetting config and
# letting Jellyfin pick up the zip on startup via its restore prompt.
# We wipe the config volume and place only the zip so Jellyfin presents the
# restore screen on first launch.

log "Placing backup zip into volume ${VOLUME}..."
BACKUP_FILENAME="$(basename "$BACKUP_FILE")"
docker run --rm \
  -v "${VOLUME}:/config" \
  -v "$(dirname "$BACKUP_FILE"):/source:ro" \
  alpine sh -c "
    rm -rf /config/*
    mkdir -p /config/data/backups
    cp /source/${BACKUP_FILENAME} /config/data/backups/${BACKUP_FILENAME}
  "
log "Backup zip placed."

# ── Restart Jellyfin ──────────────────────────────────────────────────────────

log "Starting Jellyfin..."
# Use 'up -d' rather than 'start' so it creates the container if it was removed
docker compose -f "$COMPOSE_FILE" up -d jellyfin

# Wait up to 30 seconds for the container to become running
for i in $(seq 1 30); do
  STATUS="$(docker inspect -f '{{.State.Status}}' jellyfin 2>/dev/null || echo 'unknown')"
  [[ "$STATUS" == "running" ]] && break
  sleep 1
done

STATUS="$(docker inspect -f '{{.State.Status}}' jellyfin 2>/dev/null || echo 'unknown')"
if [[ "$STATUS" == "running" ]]; then
  log "Jellyfin is running."
  echo ""
  echo "  Next steps:"
  echo "    1. Open https://jellyfin.tariqbk.com"
  echo "    2. Jellyfin will show a restore prompt — select the backup to restore."
  echo "    3. After restore completes, Jellyfin will restart automatically."
  echo ""
else
  fail "Jellyfin did not come up (status: ${STATUS}). Check logs: docker logs jellyfin"
fi
