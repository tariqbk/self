#!/bin/bash
# Daily Pi-hole backup to NAS.
# Backs up pihole.toml and custom.list (local DNS overrides).
# gravity.db is excluded — it can be regenerated with 'pihole -g'.
# Retains backups for 30 days, deleting older ones automatically.
#
# Usage (normally run by cron at 2 AM):
#   bash ~/docker/backup-pihole.sh

set -euo pipefail

PIHOLE_DATA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pihole/etc-pihole"
BACKUP_DIR="/mnt/nas/backups/pihole"
DATE="$(date +%Y-%m-%d-%H-%M)"
ARCHIVE="${BACKUP_DIR}/pihole-${DATE}.tar.gz"
RETAIN_DAYS=30
LOG_PREFIX="[pihole-backup]"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $*"; }

# ── Pre-flight checks ─────────────────────────────────────────────────────────

if ! mountpoint -q /mnt/nas/backups; then
  log "ERROR: /mnt/nas/backups is not mounted. Aborting."
  exit 1
fi

if ! docker inspect pihole > /dev/null 2>&1; then
  log "ERROR: pihole container not found. Is the Pi-hole stack running?"
  exit 1
fi

if [[ ! -d "$PIHOLE_DATA" ]]; then
  log "ERROR: Pi-hole data directory not found: ${PIHOLE_DATA}"
  exit 1
fi

mkdir -p "$BACKUP_DIR"

# ── Bundle config files into archive ─────────────────────────────────────────
# Only pihole.toml and custom.list are backed up.
# gravity.db is excluded — it is regenerated from upstream blocklists on restore.

log "Creating archive: ${ARCHIVE}"
tar -czf "$ARCHIVE" \
  -C "$PIHOLE_DATA" \
  --ignore-failed-read \
  $([ -f "$PIHOLE_DATA/pihole.toml" ] && echo "pihole.toml") \
  $([ -f "$PIHOLE_DATA/custom.list" ] && echo "custom.list")
log "Archive size: $(du -sh "$ARCHIVE" | cut -f1)"

# ── Rotate old backups ────────────────────────────────────────────────────────
# Age is determined from the date embedded in the filename (YYYY-MM-DD),
# not from filesystem mtime — mtime can drift if the Pi's clock is wrong.

log "Removing backups older than ${RETAIN_DAYS} days..."
NOW_SECONDS="$(date +%s)"

while IFS= read -r f; do
  fname="$(basename "$f")"

  # Extract the YYYY-MM-DD portion from e.g. pihole-2026-06-15-02-00.tar.gz
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
done < <(find "$BACKUP_DIR" -name "pihole-*.tar.gz")

REMAINING=$(find "$BACKUP_DIR" -name "pihole-*.tar.gz" | wc -l)
log "Backup rotation complete. ${REMAINING} backup(s) retained."

log "Done. Backup stored at: ${ARCHIVE}"
