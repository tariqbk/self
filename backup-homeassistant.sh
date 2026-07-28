#!/bin/bash
# Daily Home Assistant backup to NAS.
# Backs up all essential config files and directories. Home Assistant keeps
# running during backup — no downtime needed since these are plain files.
# The history database (home-assistant_v2.db) is excluded — it is large and
# regenerates from live data. Logs are also excluded.
# Retains backups for 30 days, deleting older ones automatically.
#
# Usage (normally run by cron at 2 AM):
#   bash ~/docker/backup-homeassistant.sh

set -euo pipefail

HA_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/homeassistant/config"
BACKUP_DIR="/mnt/nas/backups/homeassistant"
DATE="$(date +%Y-%m-%d-%H-%M)"
ARCHIVE="${BACKUP_DIR}/homeassistant-${DATE}.tar.gz"
RETAIN_DAYS=30
LOG_PREFIX="[homeassistant-backup]"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $*"; }

# ── Pre-flight checks ─────────────────────────────────────────────────────────

if ! mountpoint -q /mnt/nas/backups; then
  log "ERROR: /mnt/nas/backups is not mounted. Aborting."
  exit 1
fi

if ! docker inspect homeassistant > /dev/null 2>&1; then
  log "ERROR: homeassistant container not found. Is the stack running?"
  exit 1
fi

if [[ ! -d "$HA_CONFIG" ]]; then
  log "ERROR: Home Assistant config directory not found: ${HA_CONFIG}"
  exit 1
fi

mkdir -p "$BACKUP_DIR" 2>/dev/null || true

# ── Bundle config into archive ────────────────────────────────────────────────
# Includes all essential config files and directories.
# Excludes: home-assistant_v2.db (history, large, regenerates),
#           home-assistant.log and logs/ (not needed for restore),
#           __pycache__ directories.

log "Creating archive: ${ARCHIVE}"
tar -czf "$ARCHIVE" \
  -C "$HA_CONFIG" \
  --exclude="./home-assistant_v2.db" \
  --exclude="./home-assistant.log" \
  --exclude="./logs" \
  --exclude="./__pycache__" \
  --exclude="./*/__pycache__" \
  --ignore-failed-read \
  .
log "Archive size: $(du -sh "$ARCHIVE" | cut -f1)"

# ── Rotate old backups ────────────────────────────────────────────────────────
# Age is determined from the date embedded in the filename (YYYY-MM-DD),
# not from filesystem mtime — mtime can drift if the Pi's clock is wrong.

log "Removing backups older than ${RETAIN_DAYS} days..."
NOW_SECONDS="$(date +%s)"

while IFS= read -r f; do
  fname="$(basename "$f")"

  # Extract the YYYY-MM-DD portion from e.g. homeassistant-2026-06-15-02-00.tar.gz
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
done < <(find "$BACKUP_DIR" -name "homeassistant-*.tar.gz")

REMAINING=$(find "$BACKUP_DIR" -name "homeassistant-*.tar.gz" | wc -l)
log "Backup rotation complete. ${REMAINING} backup(s) retained."

log "Done. Backup stored at: ${ARCHIVE}"
