#!/bin/bash
# Restore Vaultwarden from a backup tarball.
# Stops the Vaultwarden container, replaces all data, then restarts it.
#
# Usage:
#   bash ~/docker/restore-vaultwarden.sh <path-to-backup.tar.gz>
#   bash ~/docker/restore-vaultwarden.sh <path-to-backup.tar.gz> -f   # skip confirmation

set -euo pipefail

VOLUME="tunnel-stack_vaultwarden_data"
COMPOSE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tunnel-stack/docker-compose.yml"
LOG_PREFIX="[vaultwarden-restore]"

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
echo "  │  VAULTWARDEN RESTORE                                        │"
echo "  │                                                             │"
echo "  │  This will:                                                 │"
echo "  │    1. Stop the Vaultwarden container                        │"
echo "  │    2. Erase all current vault data                          │"
echo "  │    3. Restore from: $(basename "$BACKUP_FILE")"
echo "  │    4. Restart Vaultwarden                                   │"
echo "  │                                                             │"
echo "  │  Current vault data will be REPLACED. This cannot be       │"
echo "  │  undone unless you have another backup.                     │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""

if [[ "$FORCE" != true ]]; then
  read -rp "  Type 'yes' to proceed: " CONFIRM
  [[ "$CONFIRM" != "yes" ]] && { echo "  Aborted."; exit 0; }
  echo ""
fi

# ── Stop Vaultwarden ──────────────────────────────────────────────────────────

log "Stopping Vaultwarden..."
docker compose -f "$COMPOSE_FILE" stop vaultwarden
log "Vaultwarden stopped."

# ── Extract backup ────────────────────────────────────────────────────────────

log "Extracting backup: ${BACKUP_FILE}"
tar -xzf "$BACKUP_FILE" -C "$TMPDIR"
log "Extraction complete."

# ── Restore into volume ───────────────────────────────────────────────────────

log "Restoring data into volume ${VOLUME}..."
docker run --rm \
  -v "${VOLUME}:/vw-data" \
  -v "${TMPDIR}:/restore:ro" \
  alpine sh -c "
    rm -rf /vw-data/*

    [ -f /restore/db.sqlite3 ]   && cp    /restore/db.sqlite3   /vw-data/
    [ -d /restore/attachments ]  && cp -r /restore/attachments  /vw-data/
    [ -d /restore/sends ]        && cp -r /restore/sends        /vw-data/
    [ -f /restore/config.json ]  && cp    /restore/config.json  /vw-data/
    cp /restore/rsa_key*.pem /vw-data/ 2>/dev/null || true

    chmod 600 /vw-data/db.sqlite3 2>/dev/null || true
    chmod 600 /vw-data/rsa_key*.pem 2>/dev/null || true
  "
log "Data restored."

# ── Restart Vaultwarden ───────────────────────────────────────────────────────

log "Starting Vaultwarden..."
# Use 'up -d' rather than 'start' so it creates the container if it was removed
docker compose -f "$COMPOSE_FILE" up -d vaultwarden

# Wait up to 15 seconds for the container to become healthy/running
for i in $(seq 1 15); do
  STATUS="$(docker inspect -f '{{.State.Status}}' vaultwarden 2>/dev/null || echo 'unknown')"
  [[ "$STATUS" == "running" ]] && break
  sleep 1
done

STATUS="$(docker inspect -f '{{.State.Status}}' vaultwarden 2>/dev/null || echo 'unknown')"
if [[ "$STATUS" == "running" ]]; then
  log "Vaultwarden is running."
  echo ""
  echo "  Restore complete. Verify your vault at https://vault.tariqbk.com"
  echo ""
else
  fail "Vaultwarden did not come up (status: ${STATUS}). Check logs: docker logs vaultwarden"
fi
