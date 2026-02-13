# Punch — Design Document

## 1. Overview

Punch deploys a VLESS-Reality proxy node on Ubuntu 24.04 via a single bash script. The same script is run on multiple servers to create independent nodes for different purposes (e.g. dev tooling, daily browsing, video streaming).

## 2. Protocol: VLESS + XTLS-Reality + Vision

VLESS with Reality TLS is chosen as the sole protocol for its stealth properties against the GFW:

- **No certificate needed.** Reality borrows the TLS 1.3 identity of a real website (www.microsoft.com). The server performs a real TLS handshake with the target on behalf of unauthorized probes, so active probing sees a genuine website.
- **Vision flow** (`xtls-rprx-vision`) disguises proxy traffic patterns to look like normal TLS web browsing, resisting DPI-based detection.
- **Multiplex with padding** is enabled on the server inbound. Clients that opt into muxing get random-length padding bytes injected into each frame, disrupting statistical traffic analysis (packet size/timing fingerprinting). The server accepts both muxed and non-muxed (Vision flow) connections.
- **Port 443/tcp** — blends in with normal HTTPS traffic. No unusual ports to flag.

### Why not Hysteria2

Hysteria2 (UDP/QUIC-based) was evaluated and removed:

- The GFW aggressively throttles UDP during sensitive periods, making it unreliable.
- Self-signed certificates are detectable: a TLS probe to the Hysteria2 port reveals a cert chain that doesn't match the claimed SNI.
- A single protocol keeps the deployment simple — one container, one port, one firewall rule.

## 3. SNI Choice: www.microsoft.com

The Reality handshake target must be:

- **TLS 1.3 capable** — Reality requires it.
- **Not blocked by the GFW** — the SNI is sent in plaintext; a blocked domain would be filtered.
- **Stable and long-lived** — if the target domain goes down, active probes see a dead handshake, which is suspicious.
- **High traffic from China** — so connections to it from Chinese IPs are not anomalous.

`www.microsoft.com` satisfies all four. Previously considered `www.skype.com`, but Skype was discontinued in May 2025 making the domain's future unreliable.

## 4. Secrets Generation

All secrets are generated at deploy time on the server. Nothing is hardcoded or shared across nodes.

| Secret | Method | Purpose |
|---|---|---|
| UUID | `sing-box generate uuid` (in container) | VLESS user identity |
| Reality keypair | `sing-box generate reality-keypair` (in container) | Ed25519 key pair for Reality TLS |
| Short ID | `openssl rand -hex 8` (16 hex chars, max length) | Additional authentication factor; full 8 bytes to resist brute-force matching |

No host-level sing-box installation is needed. The sing-box Docker image is used as a temporary tool to generate UUID and keypair.

## 5. Container Architecture

Single container, host networking, read-only config volume:

```
sing-box-reality
  image:    ghcr.io/sagernet/sing-box:latest
  network:  host (avoids Docker NAT on port 443)
  volumes:  /opt/punch/reality/config.json → /etc/sing-box/config.json (ro)
  restart:  unless-stopped
  logging:  json-file, max 1MB
```

Host networking is used because Docker NAT introduces latency and complicates TLS passthrough. The container binds directly to port 443 on all interfaces (`::`).

## 6. Kernel Tuning: BBR

Ubuntu 24.04 defaults to CUBIC congestion control with fq_codel qdisc. The script switches to:

```
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

BBR (Bottleneck Bandwidth and Round-trip propagation time) improves throughput on lossy international links, which is the typical path between Chinese clients and overseas servers.

## 7. Client Config: Clash Verge (mihomo)

The script generates a Clash YAML config at `/opt/punch/clients/clash.yaml` designed for Clash Verge on macOS.

### 7.1 DNS Strategy

The GFW poisons DNS responses for blocked domains. The config uses fake-ip mode to neutralize this:

- **fake-ip mode** — Clash returns a fake IP (198.18.0.0/16) to local applications immediately, then resolves the real IP internally based on routing rules. Applications never see poisoned results.
- **Domestic nameservers** (223.5.5.5, 119.29.29.29) — used as primary resolvers. Fast for Chinese domains.
- **Foreign nameservers** (tls://8.8.8.8:853, tls://1.1.1.1:853) — used as fallback when the domestic resolver returns a non-CN IP (indicating possible poisoning). DNS-over-TLS prevents the GFW from seeing or tampering with these queries.
- **fallback-filter with geoip-code CN** — if the domestic DNS returns a CN IP, trust it (no fallback). If it returns a non-CN IP, use the foreign fallback instead. This catches the common GFW pattern of returning foreign IPs for blocked domains.
- **fake-ip-filter** — domains that must get real IPs (captive portal checks, connectivity tests, STUN) are excluded from fake-ip.

### 7.2 Routing Rules

Rules are evaluated top-to-bottom, first match wins:

| Priority | Category | Action | Rationale |
|---|---|---|---|
| 1 | Private/LAN | DIRECT | RFC1918, .local, .lan — never proxy local traffic |
| 2 | Ads | REJECT | GEOSITE category-ads-all — block tracking and ads |
| 3 | AI services | Proxy | OpenAI, Anthropic, Perplexity, Gemini — all blocked in China |
| 4 | Dev tools | Proxy | GitHub, Go modules, npm, Docker Hub, PyPI, crates.io, Homebrew, gcr.io, k8s.io, Stack Overflow, HuggingFace, etc. |
| 5 | Google + YouTube | Proxy | GEOSITE google + youtube |
| 6 | Social media | Proxy | Twitter, Facebook, Telegram, Reddit, Discord, Instagram, LinkedIn, WhatsApp, Signal, etc. |
| 7 | Streaming | Proxy | Netflix, Spotify, Twitch, Disney+, HBO, Prime Video, Vimeo, etc. |
| 8 | News & knowledge | Proxy | Wikipedia, NYT, BBC, Reuters, archive.org, etc. |
| 9 | Cloud & CDN | Proxy | AWS CloudFront, Vercel, Netlify, Cloudflare Pages/Workers, Firebase, Fly.io, etc. — often slow or blocked from China |
| 10 | Apple | DIRECT | GEOSITE apple — Apple services are accessible from China |
| 11 | Microsoft | DIRECT | GEOSITE microsoft — accessible from China (LinkedIn is overridden to Proxy in the social media rules above) |
| 12 | China domains | DIRECT | GEOSITE cn — match by domain name |
| 13 | China IPs | DIRECT | GEOIP CN — catch any remaining CN-destined traffic |
| 14 | Default | Proxy | MATCH — everything else goes through the proxy |

The explicit DOMAIN-SUFFIX rules for dev tools, social media, streaming, etc. serve two purposes: (1) they match faster than falling through to MATCH for frequently accessed domains, and (2) they document exactly what is proxied, making the config auditable.

Apple and Microsoft are placed after the social/dev rules so that LinkedIn (Microsoft-owned, blocked in China) and specific Google-adjacent services are correctly routed to Proxy before the blanket DIRECT rules.

### 7.3 Proxy Node Config

```yaml
type: vless
port: 443
flow: xtls-rprx-vision
client-fingerprint: chrome
reality-opts:
  public-key: <generated>
  short-id: <generated>
```

- **client-fingerprint: chrome** — uTLS mimics Chrome's TLS fingerprint so the handshake is indistinguishable from a real Chrome browser connecting to www.microsoft.com.
- **Clash uses hyphenated keys** (`public-key`, `short-id`, `client-fingerprint`) — different from sing-box's underscored keys (`public_key`, `short_id`).

### 7.4 Global Settings

- `unified-delay: true` — measures real end-to-end delay including handshake, giving more accurate latency numbers.
- `tcp-concurrent: true` — Happy Eyeballs: races IPv4 and IPv6 connections, uses whichever completes first.
- `geo-auto-update: true` — auto-updates GeoIP/GeoSite databases every 24 hours.

## 8. Multi-Server Usage

The script accepts an optional `--role` flag to label each node:

```bash
sudo ./deploy.sh --role dev    # Server 1
sudo ./deploy.sh --role work   # Server 2
sudo ./deploy.sh --role video  # Server 3
```

Valid roles: `dev`, `work`, `video`. The role is recorded in `deploy-output.txt` and used to name the proxy node in share links (e.g. `dev-1.2.3.4`). Without `--role`, the node is named by IP only.

Each run generates independent secrets. The intended setup:

| Server | Role | Traffic |
|---|---|---|
| Node 1 | `dev` | AI services, GitHub, package registries, Cloud/CDN, Stack Overflow, HuggingFace |
| Node 2 | `work` | Google, social media, news, Wikipedia, general browsing |
| Node 3 | `video` | YouTube, Netflix, Spotify, Twitch, Disney+, HBO, Vimeo |

### 8.1 Combined Client Config: gen-clash.sh

`deploy.sh` still generates a single-node `clash.yaml` per server (useful for quick testing). For the three-server setup, `gen-clash.sh` runs locally on the user's Mac and produces a combined config:

```bash
./gen-clash.sh dev-output.txt work-output.txt video-output.txt
# → clash.yaml
```

It parses the three `deploy-output.txt` files and generates one `clash.yaml` with:

- **3 proxies** — one per server, named `dev-<ip>`, `work-<ip>`, `video-<ip>`
- **3 proxy groups** — `Dev`, `Work`, `Video`. Each group lists its dedicated node first, with the other two as fallbacks, plus DIRECT.
- **Purpose-based routing rules:**

| Priority | Category | Group | Rationale |
|---|---|---|---|
| 1 | Private/LAN | DIRECT | RFC1918, .local, .lan |
| 2 | Ads | REJECT | GEOSITE category-ads-all |
| 3 | AI services | Dev | OpenAI, Anthropic, Perplexity, Gemini |
| 4 | Dev tools | Dev | GitHub, Go, npm, Docker, PyPI, crates.io, Homebrew, etc. |
| 5 | Streaming | Video | YouTube, Netflix, Spotify, Twitch, Disney+, HBO, etc. |
| 6 | Google | Work | GEOSITE google |
| 7 | Social media | Work | Twitter, Facebook, Telegram, Reddit, Discord, etc. |
| 8 | News & knowledge | Work | Wikipedia, NYT, BBC, Reuters, archive.org |
| 9 | Cloud & CDN | Dev | CloudFront, Vercel, Netlify, Cloudflare, Firebase, etc. |
| 10 | Apple | DIRECT | Accessible from China |
| 11 | Microsoft | DIRECT | Accessible (LinkedIn overridden to Work above) |
| 12 | China domestic | DIRECT | Baidu, Tencent, Taobao, JD, DeepSeek, Qwen, etc. |
| 13 | China domains/IPs | DIRECT | GEOSITE cn + GEOIP CN |
| 14 | Default | Work | MATCH — everything else |

The fallback ordering in each group means if the dedicated node goes down, traffic automatically falls back to another node rather than failing entirely.

## 9. Security Posture

- **No web panel** — no 3X-UI or similar. Pure config files minimize attack surface.
- **Minimal logging** — log level `warn`. No user activity is recorded.
- **Read-only volumes** — the container cannot modify its own config.
- **Auto-restart** — `restart: unless-stopped` ensures the proxy survives reboots.
- **Fail-fast preflight** — the script aborts on unsupported OS, missing `/etc/os-release`, or port 443 conflict. No partial deployments.

## 10. Known Limitations

- **Single IP per node** — if the GFW blocks the server IP, the node is dead. No CDN relay or domain fronting. The combined config provides fallback to other nodes, but not automatic failover.
- **Self-signed certs not used** — Reality doesn't need certs (it borrows from the target). But this means no HTTPS subscription endpoint. Client configs must be copied manually (scp).
- **IPv4 only** — IP detection and share links assume IPv4. IPv6 is not handled.

## 11. File Layout on Server

```
/opt/punch/
├── reality/
│   └── config.json         # sing-box server config
├── clients/
│   └── clash.yaml          # Clash Verge client config
├── docker-compose.yml      # Container orchestration
└── deploy-output.txt       # Secrets and share link
```
