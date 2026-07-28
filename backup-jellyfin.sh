#!/bin/bash
# Daily Jellyfin backup to NAS.
# Performs live SQLite hot-backups of all databases in the config volume,
# then copies remaining config files. Jellyfin keeps running with no downtime.
# The jellyfin_cache volume is excluded — it regenerates automatically.
# Retains backups for 30 days, deleting older ones automatically.
#
# Usage (normally run by cron at 2 AM):
#   bash ~/docker/backup-jellyfin.sh

set -euo pipefail

BACKUP_DIR="/mnt/nas/backups/jellyfin"
VOLUME="tunnel-stack_jellyfin_config"
DATE="$(date +%Y-%m-%d-%H-%M)"
ARCHIVE="${BACKUP_DIR}/jellyfin-${DATE}.tar.gz"
TMPDIR="$(mktemp -d)"
RETAIN_DAYS=30
LOG_PREFIX="[jellyfin-backup]"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $*"; }

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# ── Pre-flight checks ─────────────────────────────────────────────────────────

if ! mountpoint -q /mnt/nas/backups; then
  log "ERROR: /mnt/nas/backups is not mounted. Aborting."
  exit 1
fi

if ! docker inspect jellyfin > /dev/null 2>&1; then
  log "ERROR: jellyfin container not found. Is the tunnel stack running?"
  exit 1
fi

mkdir -p "$BACKUP_DIR" 2>/dev/null || true

# ── SQLite hot-backup ─────────────────────────────────────────────────────────
# Run sqlite3 in a temporary container with read-only access to the volume.
# sqlite3 .backup is safe against a live database — no need to stop Jellyfin.
# Backs up all .db files found in /config/data/.

log "Starting SQLite hot-backup of all databases..."
docker run --rm \
  -v "${VOLUME}:/config:ro" \
  -v "${TMPDIR}:/backup" \
  alpine sh -c "
    apk add --no-cache --quiet sqlite > /dev/null 2>&1
    mkdir -p /backup/data
    for db in /config/data/*.db; do
      [ -f \"\$db\" ] || continue
      fname=\"\$(basename \"\$db\")\"
      echo \"Backing up \$fname...\"
      sqlite3 \"\$db\" \".backup '/backup/data/\$fname'\"
    done
  "
log "SQLite backup complete."

# ── Copy remaining config files ───────────────────────────────────────────────
# Copies xml config files and plugins. Excludes logs — they are not needed
# for a restore and can be large.

log "Copying config files and plugins..."
docker run --rm \
  -v "${VOLUME}:/config:ro" \
  -v "${TMPDIR}:/backup" \
  alpine sh -c "
    [ -d /config/config ]  && cp -r /config/config  /backup/ || true
    [ -d /config/plugins ] && cp -r /config/plugins /backup/ || true
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

  # Extract the YYYY-MM-DD portion from e.g. jellyfin-2026-06-15-02-00.tar.gz
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
done < <(find "$BACKUP_DIR" -name "jellyfin-*.tar.gz")

REMAINING=$(find "$BACKUP_DIR" -name "jellyfin-*.tar.gz" | wc -l)
log "Backup rotation complete. ${REMAINING} backup(s) retained."

log "Done. Backup stored at: ${ARCHIVE}"
