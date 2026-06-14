#!/bin/bash
# Mounts Synology NAS NFS shares (Immich photos, Jellyfin media)
# Run once before starting the tunnel-stack
# Usage: ./mount-nas.sh <nas-ip>

NAS_IP="${1:-192.168.68.x}"   # Replace with your Synology NAS static IP

echo "Setting up NFS mounts..."

# Install NFS client if not present
if ! dpkg -l | grep -q nfs-common; then
  echo "Installing nfs-common..."
  sudo apt install nfs-common -y
fi

mount_share() {
  local nas_share="$1"
  local mount_point="$2"

  # Create mount point
  sudo mkdir -p "$mount_point"

  # Add to /etc/fstab if not already there
  local fstab_entry="${NAS_IP}:${nas_share} ${mount_point} nfs defaults,_netdev,auto,nofail,x-systemd.automount 0 0"

  if grep -q "$mount_point" /etc/fstab; then
    echo "fstab entry for $mount_point already exists, skipping."
  else
    echo "Adding NFS mount for $mount_point to /etc/fstab..."
    echo "$fstab_entry" | sudo tee -a /etc/fstab
  fi

  # Mount now
  if mountpoint -q "$mount_point"; then
    echo "Already mounted, skipping mount: $mount_point"
  else
    echo "Mounting $mount_point..."
    sudo mount "$mount_point"
  fi

  if mountpoint -q "$mount_point"; then
    echo "NFS mount successful: $mount_point"
  else
    echo "ERROR: Mount failed for $mount_point. Check:"
    echo "  1. NAS IP is correct ($NAS_IP)"
    echo "  2. NFS is enabled on Synology (Control Panel > File Services > NFS)"
    echo "  3. Pi's IP is in the NFS allowed hosts for the $nas_share share"
    echo "  4. Share path is correct ($nas_share)"
    exit 1
  fi
}

mount_share "/volume1/immich" "/mnt/nas/immich"
mount_share "/volume1/media" "/mnt/nas/media"
