#!/bin/bash
# Mounts Synology NAS NFS share for Immich photo storage
# Run once before starting the tunnel-stack
# Usage: ./mount-nas.sh <nas-ip>

NAS_IP="${1:-192.168.68.x}"   # Replace with your Synology NAS static IP
NAS_SHARE="/volume1/immich"   # Synology share path - update if different
MOUNT_POINT="/mnt/nas/immich"

echo "Setting up NFS mount for Immich..."

# Install NFS client if not present
if ! dpkg -l | grep -q nfs-common; then
  echo "Installing nfs-common..."
  sudo apt install nfs-common -y
fi

# Create mount point
sudo mkdir -p "$MOUNT_POINT"

# Add to /etc/fstab if not already there
FSTAB_ENTRY="${NAS_IP}:${NAS_SHARE} ${MOUNT_POINT} nfs defaults,_netdev,auto,nofail,x-systemd.automount 0 0"

if grep -q "$MOUNT_POINT" /etc/fstab; then
  echo "fstab entry already exists, skipping."
else
  echo "Adding NFS mount to /etc/fstab..."
  echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
fi

# Mount now
if mountpoint -q "$MOUNT_POINT"; then
  echo "Already mounted, skipping mount."
else
  echo "Mounting NFS share..."
  sudo mount "$MOUNT_POINT"
fi

if mountpoint -q "$MOUNT_POINT"; then
  echo "NFS mount successful: $MOUNT_POINT"
else
  echo "ERROR: Mount failed. Check:"
  echo "  1. NAS IP is correct ($NAS_IP)"
  echo "  2. NFS is enabled on Synology (Control Panel > File Services > NFS)"
  echo "  3. Pi's IP is in the NFS allowed hosts for the immich share"
  echo "  4. Share path is correct ($NAS_SHARE)"
  exit 1
fi
