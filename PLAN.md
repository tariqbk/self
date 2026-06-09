# Pi Home Server — Automation Build Plan

## Goal

A single `user-data` file that, when placed on a freshly flashed Pi OS Lite SD card,
brings up the entire home server stack on first boot with zero manual steps on the Pi.
Secrets are kept in a local `secrets.env` file (gitignored). A build script merges
them into the final `user-data` file before flashing.

---

## File Structure

| File | In git? | Purpose |
|---|---|---|
| `user-data.yml` | ✅ Yes | Template with `${PLACEHOLDER}` tokens |
| `secrets.env.example` | ✅ Yes | Placeholder template for secrets |
| `secrets.env` | ❌ No | Your real secrets (gitignored) |
| `build-user-data.sh` | ✅ Yes | Merges template + secrets → final `user-data` |
| `PLAN.md` | ✅ Yes | This file |

### Flashing Workflow
```bash
# First time only — fill in your secrets
cp secrets.env.example secrets.env
nano secrets.env

# Every time you flash
./build-user-data.sh         # outputs ./user-data (gitignored)
# Copy ./user-data to the boot partition of the SD card, replacing the existing one
```

---

## Phases

### ✅ Phase 0 — Foundation
- Repo created, directory structure established
- All docker-compose files written for all services
- Git strategy defined (no secrets in repo)

---

### 🔄 Phase 1 — Docker + Portainer  ← CURRENT
**What user-data does:**
- Sets hostname, timezone, keyboard, locale
- Creates user `tariqbk` with hashed password
- Enables SSH (password auth)
- Installs Docker + Compose plugin via official script
- Adds user to `docker` group
- Clones repo into `~/docker`
- Runs `docker compose up -d` in `portainer/`
- Deletes `user-data` from boot partition

**Verify before moving on:**
- [ ] SSH into Pi successfully
- [ ] `docker ps` shows `portainer` container running
- [ ] https://[pi-ip]:9443 loads Portainer UI

---

### Phase 2 — Pi-hole
**Adds to user-data:**
- Write `pihole/.env` from secrets
- Run `docker compose up -d` in `pihole/`
- Apply iptables DNS redirect rules (wlan0 + eth0 → Pi-hole)
- Save iptables rules, install restore-on-boot service

**Verify before moving on:**
- [ ] http://pihole.home loads Pi-hole UI (or http://[pi-ip]/admin)
- [ ] DNS resolution working (nslookup from a device using Pi as DNS)
- [ ] Ad blocking active

---

### Phase 3 — Home Assistant
**Adds to user-data:**
- Run `docker compose up -d` in `homeassistant/`
- Register Pi-hole DNS entry for `ha.home`

**Verify before moving on:**
- [ ] http://ha.home:8123 loads Home Assistant UI
- [ ] Onboarding flow completes

---

### Phase 4 — Glances
**Adds to user-data:**
- Run `docker compose up -d` in `glances/`
- Register Pi-hole DNS entry for `glances.home`

**Verify before moving on:**
- [ ] http://glances.home:61208 loads Glances UI
- [ ] Network tab shows eth0 / wlan0
- [ ] Docker containers visible

---

### Phase 5 — Tunnel Stack (Vaultwarden + Immich + Linkding + Cloudflared)
**Adds to user-data:**
- Mount NAS via NFS (`mount-nas.sh`)
- Write `tunnel-stack/.env` from secrets
- Run `docker compose up -d` in `tunnel-stack/`

**Prerequisites (manual, one-time — Cloudflare setup can't be automated):**
- Cloudflare account with `tariqbk.com` added
- Tunnel created in Cloudflare Zero Trust dashboard
- Public hostnames configured:
  - `vault.tariqbk.com` → `http://vaultwarden:80`
  - `photos.tariqbk.com` → `http://immich-server:2283`
  - `links.tariqbk.com` → `http://linkding:9090`
- Tunnel token copied into `secrets.env`

**Verify before marking complete:**
- [ ] https://vault.tariqbk.com loads Vaultwarden
- [ ] https://photos.tariqbk.com loads Immich
- [ ] https://links.tariqbk.com loads Linkding
- [ ] Local access also works via `.home` hostnames

---

### Phase 6 — Final Hardening (optional, post-MVP)
Ideas to consider:
- Switch SSH to key-only auth (disable password)
- Automatic Docker image updates (Watchtower or similar)
- Unattended security upgrades for OS packages
- Portainer agent → Portainer server setup

---

## Notes

- The `user-data` file is deleted from the boot partition after first boot so secrets
  don't persist on the card.
- Cloudflare tunnel setup (dashboard config) is the one step that can never be fully
  automated — it requires a browser login. Everything else is hands-free.
- Each phase re-images from scratch to verify the full boot flow, not just incremental
  changes on a running Pi.
