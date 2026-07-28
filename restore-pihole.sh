#!/bin/bash
# Restore Pi-hole from a backup tarball.
# Stops Pi-hole, replaces config files, restarts it, then rebuilds gravity.
#
# Usage:
#   bash ~/docker/restore-pihole.sh <path-to-backup.tar.gz>
#   bash ~/docker/restore-pihole.sh <path-to-backup.tar.gz> -f   # skip confirmation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIHOLE_DATA="${SCRIPT_DIR}/pihole/etc-pihole"
COMPOSE_FILE="${SCRIPT_DIR}/pihole/docker-compose.yml"
LOG_PREFIX="[pihole-restore]"

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
echo "  │  PI-HOLE RESTORE                                            │"
echo "  │                                                             │"
echo "  │  This will:                                                 │"
echo "  │    1. Stop the Pi-hole container                            │"
echo "  │    2. Replace pihole.toml and custom.list                   │"
echo "  │    3. Restore from: $(basename "$BACKUP_FILE")"
echo "  │    4. Restart Pi-hole                                       │"
echo "  │    5. Rebuild gravity database (pihole -g)                  │"
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

# ── Stop Pi-hole ──────────────────────────────────────────────────────────────

log "Stopping Pi-hole..."
docker compose -f "$COMPOSE_FILE" stop pihole
log "Pi-hole stopped."

# ── Restore config files ──────────────────────────────────────────────────────

log "Restoring config files to: ${PIHOLE_DATA}"
tar -xzf "$BACKUP_FILE" -C "$PIHOLE_DATA"
log "Config files restored."

# ── Restart Pi-hole ───────────────────────────────────────────────────────────

log "Starting Pi-hole..."
docker compose -f "$COMPOSE_FILE" up -d pihole

# Wait up to 15 seconds for the container to become running
for i in $(seq 1 15); do
  STATUS="$(docker inspect -f '{{.State.Status}}' pihole 2>/dev/null || echo 'unknown')"
  [[ "$STATUS" == "running" ]] && break
  sleep 1
done

STATUS="$(docker inspect -f '{{.State.Status}}' pihole 2>/dev/null || echo 'unknown')"
[[ "$STATUS" != "running" ]] && fail "Pi-hole did not come up (status: ${STATUS}). Check logs: docker logs pihole"

log "Pi-hole is running."

# ── Rebuild gravity database ──────────────────────────────────────────────────
# gravity.db is not backed up since it is regenerated from upstream blocklists.

log "Rebuilding gravity database (this takes about a minute)..."
docker exec pihole pihole -g
log "Gravity rebuild complete."

echo ""
echo "  Restore complete. Verify Pi-hole at http://pihole.home"
echo ""
