#!/bin/bash
# Restore Jellyfin from a backup tarball.
# Stops Jellyfin, replaces all config data, then restarts it.
#
# Usage:
#   bash ~/docker/restore-jellyfin.sh <path-to-backup.tar.gz>
#   bash ~/docker/restore-jellyfin.sh <path-to-backup.tar.gz> -f   # skip confirmation

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

[[ -z "$BACKUP_FILE" ]] && fail "No backup file specified.\nUsage: $0 <path-to-backup.tar.gz> [-f]"
[[ ! -f "$BACKUP_FILE" ]] && fail "Backup file not found: ${BACKUP_FILE}"

# ── Pre-flight checks ─────────────────────────────────────────────────────────

if ! mountpoint -q /mnt/nas/backups; then
  fail "/mnt/nas/backups is not mounted. Mount the NAS first."
fi

BACKUP_FILE="$(realpath "$BACKUP_FILE")"
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# ── Confirmation ──────────────────────────────────────────────────────────────

echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │  JELLYFIN RESTORE                                           │"
echo "  │                                                             │"
echo "  │  This will:                                                 │"
echo "  │    1. Stop the Jellyfin container                           │"
echo "  │    2. Erase all current config data                         │"
echo "  │    3. Restore from: $(basename "$BACKUP_FILE")"
echo "  │    4. Restart Jellyfin                                      │"
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

# ── Extract backup ────────────────────────────────────────────────────────────

log "Extracting backup: ${BACKUP_FILE}"
tar -xzf "$BACKUP_FILE" -C "$TMPDIR"
log "Extraction complete."

# ── Restore into volume ───────────────────────────────────────────────────────

log "Restoring data into volume ${VOLUME}..."
docker run --rm \
  -v "${VOLUME}:/config" \
  -v "${TMPDIR}:/restore:ro" \
  alpine sh -c "
    rm -rf /config/*

    [ -d /restore/data ]     && cp -r /restore/data     /config/
    [ -d /restore/config ]   && cp -r /restore/config   /config/
    [ -d /restore/plugins ]  && cp -r /restore/plugins  /config/
    [ -d /restore/metadata ] && cp -r /restore/metadata /config/
  "
log "Data restored."

# ── Restart Jellyfin ──────────────────────────────────────────────────────────

log "Starting Jellyfin..."
# Use 'up -d' rather than 'start' so it creates the container if it was removed
docker compose -f "$COMPOSE_FILE" up -d jellyfin

# Wait up to 15 seconds for the container to become running
for i in $(seq 1 15); do
  STATUS="$(docker inspect -f '{{.State.Status}}' jellyfin 2>/dev/null || echo 'unknown')"
  [[ "$STATUS" == "running" ]] && break
  sleep 1
done

STATUS="$(docker inspect -f '{{.State.Status}}' jellyfin 2>/dev/null || echo 'unknown')"
if [[ "$STATUS" == "running" ]]; then
  log "Jellyfin is running."
  echo ""
  echo "  Restore complete. Verify Jellyfin at https://jellyfin.tariqbk.com"
  echo ""
else
  fail "Jellyfin did not come up (status: ${STATUS}). Check logs: docker logs jellyfin"
fi
