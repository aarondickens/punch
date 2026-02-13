
# CLAUDE.md

You, as an AI, remember should plan first, and executed it after I approve.

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

punch — a VLESS-Reality proxy deployer. Single-script deployment on Ubuntu 24.04. Designed to be run on multiple servers for different purposes (e.g. dev tools, daily browsing, video streaming).

## Repository Structure

```
punch/
├── deploy.sh      # Deployment script (run on target server as root)
├── gen-clash.sh   # Generate combined Clash config from 3 deploy outputs (run locally)
├── CLAUDE.md      # This file
├── DESIGN.md      # Architecture notes
└── README.md      # Project overview
```

## Deployment

```bash
# Single server:
sudo ./deploy.sh

# With role (for multi-server setup):
sudo ./deploy.sh --role dev
sudo ./deploy.sh --role work
sudo ./deploy.sh --role video
```

Run the same script on each server. Each deployment generates its own UUID, Reality keypair, and short ID.
The `--role` flag labels the node in deploy-output.txt and share links.

## Multi-Server Client Config

```bash
# On your Mac, after collecting deploy-output.txt from each server:
./gen-clash.sh dev-output.txt work-output.txt video-output.txt
```

Generates a combined `clash.yaml` with three proxy groups (Dev, Work, Video) and purpose-based routing rules.

The script:
1. Installs Docker + Compose if missing
2. Enables BBR congestion control
3. Generates secrets (UUID, Reality keypair, short ID)
4. Writes sing-box VLESS-Reality server config to `/opt/punch/`
5. Launches sing-box container via docker-compose (host network, port 443)
6. Opens firewall port and prints share link

## Managing the Deployment

```bash
# On the target server:
docker compose -f /opt/punch/docker-compose.yml ps
docker compose -f /opt/punch/docker-compose.yml logs -f
docker compose -f /opt/punch/docker-compose.yml restart
docker compose -f /opt/punch/docker-compose.yml down
```

## Key Paths on Target Server

- `/opt/punch/reality/config.json` — sing-box server config
- `/opt/punch/docker-compose.yml` — docker-compose file
- `/opt/punch/deploy-output.txt` — deployment secrets and share link
