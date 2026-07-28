#!/bin/bash
# Daily Linkding backup to NAS.
# Performs a live SQLite hot-backup of the bookmarks database and copies
# the assets directory. Linkding keeps running with no downtime.
# Retains backups for 30 days, deleting older ones automatically.
#
# Usage (normally run by cron at 2 AM):
#   bash ~/docker/backup-linkding.sh

set -euo pipefail

BACKUP_DIR="/mnt/nas/backups/linkding"
VOLUME="tunnel-stack_linkding_data"
DATE="$(date +%Y-%m-%d-%H-%M)"
ARCHIVE="${BACKUP_DIR}/linkding-${DATE}.tar.gz"
TMPDIR="$(mktemp -d)"
RETAIN_DAYS=30
LOG_PREFIX="[linkding-backup]"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $*"; }

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# ── Pre-flight checks ─────────────────────────────────────────────────────────

if ! mountpoint -q /mnt/nas/backups; then
  log "ERROR: /mnt/nas/backups is not mounted. Aborting."
  exit 1
fi

if ! docker inspect linkding > /dev/null 2>&1; then
  log "ERROR: linkding container not found. Is the tunnel stack running?"
  exit 1
fi

mkdir -p "$BACKUP_DIR" 2>/dev/null || true

# ── SQLite hot-backup ─────────────────────────────────────────────────────────
# Run sqlite3 in a temporary container with read-only access to the volume.
# sqlite3 .backup is safe against a live database — no need to stop Linkding.

log "Starting SQLite hot-backup..."
docker run --rm \
  -v "${VOLUME}:/data:ro" \
  -v "${TMPDIR}:/backup" \
  alpine sh -c "apk add --no-cache --quiet sqlite > /dev/null 2>&1 && \
    sqlite3 /data/db.sqlite3 \".backup '/backup/db.sqlite3'\""
log "SQLite backup complete."

# ── Copy assets ───────────────────────────────────────────────────────────────

log "Copying assets..."
docker run --rm \
  -v "${VOLUME}:/data:ro" \
  -v "${TMPDIR}:/backup" \
  alpine sh -c "[ -d /data/assets ] && cp -r /data/assets /backup/ || true"

# ── Bundle into archive ───────────────────────────────────────────────────────

log "Creating archive: ${ARCHIVE}"
tar -czf "$ARCHIVE" -C "$TMPDIR" .
log "Archive size: $(du -sh "$ARCHIVE" | cut -f1)"

# ── Rotate old backups ────────────────────────────────────────────────────────
# Age is determined from the date embedded in the filename (YYYY-MM-DD),
# not from filesystem mtime — mtime can drift if the Pi's clock is wrong.

log "Removing backups older than ${RETAIN_DAYS} days..."
NOW_SECONDS="$(date +%s)"

while IFS= read -r f; do
  fname="$(basename "$f")"

  # Extract the YYYY-MM-DD portion from e.g. linkding-2026-06-15-02-00.tar.gz
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
done < <(find "$BACKUP_DIR" -name "linkding-*.tar.gz")

REMAINING=$(find "$BACKUP_DIR" -name "linkding-*.tar.gz" | wc -l)
log "Backup rotation complete. ${REMAINING} backup(s) retained."

log "Done. Backup stored at: ${ARCHIVE}"
