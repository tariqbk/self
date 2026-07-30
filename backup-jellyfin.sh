#!/bin/bash
# Daily Jellyfin backup to NAS.
# Triggers Jellyfin's native backup via API (database + metadata), waits for
# it to complete, then copies the resulting zip to the NAS.
# Retains backups for 30 days, deleting older ones automatically.
#
# Usage (normally run by cron at 2 AM):
#   bash ~/docker/backup-jellyfin.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="/mnt/nas/backups/jellyfin"
VOLUME="tunnel-stack_jellyfin_config"
DATE="$(date +%Y-%m-%d-%H-%M)"
RETAIN_DAYS=30
LOG_PREFIX="[jellyfin-backup]"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $*"; }

# ── Read API key ──────────────────────────────────────────────────────────────

ENV_FILE="${SCRIPT_DIR}/tunnel-stack/.env"
[[ ! -f "$ENV_FILE" ]] && { log "ERROR: tunnel-stack/.env not found."; exit 1; }

JELLYFIN_API_KEY="$(grep JELLYFIN_API_KEY "$ENV_FILE" | cut -d= -f2)"
[[ -z "$JELLYFIN_API_KEY" ]] && { log "ERROR: JELLYFIN_API_KEY not set in tunnel-stack/.env"; exit 1; }

JELLYFIN_URL="http://localhost:8096"

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

# ── Trigger native backup via Jellyfin API ────────────────────────────────────
# Jellyfin's backup API creates a zip in /config/data/backups/ inside the
# container. We include database and metadata for a complete restore.

log "Triggering Jellyfin native backup..."
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${JELLYFIN_URL}/Backup/Create" \
  -H "Authorization: MediaBrowser Token=\"${JELLYFIN_API_KEY}\"" \
  -H "Content-Type: application/json" \
  -d '{"BackupOptions": {"Database": true, "MediaEncoding": false, "Metadata": true, "Subtitles": false, "Trickplay": false}}')

if [[ "$RESPONSE" != "204" && "$RESPONSE" != "200" ]]; then
  log "ERROR: Backup API returned HTTP ${RESPONSE}. Is the API key valid?"
  exit 1
fi

log "Backup triggered (HTTP ${RESPONSE}). Waiting for completion..."

# ── Wait for backup zip to appear ─────────────────────────────────────────────
# Poll the volume for a new zip file created within the last 2 minutes.

BACKUP_FILE=""
for i in $(seq 1 30); do
  sleep 5
  BACKUP_FILE=$(docker run --rm \
    -v "${VOLUME}:/config:ro" \
    alpine sh -c "find /config/data/backups -name '*.zip' -newer /config/data/backups -maxdepth 1 2>/dev/null | sort | tail -1" 2>/dev/null || true)
  # Fallback: just get the most recently modified zip
  if [[ -z "$BACKUP_FILE" ]]; then
    BACKUP_FILE=$(docker run --rm \
      -v "${VOLUME}:/config:ro" \
      alpine sh -c "ls -t /config/data/backups/*.zip 2>/dev/null | head -1" 2>/dev/null || true)
  fi
  [[ -n "$BACKUP_FILE" ]] && break
  log "Waiting for backup to complete... (${i}/30)"
done

if [[ -z "$BACKUP_FILE" ]]; then
  log "ERROR: Backup zip not found after 150 seconds."
  exit 1
fi

log "Backup complete: ${BACKUP_FILE}"

# ── Copy to NAS ───────────────────────────────────────────────────────────────

ARCHIVE="${BACKUP_DIR}/jellyfin-${DATE}.zip"
log "Copying to NAS: ${ARCHIVE}"
docker run --rm \
  -v "${VOLUME}:/config:ro" \
  -v "${BACKUP_DIR}:/nas" \
  alpine cp "/config/data/backups/$(basename "$BACKUP_FILE")" "/nas/jellyfin-${DATE}.zip"
log "Archive size: $(du -sh "$ARCHIVE" | cut -f1)"

# ── Rotate old backups ────────────────────────────────────────────────────────
# Age is determined from the date embedded in the filename (YYYY-MM-DD),
# not from filesystem mtime — mtime can drift if the Pi's clock is wrong.

log "Removing backups older than ${RETAIN_DAYS} days..."
NOW_SECONDS="$(date +%s)"

while IFS= read -r f; do
  fname="$(basename "$f")"

  # Extract the YYYY-MM-DD portion from e.g. jellyfin-2026-06-15-02-00.zip
  file_date="$(echo "$fname" | grep -oP '\d{4}-\d{2}-\d{2}')"
  if [[ -z "$file_date" ]]; then
    log "WARN: Could not parse date from filename, skipping: ${fname}"
    continue
  fi

  file_seconds="$(date -d "$file_date" +%s)"
  age_days="$(( (NOW_SECONDS - file_seconds) / 86400 ))"

  if [[ "$age_days" -gt "$RETAIN_DAYS" ]]; then
    log "Deleting ${fname} (${age_days} days old)..."
    rm "$f"
  fi
done < <(find "$BACKUP_DIR" -name "jellyfin-*.zip")

REMAINING=$(find "$BACKUP_DIR" -name "jellyfin-*.zip" | wc -l)
log "Backup rotation complete. ${REMAINING} backup(s) retained."

log "Done. Backup stored at: ${ARCHIVE}"
