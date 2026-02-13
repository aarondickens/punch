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
5. Generates a Clash Verge (mihomo) client config with DNS anti-poisoning and China-aware routing rules
6. Prints a VLESS share link for mobile clients (Shadowrocket, v2rayN, NekoBox)

Run the same script on multiple servers to create independent nodes for different purposes (dev tools, daily browsing, video streaming, etc.).

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
- Client config includes fake-ip DNS to neutralize GFW DNS poisoning, with domestic/foreign nameserver fallback
- Routing rules split traffic: China-destined traffic goes direct, blocked services go through the proxy, ads get rejected

## Quick Start

### Single server

```bash
# On a fresh Ubuntu 24.04 / Debian 12 server:
chmod +x deploy.sh
sudo ./deploy.sh
```

The script prints a VLESS share link and saves a single-node Clash config to `/opt/punch/clients/clash.yaml`.

### Three servers (dev / work / video)

Deploy each server with a role:

```bash
# Server 1 — dev tools (GitHub, Docker, npm, AI services)
sudo ./deploy.sh --role dev

# Server 2 — daily work (Google, social media, news)
sudo ./deploy.sh --role work

# Server 3 — video streaming (YouTube, Netflix, Twitch)
sudo ./deploy.sh --role video
```

Then copy the three `deploy-output.txt` files to your Mac and generate a combined Clash config:

```bash
./gen-clash.sh dev-output.txt work-output.txt video-output.txt
```

This produces a single `clash.yaml` with three proxy groups (`Dev`, `Work`, `Video`) and rules that route traffic to the right node. Import it into [Clash Verge](https://github.com/clash-verge-rev/clash-verge-rev).

## Management

```bash
docker compose -f /opt/punch/docker-compose.yml ps
docker compose -f /opt/punch/docker-compose.yml logs -f
docker compose -f /opt/punch/docker-compose.yml restart
docker compose -f /opt/punch/docker-compose.yml down
```

## File Layout on Server

```
/opt/punch/
├── reality/
│   └── config.json         # sing-box server config
├── clients/
│   └── clash.yaml          # Clash Verge client config
├── docker-compose.yml
└── deploy-output.txt       # secrets and share link
```

## Limitations

- Single IP per node — if the GFW blocks the server IP, the node is dead
- Client configs must be copied via scp (no subscription endpoint)
- IPv4 only
