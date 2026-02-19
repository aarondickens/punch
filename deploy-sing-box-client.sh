#!/usr/bin/env bash
#
# punch/deploy-sing-box-client.sh — Install sing-box client on macOS via Docker
# Parses a deploy-output.txt and sets up a local VLESS-Reality proxy.
#
# Usage:
#   ./deploy-sing-box-client.sh <deploy-output.txt>
#
# After running, use in terminal:
#   export https_proxy=http://127.0.0.1:7890
#   export http_proxy=http://127.0.0.1:7890
#   export all_proxy=socks5://127.0.0.1:7890
#
set -euo pipefail

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

LISTEN_PORT=7891
BASE_DIR="$HOME/.config/punch-client"
CONFIG_FILE="$BASE_DIR/config.json"
RULES_PATH="$BASE_DIR/rules"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
CONTAINER_NAME="punch-sing-box-client"
SINGBOX_IMAGE="ghcr.io/sagernet/sing-box:latest"

# ─────────────────────────────────────────────
# 1. Args
# ─────────────────────────────────────────────
[[ $# -eq 1 ]] || error "Usage: $0 <deploy-output.txt>"
OUTPUT_FILE="$1"
[[ -f "$OUTPUT_FILE" ]] || error "File not found: $OUTPUT_FILE"

# ─────────────────────────────────────────────
# 2. Preflight
# ─────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  error "Docker not found. Install Docker Desktop for Mac first: https://docs.docker.com/desktop/install/mac-install/"
fi
docker compose version &>/dev/null || error "docker compose plugin not found."

# ─────────────────────────────────────────────
# 3. Parse deploy-output.txt
# ─────────────────────────────────────────────
info "Parsing $OUTPUT_FILE..."

SERVER_IP=$(grep '^Server IP:' "$OUTPUT_FILE" | awk '{print $NF}')
UUID=$(grep '^UUID:' "$OUTPUT_FILE" | awk '{print $NF}')
PUBKEY=$(grep '^Reality Public Key:' "$OUTPUT_FILE" | awk '{print $NF}')
SHORT_ID=$(grep '^Short ID:' "$OUTPUT_FILE" | awk '{print $NF}')
SNI=$(grep '^SNI:' "$OUTPUT_FILE" | awk '{print $NF}')

for var in SERVER_IP UUID PUBKEY SHORT_ID SNI; do
  eval "val=\$$var"
  [[ -n "$val" ]] || error "Could not parse $var from $OUTPUT_FILE"
done

info "Server: $SERVER_IP  SNI: $SNI"

# ─────────────────────────────────────────────
# 4. Stop existing container if running
# ─────────────────────────────────────────────
if [[ -f "$COMPOSE_FILE" ]]; then
  info "Stopping existing client container..."
  docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
fi

# ─────────────────────────────────────────────
# 5. Write client config
# ─────────────────────────────────────────────
info "Writing config to $CONFIG_FILE..."
mkdir -p "$BASE_DIR"

cat >"$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "tls",
        "tag": "google",
        "server": "8.8.8.8",
        "server_port": 853,
        "detour": "proxy"
      },
      {
        "type": "udp",
        "tag": "local",
        "server": "223.5.5.5",
        "server_port": 53
      }
    ],
    "rules": [
      {
        "query_type": ["PTR"],
        "server": "local"
      },
      {
        "rule_set": ["geosite-cn"],
        "server": "local"
      },
      {
        "query_type": ["A", "AAAA"],
        "server": "google"
      }
    ],
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "::",
      "listen_port": ${LISTEN_PORT}
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "${SERVER_IP}",
      "server_port": 443,
      "uuid": "${UUID}",
      "flow": "xtls-rprx-vision",
      "domain_strategy": "prefer_ipv4",
      "tcp_fast_open": true,
      "tcp_multi_path": false,
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "${PUBKEY}",
          "short_id": "${SHORT_ID}"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "default_domain_resolver": "local",
    "rules": [
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      },
      {
        "domain_suffix": [
          "claude-code.club",
          "minimax.io",
          "qwen.ai",
          "deepseek.com",
          "doubao.com",
          "zhipuai.cn",
          "z.ai"
        ],
        "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "tag": "geosite-cn",
        "type": "local",
        "format": "binary",
        "path": "/etc/sing-box/rules/geosite-cn.srs",
      },
      {
        "tag": "geoip-cn",
        "type": "local",
        "format": "binary",
        "path": "/etc/sing-box/rules/geoip-cn.srs",
      }
    ],

    "final": "proxy"
  }
}
EOF

# ─────────────────────────────────────────────
# 6. Validate config
# ─────────────────────────────────────────────
info "Validating config..."
docker run --rm \
  -v "${CONFIG_FILE}:/etc/sing-box/config.json:ro" \
  -v "${RULES_PATH}:/etc/sing-box/rules:ro" \
  "$SINGBOX_IMAGE" check -c /etc/sing-box/config.json ||
  error "Config validation failed."
info "Config is valid."

# ─────────────────────────────────────────────
# 7. Write docker-compose.yml
# ─────────────────────────────────────────────
info "Writing docker-compose.yml..."
cat >"$COMPOSE_FILE" <<EOF
services:
  sing-box-client:
    image: ${SINGBOX_IMAGE}
    container_name: ${CONTAINER_NAME}
    command: ["run", "-c", "/etc/sing-box/config.json"]
    ports:
      - "127.0.0.1:${LISTEN_PORT}:${LISTEN_PORT}"
    volumes:
      - "${CONFIG_FILE}:/etc/sing-box/config.json:ro"
      - "${RULES_PATH}:/etc/sing-box/rules:ro"
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "1m"
EOF

# ─────────────────────────────────────────────
# 8. Start container
# ─────────────────────────────────────────────
info "Pulling image..."
docker compose -f "$COMPOSE_FILE" pull -q 2>/dev/null

info "Starting container..."
docker compose -f "$COMPOSE_FILE" up -d

sleep 3
RUNNING=$(docker compose -f "$COMPOSE_FILE" ps --status running -q | wc -l)
if [[ "$RUNNING" -ge 1 ]]; then
  info "sing-box client is running on 127.0.0.1:${LISTEN_PORT}"
else
  warn "Container may not be running. Check:"
  warn "  docker compose -f $COMPOSE_FILE ps"
  warn "  docker compose -f $COMPOSE_FILE logs"
fi

# ─────────────────────────────────────────────
# 9. Print usage
# ─────────────────────────────────────────────
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}        Punch sing-box Client — Ready                     ${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}Proxy:${NC}  127.0.0.1:${LISTEN_PORT} (HTTP + SOCKS5)"
echo -e "${GREEN}Server:${NC} ${SERVER_IP}:443 (VLESS-Reality)"
echo -e "${GREEN}Config:${NC} ${CONFIG_FILE}"
echo ""
echo -e "${YELLOW}── Use in terminal ──${NC}"
echo ""
echo -e "  export https_proxy=http://127.0.0.1:${LISTEN_PORT}"
echo -e "  export http_proxy=http://127.0.0.1:${LISTEN_PORT}"
echo -e "  export all_proxy=socks5://127.0.0.1:${LISTEN_PORT}"
echo ""
echo -e "${YELLOW}── Add to ~/.zshrc for permanent use ──${NC}"
echo ""
echo -e "  # punch proxy"
echo -e "  export https_proxy=http://127.0.0.1:${LISTEN_PORT}"
echo -e "  export http_proxy=http://127.0.0.1:${LISTEN_PORT}"
echo -e "  export all_proxy=socks5://127.0.0.1:${LISTEN_PORT}"
echo ""
echo -e "${YELLOW}── Management ──${NC}"
echo ""
echo -e "  docker compose -f ${COMPOSE_FILE} ps"
echo -e "  docker compose -f ${COMPOSE_FILE} logs -f"
echo -e "  docker compose -f ${COMPOSE_FILE} restart"
echo -e "  docker compose -f ${COMPOSE_FILE} down"
echo ""
echo -e "${YELLOW}── Quick test ──${NC}"
echo ""
echo -e "  curl -x http://127.0.0.1:${LISTEN_PORT} https://ifconfig.me"
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
