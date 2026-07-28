#!/bin/bash
# Brings up the full home server stack. Run after cloning this repo.
#
# Usage:
#   ./setup.sh
#
# Requires secrets.env (gitignored) in the same directory as this script.
# On first boot, cloud-init copies it here from the boot partition. For
# manual reruns/recovery, copy your own secrets.env into place first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -a
# shellcheck disable=SC1091
source "$SCRIPT_DIR/secrets.env"
set +a

# Phase 1: Portainer
echo "==> Starting Portainer..."
docker compose -f "$SCRIPT_DIR/portainer/docker-compose.yml" up -d
echo "==> Portainer started."

# Phase 2: Pi-hole
echo "==> Configuring Pi-hole..."
mkdir -p "$SCRIPT_DIR/pihole/etc-pihole"
cat > "$SCRIPT_DIR/pihole/.env" << EOF
PIHOLE_PASSWORD=${PIHOLE_PASSWORD}
PI_LOCAL_IP=${PI_LOCAL_IP}
EOF
chown -R tariqbk:tariqbk "$SCRIPT_DIR/pihole"
echo "==> Starting Pi-hole..."
docker compose -f "$SCRIPT_DIR/pihole/docker-compose.yml" up -d
echo "==> Pi-hole started."

# Phase 3: Home Assistant
echo "==> Starting Home Assistant..."
mkdir -p "$SCRIPT_DIR/homeassistant/config"
chown -R tariqbk:tariqbk "$SCRIPT_DIR/homeassistant"
docker compose -f "$SCRIPT_DIR/homeassistant/docker-compose.yml" up -d
echo "==> Home Assistant started."

# Phase 4: Glances
echo "==> Starting Glances..."
docker compose -f "$SCRIPT_DIR/glances/docker-compose.yml" up -d
echo "==> Glances started."

# Phase 5: Tunnel stack
echo "==> Mounting NAS shares for Immich, Jellyfin, and backups..."
bash "$SCRIPT_DIR/tunnel-stack/mount-nas.sh" "${NAS_IP}"
echo "==> Configuring tunnel stack..."
cat > "$SCRIPT_DIR/tunnel-stack/.env" << EOF
BASE_DOMAIN=${BASE_DOMAIN}
CLOUDFLARE_TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN}
LINKDING_SUPERUSER=${LINKDING_SUPERUSER}
LINKDING_PASSWORD=${LINKDING_PASSWORD}
IMMICH_DB_USER=${IMMICH_DB_USER}
IMMICH_DB_PASSWORD=${IMMICH_DB_PASSWORD}
IMMICH_PHOTOS_PATH=${IMMICH_PHOTOS_PATH}
JELLYFIN_MEDIA_PATH=${JELLYFIN_MEDIA_PATH}
CLOUDFLARE_DNS_API_TOKEN=${CLOUDFLARE_DNS_API_TOKEN}
SMTP_PASSWORD=${SMTP_PASSWORD}
SMTP_FROM=${SMTP_FROM}
EOF
chown -R tariqbk:tariqbk "$SCRIPT_DIR/tunnel-stack"
echo "==> Starting tunnel stack..."
# vaultwarden_data is declared external so Compose won't create it automatically.
# Create it here if it doesn't already exist (e.g. fresh boot before any restore).
docker volume create tunnel-stack_vaultwarden_data > /dev/null 2>&1 || true
docker compose -f "$SCRIPT_DIR/tunnel-stack/docker-compose.yml" up -d --build
echo "==> Tunnel stack started."

# Backups
echo "==> Setting up backup cron jobs..."
mkdir -p "$SCRIPT_DIR/logs"
chown tariqbk:tariqbk "$SCRIPT_DIR/logs"
chmod +x "$SCRIPT_DIR/backup-vaultwarden.sh"
chmod +x "$SCRIPT_DIR/restore-vaultwarden.sh"
chmod +x "$SCRIPT_DIR/backup-pihole.sh"
chmod +x "$SCRIPT_DIR/restore-pihole.sh"

# Build the full crontab: strip any existing backup jobs, then re-add all of them.
# This makes setup.sh idempotent — re-running it won't duplicate cron entries.
(
  crontab -u tariqbk -l 2>/dev/null | grep -v "backup-vaultwarden\|backup-pihole"
  echo "0 2 * * * bash ${SCRIPT_DIR}/backup-vaultwarden.sh >> ${SCRIPT_DIR}/logs/backup-vaultwarden.log 2>&1"
  echo "0 2 * * * bash ${SCRIPT_DIR}/backup-pihole.sh >> ${SCRIPT_DIR}/logs/backup-pihole.log 2>&1"
) | crontab -u tariqbk -
echo "==> Backup cron jobs installed (daily at 2 AM)."

echo "==> Setup complete."
