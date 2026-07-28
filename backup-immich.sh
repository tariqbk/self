#!/bin/bash
# Daily Immich backup to NAS.
# Dumps the full PostgreSQL instance via pg_dumpall — covers the immich
# database and any future databases added to the same instance.
# Photos/videos are excluded — they live on the NAS and are inherently safe.
# The ML model cache is excluded — it is large and regenerates automatically.
# Retains backups for 30 days, deleting older ones automatically.
#
# Usage (normally run by cron at 2 AM):
#   bash ~/docker/backup-immich.sh

set -euo pipefail

BACKUP_DIR="/mnt/nas/backups/immich"
DATE="$(date +%Y-%m-%d-%H-%M)"
ARCHIVE="${BACKUP_DIR}/immich-${DATE}.tar.gz"
TMPDIR="$(mktemp -d)"
RETAIN_DAYS=30
LOG_PREFIX="[immich-backup]"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $*"; }

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# ── Pre-flight checks ─────────────────────────────────────────────────────────

if ! mountpoint -q /mnt/nas/backups; then
  log "ERROR: /mnt/nas/backups is not mounted. Aborting."
  exit 1
fi

if ! docker inspect immich_postgres > /dev/null 2>&1; then
  log "ERROR: immich_postgres container not found. Is the tunnel stack running?"
  exit 1
fi

mkdir -p "$BACKUP_DIR" 2>/dev/null || true

# ── PostgreSQL full dump ──────────────────────────────────────────────────────
# pg_dumpall runs inside a temporary container on tunnel_net so it can reach
# immich-postgres by container name. Dumps all databases in the instance.
# Safe against a live database — no need to stop Immich.

log "Starting pg_dumpall..."
docker run --rm \
  --network tunnel_net \
  -v "${TMPDIR}:/backup" \
  -e PGPASSWORD="${IMMICH_DB_PASSWORD:-}" \
  ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0 \
  pg_dumpall \
    --host=immich-postgres \
    --username=postgres \
    --file=/backup/immich_dump.sql

log "pg_dumpall complete. Dump size: $(du -sh "${TMPDIR}/immich_dump.sql" | cut -f1)"

# ── Bundle into archive ───────────────────────────────────────────────────────

log "Creating archive: ${ARCHIVE}"
tar -czf "$ARCHIVE" -C "$TMPDIR" immich_dump.sql
log "Archive size: $(du -sh "$ARCHIVE" | cut -f1)"

# ── Rotate old backups ────────────────────────────────────────────────────────
# Age is determined from the date embedded in the filename (YYYY-MM-DD),
# not from filesystem mtime — mtime can drift if the Pi's clock is wrong.

log "Removing backups older than ${RETAIN_DAYS} days..."
NOW_SECONDS="$(date +%s)"

while IFS= read -r f; do
  fname="$(basename "$f")"

  # Extract the YYYY-MM-DD portion from e.g. immich-2026-06-15-02-00.tar.gz
  file_date="$(echo "$fname" | grep -oP '\d{4}-\d{2}-\d{2}')"
  if [[ -z "$file_date" ]]; then
    log "WARN: Could not parse date from filename, skipping: ${fname}"
    continue
  fi

  # Convert the file's date to epoch seconds, then compute age in whole days
  file_seconds="$(date -d "$file_date" +%s)"
  age_days="$(( (NOW_SECONDS - file_seconds) / 86400 ))"

  if [[ "$age_days" -gt "$RETAIN_DAYS" ]]; then
    log "Deleting ${fname} (${age_days} days old)..."
    rm "$f"
  fi
done < <(find "$BACKUP_DIR" -name "immich-*.tar.gz")

REMAINING=$(find "$BACKUP_DIR" -name "immich-*.tar.gz" | wc -l)
log "Backup rotation complete. ${REMAINING} backup(s) retained."

log "Done. Backup stored at: ${ARCHIVE}"
