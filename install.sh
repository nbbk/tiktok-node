#!/usr/bin/env bash
# TikTok 运营节点一键部署：VLESS + WS (+TLS)，DNS 防泄漏 + 禁 IPv6
# 用法：
#   本地：bash install.sh [域名]
#   远程一键：curl -fsSL https://raw.githubusercontent.com/nbbk/tiktok-node/main/install.sh | bash -s [域名]
#   （不给域名则交互询问；直接回车用 IP + 明文跑）
#   端口可预设：HTTPS_PORT=8443 bash install.sh [域名]（TLS 模式，默认 443）
#              WS_PORT=9080 bash install.sh（明文模式，默认 8080）
# 架构：有域名 -> Caddy 在 HTTPS 端口（默认 443，可改高位端口）终止 TLS，反代本机 xray 的 WS 入站
#        无域名 -> xray 直接在 WS 端口（默认 8080，可改）跑明文 WS（能用，但不如 TLS 隐蔽）
# 注意：TLS 模式 80 端口必须空闲（Caddy 签证书走 HTTP-01 验证必须用 80）；80 被占则 TLS 装不了。
# DNS 防泄漏设计：
#   1) xray 自身解析走 DoH(1.1.1.1/8.8.8.8) + TCP 兜底，不走 UDP 53 明文 DNS
#   2) queryStrategy=UseIPv4，只解析 A 记录，不产生 AAAA/IPv6 解析路径
#   3) 主机级禁用 IPv6（sysctl 持久化），堵死 IPv6 泄漏口
#   4) 客户端用随包生成的 clash.yaml：全部 DNS 走代理 DoH、ipv6: false
#      （节点只能管住服务端这一半，手机端设置见 README，装完务必跑 check.sh）
set -euo pipefail

# 工作目录：本地跑 bash install.sh 时用脚本所在目录；
# 远程一键（curl | bash 或 bash <(...)）时用 ~/tiktok-node-kit
if [ -f "$0" ]; then
  cd "$(dirname "$0")"
else
  mkdir -p "$HOME/tiktok-node-kit"
  cd "$HOME/tiktok-node-kit"
fi

DRY_RUN="${DRY_RUN:-0}"
TLS_MODE=1
CLI_DOMAIN="${1:-}"
DOMAIN="${DOMAIN:-}"
SERVER_IP="${SERVER_IP:-}"

# ---------- 交互输入：远程一键时 stdin 是管道，用 /dev/tty 直接问终端 ----------
# 已通过命令行参数/环境变量预设的值不再询问（便于自动化与测试）
ask() {
  local prompt="$1" varname="$2" default="${3:-}"
  if [ -n "${!varname:-}" ]; then return 0; fi
  local ans=""
  if [ -t 0 ]; then
    read -rp "$prompt" ans || true
  elif [ -r /dev/tty ]; then
    read -rp "$prompt" ans </dev/tty 2>/dev/null || true
  fi
  [ -z "$ans" ] && ans="$default"
  printf -v "$varname" '%s' "$ans"
}

valid_port() {  # 1-65535 的整数（高位端口如 8443、24443、30000 都可以）
  case "$1" in ''|*[!0-9]*) return 1;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

ask_port() {  # ask_port "提示" 变量名 默认值：反复问到拿到合法端口
  local prompt="$1" varname="$2" default="$3" ans=""
  while :; do
    ask "$prompt" "$varname" "$default"
    ans="${!varname}"
    if valid_port "$ans"; then return 0; fi
    echo "端口不合法：$ans（要填 1-65535 的数字）"
    printf -v "$varname" '%s' ""
  done
}

# ---------- 端口占用预检（ss -> netstat -> /proc 回退） ----------
port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
  else
    local hex
    hex=$(printf '%04X' "$port")
    grep -qiE "^[[:space:]]*[0-9]+:[[:space:]]+[0-9A-Fa-f]+:${hex}[[:space:]]" /proc/net/tcp /proc/net/tcp6 2>/dev/null
  fi
}

port_owner() {  # 打印占用指定端口的进程（ss 能看到时）
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep -E "[:.]${1}[[:space:]]" | sed 's/^/    /' || true
  fi
}

if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] 只生成配置文件，不安装、不改系统"
  [ -n "$SERVER_IP" ] || SERVER_IP="203.0.113.1"
fi

echo "== 1/6 检查 Docker =="
if [ "$DRY_RUN" != "1" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "未检测到 Docker，正在安装..."
    curl -fsSL https://get.docker.com | sh
  fi
  docker compose version >/dev/null 2>&1 || { echo "缺少 Docker Compose 插件，请先安装 docker-compose-plugin"; exit 1; }
fi

echo "== 2/6 域名与端口 =="
# 端口预设优先级：环境变量 > .env > 交互输入（直接回车用默认）
ENV_HTTPS_PORT="${HTTPS_PORT:-}"
ENV_WS_PORT="${WS_PORT:-}"
# 优先级：命令行参数 > .env > 环境变量 > 交互输入 > 留空走明文
if [ -f .env ]; then set -a; . ./.env; set +a; fi
DOMAIN="${CLI_DOMAIN:-${DOMAIN:-}}"
if [ -z "$DOMAIN" ] && [ "$DRY_RUN" != "1" ]; then
  echo "请填写你的域名："
  ask "域名（已解析到本机；没有直接回车，用 IP 明文跑）： " DOMAIN
fi
if [ -z "$DOMAIN" ]; then
  TLS_MODE=0
  echo "无域名：明文 WS 模式，建议之后补域名重跑以启用 TLS"
else
  echo "域名：$DOMAIN（TLS 模式）"
fi

# 端口：默认 443（TLS）/ 8080（明文），可自定义高位端口避开占用
if [ "$TLS_MODE" = "1" ]; then
  HTTPS_PORT="${ENV_HTTPS_PORT:-${HTTPS_PORT:-}}"
  if [ "$DRY_RUN" != "1" ]; then
    echo "HTTPS 端口用默认 443 还是自定义？（443 被占时可改高位端口，如 8443、24443）："
    ask_port "HTTPS 端口（默认 443，直接回车就是 443）： " HTTPS_PORT "443"
    while [ "$HTTPS_PORT" = "80" ]; do
      echo "HTTPS 端口不能填 80（80 要留给 Caddy 签证书验证用），请换一个："
      HTTPS_PORT=""
      ask_port "HTTPS 端口（默认 443，直接回车就是 443）： " HTTPS_PORT "443"
    done
  else
    HTTPS_PORT="${HTTPS_PORT:-443}"
  fi
  echo "HTTPS 端口：$HTTPS_PORT"
else
  WS_PORT="${ENV_WS_PORT:-${WS_PORT:-}}"
  if [ "$DRY_RUN" != "1" ]; then
    echo "WS 端口用默认 8080 还是自定义？（8080 被占时可改高位端口，如 9080、30000）："
    ask_port "WS 端口（默认 8080，直接回车就是 8080）： " WS_PORT "8080"
  else
    WS_PORT="${WS_PORT:-8080}"
  fi
  echo "WS 端口：$WS_PORT"
fi

# 端口预检：按最终选定的端口查占用，被占就明确说哪个端口被谁占了并退出
echo "端口预检："
if [ "$DRY_RUN" != "1" ]; then
  if [ "$TLS_MODE" = "1" ]; then
    if port_in_use 80; then
      echo "80 端口已被占用，TLS 装不了（Caddy 签证书走 HTTP-01 验证必须用 80）："
      port_owner 80
      echo "建议：换一台 80 空闲的服务器，或不填域名重跑走明文模式。"
      exit 1
    fi
    if port_in_use "$HTTPS_PORT"; then
      echo "$HTTPS_PORT 端口已被占用，装不了："
      port_owner "$HTTPS_PORT"
      echo "建议：停掉占用它的程序，或重跑并把 HTTPS 端口改成别的（如 8443、24443）。"
      exit 1
    fi
    echo "80 与 $HTTPS_PORT 端口空闲。"
  else
    if port_in_use "$WS_PORT"; then
      echo "$WS_PORT 端口已被占用，装不了："
      port_owner "$WS_PORT"
      echo "建议：停掉占用它的程序，或重跑并把 WS 端口改成别的（如 9080、30000）。"
      exit 1
    fi
    echo "$WS_PORT 端口空闲。"
  fi
else
  echo "[dry-run] 跳过端口预检"
fi

if [ "$TLS_MODE" = "0" ] && [ -z "$SERVER_IP" ]; then
  SERVER_IP="$(curl -s --max-time 5 https://api.ipify.org || true)"
  [ -n "$SERVER_IP" ] || SERVER_IP="$(curl -s --max-time 5 https://ifconfig.me || true)"
  [ -n "$SERVER_IP" ] || { echo "拿不到本机公网 IP，请手动在 .env 写 SERVER_IP=你的IP 后重跑"; exit 1; }
fi

echo "== 3/6 生成 UUID 与 WS 路径 =="
UUID="$(cat /proc/sys/kernel/random/uuid)"
WSPATH="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
echo "UUID: $UUID"
echo "WS 路径: /$WSPATH"

echo "== 4/6 禁用 IPv6（防泄漏） =="
if [ "$DRY_RUN" != "1" ]; then
  cat > /etc/sysctl.d/99-tiktok-node.conf <<'SYSCTL'
# TikTok 节点：禁用 IPv6，堵死 IPv6 泄漏口
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSCTL
  sysctl -p /etc/sysctl.d/99-tiktok-node.conf >/dev/null
  echo "IPv6 已禁用：$(sysctl -n net.ipv6.conf.all.disable_ipv6)"
else
  echo "[dry-run] 跳过写 /etc/sysctl.d"
fi

echo "== 5/6 写入配置 =="
cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": [
      { "address": "https+local://1.1.1.1/dns-query" },
      { "address": "https+local://8.8.8.8/dns-query" },
      { "address": "tcp://1.1.1.1", "port": 53 }
    ],
    "queryStrategy": "UseIPv4",
    "disableCache": false
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 10000,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/$WSPATH" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF

if [ "$TLS_MODE" = "1" ]; then
  cat > Caddyfile <<EOF
$DOMAIN:$HTTPS_PORT {
    handle /$WSPATH {
        reverse_proxy xray:10000
    }
    handle {
        respond "ok" 200
    }
}
EOF
  cat > docker-compose.yml <<EOF
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: tiktok-xray
    restart: unless-stopped
    volumes:
      - ./config.json:/usr/local/etc/xray/config.json:ro
  caddy:
    image: caddy:2
    container_name: tiktok-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "$HTTPS_PORT:$HTTPS_PORT"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - xray
volumes:
  caddy_data:
  caddy_config:
EOF
else
  cat > docker-compose.yml <<EOF
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: tiktok-xray
    restart: unless-stopped
    ports:
      - "$WS_PORT:10000"
    volumes:
      - ./config.json:/usr/local/etc/xray/config.json:ro
EOF
fi

# 客户端 Clash 配置：全部流量走节点；DNS 全部走代理 DoH；禁 IPv6
if [ "$TLS_MODE" = "1" ]; then
  cat > clash.yaml <<EOF
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
ipv6: false
dns:
  enable: true
  ipv6: false
  listen: 0.0.0.0:1053
  enhanced-mode: redir-host
  nameserver:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  proxy-server-nameserver:
    - https://dns.cloudflare.com/dns-query
  nameserver-policy:
    "+.tiktok.com":
      - https://dns.cloudflare.com/dns-query
proxies:
  - name: "TikTok-Node"
    type: vless
    server: $DOMAIN
    port: $HTTPS_PORT
    uuid: $UUID
    tls: true
    servername: $DOMAIN
    network: ws
    ws-opts:
      path: /$WSPATH
      headers:
        Host: $DOMAIN
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "TikTok-Node"
rules:
  - MATCH,PROXY
EOF
  LINK="vless://$UUID@$DOMAIN:$HTTPS_PORT?encryption=none&security=tls&type=ws&host=$DOMAIN&path=%2F$WSPATH#TikTok-Node"
else
  cat > clash.yaml <<EOF
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
ipv6: false
dns:
  enable: true
  ipv6: false
  listen: 0.0.0.0:1053
  enhanced-mode: redir-host
  nameserver:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  proxy-server-nameserver:
    - https://dns.cloudflare.com/dns-query
  nameserver-policy:
    "+.tiktok.com":
      - https://dns.cloudflare.com/dns-query
proxies:
  - name: "TikTok-Node"
    type: vless
    server: $SERVER_IP
    port: $WS_PORT
    uuid: $UUID
    tls: false
    network: ws
    ws-opts:
      path: /$WSPATH
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "TikTok-Node"
rules:
  - MATCH,PROXY
EOF
  LINK="vless://$UUID@$SERVER_IP:$WS_PORT?encryption=none&security=none&type=ws&path=%2F$WSPATH#TikTok-Node"
fi
SUB=$(printf '%s' "$LINK" | base64 -w0)

# 安装记录：端口、域名、WS 路径写进 .env，供 check.sh / stop.sh 读实际端口（重跑时默认沿用上次的）
{
  echo "# tiktok-node 安装记录（install.sh 生成；重跑时域名与端口默认沿用上次的）"
  echo "DOMAIN=$DOMAIN"
  echo "TLS_MODE=$TLS_MODE"
  if [ "$TLS_MODE" = "1" ]; then echo "HTTPS_PORT=$HTTPS_PORT"; else echo "WS_PORT=$WS_PORT"; fi
  echo "SERVER_IP=$SERVER_IP"
  echo "WSPATH=$WSPATH"
} > .env

echo "== 6/6 启动并拨测 =="
if [ "$DRY_RUN" != "1" ]; then
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    if [ "$TLS_MODE" = "1" ]; then ufw allow 80/tcp >/dev/null; ufw allow "$HTTPS_PORT"/tcp >/dev/null;
    else ufw allow "$WS_PORT"/tcp >/dev/null; fi
    echo "ufw 已放行对应端口"
  fi
  # --force-recreate：重跑脚本换了 UUID/路径时，旧容器必须重建才生效
  docker compose up -d --force-recreate
  sleep 3
  if [ "$TLS_MODE" = "1" ]; then
    CODE=""
    for i in $(seq 1 30); do
      CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN:$HTTPS_PORT/" || true)
      [ "$CODE" = "200" ] && break
      sleep 3
    done
    echo "首页 https://$DOMAIN:$HTTPS_PORT/ -> HTTP ${CODE:-无响应}（200 = Caddy 与证书正常）"
    WSCODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" "https://$DOMAIN:$HTTPS_PORT/$WSPATH" || true)
    echo "WS 握手 https://$DOMAIN:$HTTPS_PORT/$WSPATH -> HTTP ${WSCODE:-无响应}（101 = 正常；200 = Caddy 没转给 xray，跑 docker compose down && docker compose up -d 重建；400 = xray 拒绝握手）"
  else
    WSCODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$SERVER_IP:$WS_PORT/$WSPATH" || true)
    echo "WS 端口 -> HTTP ${WSCODE:-无响应}（400 = xray 已响应，正常）"
    WSCODE2=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" "http://$SERVER_IP:$WS_PORT/$WSPATH" || true)
    echo "WS 握手 -> HTTP ${WSCODE2:-无响应}（101 = 正常）"
  fi
else
  echo "[dry-run] 跳过启动与拨测"
fi

QR_OK=0
if ! command -v qrencode >/dev/null 2>&1; then
  echo "本机没有 qrencode，尝试安装..."
  if command -v apt-get >/dev/null 2>&1; then
    timeout 180 apt-get update -qq >/dev/null 2>&1 || true
    timeout 180 apt-get install -y -qq qrencode >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    timeout 180 yum install -y -q qrencode >/dev/null 2>&1 || true
  fi
fi
if command -v qrencode >/dev/null 2>&1; then
  qrencode -o qr.png -s 8 "$LINK" && QR_OK=1
elif command -v python3 >/dev/null 2>&1; then
  if python3 - "$LINK" <<'PY'
import sys
try:
    import qrcode
except ImportError:
    sys.exit(1)
qrcode.make(sys.argv[1]).save("qr.png")
PY
  then QR_OK=1; fi
fi

echo ""
echo "================ 部署完成 ================"
echo "节点链接（小火箭/Clash 可直接导入）："
echo "$LINK"
echo ""
echo "订阅内容（base64）："
echo "$SUB"
echo ""
echo "Clash 配置已生成：$(pwd)/clash.yaml（DNS 全走代理、禁 IPv6，直接导入 Clash/Stash）"
if [ "$QR_OK" = "1" ]; then
  echo "二维码已生成：$(pwd)/qr.png（下载到手机扫码即可）"
else
  echo "本机没生成二维码：把上面的节点链接发给 Muse，它会回你二维码图片。"
fi
echo ""
echo "注意：链接里的 UUID 就是密码，不要外传。"
echo "下一步：运行 bash check.sh 做泄漏自检，再按 README 配手机端。"
# check.sh 由 install.sh 内嵌生成（远程一键时只有一个文件）
cat > check.sh <<'CHECK_EOF'
#!/usr/bin/env bash
# TikTok 节点泄漏自检：在节点服务器上运行，检查 IP 纯净度、地区、IPv6、DNS、TikTok 可达性、节点端口
# 手机端的 DNS/WebRTC 泄漏需在手机上验证（脚本末尾会给出检查方法）
# 端口不写死：优先读同目录 .env（install.sh 写下的实际端口），没有就读 clash.yaml，再没有回退默认 443/8080
set -uo pipefail

pass() { echo "  [通过] $1"; }
warn() { echo "  [注意] $1"; }
fail() { echo "  [风险] $1"; }

echo "== 1/6 节点 IP 与地区 =="
IPJSON="$(curl -s --max-time 10 "https://ip-api.org/json/" || true)"
if [ -z "$IPJSON" ]; then
  warn "ip-api.org 查不到，改用 ipinfo.io"
  IPJSON="$(curl -s --max-time 10 "https://ipinfo.io/json" || true)"
fi
if command -v python3 >/dev/null 2>&1 && [ -n "$IPJSON" ]; then
  python3 - "$IPJSON" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("  [注意] IP 查询返回异常"); sys.exit(0)
ip = d.get("query") or d.get("ip", "?")
country = d.get("country") or d.get("countryCode", "?")
cc = d.get("countryCode") or ""
city = d.get("city") or d.get("region", "?")
isp = d.get("isp") or d.get("org", "?")
hosting = d.get("hosting")
print(f"  节点 IP：{ip}")
print(f"  地区：{country} {cc} / {city}")
print(f"  运营商/机房：{isp}")
if hosting is True:
    print("  [风险] 这是机房 IP（hosting=true）。TikTok 对机房 IP 风控更严，")
    print("        容易限流/0播放。如果之后播放量异常，优先换住宅/ISP 的干净 IP。")
elif hosting is False:
    print("  [通过] 看起来是住宅/ISP IP（hosting=false），TikTok 风控相对友好。")
else:
    print("  [注意] 查不到 hosting 标记，可在 https://ipinfo.io 再核对一次。")
PY
else
  echo "  原始结果：$IPJSON"
fi

echo ""
echo "== 2/6 IPv6 是否禁用 =="
V6="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "?")"
if [ "$V6" = "1" ]; then
  pass "IPv6 已禁用（disable_ipv6=1）"
else
  fail "IPv6 未禁用（disable_ipv6=$V6）。跑 install.sh 时会自动禁用；手动执行："
  echo "       echo 'net.ipv6.conf.all.disable_ipv6 = 1' >> /etc/sysctl.d/99-tiktok-node.conf && sysctl -p"
fi
if ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
  fail "本机仍有全局 IPv6 地址，存在 IPv6 泄漏口"
else
  pass "本机无全局 IPv6 地址"
fi

echo ""
echo "== 3/6 DNS 解析路径 =="
if command -v dig >/dev/null 2>&1; then
  RESOLVER="$(dig +short whoami.akamai.net @1.1.1.1 2>/dev/null | head -1)"
  [ -n "$RESOLVER" ] && echo "  经 1.1.1.1 解析的出口解析器 IP：$RESOLVER（应为 Cloudflare 的 IP，非国内运营商）"
  [ -z "$RESOLVER" ] && warn "dig 查询无返回，检查本机出站 UDP/TCP 53 是否被墙"
else
  warn "本机无 dig，跳过解析器核对（apt install dnsutils 可装）"
fi
echo "  xray 已配置 DoH(1.1.1.1/8.8.8.8)+TCP 兜底、只解析 IPv4，服务端不再走明文 UDP 53"

echo ""
echo "== 4/6 TikTok 可达性（从节点 IP 出口测） =="
TT_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://www.tiktok.com/" || true)"
API_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://api16-normal-c-useast1a.tiktokv.com/" || true)"
echo "  tiktok.com -> HTTP $TT_CODE"
echo "  TikTok API 域名 -> HTTP $API_CODE"
if [ "$TT_CODE" = "200" ] || [ "$TT_CODE" = "301" ] || [ "$TT_CODE" = "302" ]; then
  pass "TikTok 主站从节点 IP 可达"
else
  fail "TikTok 主站从节点 IP 不可达（HTTP $TT_CODE），检查节点 IP 是否被 TikTok 拉黑或出站被墙"
fi

echo ""
echo "== 5/6 手机端自查（在手机上开着节点做） =="
echo "  节点只能管服务端这一半，手机端泄漏要这样验："
echo "  1) 打开 https://www.dnsleaktest.com 点 Extended test："
echo "     全部 DNS 服务器 IP 应该都是节点所在国家/机房的，出现中国运营商 DNS = 泄漏"
echo "  2) 打开 https://browserleaks.com/ip："
echo "     不能出现你的真实 IP、不能出现 IPv6 地址、时区/语言要和节点地区一致"
echo "  3) TikTok 里刷几个视频再看个人主页地区：应与节点地区一致"
echo "  4) 手机设置核对（见 README）：已拔国内 SIM 卡、时区语言=节点地区、定位已关"
echo ""
echo "== 6/6 节点端口连通性 =="
# 读安装记录（install.sh 写下的实际端口），没有就读 clash.yaml，再没有回退默认
CK_DIR="$(cd "$(dirname "$0")" && pwd)"
CK_TLS=""; CK_PORT=""; CK_HOST=""; CK_PATH=""; CK_PROTO="http"
if [ -f "$CK_DIR/.env" ]; then set -a; . "$CK_DIR/.env" 2>/dev/null; set +a; fi
if [ "${TLS_MODE:-}" = "1" ]; then
  CK_TLS=1; CK_PORT="${HTTPS_PORT:-443}"; CK_HOST="${DOMAIN:-}"; CK_PROTO="https"; CK_PATH="/${WSPATH:-}"
elif [ "${TLS_MODE:-}" = "0" ]; then
  CK_TLS=0; CK_PORT="${WS_PORT:-8080}"; CK_HOST="${SERVER_IP:-}"; CK_PROTO="http"; CK_PATH="/${WSPATH:-}"
elif [ -f "$CK_DIR/clash.yaml" ]; then
  CK_PORT="$(grep -m1 -E '^    port: ' "$CK_DIR/clash.yaml" | awk '{print $2}')"
  CK_TLS_TXT="$(grep -m1 -E '^    tls: ' "$CK_DIR/clash.yaml" | awk '{print $2}')"
  CK_HOST="$(grep -m1 -E '^    server: ' "$CK_DIR/clash.yaml" | awk '{print $2}')"
  CK_PATH="$(grep -m1 -E '^      path: ' "$CK_DIR/clash.yaml" | awk '{print $2}')"
  if [ "$CK_TLS_TXT" = "true" ]; then CK_TLS=1; CK_PROTO="https"; else CK_TLS=0; CK_PROTO="http"; fi
  [ -n "$CK_PORT" ] || CK_PORT=443
fi
if [ -z "$CK_HOST" ] || [ -z "$CK_PORT" ]; then
  warn "没找到节点端口记录（.env / clash.yaml 都不在），跳过端口自检；按默认端口 443（TLS）/ 8080（明文）核对即可"
elif [ -n "$CK_PATH" ] && [ "$CK_PATH" != "/" ]; then
  echo "  节点地址：$CK_PROTO://$CK_HOST:$CK_PORT$CK_PATH"
  CK_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" "$CK_PROTO://$CK_HOST:$CK_PORT$CK_PATH" || true)"
  echo "  WS 握手 -> HTTP $CK_CODE"
  if [ "$CK_CODE" = "101" ]; then
    pass "WS 握手 101，节点端口正常"
  elif [ "$CK_CODE" = "400" ]; then
    pass "WS 端口已响应（400 = xray 已响应，正常）"
  elif [ "$CK_CODE" = "200" ]; then
    fail "WS 握手返回 200：Caddy 没把请求转给 xray，跑 docker compose down && docker compose up -d 重建"
  else
    fail "WS 握手无响应（HTTP $CK_CODE）：检查端口 $CK_PORT 是否放行、容器是否在跑"
  fi
else
  echo "  节点地址：$CK_PROTO://$CK_HOST:$CK_PORT/"
  CK_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$CK_PROTO://$CK_HOST:$CK_PORT/" || true)"
  echo "  首页 -> HTTP $CK_CODE"
  if [ "$CK_CODE" = "200" ]; then pass "节点端口 $CK_PORT 可达"; else fail "节点端口 $CK_PORT 不可达（HTTP $CK_CODE）"; fi
fi

echo ""
echo "自检完成。"
CHECK_EOF
chmod +x check.sh

if [ "$DRY_RUN" != "1" ]; then
  echo ""
  bash check.sh || true
fi
