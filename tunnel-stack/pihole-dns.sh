#!/bin/bash
# Sets up Pi-hole local DNS entries for all services
# Run after Pi-hole container is healthy
# Usage: ./pihole-dns.sh <pi-ip>

PI_IP="${1:-192.168.68.2}"
PIHOLE_CUSTOM_DNS="/home/tariqbk/docker/pihole/etc-pihole/custom.list"

echo "Writing Pi-hole local DNS entries to $PIHOLE_CUSTOM_DNS..."

# Wait for Pi-hole volume directory to exist
until [ -f "$PIHOLE_CUSTOM_DNS" ] || [ -d "$(dirname $PIHOLE_CUSTOM_DNS)" ]; do
  echo "Waiting for Pi-hole volume to be ready..."
  sleep 3
done

cat > "$PIHOLE_CUSTOM_DNS" <<EOF
$PI_IP pihole.home
$PI_IP portainer.home
$PI_IP vault.home
$PI_IP photos.home
$PI_IP links.home
$PI_IP ha.home
$PI_IP glances.home
EOF

echo "DNS entries written:"
cat "$PIHOLE_CUSTOM_DNS"

# Restart Pi-hole FTL to pick up changes
echo "Restarting Pi-hole FTL..."
docker exec pihole pihole restartdns

echo "Done. Local DNS entries active."
