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
REALITY_SNI="archive.ubuntu.com"

# Parse --role flag
ROLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --role)
    ROLE="$2"
    shift 2
    ;;
  *)
    error "Unknown option: $1. Usage: deploy.sh [--role dev|work|video]"
    ;;
  esac
done

if [[ -n "$ROLE" ]]; then
  case "$ROLE" in
  dev | work | video) ;;
  *) error "Invalid role: $ROLE. Must be one of: dev, work, video" ;;
  esac
  info "Role: $ROLE"
fi

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
mkdir -p "$BASE_DIR"/reality

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
# 10. Firewall
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
NODE_NAME="${ROLE:+${ROLE}-}${SERVER_IP}"
VLESS_LINK="vless://${UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&sni=${REALITY_SNI}&fp=chrome&type=tcp#${NODE_NAME}"

# ─────────────────────────────────────────────
# 13. Console output
# ─────────────────────────────────────────────
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}        Punch VLESS-Reality — Deployment Complete          ${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""
if [[ -n "$ROLE" ]]; then
  echo -e "${GREEN}Role:${NC}                 ${ROLE}"
fi
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
echo -e "  docker-compose:     ${BASE_DIR}/docker-compose.yml"
echo -e "  deploy output:      ${BASE_DIR}/deploy-output.txt"
echo ""
echo -e "${CYAN}── Management ──${NC}"
echo -e "  docker compose -f ${BASE_DIR}/docker-compose.yml [ps|logs|restart|down]"
echo ""
echo -e "${CYAN}── Client Config ──${NC}"
echo -e "  Copy deploy-output.txt from each server, then run locally:"
echo -e "  ./gen-clash.sh dev-output.txt work-output.txt video-output.txt"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"

# Save output to file
{
  echo "Punch VLESS-Reality — Deployment Summary"
  echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo ""
  echo "Role:                 ${ROLE:-unset}"
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
} >"$BASE_DIR/deploy-output.txt"

info "Deployment summary saved to ${BASE_DIR}/deploy-output.txt"
