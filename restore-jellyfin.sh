#!/bin/bash
# Restore Jellyfin from a native backup zip (created by Jellyfin's backup API).
# Fully automated: places the zip, boots Jellyfin, completes the setup wizard
# via API, triggers restore, and waits for Jellyfin to come back up.
#
# Usage:
#   bash ~/docker/restore-jellyfin.sh <path-to-backup.zip>
#   bash ~/docker/restore-jellyfin.sh <path-to-backup.zip> -f   # skip confirmation

set -euo pipefail

VOLUME="tunnel-stack_jellyfin_config"
COMPOSE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tunnel-stack/docker-compose.yml"
LOG_PREFIX="[jellyfin-restore]"
JELLYFIN_URL="http://localhost:8096"

# Temporary admin created just to authenticate and trigger the restore.
# The restore overwrites this account with the backed-up users.
TEMP_USER="restore-admin"
TEMP_PASS="Restore-$(date +%s)!"

log()  { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $*"; }
fail() { log "ERROR: $*"; exit 1; }

# ── Arguments ─────────────────────────────────────────────────────────────────

BACKUP_FILE="${1:-}"
FORCE=false
for arg in "$@"; do [[ "$arg" == "-f" ]] && FORCE=true; done

[[ -z "$BACKUP_FILE" ]] && fail "No backup file specified.\nUsage: $0 <path-to-backup.zip> [-f]"
[[ ! -f "$BACKUP_FILE" ]] && fail "Backup file not found: ${BACKUP_FILE}"

BACKUP_FILE="$(realpath "$BACKUP_FILE")"
BACKUP_FILENAME="$(basename "$BACKUP_FILE")"

# ── Confirmation ──────────────────────────────────────────────────────────────

echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │  JELLYFIN RESTORE                                           │"
echo "  │                                                             │"
echo "  │  This will:                                                 │"
echo "  │    1. Stop Jellyfin and wipe its config volume              │"
echo "  │    2. Place the backup zip into the volume                  │"
echo "  │    3. Boot Jellyfin and complete the setup wizard via API   │"
echo "  │    4. Trigger the native restore via API                    │"
echo "  │    5. Wait for Jellyfin to restart with restored data       │"
echo "  │                                                             │"
echo "  │  Restore from: $(basename "$BACKUP_FILE")"
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

# ── Stop Jellyfin ─────────────────────────────────────────────────────────────

log "Stopping Jellyfin..."
docker compose -f "$COMPOSE_FILE" stop jellyfin
log "Jellyfin stopped."

# ── Place zip into volume ─────────────────────────────────────────────────────

log "Wiping config volume and placing backup zip..."
docker run --rm \
  -v "${VOLUME}:/config" \
  -v "$(dirname "$BACKUP_FILE"):/source:ro" \
  alpine sh -c "
    rm -rf /config/*
    mkdir -p /config/data/backups
    cp /source/${BACKUP_FILENAME} /config/data/backups/${BACKUP_FILENAME}
  "
log "Backup zip placed at /config/data/backups/${BACKUP_FILENAME}"

# ── Start Jellyfin ────────────────────────────────────────────────────────────

log "Starting Jellyfin..."
docker compose -f "$COMPOSE_FILE" up -d jellyfin

log "Waiting for Jellyfin to be ready..."
for i in $(seq 1 60); do
  if curl -sf "${JELLYFIN_URL}/health" > /dev/null 2>&1; then
    break
  fi
  sleep 2
  [[ "$i" -eq 60 ]] && fail "Jellyfin did not become ready in time. Check: docker logs jellyfin"
done
log "Jellyfin is up."

# ── Wait for startup wizard to be ready ───────────────────────────────────────
# Jellyfin reports /health OK before the wizard API is initialized.
# Poll GET /Startup/Configuration until it returns 200.

log "Waiting for startup wizard to be ready..."
for i in $(seq 1 30); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${JELLYFIN_URL}/Startup/Configuration")
  [[ "$STATUS" == "200" ]] && break
  sleep 2
  [[ "$i" -eq 30 ]] && fail "Startup wizard did not become ready in time."
done
log "Startup wizard is ready."

# ── Complete setup wizard via API ─────────────────────────────────────────────
# These endpoints are unauthenticated — only available during first-run wizard.
# The GET /Startup/User call is required to prime the wizard state before POST.

log "Completing setup wizard..."

curl -sf -X POST "${JELLYFIN_URL}/Startup/Configuration" \
  -H "Content-Type: application/json" \
  -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' \
  > /dev/null || fail "POST /Startup/Configuration failed"

curl -sf "${JELLYFIN_URL}/Startup/User" > /dev/null \
  || fail "GET /Startup/User failed"

curl -sf -X POST "${JELLYFIN_URL}/Startup/User" \
  -H "Content-Type: application/json" \
  -d "{\"Name\":\"${TEMP_USER}\",\"Password\":\"${TEMP_PASS}\"}" \
  > /dev/null || fail "POST /Startup/User failed"

curl -sf -X POST "${JELLYFIN_URL}/Startup/RemoteAccess" \
  -H "Content-Type: application/json" \
  -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' \
  > /dev/null || fail "POST /Startup/RemoteAccess failed"

curl -sf -X POST "${JELLYFIN_URL}/Startup/Complete" > /dev/null \
  || fail "POST /Startup/Complete failed"

log "Setup wizard complete."

# ── Authenticate to get a token ───────────────────────────────────────────────

log "Authenticating as temporary admin..."
AUTH_RESPONSE=$(curl -sf -X POST "${JELLYFIN_URL}/Users/AuthenticateByName" \
  -H "Content-Type: application/json" \
  -H 'X-Emby-Authorization: MediaBrowser Client="restore-script", Device="pi", DeviceId="restore", Version="1.0"' \
  -d "{\"Username\":\"${TEMP_USER}\",\"Pw\":\"${TEMP_PASS}\"}")

TOKEN=$(echo "$AUTH_RESPONSE" | grep -o '"AccessToken":"[^"]*"' | cut -d'"' -f4)
[[ -z "$TOKEN" ]] && fail "Failed to authenticate. Response: ${AUTH_RESPONSE}"
log "Authenticated."

# ── Trigger restore ───────────────────────────────────────────────────────────

log "Triggering restore from ${BACKUP_FILENAME}..."
RESTORE_HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${JELLYFIN_URL}/Backup/Restore" \
  -H "Authorization: MediaBrowser Token=\"${TOKEN}\"" \
  -H "Content-Type: application/json" \
  -d "{\"ArchiveFileName\":\"${BACKUP_FILENAME}\"}")

[[ "$RESTORE_HTTP" != "204" ]] && fail "Restore API returned HTTP ${RESTORE_HTTP}. Check: docker logs jellyfin"
log "Restore triggered. Waiting for Jellyfin to restart..."

# Jellyfin restarts itself after restore — wait for it to go down then come back up
sleep 5
for i in $(seq 1 60); do
  if curl -sf "${JELLYFIN_URL}/health" > /dev/null 2>&1; then
    break
  fi
  sleep 3
  [[ "$i" -eq 60 ]] && fail "Jellyfin did not come back up after restore. Check: docker logs jellyfin"
done

log "Jellyfin is back up."
echo ""
echo "  Restore complete. Log in at https://jellyfin.tariqbk.com"
echo "  with your original credentials."
echo ""
