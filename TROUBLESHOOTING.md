# Troubleshooting Reference

## General Pi health

```bash
# Check all running containers
docker ps

# Check a container's logs
docker logs <container_name> --tail 50

# Follow logs live
docker logs <container_name> -f
```

---

## DNS (Mac)

```bash
# Check what DNS server your Mac is using
scutil --dns | head -30

# Check which nameserver is active per interface
scutil --dns | grep nameserver

# Test DNS resolution (uses your configured DNS)
dig <hostname>

# Test DNS resolution against a specific server
dig <hostname> @192.168.68.2

# Flush DNS cache
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
```

---

## Pi-hole

```bash
# Check Pi-hole is running
docker ps | grep pihole

# Check Pi-hole logs
docker logs pihole --tail 50

# Verify Pi-hole DNS is responding
dig google.com @192.168.68.2

# Test a local DNS record
dig vault.tariqbk.com @192.168.68.2
dig pihole.home @192.168.68.2
```

---

## Caddy

```bash
# Check Caddy logs (certs, proxy errors)
docker logs caddy --tail 50

# Verify TLS certs were issued
docker logs caddy | grep "certificate obtained"

# Reload Caddy config without restart
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

---

## Vaultwarden

```bash
# Check Vaultwarden logs
docker logs vaultwarden --tail 50

# Verify it's reachable locally
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080
```

---

## Jellyfin

```bash
# Check Jellyfin logs
docker logs jellyfin --tail 50

# Run backup manually
sudo bash ~/docker/backup-jellyfin.sh >> ~/docker/logs/backup-jellyfin.log 2>&1

# Run restore
sudo bash ~/docker/restore-jellyfin.sh /mnt/nas/backups/jellyfin/<filename>.zip

# Check backup log
tail -30 ~/docker/logs/backup-jellyfin.log
```

---

## Immich

```bash
# Check Immich server logs
docker logs immich_server --tail 50

# Upgrade Immich
cd ~/docker/tunnel-stack
docker compose pull immich-server immich-machine-learning
docker compose up -d immich-server immich-machine-learning
```

---

## Portainer

```bash
# Check if Portainer is running
docker ps | grep portainer

# Start Portainer (must source secrets first)
set -a && source ~/docker/secrets.env && set +a
cd ~/docker/portainer && docker compose up -d
```

---

## Home Assistant

```bash
# Check Home Assistant logs
docker logs homeassistant --tail 50
```

---

## NordVPN / VPN interference (Mac)

If `.home` domains or split-horizon DNS stops working on your Mac, check
whether NordVPN is running in the background — it overrides DNS even when
disconnected from a server.

```bash
# Check if a VPN tunnel is overriding DNS
scutil --dns | grep -A5 utun

# Kill NordVPN if still running in background
sudo pkill -f NordVPN

# Flush DNS after quitting VPN
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
```

---

## OS updates

```bash
# Check unattended-upgrades status
systemctl status unattended-upgrades

# Check scheduled apt timers
systemctl list-timers | grep apt

# Check if a reboot is pending after updates
[ -f /var/run/reboot-required ] && cat /var/run/reboot-required.pkgs || echo 'No reboot required'

# Check upgrade log
sudo cat /var/log/unattended-upgrades/unattended-upgrades.log | tail -30
```

---

## NAS / mounts

```bash
# Check NAS mounts are active
mount | grep nas

# List backup files
ls -lh /mnt/nas/backups/<service>/
```

---

## Docker container updates

```bash
# Pull and restart a single service
cd ~/docker/tunnel-stack
docker compose pull <service> && docker compose up -d <service>

# Pull and restart all tunnel-stack services
docker compose pull && docker compose up -d
```
