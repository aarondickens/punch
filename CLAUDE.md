
# CLAUDE.md

You, as an AI, remember should plan first, and executed it after I approve.

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

punch — a VLESS-Reality proxy deployer. Single-script deployment on Ubuntu 24.04. Designed to be run on multiple servers for different purposes (e.g. daily browsing, video streaming).

## Repository Structure

```
punch/
├── deploy.sh                  # Deployment script (run on target server as root)
├── gen-clash.sh               # Generate combined Clash config from 2 deploy outputs (run locally)
├── gen-sing-box-config.sh     # Generate sing-box client config from 2 deploy outputs (run locally)
├── deploy-sing-box-client.sh  # Deploy sing-box client via Docker on macOS (run locally)
├── CLAUDE.md                  # This file
├── DESIGN.md                  # Architecture notes
└── README.md                  # Project overview
```

## Deployment

```bash
# Single server:
sudo ./deploy.sh

# With role (for multi-server setup):
sudo ./deploy.sh --role work
sudo ./deploy.sh --role video
```

Run the same script on each server. Each deployment generates its own UUID, Reality keypair, and short ID.
The `--role` flag labels the node in deploy-output.txt and share links.

## Multi-Server Client Config

```bash
# On your Mac, after collecting deploy-output.txt from each server:
./gen-clash.sh work-output.txt video-output.txt
```

Generates a combined `clash.yaml` with two proxy groups (Work, Video) and purpose-based routing rules.

## sing-box App Config (SFI/SFA/SFM)

```bash
# On your Mac, after collecting deploy-output.txt from each server:
./gen-sing-box-config.sh work-output.txt video-output.txt
```

Generates `sing-box.json` for import into sing-box GUI apps (SFI/SFA/SFM). Uses sing-box 1.11+ format with:
- Mixed inbound (HTTP+SOCKS proxy on 127.0.0.1:7891) - for Chrome, not system-wide
- GFW-resistant optimizations: TCP Fast Open, prefer_ipv4 domain strategy
- Purpose-based routing (Work/Video groups with automatic failover)

## Terminal Proxy (sing-box client)

```bash
# On your Mac, with a deploy-output.txt from any server:
./deploy-sing-box-client.sh deploy-output.txt
```

Deploys a sing-box Docker container locally, exposing HTTP+SOCKS5 on `127.0.0.1:7891`. Requires Docker Desktop for Mac.
Includes GFW-resistant optimizations: TCP Fast Open, prefer_ipv4 domain strategy.

## deploy.sh Details

The script:
1. Installs Docker + Compose if missing
2. Enables BBR congestion control
3. Generates secrets (UUID, Reality keypair, short ID)
4. Writes sing-box VLESS-Reality server config to `/opt/punch/`
5. Launches sing-box container via docker-compose (host network, port 443)
6. Opens firewall port and prints share link

## Managing the Deployment

```bash
# Server:
docker compose -f /opt/punch/docker-compose.yml ps
docker compose -f /opt/punch/docker-compose.yml logs -f
docker compose -f /opt/punch/docker-compose.yml restart
docker compose -f /opt/punch/docker-compose.yml down

# Client (macOS):
docker compose -f ~/.config/punch-client/docker-compose.yml ps
docker compose -f ~/.config/punch-client/docker-compose.yml logs -f
docker compose -f ~/.config/punch-client/docker-compose.yml restart
docker compose -f ~/.config/punch-client/docker-compose.yml down
```

## Key Paths

### Server

- `/opt/punch/reality/config.json` — sing-box server config
- `/opt/punch/docker-compose.yml` — docker-compose file
- `/opt/punch/deploy-output.txt` — deployment secrets and share link

### Client (macOS)

- `~/.config/punch-client/config.json` — sing-box client config
- `~/.config/punch-client/docker-compose.yml` — docker-compose file
