# Punch

One-script VLESS-Reality proxy deployer for Ubuntu 24.04 / Debian 12.

## Background

The GFW (Great Firewall of China) blocks or throttles access to a wide range of services — developer tools (GitHub, Docker Hub, npm), search engines (Google), AI platforms (ChatGPT, Claude), social media, streaming, and news sites. Punch exists to punch through that wall with minimal setup: copy one script to a VPS, run it, get a working proxy.

## What It Does

`deploy.sh` turns a fresh Ubuntu 24.04 server into a VLESS-Reality proxy node in under a minute:

1. Installs Docker if missing
2. Enables BBR congestion control for better throughput on lossy international links
3. Generates all secrets (UUID, Reality keypair, short ID) — nothing hardcoded
4. Deploys a [sing-box](https://github.com/SagerNet/sing-box) container on port 443 with host networking
5. Opens firewall port and prints a VLESS share link for mobile clients (Shadowrocket, v2rayN, NekoBox)

`gen-clash.sh` runs locally on your Mac and combines credentials from multiple servers into a single Clash Verge (mihomo) config with purpose-based routing.

`gen-sing-box-config.sh` runs locally and generates a sing-box JSON config from two deploy outputs — for import into sing-box GUI apps (SFI on iOS, SFA on Android, SFM on macOS). Same routing logic as the Clash config but in sing-box 1.11+ format with HTTP/SOCKS proxy mode (127.0.0.1:7890) and GFW-resistant optimizations (TCP Fast Open, prefer_ipv4 domain strategy).

`gen-shadowrocket-config.sh` runs locally and generates a Shadowrocket `.conf` file from two deploy outputs — for import into [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118) on iOS. Same routing logic as the Clash config but using Shadowrocket-native syntax with RULE-SET from blackmatrix7 for category matching.

`deploy-sing-box-client.sh` runs locally on your Mac and sets up a sing-box Docker container as a local proxy — useful for terminal/CLI usage without a GUI client.

Run the same script on multiple servers to create independent nodes for different purposes (daily browsing, video streaming, etc.).

## Why VLESS-Reality

- No certificates needed — Reality borrows the TLS 1.3 identity of `www.microsoft.com`, so active probes see a genuine website
- Vision flow disguises traffic patterns as normal TLS browsing, resisting DPI detection
- Multiplex with padding disrupts statistical traffic analysis
- Port 443/tcp blends in with regular HTTPS
- Single protocol = one container, one port, one firewall rule

UDP-based protocols (Hysteria2) were evaluated and dropped — the GFW throttles UDP aggressively during sensitive periods, and self-signed certs are detectable.

## Design Highlights

- Zero config — all secrets generated at deploy time, no manual input required
- No web panel — pure config files, minimal attack surface
- Read-only container volumes, minimal logging (`warn` level), auto-restart
- GFW-resistant client optimizations: TCP Fast Open, prefer_ipv4 domain strategy, DNS over TLS for foreign queries
- Routing rules split traffic: China-destined traffic goes direct, blocked services go through the proxy, ads get rejected

## Quick Start

### Single server

```bash
# On a fresh Ubuntu 24.04 / Debian 12 server:
chmod +x deploy.sh
sudo ./deploy.sh
```

The script prints a VLESS share link and saves deployment credentials to `/opt/punch/deploy-output.txt`.

### Two servers (work / video)

Deploy each server with a role:

```bash
# Server 1 — daily work (Google, social media, news, dev tools, AI services)
sudo ./deploy.sh --role work

# Server 2 — video streaming (YouTube, Netflix, Twitch)
sudo ./deploy.sh --role video
```

Then copy the two `deploy-output.txt` files to your Mac and generate a combined Clash config:

```bash
./gen-clash.sh work-output.txt video-output.txt
```

This produces a single `clash.yaml` with two proxy groups (`Work`, `Video`) and rules that route traffic to the right node. Import it into [Clash Verge](https://github.com/clash-verge-rev/clash-verge-rev).

### sing-box app (SFI/SFA/SFM)

Generate a sing-box config for GUI apps:

```bash
./gen-sing-box-config.sh work-output.txt video-output.txt
```

This produces `sing-box.json` with HTTP/SOCKS proxy inbound on 127.0.0.1:7890 (for Chrome, not system-wide), GFW-resistant optimizations (TCP Fast Open, prefer_ipv4), and the same Work/Video routing rules. Import it into [SFI](https://apps.apple.com/app/sing-box/id6451272673) (iOS), SFA (Android), or SFM (macOS). Configure Chrome to use the proxy via system settings or SwitchyOmega extension.

### Shadowrocket (iOS)

Generate a Shadowrocket config for iOS:

```bash
./gen-shadowrocket-config.sh work-output.txt video-output.txt
```

This produces `shadowrocket.conf` with VLESS Reality proxy nodes, Work/Video proxy groups, and comprehensive routing rules using RULE-SET from blackmatrix7 (Ads, OpenAI, GitHub, YouTube, Netflix, Google, Telegram, Twitter, Facebook, Apple, Microsoft). Import it into [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118) via file sharing, AirDrop, or iCloud.

### Terminal proxy (sing-box client via Docker)

For CLI/terminal usage without a GUI client, deploy a local sing-box container:

```bash
./deploy-sing-box-client.sh deploy-output.txt
```

Then in your terminal:

```bash
export https_proxy=http://127.0.0.1:7891
export http_proxy=http://127.0.0.1:7891
export all_proxy=socks5://127.0.0.1:7891

# Test it:
curl -x http://127.0.0.1:7891 https://ifconfig.me
```

Requires Docker Desktop for Mac. Config lives in `~/.config/punch-client/`. Includes GFW-resistant optimizations: TCP Fast Open, prefer_ipv4 domain strategy.

## Management

### Server

```bash
docker compose -f /opt/punch/docker-compose.yml ps
docker compose -f /opt/punch/docker-compose.yml logs -f
docker compose -f /opt/punch/docker-compose.yml restart
docker compose -f /opt/punch/docker-compose.yml down
```

### Client (sing-box)

```bash
docker compose -f ~/.config/punch-client/docker-compose.yml ps
docker compose -f ~/.config/punch-client/docker-compose.yml logs -f
docker compose -f ~/.config/punch-client/docker-compose.yml restart
docker compose -f ~/.config/punch-client/docker-compose.yml down
```

## File Layout

### Server

```
/opt/punch/
├── reality/
│   └── config.json         # sing-box server config
├── docker-compose.yml
└── deploy-output.txt       # secrets and share link
```

### Client (macOS)

```
~/.config/punch-client/
├── config.json             # sing-box client config
└── docker-compose.yml
```

## Limitations

- Single IP per node — if the GFW blocks the server IP, the node is dead
- Client configs must be copied via scp (no subscription endpoint)
- IPv4 only
