# Pi Home Server — Automation Build Plan

## Goal

A single `user-data` + `network-config` pair that, when placed on a freshly
flashed Pi OS Lite SD card, brings up the entire home server stack on first
boot with zero manual steps on the Pi. Secrets are kept in a local
`secrets.env` file (gitignored). A build script merges them into the final
files before flashing.

---

## File Structure

| File | In git? | Purpose |
|---|---|---|
| `user-data.yml` | ✅ Yes | cloud-init template with `${PLACEHOLDER}` tokens |
| `network-config.yml` | ✅ Yes | netplan template (static IP + wifi) with `${PLACEHOLDER}` tokens |
| `secrets.env.example` | ✅ Yes | Placeholder template for secrets |
| `secrets.env` | ❌ No | Your real secrets (gitignored) |
| `build-user-data.sh` | ✅ Yes | Merges templates + secrets → final `user-data` / `network-config` |
| `PLAN.md` | ✅ Yes | This file |

### Flashing Workflow
```bash
# First time only — fill in your secrets
cp secrets.env.example secrets.env
nano secrets.env

# Every time you flash
./build-user-data.sh         # outputs ./user-data and ./network-config (gitignored)
# Copy both files to the boot partition of the SD card, replacing the existing ones
```

---

## Phases

### ✅ Phase 0 — Foundation
- Repo created, directory structure established
- All docker-compose files written for all services
- Git strategy defined (no secrets in repo)

---

### ✅ Phase 1 — Docker + Portainer
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

### ✅ Phase 2 — Pi-hole
**Adds to user-data:**
- Write `pihole/.env` from secrets (`PIHOLE_PASSWORD`, `PI_LOCAL_IP`)
- Run `docker compose up -d` in `pihole/`

**Adds network-config.yml (new):**
- Static IP (`PI_LOCAL_IP`) for both `wlan0` and `eth0`, configured directly
  on the Pi via netplan — no router DHCP reservation needed. Only connect one
  interface at a time (same static IP on both).
- WiFi SSID/password (from secrets)
- Deleted from boot partition after first boot (cleanup step), like `user-data`

**docker-compose.yml fixes (discovered during verification):**
- `FTLCONF_dns_hosts`: local DNS records for `.home` hostnames (Pi-hole v6
  doesn't use `custom.list`/dnsmasq anymore)
- `FTLCONF_dns_listeningMode: "all"`: default `LOCAL` mode rejects DNS queries
  from LAN devices since their source IP isn't in the docker bridge subnet —
  caused UDP timeouts / TCP resets from external clients

**Note:** No iptables needed — Pi-hole publishes port 53 directly to the host.
Point your router's DNS at the Pi's static IP.

**Verify before moving on:**
- [x] http://pihole.home loads Pi-hole UI (or http://[pi-ip]/admin) — *to confirm
  once router DNS points to the Pi, deferred until full setup is complete*
- [x] DNS resolution working (nslookup from a device using Pi as DNS)
- [x] Static IP (192.168.68.2) confirmed after re-flash with network-config
- [x] docker ps shows portainer + pihole healthy, cloud-init status: done,
  user-data/network-config cleaned up

---

### ✅ Phase 3 — Home Assistant
**Adds to user-data:**
- Create `homeassistant/config/` (owned by `tariqbk`)
- Run `docker compose up -d` in `homeassistant/`

**Note:** `ha.home` DNS entry was already added to Pi-hole's `FTLCONF_dns_hosts`
in Phase 2 — no Pi-hole changes needed here.

**Time-sync fix:**
- Time sync now happens as the first `runcmd` step using
  `systemctl start systemd-timesyncd` + `timedatectl set-ntp true` + polling
  on `NTPSynchronized=yes`. D-Bus is available by the `runcmd` ("final")
  stage, so `systemctl`/`timedatectl` work here.
- `package_update`/`package_upgrade` removed from `user-data.yml` — system
  updates will be run manually later, after everything is installed.
- The `packages` list (avahi-daemon, curl, git) still installs in the
  "config" stage, before `runcmd`'s time sync — `apt: conf: Check-Date
  "false"` remains as a safety net for that early step.

**Verify before moving on:**
- [x] `docker ps` shows `homeassistant` container running
- [x] cloud-init status: done, user-data/network-config cleaned up
- [x] http://[pi-ip]:8123 loads Home Assistant onboarding
- [ ] Onboarding flow completes
- [ ] http://ha.home:8123 works (after router DNS points to Pi)

---

### ✅ Phase 4 — Glances
**Adds to user-data:**
- Run `docker compose up -d` in `glances/`

**Note:** `glances.home` DNS entry was already added to Pi-hole's
`FTLCONF_dns_hosts` in Phase 2 — no Pi-hole changes needed here.

**Note:** Home Assistant runcmd steps are temporarily disabled (commented out)
for faster test re-flashes during this and the next phase — re-enable before
the final full re-flash.

**Verify before moving on:**
- [x] http://[pi-ip]:61208 loads Glances UI
- [x] Network tab shows wlan0 with live traffic

---

### Phase 5 — Tunnel Stack (Vaultwarden + Immich + Linkding + Cloudflared)
Split into sub-phases — bring services up one at a time behind the tunnel.

**Removed:** `tunnel-stack/pihole-dns.sh` — obsolete `custom.list` approach,
superseded by `FTLCONF_dns_hosts` in Phase 2. Also removed
`tunnel-stack/cloudflared-config.yml` — unused; ingress rules are configured
in the Cloudflare dashboard (Public Hostname tab) since `cloudflared` runs in
remotely-managed mode via `TUNNEL_TOKEN`.

---

#### ✅ Phase 5a — Cloudflare Tunnel + Linkding
**Manual prerequisites (one-time, can't be automated):**
- [x] Cloudflare account created, `tariqbk.com` added (nameservers updated at
  Hover)
- [x] Tunnel created in Zero Trust dashboard, token copied into `secrets.env`
  as `CLOUDFLARE_TUNNEL_TOKEN`
- [x] Public hostname configured: `links.tariqbk.com` → `http://linkding:9090`

**Adds to user-data:**
- Write `tunnel-stack/.env` from secrets (`CLOUDFLARE_TUNNEL_TOKEN`,
  `LINKDING_SUPERUSER/PASSWORD`, plus Immich vars for later sub-phases)
- Run `docker compose up -d --no-deps linkding cloudflared`

**Verify before moving on:**
- [x] https://links.tariqbk.com loads Linkding through the tunnel

---

#### ✅ Phase 5b — Vaultwarden
**Adds to user-data:**
- Run `docker compose up -d --no-deps vaultwarden` (and add `vaultwarden` to
  the existing `linkding cloudflared` line)

**Manual prerequisite:**
- [x] Public hostname configured: `vault.tariqbk.com` → `http://vaultwarden:80`

**Verify before moving on:**
- [x] https://vault.tariqbk.com loads Vaultwarden

---

#### 🔄 Phase 5c — Immich  ← CURRENT
**Adds to user-data:**
- Mount NAS via NFS (`mount-nas.sh ${NAS_IP}`) — NAS NFS share already
  configured and ready
- Run `docker compose up -d` for `immich-server immich-machine-learning
  immich-redis immich-postgres` (and add `cloudflared` deps as needed)

**Manual prerequisite:**
- [x] Public hostname configured: `immich.tariqbk.com` → `http://immich-server:2283`
  (subdomain changed from `photos` to `immich`)

**Verify before moving on:**
- [x] NAS mounted at `/mnt/nas/immich` on the Pi
- [x] https://immich.tariqbk.com loads Immich through the tunnel

---

#### 🔄 Phase 5d — Final tunnel-stack wiring  ← CURRENT
- [x] Switch the `runcmd` line to a plain `docker compose up -d` (no
  `--no-deps`/service list) for the whole `tunnel-stack/` directory
- [x] Re-enable Portainer, Pi-hole, Glances, Home Assistant in `user-data.yml`

**Refactor: extract `setup.sh`** — moves all Phase 1-5 orchestration out of
`user-data.yml`'s `runcmd` into a `setup.sh` script in the repo. `runcmd`
becomes: time sync → install Docker → clone repo → copy `secrets.env` from
the boot partition onto the Pi's disk (`~/docker/secrets.env`, `chmod 600`)
→ `bash setup.sh`. `build-user-data.sh` now also instructs copying
`secrets.env` to the boot partition (read by `setup.sh`, then deleted in
cleanup along with `user-data`/`network-config`).

Benefit: recovery without re-flashing — `git clone <repo> ~/docker2 && cp
~/docker/secrets.env ~/docker2/ && bash ~/docker2/setup.sh` brings the whole
stack back up on a running Pi.

- [x] Create `setup.sh`, slim `user-data.yml`, update `build-user-data.sh`
  message and README
- [ ] Full re-flash: confirm all 8 containers come up via `setup.sh`
  (portainer, pihole, homeassistant, glances, linkding, vaultwarden, immich
  x4, cloudflared)
- [ ] Confirm `/boot/firmware/secrets.env` is removed after boot and
  `~/docker/secrets.env` exists with `600` permissions
- [ ] Confirm local `.home` hostnames work for vault/immich/links
- [ ] Confirm public hostnames still work for vault/immich/links

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
