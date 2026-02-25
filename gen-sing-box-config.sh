#!/usr/bin/env bash
#
# punch/gen-sing-box-config.sh — Generate a sing-box client config (JSON)
# from two deploy-output.txt files (work, video).
#
# Usage:
#   ./gen-sing-box-config.sh <work-output.txt> <video-output.txt>
#
# Run locally. Produces sing-box.json for import into SFI/SFA/SFM.
# Requires sing-box 1.11+.
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
error() {
  echo -e "${RED}[ERROR]${NC} $*"
  exit 1
}

[[ $# -eq 2 ]] || error "Usage: $0 <work-output.txt> <video-output.txt>"

WORK_FILE="$1"
VIDEO_FILE="$2"

for f in "$WORK_FILE" "$VIDEO_FILE"; do
  [[ -f "$f" ]] || error "File not found: $f"
done

# ─────────────────────────────────────────────
# Parse a deploy-output.txt into variables
# ─────────────────────────────────────────────
parse_output() {
  local file="$1" prefix="$2"
  local ip uuid pubkey shortid sni
  ip=$(grep '^Server IP:' "$file" | awk '{print $NF}')
  uuid=$(grep '^UUID:' "$file" | awk '{print $NF}')
  pubkey=$(grep '^Reality Public Key:' "$file" | awk '{print $NF}')
  shortid=$(grep '^Short ID:' "$file" | awk '{print $NF}')
  sni=$(grep '^SNI:' "$file" | awk '{print $NF}')

  for var in ip uuid pubkey shortid sni; do
    eval "local val=\$$var"
    [[ -n "$val" ]] || error "Could not parse $var from $file"
  done

  eval "${prefix}_IP='$ip'"
  eval "${prefix}_UUID='$uuid'"
  eval "${prefix}_PUBKEY='$pubkey'"
  eval "${prefix}_SHORTID='$shortid'"
  eval "${prefix}_SNI='$sni'"
}

parse_output "$WORK_FILE" WORK
parse_output "$VIDEO_FILE" VIDEO

info "Parsed: work=$WORK_IP  video=$VIDEO_IP"

OUTPUT="sing-box.json"

cat >"$OUTPUT" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "proxy-dns",
        "address": "tls://8.8.8.8",
        "detour": "Work"
      },
      {
        "tag": "local",
        "address": "223.5.5.5",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "rule_set": ["geosite-cn"],
        "server": "local"
      }
    ],
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 7890
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "work-${WORK_IP}",
      "server": "${WORK_IP}",
      "server_port": 443,
      "uuid": "${WORK_UUID}",
      "flow": "xtls-rprx-vision",
      "domain_strategy": "prefer_ipv4",
      "tls": {
        "enabled": true,
        "server_name": "${WORK_SNI}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "${WORK_PUBKEY}",
          "short_id": "${WORK_SHORTID}"
        }
      }
    },
    {
      "type": "vless",
      "tag": "video-${VIDEO_IP}",
      "server": "${VIDEO_IP}",
      "server_port": 443,
      "uuid": "${VIDEO_UUID}",
      "flow": "xtls-rprx-vision",
      "domain_strategy": "prefer_ipv4",
      "tls": {
        "enabled": true,
        "server_name": "${VIDEO_SNI}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "${VIDEO_PUBKEY}",
          "short_id": "${VIDEO_SHORTID}"
        }
      }
    },
    {
      "type": "selector",
      "tag": "Work",
      "outbounds": ["work-${WORK_IP}", "video-${VIDEO_IP}", "direct"],
      "default": "work-${WORK_IP}"
    },
    {
      "type": "selector",
      "tag": "Video",
      "outbounds": ["video-${VIDEO_IP}", "work-${WORK_IP}", "direct"],
      "default": "video-${VIDEO_IP}"
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      {
        "ip_is_private": true,
        "action": "route",
        "outbound": "direct"
      },
      {
        "rule_set": ["geosite-category-ads-all"],
        "action": "reject"
      },
      {
        "rule_set": ["geosite-openai"],
        "domain_suffix": [
          "anthropic.com",
          "claude.ai",
          "perplexity.ai",
          "gemini.google.com"
        ],
        "outbound": "Work"
      },
      {
        "rule_set": ["geosite-github"],
        "domain_suffix": [
          "ghcr.io",
          "raw.githubusercontent.com",
          "objects.githubusercontent.com",
          "golang.org",
          "go.dev",
          "proxy.golang.org",
          "sum.golang.org",
          "storage.googleapis.com",
          "registry.npmjs.org",
          "npmjs.com",
          "yarnpkg.com",
          "docker.io",
          "docker.com",
          "gcr.io",
          "k8s.io",
          "kubernetes.io",
          "registry.k8s.io",
          "dl.google.com",
          "dl-ssl.google.com",
          "crates.io",
          "static.crates.io",
          "rust-lang.org",
          "static.rust-lang.org",
          "pypi.org",
          "files.pythonhosted.org",
          "rubygems.org",
          "gradle.org",
          "repo.maven.apache.org",
          "plugins.gradle.org",
          "cocoapods.org",
          "cdn.cocoapods.org",
          "homebrew.sh",
          "formulae.brew.sh",
          "stackoverflow.com",
          "stackexchange.com",
          "askubuntu.com",
          "serverfault.com",
          "superuser.com",
          "medium.com",
          "dev.to",
          "hf.co",
          "huggingface.co"
        ],
        "outbound": "Work"
      },
      {
        "rule_set": ["geosite-youtube", "geosite-netflix"],
        "domain_suffix": [
          "spotify.com",
          "spotifycdn.com",
          "scdn.co",
          "twitch.tv",
          "ttvnw.net",
          "jtvnw.net",
          "disneyplus.com",
          "disney-plus.net",
          "bamgrid.com",
          "dssott.com",
          "hulu.com",
          "hbo.com",
          "hbomax.com",
          "max.com",
          "missav.ws",
          "recombee.com",
          "pornhub.com",
          "xhamster.com",
          "faphouselive.com",
          "91tanhua.net",
          "51cg1.com",
          "primevideo.com",
          "aiv-cdn.net",
          "soundcloud.com",
          "sndcdn.com",
          "pandora.com",
          "vimeo.com",
          "vimeocdn.com",
          "dailymotion.com"
        ],
        "outbound": "Video"
      },
      {
        "rule_set": ["geosite-google"],
        "outbound": "Work"
      },
      {
        "rule_set": ["geosite-twitter", "geosite-facebook", "geosite-telegram"],
        "domain_suffix": [
          "reddit.com",
          "redd.it",
          "redditmedia.com",
          "redditstatic.com",
          "discord.com",
          "discord.gg",
          "discordapp.com",
          "discordapp.net",
          "instagram.com",
          "cdninstagram.com",
          "linkedin.com",
          "licdn.com",
          "pinterest.com",
          "pinimg.com",
          "whatsapp.com",
          "whatsapp.net",
          "line.me",
          "line-scdn.net",
          "naver.jp",
          "signal.org"
        ],
        "outbound": "Work"
      },
      {
        "domain_suffix": [
          "wikipedia.org",
          "wikimedia.org",
          "wiktionary.org",
          "nytimes.com",
          "wsj.com",
          "bbc.com",
          "bbc.co.uk",
          "reuters.com",
          "theguardian.com",
          "apnews.com",
          "archive.org"
        ],
        "outbound": "Work"
      },
      {
        "domain_suffix": [
          "cloudfront.net",
          "amazonaws.com",
          "s3.amazonaws.com",
          "heroku.com",
          "herokuapp.com",
          "vercel.app",
          "vercel.com",
          "netlify.app",
          "netlify.com",
          "pages.dev",
          "workers.dev",
          "r2.dev",
          "firebaseio.com",
          "firebase.google.com",
          "firebaseapp.com",
          "fly.dev",
          "fly.io",
          "railway.app",
          "render.com",
          "onrender.com",
          "supabase.co",
          "supabase.com",
          "deno.land",
          "deno.com"
        ],
        "outbound": "Work"
      },
      {
        "rule_set": ["geosite-apple"],
        "outbound": "direct"
      },
      {
        "rule_set": ["geosite-microsoft"],
        "outbound": "direct"
      },
      {
        "domain_suffix": [
          "claude-code.club",
          "baidu.com",
          "doubao.com",
          "tencent.com",
          "qq.com",
          "taobao.com",
          "jd.com",
          "sina.com.cn",
          "sohu.com",
          "163.com",
          "deepseek.com",
          "qwen.ai",
          "douban.com",
          "minimax.io",
          "minimaxi.com",
          "zhipuai.cn",
          "z.ai",
          "tencencloud.com",
          "aliyun.com"
        ],
        "outbound": "direct"
      },
      {
        "rule_set": ["geosite-cn"],
        "outbound": "direct"
      },
      {
        "rule_set": ["geoip-cn"],
        "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "tag": "geosite-category-ads-all",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs",
        "download_detour": "Work"
      },
      {
        "tag": "geosite-openai",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs",
        "download_detour": "Work"
      },
      {
        "tag": "geosite-github",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-github.srs",
        "download_detour": "Work"
      },
      {
        "tag": "geosite-youtube",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-youtube.srs",
        "download_detour": "Work"
      },
      {
        "tag": "geosite-netflix",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-netflix.srs",
        "download_detour": "Work"
      },
      {
        "tag": "geosite-google",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google.srs",
        "download_detour": "Work"
      },
      {
        "tag": "geosite-twitter",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-twitter.srs",
        "download_detour": "Work"
      },
      {
        "tag": "geosite-facebook",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-facebook.srs",
        "download_detour": "Work"
      },
      {
        "tag": "geosite-telegram",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-telegram.srs",
        "download_detour": "Work"
      },
      {
        "tag": "geosite-apple",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-apple.srs",
        "download_detour": "Work"
      },
      {
        "tag": "geosite-microsoft",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-microsoft.srs",
        "download_detour": "Work"
      },
      {
        "tag": "geosite-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "download_detour": "Work"
      },
      {
        "tag": "geoip-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        "download_detour": "Work"
      }
    ],
    "final": "Work"
  },
  "experimental": {
    "cache_file": {
      "enabled": true
    }
  }
}
EOF

info "Generated $OUTPUT"
info "Import into sing-box client (SFI/SFA/SFM)."
