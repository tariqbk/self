#!/bin/bash
# Daily Vaultwarden backup to NAS.
# Performs a live SQLite hot-backup (no downtime) plus all supporting files.
# Retains backups for 30 days, deleting older ones automatically.
#
# Usage (normally run by cron at 2 AM):
#   bash ~/docker/backup-vaultwarden.sh

set -euo pipefail

BACKUP_DIR="/mnt/nas/backups/vaultwarden"
VOLUME="tunnel-stack_vaultwarden_data"
DATE="$(date +%Y-%m-%d-%H-%M)"
ARCHIVE="${BACKUP_DIR}/vaultwarden-${DATE}.tar.gz"
TMPDIR="$(mktemp -d)"
RETAIN_DAYS=30
LOG_PREFIX="[vaultwarden-backup]"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $*"; }

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# ── Pre-flight checks ─────────────────────────────────────────────────────────

if ! mountpoint -q /mnt/nas/backups; then
  log "ERROR: /mnt/nas/backups is not mounted. Aborting."
  exit 1
fi

if ! docker inspect vaultwarden > /dev/null 2>&1; then
  log "ERROR: vaultwarden container not found. Is the tunnel stack running?"
  exit 1
fi

mkdir -p "$BACKUP_DIR" 2>/dev/null || true

# ── SQLite hot-backup ─────────────────────────────────────────────────────────
# Run sqlite3 in a temporary container with read-only access to the volume.
# sqlite3 .backup is safe against a live database — no need to stop Vaultwarden.

log "Starting SQLite hot-backup..."
docker run --rm \
  -v "${VOLUME}:/vw-data:ro" \
  -v "${TMPDIR}:/backup" \
  alpine sh -c "apk add --no-cache --quiet sqlite > /dev/null 2>&1 && \
    sqlite3 /vw-data/db.sqlite3 \".backup '/backup/db.sqlite3'\""
log "SQLite backup complete."

# ── Copy supporting files ─────────────────────────────────────────────────────

log "Copying attachments, sends, and keys..."
docker run --rm \
  -v "${VOLUME}:/vw-data:ro" \
  -v "${TMPDIR}:/backup" \
  alpine sh -c "
    [ -d /vw-data/attachments ] && cp -r /vw-data/attachments /backup/ || true
    [ -d /vw-data/sends ]       && cp -r /vw-data/sends       /backup/ || true
    [ -f /vw-data/config.json ] && cp    /vw-data/config.json /backup/ || true
    cp /vw-data/rsa_key*.pem /backup/ 2>/dev/null || true
  "

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

  # Extract the YYYY-MM-DD portion from e.g. vaultwarden-2026-06-15-02-00.tar.gz
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
done < <(find "$BACKUP_DIR" -name "vaultwarden-*.tar.gz")

REMAINING=$(find "$BACKUP_DIR" -name "vaultwarden-*.tar.gz" | wc -l)
log "Backup rotation complete. ${REMAINING} backup(s) retained."

log "Done. Backup stored at: ${ARCHIVE}"
