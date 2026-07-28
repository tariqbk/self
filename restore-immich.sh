#!/bin/bash
# Restore Immich from a backup tarball.
# Stops Immich services, restores the PostgreSQL dump, then restarts everything.
# Photos/videos on the NAS are untouched — only the database is restored.
# ML re-indexing happens automatically in the background after restart.
#
# Usage:
#   bash ~/docker/restore-immich.sh <path-to-backup.tar.gz>
#   bash ~/docker/restore-immich.sh <path-to-backup.tar.gz> -f   # skip confirmation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/tunnel-stack/docker-compose.yml"
LOG_PREFIX="[immich-restore]"

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

if ! docker inspect immich_postgres > /dev/null 2>&1; then
  fail "immich_postgres container not found. Is the tunnel stack running?"
fi

# Read DB password from the tunnel-stack .env
IMMICH_DB_USER="$(grep IMMICH_DB_USER "${SCRIPT_DIR}/tunnel-stack/.env" | cut -d= -f2)"
IMMICH_DB_PASSWORD="$(grep IMMICH_DB_PASSWORD "${SCRIPT_DIR}/tunnel-stack/.env" | cut -d= -f2)"
[[ -z "$IMMICH_DB_USER" || -z "$IMMICH_DB_PASSWORD" ]] && fail "Could not read DB credentials from tunnel-stack/.env"

BACKUP_FILE="$(realpath "$BACKUP_FILE")"
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# ── Confirmation ──────────────────────────────────────────────────────────────

echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │  IMMICH RESTORE                                             │"
echo "  │                                                             │"
echo "  │  This will:                                                 │"
echo "  │    1. Stop Immich server and machine learning               │"
echo "  │    2. Drop and recreate all databases                       │"
echo "  │    3. Restore from: $(basename "$BACKUP_FILE")"
echo "  │    4. Restart all Immich services                           │"
echo "  │                                                             │"
echo "  │  Photos on the NAS are NOT affected.                        │"
echo "  │  ML re-indexing will run automatically after restart.       │"
echo "  │                                                             │"
echo "  │  Current database will be REPLACED. This cannot be undone  │"
echo "  │  unless you have another backup.                            │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""

if [[ "$FORCE" != true ]]; then
  read -rp "  Type 'yes' to proceed: " CONFIRM
  [[ "$CONFIRM" != "yes" ]] && { echo "  Aborted."; exit 0; }
  echo ""
fi

# ── Stop Immich app services (leave postgres running) ─────────────────────────

log "Stopping Immich server and machine learning..."
docker compose -f "$COMPOSE_FILE" stop immich-server immich-machine-learning
log "Immich app services stopped."

# ── Extract backup ────────────────────────────────────────────────────────────

log "Extracting backup: ${BACKUP_FILE}"
tar -xzf "$BACKUP_FILE" -C "$TMPDIR"
log "Extraction complete."

# ── Restore database ──────────────────────────────────────────────────────────
# Drop and recreate the immich database, then restore from the SQL dump.
# pg_dumpall output includes CREATE DATABASE statements, so we restore
# against the postgres database (not immich directly).

log "Dropping and recreating immich database..."
docker run --rm \
  --network tunnel_net \
  -e PGPASSWORD="${IMMICH_DB_PASSWORD}" \
  ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0 \
  psql \
    --host=immich-postgres \
    --username="${IMMICH_DB_USER}" \
    --dbname=postgres \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='immich';" \
    -c "DROP DATABASE IF EXISTS immich;" \
    -c "CREATE DATABASE immich OWNER ${IMMICH_DB_USER};"

log "Restoring from SQL dump..."
docker run --rm \
  --network tunnel_net \
  -v "${TMPDIR}:/restore:ro" \
  -e PGPASSWORD="${IMMICH_DB_PASSWORD}" \
  ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0 \
  psql \
    --host=immich-postgres \
    --username="${IMMICH_DB_USER}" \
    --dbname=immich \
    --file=/restore/immich_dump.sql

log "Database restored."

# ── Restart Immich services ───────────────────────────────────────────────────

log "Starting Immich services..."
docker compose -f "$COMPOSE_FILE" up -d immich-server immich-machine-learning

# Wait up to 15 seconds for immich-server to become running
for i in $(seq 1 15); do
  STATUS="$(docker inspect -f '{{.State.Status}}' immich_server 2>/dev/null || echo 'unknown')"
  [[ "$STATUS" == "running" ]] && break
  sleep 1
done

STATUS="$(docker inspect -f '{{.State.Status}}' immich_server 2>/dev/null || echo 'unknown')"
if [[ "$STATUS" == "running" ]]; then
  log "Immich is running."
  echo ""
  echo "  Restore complete. Verify Immich at https://immich.tariqbk.com"
  echo "  ML re-indexing will run automatically in the background."
  echo ""
else
  fail "Immich server did not come up (status: ${STATUS}). Check logs: docker logs immich_server"
fi
