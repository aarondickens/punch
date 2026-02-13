#!/usr/bin/env bash
#
# punch/deploy.sh — Deploy a VLESS-Reality proxy node
# Run on a fresh Ubuntu 24.04 server as root.
# Use the same script on each machine to deploy multiple nodes.
#
set -euo pipefail

# ─────────────────────────────────────────────
# 1. Constants & helpers
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() {
  echo -e "${RED}[ERROR]${NC} $*"
  exit 1
}

BASE_DIR="/opt/punch"
SINGBOX_IMAGE="ghcr.io/sagernet/sing-box:latest"
REALITY_SNI="www.microsoft.com"

# ─────────────────────────────────────────────
# 2. Preflight checks
# ─────────────────────────────────────────────
info "Running preflight checks..."

[[ $EUID -eq 0 ]] || error "This script must be run as root."

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
    error "Unsupported OS: ${ID:-unknown}. This script requires Ubuntu 24.04 / Debian 12."
  fi
else
  error "Cannot detect OS (/etc/os-release not found). This script requires Ubuntu 24.04 / Debian 12."
fi

if ss -tlnp | grep -q ':443 '; then
  error "Port 443 is already in use. Free it before running this script."
fi

# ─────────────────────────────────────────────
# 3. Docker install
# ─────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  info "Installing Docker..."
  curl -fsSL https://get.docker.com | bash -s -- --quiet
  info "Docker installed."
else
  info "Docker already installed."
fi

docker compose version &>/dev/null || error "docker compose plugin not found."

# ─────────────────────────────────────────────
# 4. BBR
# ─────────────────────────────────────────────
info "Enabling BBR congestion control..."
cat >/etc/sysctl.d/99-bbr.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL
sysctl --system &>/dev/null
info "BBR enabled."

# ─────────────────────────────────────────────
# 5. IP detection
# ─────────────────────────────────────────────
info "Detecting server public IP..."
SERVER_IP=""
for svc in "ifconfig.me" "icanhazip.com" "ipinfo.io/ip"; do
  SERVER_IP=$(curl -4 -s --connect-timeout 5 --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]') && break
done

if [[ -z "$SERVER_IP" || ! "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  warn "Could not auto-detect public IP."
  read -rp "Enter your server's public IPv4 address: " SERVER_IP
  [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || error "Invalid IP address."
fi
info "Server IP: $SERVER_IP"

# ─────────────────────────────────────────────
# 6. Secrets generation
# ─────────────────────────────────────────────
info "Generating secrets..."

docker pull -q "$SINGBOX_IMAGE" >/dev/null 2>&1

UUID=$(docker run --rm "$SINGBOX_IMAGE" generate uuid)
REALITY_KEYPAIR=$(docker run --rm "$SINGBOX_IMAGE" generate reality-keypair)
REALITY_PRIVATE_KEY=$(echo "$REALITY_KEYPAIR" | grep -i 'private' | awk '{print $NF}')
REALITY_PUBLIC_KEY=$(echo "$REALITY_KEYPAIR" | grep -i 'public' | awk '{print $NF}')
SHORT_ID=$(openssl rand -hex 8)

info "Secrets generated."

# ─────────────────────────────────────────────
# 7. Directory scaffolding
# ─────────────────────────────────────────────
info "Creating directory structure..."
mkdir -p "$BASE_DIR"/{reality,clients}

# ─────────────────────────────────────────────
# 8. sing-box server config (VLESS Reality)
# ─────────────────────────────────────────────
info "Writing sing-box Reality config..."
cat >"$BASE_DIR/reality/config.json" <<EOF
{
  "log": {
    "level": "warn"
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_SNI}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      },
      "multiplex": {
        "enabled": true,
        "padding": true
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

# ─────────────────────────────────────────────
# 9. docker-compose.yml
# ─────────────────────────────────────────────
info "Writing docker-compose.yml..."
cat >"$BASE_DIR/docker-compose.yml" <<EOF
services:
  sing-box-reality:
    image: ${SINGBOX_IMAGE}
    container_name: sing-box-reality
    network_mode: host
    volumes:
      - ${BASE_DIR}/reality/config.json:/etc/sing-box/config.json:ro
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "1m"
EOF

# ─────────────────────────────────────────────
# 10. Clash Verge client config (mihomo)
# ─────────────────────────────────────────────
info "Generating Clash client config..."
cat >"$BASE_DIR/clients/clash.yaml" <<'CLASH_HEAD'
# Clash Verge (mihomo) config — generated by punch/deploy.sh
# Import this file into Clash Verge on macOS.

mixed-port: 7897
allow-lan: false
mode: rule
log-level: warning
unified-delay: true
tcp-concurrent: true
global-client-fingerprint: chrome
geo-auto-update: true
geo-update-interval: 24

dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - "*.localhost"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
    - "localhost.ptlogin2.qq.com"
    - "captive.apple.com"
    - "connectivitycheck.gstatic.com"
    - "connectivitycheck.platform.hicloud.com"
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
  fallback:
    - "tls://8.8.8.8:853"
    - "tls://1.1.1.1:853"
  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4

CLASH_HEAD

cat >>"$BASE_DIR/clients/clash.yaml" <<EOF
proxies:
  - name: "${SERVER_IP}"
    type: vless
    server: ${SERVER_IP}
    port: 443
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${SHORT_ID}

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - "${SERVER_IP}"
      - DIRECT

EOF

cat >>"$BASE_DIR/clients/clash.yaml" <<'CLASH_RULES'
rules:
  # ─── Private & Local ───
  - GEOIP,private,DIRECT,no-resolve
  - DOMAIN-SUFFIX,local,DIRECT
  - DOMAIN-SUFFIX,lan,DIRECT

  # ─── Ad Blocking ───
  - GEOSITE,category-ads-all,REJECT

  # ─── AI Services ───
  - GEOSITE,openai,Proxy
  - DOMAIN-SUFFIX,anthropic.com,Proxy
  - DOMAIN-SUFFIX,claude.ai,Proxy
  - DOMAIN-SUFFIX,perplexity.ai,Proxy
  - DOMAIN-SUFFIX,gemini.google.com,Proxy

  # ─── Dev Tools (GitHub, package registries, docs) ───
  - GEOSITE,github,Proxy
  - DOMAIN-SUFFIX,ghcr.io,Proxy
  - DOMAIN-SUFFIX,raw.githubusercontent.com,Proxy
  - DOMAIN-SUFFIX,objects.githubusercontent.com,Proxy
  - DOMAIN-SUFFIX,golang.org,Proxy
  - DOMAIN-SUFFIX,go.dev,Proxy
  - DOMAIN-SUFFIX,proxy.golang.org,Proxy
  - DOMAIN-SUFFIX,sum.golang.org,Proxy
  - DOMAIN-SUFFIX,storage.googleapis.com,Proxy
  - DOMAIN-SUFFIX,registry.npmjs.org,Proxy
  - DOMAIN-SUFFIX,npmjs.com,Proxy
  - DOMAIN-SUFFIX,yarnpkg.com,Proxy
  - DOMAIN-SUFFIX,docker.io,Proxy
  - DOMAIN-SUFFIX,docker.com,Proxy
  - DOMAIN-SUFFIX,gcr.io,Proxy
  - DOMAIN-SUFFIX,k8s.io,Proxy
  - DOMAIN-SUFFIX,kubernetes.io,Proxy
  - DOMAIN-SUFFIX,registry.k8s.io,Proxy
  - DOMAIN-SUFFIX,dl.google.com,Proxy
  - DOMAIN-SUFFIX,dl-ssl.google.com,Proxy
  - DOMAIN-SUFFIX,crates.io,Proxy
  - DOMAIN-SUFFIX,static.crates.io,Proxy
  - DOMAIN-SUFFIX,rust-lang.org,Proxy
  - DOMAIN-SUFFIX,static.rust-lang.org,Proxy
  - DOMAIN-SUFFIX,pypi.org,Proxy
  - DOMAIN-SUFFIX,files.pythonhosted.org,Proxy
  - DOMAIN-SUFFIX,rubygems.org,Proxy
  - DOMAIN-SUFFIX,gradle.org,Proxy
  - DOMAIN-SUFFIX,repo.maven.apache.org,Proxy
  - DOMAIN-SUFFIX,plugins.gradle.org,Proxy
  - DOMAIN-SUFFIX,cocoapods.org,Proxy
  - DOMAIN-SUFFIX,cdn.cocoapods.org,Proxy
  - DOMAIN-SUFFIX,homebrew.sh,Proxy
  - DOMAIN-SUFFIX,formulae.brew.sh,Proxy
  - DOMAIN-SUFFIX,stackoverflow.com,Proxy
  - DOMAIN-SUFFIX,stackexchange.com,Proxy
  - DOMAIN-SUFFIX,askubuntu.com,Proxy
  - DOMAIN-SUFFIX,serverfault.com,Proxy
  - DOMAIN-SUFFIX,superuser.com,Proxy
  - DOMAIN-SUFFIX,medium.com,Proxy
  - DOMAIN-SUFFIX,dev.to,Proxy
  - DOMAIN-SUFFIX,hf.co,Proxy
  - DOMAIN-SUFFIX,huggingface.co,Proxy

  # ─── Google ───
  - GEOSITE,google,Proxy
  - GEOSITE,youtube,Proxy

  # ─── Social Media ───
  - GEOSITE,twitter,Proxy
  - GEOSITE,facebook,Proxy
  - GEOSITE,telegram,Proxy
  - DOMAIN-SUFFIX,reddit.com,Proxy
  - DOMAIN-SUFFIX,redd.it,Proxy
  - DOMAIN-SUFFIX,redditmedia.com,Proxy
  - DOMAIN-SUFFIX,redditstatic.com,Proxy
  - DOMAIN-SUFFIX,discord.com,Proxy
  - DOMAIN-SUFFIX,discord.gg,Proxy
  - DOMAIN-SUFFIX,discordapp.com,Proxy
  - DOMAIN-SUFFIX,discordapp.net,Proxy
  - DOMAIN-SUFFIX,instagram.com,Proxy
  - DOMAIN-SUFFIX,cdninstagram.com,Proxy
  - DOMAIN-SUFFIX,linkedin.com,Proxy
  - DOMAIN-SUFFIX,licdn.com,Proxy
  - DOMAIN-SUFFIX,pinterest.com,Proxy
  - DOMAIN-SUFFIX,pinimg.com,Proxy
  - DOMAIN-SUFFIX,whatsapp.com,Proxy
  - DOMAIN-SUFFIX,whatsapp.net,Proxy
  - DOMAIN-SUFFIX,line.me,Proxy
  - DOMAIN-SUFFIX,line-scdn.net,Proxy
  - DOMAIN-SUFFIX,naver.jp,Proxy
  - DOMAIN-SUFFIX,signal.org,Proxy

  # ─── Streaming & Media ───
  - GEOSITE,netflix,Proxy
  - DOMAIN-SUFFIX,spotify.com,Proxy
  - DOMAIN-SUFFIX,spotifycdn.com,Proxy
  - DOMAIN-SUFFIX,scdn.co,Proxy
  - DOMAIN-SUFFIX,twitch.tv,Proxy
  - DOMAIN-SUFFIX,ttvnw.net,Proxy
  - DOMAIN-SUFFIX,jtvnw.net,Proxy
  - DOMAIN-SUFFIX,disneyplus.com,Proxy
  - DOMAIN-SUFFIX,disney-plus.net,Proxy
  - DOMAIN-SUFFIX,bamgrid.com,Proxy
  - DOMAIN-SUFFIX,dssott.com,Proxy
  - DOMAIN-SUFFIX,hulu.com,Proxy
  - DOMAIN-SUFFIX,hbo.com,Proxy
  - DOMAIN-SUFFIX,hbomax.com,Proxy
  - DOMAIN-SUFFIX,max.com,Proxy
  - DOMAIN-SUFFIX,primevideo.com,Proxy
  - DOMAIN-SUFFIX,aiv-cdn.net,Proxy
  - DOMAIN-SUFFIX,soundcloud.com,Proxy
  - DOMAIN-SUFFIX,sndcdn.com,Proxy
  - DOMAIN-SUFFIX,pandora.com,Proxy
  - DOMAIN-SUFFIX,vimeo.com,Proxy
  - DOMAIN-SUFFIX,vimeocdn.com,Proxy
  - DOMAIN-SUFFIX,dailymotion.com,Proxy

  # ─── News & Knowledge ───
  - GEOSITE,wikipedia,Proxy
  - DOMAIN-SUFFIX,wikimedia.org,Proxy
  - DOMAIN-SUFFIX,wiktionary.org,Proxy
  - DOMAIN-SUFFIX,nytimes.com,Proxy
  - DOMAIN-SUFFIX,wsj.com,Proxy
  - DOMAIN-SUFFIX,bbc.com,Proxy
  - DOMAIN-SUFFIX,bbc.co.uk,Proxy
  - DOMAIN-SUFFIX,reuters.com,Proxy
  - DOMAIN-SUFFIX,theguardian.com,Proxy
  - DOMAIN-SUFFIX,apnews.com,Proxy
  - DOMAIN-SUFFIX,archive.org,Proxy

  # ─── Cloud & CDN (often slow or blocked from China) ───
  - DOMAIN-SUFFIX,cloudfront.net,Proxy
  - DOMAIN-SUFFIX,amazonaws.com,Proxy
  - DOMAIN-SUFFIX,s3.amazonaws.com,Proxy
  - DOMAIN-SUFFIX,heroku.com,Proxy
  - DOMAIN-SUFFIX,herokuapp.com,Proxy
  - DOMAIN-SUFFIX,vercel.app,Proxy
  - DOMAIN-SUFFIX,vercel.com,Proxy
  - DOMAIN-SUFFIX,netlify.app,Proxy
  - DOMAIN-SUFFIX,netlify.com,Proxy
  - DOMAIN-SUFFIX,pages.dev,Proxy
  - DOMAIN-SUFFIX,workers.dev,Proxy
  - DOMAIN-SUFFIX,r2.dev,Proxy
  - DOMAIN-SUFFIX,firebaseio.com,Proxy
  - DOMAIN-SUFFIX,firebase.google.com,Proxy
  - DOMAIN-SUFFIX,firebaseapp.com,Proxy
  - DOMAIN-SUFFIX,fly.dev,Proxy
  - DOMAIN-SUFFIX,fly.io,Proxy
  - DOMAIN-SUFFIX,railway.app,Proxy
  - DOMAIN-SUFFIX,render.com,Proxy
  - DOMAIN-SUFFIX,onrender.com,Proxy
  - DOMAIN-SUFFIX,supabase.co,Proxy
  - DOMAIN-SUFFIX,supabase.com,Proxy
  - DOMAIN-SUFFIX,deno.land,Proxy
  - DOMAIN-SUFFIX,deno.com,Proxy

  # ─── Apple (mostly accessible from China, keep direct) ───
  - GEOSITE,apple,DIRECT

  # ─── Microsoft (mostly accessible, except LinkedIn above) ───
  - GEOSITE,microsoft,DIRECT

  # ─── China Domestic Services ───
  - DOMAIN-SUFFIX,baidu.com,DIRECT
  - DOMAIN-SUFFIX,doubao.com,DIRECT
  - DOMAIN-SUFFIX,tencent.com,DIRECT
  - DOMAIN-SUFFIX,qq.com,DIRECT
  - DOMAIN-SUFFIX,taobao.com,DIRECT
  - DOMAIN-SUFFIX,jd.com,DIRECT
  - DOMAIN-SUFFIX,sina.com.cn,DIRECT
  - DOMAIN-SUFFIX,163.com,DIRECT
  - DOMAIN-SUFFIX,deepseek.com,DIRECT
  - DOMAIN-SUFFIX,qwen.ai,DIRECT

  # ─── China Direct ───
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT

  # ─── Default: proxy everything else ───
  - MATCH,Proxy
CLASH_RULES

# ─────────────────────────────────────────────
# 11. Firewall
# ─────────────────────────────────────────────
info "Configuring firewall rules..."
if command -v ufw &>/dev/null; then
  ufw allow 443/tcp >/dev/null 2>&1 || true
  info "ufw rule added (443/tcp)."
elif command -v firewall-cmd &>/dev/null; then
  firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
  info "firewalld rule added (443/tcp)."
else
  warn "No ufw or firewalld found. Manually open port 443/tcp."
fi

# ─────────────────────────────────────────────
# 11. Deploy
# ─────────────────────────────────────────────
info "Pulling image..."
docker compose -f "$BASE_DIR/docker-compose.yml" pull -q 2>/dev/null

info "Starting container..."
docker compose -f "$BASE_DIR/docker-compose.yml" up -d

sleep 3
RUNNING=$(docker compose -f "$BASE_DIR/docker-compose.yml" ps --status running -q | wc -l)
if [[ "$RUNNING" -eq 1 ]]; then
  info "Container is running."
else
  warn "Container may not be running. Check with: docker compose -f ${BASE_DIR}/docker-compose.yml ps"
fi

# ─────────────────────────────────────────────
# 12. Share link
# ─────────────────────────────────────────────
VLESS_LINK="vless://${UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&sni=${REALITY_SNI}&fp=chrome&type=tcp#${SERVER_IP}"

# ─────────────────────────────────────────────
# 13. Console output
# ─────────────────────────────────────────────
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}        Punch VLESS-Reality — Deployment Complete          ${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}Server IP:${NC}            ${SERVER_IP}"
echo -e "${GREEN}Port:${NC}                 443/tcp"
echo -e "${GREEN}SNI:${NC}                  ${REALITY_SNI}"
echo ""
echo -e "${YELLOW}── Secrets ──${NC}"
echo -e "  UUID:               ${UUID}"
echo -e "  Reality Public Key: ${REALITY_PUBLIC_KEY}"
echo -e "  Reality Private Key:${REALITY_PRIVATE_KEY}"
echo -e "  Short ID:           ${SHORT_ID}"
echo ""
echo -e "${YELLOW}── Share Link (Shadowrocket / v2rayN / NekoBox) ──${NC}"
echo -e "  ${VLESS_LINK}"
echo ""
echo -e "${YELLOW}── Config Paths ──${NC}"
echo -e "  Server config:      ${BASE_DIR}/reality/config.json"
echo -e "  Clash client:       ${BASE_DIR}/clients/clash.yaml"
echo -e "  docker-compose:     ${BASE_DIR}/docker-compose.yml"
echo ""
echo -e "${CYAN}── Management ──${NC}"
echo -e "  docker compose -f ${BASE_DIR}/docker-compose.yml [ps|logs|restart|down]"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"

# Save output to file
{
  echo "Punch VLESS-Reality — Deployment Summary"
  echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo ""
  echo "Server IP:            ${SERVER_IP}"
  echo "Port:                 443/tcp"
  echo "SNI:                  ${REALITY_SNI}"
  echo ""
  echo "UUID:                 ${UUID}"
  echo "Reality Public Key:   ${REALITY_PUBLIC_KEY}"
  echo "Reality Private Key:  ${REALITY_PRIVATE_KEY}"
  echo "Short ID:             ${SHORT_ID}"
  echo ""
  echo "Share Link:"
  echo "  ${VLESS_LINK}"
  echo ""
  echo "Clash client config: ${BASE_DIR}/clients/clash.yaml"
} >"$BASE_DIR/deploy-output.txt"

info "Deployment summary saved to ${BASE_DIR}/deploy-output.txt"
