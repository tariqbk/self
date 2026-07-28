#!/bin/bash
# Restore Linkding from a backup tarball.
# Stops Linkding, replaces all data, then restarts it.
#
# Usage:
#   bash ~/docker/restore-linkding.sh <path-to-backup.tar.gz>
#   bash ~/docker/restore-linkding.sh <path-to-backup.tar.gz> -f   # skip confirmation

set -euo pipefail

VOLUME="tunnel-stack_linkding_data"
COMPOSE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tunnel-stack/docker-compose.yml"
LOG_PREFIX="[linkding-restore]"

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
echo "  │  LINKDING RESTORE                                           │"
echo "  │                                                             │"
echo "  │  This will:                                                 │"
echo "  │    1. Stop the Linkding container                           │"
echo "  │    2. Erase all current data                                │"
echo "  │    3. Restore from: $(basename "$BACKUP_FILE")"
echo "  │    4. Restart Linkding                                      │"
echo "  │                                                             │"
echo "  │  Current data will be REPLACED. This cannot be undone      │"
echo "  │  unless you have another backup.                            │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""

if [[ "$FORCE" != true ]]; then
  read -rp "  Type 'yes' to proceed: " CONFIRM
  [[ "$CONFIRM" != "yes" ]] && { echo "  Aborted."; exit 0; }
  echo ""
fi

# ── Stop Linkding ─────────────────────────────────────────────────────────────

log "Stopping Linkding..."
docker compose -f "$COMPOSE_FILE" stop linkding
log "Linkding stopped."

# ── Extract backup ────────────────────────────────────────────────────────────

log "Extracting backup: ${BACKUP_FILE}"
tar -xzf "$BACKUP_FILE" -C "$TMPDIR"
log "Extraction complete."

# ── Restore into volume ───────────────────────────────────────────────────────

log "Restoring data into volume ${VOLUME}..."
docker run --rm \
  -v "${VOLUME}:/data" \
  -v "${TMPDIR}:/restore:ro" \
  alpine sh -c "
    rm -rf /data/*

    [ -f /restore/db.sqlite3 ] && cp    /restore/db.sqlite3 /data/
    [ -d /restore/assets ]     && cp -r /restore/assets     /data/

    chmod 600 /data/db.sqlite3 2>/dev/null || true
  "
log "Data restored."

# ── Restart Linkding ──────────────────────────────────────────────────────────

log "Starting Linkding..."
# Use 'up -d' rather than 'start' so it creates the container if it was removed
docker compose -f "$COMPOSE_FILE" up -d linkding

# Wait up to 15 seconds for the container to become running
for i in $(seq 1 15); do
  STATUS="$(docker inspect -f '{{.State.Status}}' linkding 2>/dev/null || echo 'unknown')"
  [[ "$STATUS" == "running" ]] && break
  sleep 1
done

STATUS="$(docker inspect -f '{{.State.Status}}' linkding 2>/dev/null || echo 'unknown')"
if [[ "$STATUS" == "running" ]]; then
  log "Linkding is running."
  echo ""
  echo "  Restore complete. Verify Linkding at https://links.tariqbk.com"
  echo ""
else
  fail "Linkding did not come up (status: ${STATUS}). Check logs: docker logs linkding"
fi
