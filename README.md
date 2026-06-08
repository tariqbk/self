# Pi Home Server Setup

## Git Setup

This repo contains all configuration but no secrets. Secrets are kept in
`.env` files which are gitignored.

### Clone and configure on a new Pi

```bash
git clone <your-repo-url> ~/docker
cd ~/docker

# Pi-hole
cp pihole/.env.example pihole/.env
nano pihole/.env

# Tunnel stack
cp tunnel-stack/.env.example tunnel-stack/.env
nano tunnel-stack/.env
```

### What's in git vs what's not

| Path | In git? | Reason |
|---|---|---|
| `*/docker-compose.yml` | ✅ Yes | No secrets |
| `user-data.yml` | ✅ Yes | Password hash is a placeholder |
| `cloudflared-config.yml` | ✅ Yes | No secrets |
| `*.sh` | ✅ Yes | Scripts only |
| `README.md` | ✅ Yes | Docs |
| `**/.env.example` | ✅ Yes | Templates, no real values |
| `**/.env` | ❌ No | Contains real secrets |
| `pihole/etc-pihole/` | ❌ No | Runtime data |
| `homeassistant/config/` | ❌ No | Contains tokens and credentials |

---



## Directory Structure

```
~/docker/
├── pihole/
│   ├── docker-compose.yml
│   ├── .env
│   ├── pihole-dns.sh
│   └── etc-pihole/           # auto-created by Pi-hole on first run
│       └── custom.list       # local DNS entries (pre-written by cloud-init)
├── portainer/
│   └── docker-compose.yml
├── glances/
│   └── docker-compose.yml
├── homeassistant/
│   └── docker-compose.yml
└── tunnel-stack/
    ├── docker-compose.yml
    ├── .env                  # fill in secrets before starting
    ├── cloudflared-config.yml
    └── mount-nas.sh
```

---

## Network Architecture

| Network | Services |
|---|---|
| bridge (default) | Pi-hole, Portainer, Glances |
| host | Home Assistant (required for device discovery) |
| tunnel_net | Vaultwarden, Immich, Linkding, Cloudflared |

Pi-hole, Portainer, and Glances use the default bridge network so Pi-hole's
iptables rules can route DNS traffic correctly (same issue we solved during setup).

Home Assistant uses host networking so it can discover local devices via mDNS,
Zigbee, Matter, etc.

The tunnel stack uses its own isolated bridge network. Cloudflared reaches
Vaultwarden, Immich, and Linkding by container name — no ports need to be
exposed to the host for external access (ports are exposed for local access only).

---

## Local Access (via Pi-hole DNS)

Point your router's DNS to 192.168.68.2 (Pi's IP). Pi-hole will resolve
these local hostnames automatically via custom.list:

| Service | Local URL |
|---|---|
| Pi-hole | http://pihole.home |
| Portainer | https://portainer.home:9443 |
| Vaultwarden | http://vault.home:8080 |
| Immich | http://photos.home:2283 |
| Linkding | http://links.home:9090 |
| Home Assistant | http://ha.home:8123 |
| Glances | http://glances.home:61208 |

---

## External Access (via Cloudflare Tunnel)

| Service | Public URL |
|---|---|
| Vaultwarden | https://vault.tariqbk.com |
| Immich | https://photos.tariqbk.com |
| Linkding | https://links.tariqbk.com |

---

## First Boot — What Happens Automatically

1. Docker installed
2. iptables rules applied (wlan0 + eth0 → Pi-hole DNS)
3. Pi-hole started (DNS active)
4. Portainer started
5. Glances started
6. Home Assistant started

## Manual Steps Required After First Boot

### 1. Update passwords in .env files
```bash
nano ~/docker/pihole/.env
nano ~/docker/tunnel-stack/.env
```

### 2. Set up Synology NAS (do this on the NAS before mounting)
- Open DSM → Control Panel → File Services → NFS → Enable NFS
- Create shared folder: `immich` under volume1
- Edit NFS permissions on the share:
  - Hostname/IP: 192.168.68.2 (Pi's IP)
  - Privilege: Read/Write
  - Squash: No mapping (no_root_squash)
  - Enable async: yes

### 3. Mount the NAS
```bash
# Update NAS_IP in the script first
nano ~/docker/tunnel-stack/mount-nas.sh
bash ~/docker/tunnel-stack/mount-nas.sh
```

### 4. Set up Cloudflare Tunnel
1. Create a Cloudflare account at cloudflare.com
2. Add your domain tariqbk.com (point Hover nameservers to Cloudflare)
3. Go to Zero Trust → Networks → Tunnels → Create tunnel
4. Copy the tunnel token into ~/docker/tunnel-stack/.env
5. Configure public hostnames in Cloudflare dashboard:
   - vault.tariqbk.com → http://vaultwarden:80
   - photos.tariqbk.com → http://immich-server:2283
   - links.tariqbk.com → http://linkding:9090

### 5. Start the tunnel stack
```bash
cd ~/docker/tunnel-stack
docker compose up -d
```

---

## iptables Notes

The iptables rules are saved to /etc/iptables/rules.v4 and restored on boot
via pihole-iptables.service (runs after docker.service).

Rules cover both wlan0 (WiFi) and eth0 (Ethernet) — switching between them
requires no changes.

If Pi-hole's container IP ever changes (e.g. after recreating the container),
update the DNAT destination in /etc/iptables/rules.v4 and run:
  sudo iptables-restore /etc/iptables/rules.v4

To check the current container IP:
  docker inspect pihole | grep IPAddress
