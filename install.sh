#!/usr/bin/env bash
# TikTok 运营节点一键部署：VLESS + WS (+TLS)，DNS 防泄漏 + 禁 IPv6
# 用法：
#   本地：bash install.sh [域名]
#   远程一键：curl -fsSL https://raw.githubusercontent.com/nbbk/tiktok-node/main/install.sh | bash -s [域名]
#   （不给域名则交互询问；直接回车用 IP + 明文跑）
#   追加节点：一台落地机跑多个节点时用 bash install.sh --add-node（事后追加）；
#             装完也会问“还要再加一个节点吗？”。追加的节点共用一个 Caddy 的 443，按域名分流，
#             各节点 UUID、WS 路径、后端容器都独立，重跑 install.sh 只换首节点凭据，追加的节点不受影响。
#   删除单个节点：bash install.sh --del-node [子域名或编号]（不给参数就列出节点让你选）
#   端口可预设：HTTPS_PORT=8443 bash install.sh [域名]（TLS 模式，默认 443）
#              WS_PORT=9080 bash install.sh（明文模式，默认 8080）
#   证书方式可预设：CERT_METHOD=dns CLOUDFLARE_API_TOKEN=你的令牌 bash install.sh [域名]
#              （CERT_METHOD=1/http 走 80，=2/dns 走 DNS 验证；令牌见 README“证书签发方式”一节）
# 架构：有域名 -> Caddy 在 HTTPS 端口（默认 443，可改高位端口）终止 TLS，反代本机 xray 的 WS 入站
#        无域名 -> xray 直接在 WS 端口（默认 8080，可改）跑明文 WS（能用，但不如 TLS 隐蔽）
# 多节点：一台落地机可跑多个节点，共用一个 Caddy 的 443，按域名（Host/SNI）分流到不同 xray 容器；
#        每个节点一个子域名，推荐一条泛域名 A 记录 *.example.com 指到落地 IP，一次配好；
#        证书方式沿用首次安装选的（http 逐个子域名自动签；dns 每个子域名自动签，全自动续签）
# 证书签发方式（有域名时安装会问，二选一，默认走 80）：
#   [1] 默认走 80（HTTP-01）：最简单，什么都不用准备；要求 80 空闲
#   [2] DNS 验证（Cloudflare，DNS-01）：不用 80、不改指向、续签全自动；要一个 Cloudflare API 令牌
# 注意：选 [1] 时 TLS 模式 80 端口必须空闲（Caddy 签证书走 HTTP-01 验证必须用 80）；80 被占则 TLS 装不了。
#        选 [2] 时 80 被占也不影响签证书和续签。
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
DOMAIN="${DOMAIN:-}"
SERVER_IP="${SERVER_IP:-}"

# ---------- 命令行参数：--add-node / --del-node [子域名或编号] / [域名] ----------
ADD_NODE=0
DEL_NODE=0
DEL_TARGET=""
DOMAIN_ARG=""
ADD_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --add-node) ADD_NODE=1; ADD_ARG="${2:-}"; [ -n "${2:-}" ] && shift ;;
    --del-node) DEL_NODE=1; DEL_TARGET="${2:-}"; [ -n "${2:-}" ] && shift ;;
    --del-node=*) DEL_NODE=1; DEL_TARGET="${1#--del-node=}" ;;
    --add-node=*) ADD_NODE=1; ADD_ARG="${1#--add-node=}" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      echo "用法：bash install.sh [域名]"
      echo "     bash install.sh --add-node [新子域名]   追加一个节点"
      echo "     bash install.sh --del-node [子域名或编号] 删除单个节点"
      exit 0 ;;
    *) [ -z "$DOMAIN_ARG" ] && DOMAIN_ARG="$1" ;;
  esac
  shift
done
CLI_DOMAIN="$DOMAIN_ARG"

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

# 证书签发方式：每个选项先印几行解释（作用、适合谁、要什么、代价），再问；直接回车默认 1
ask_cert_method() {
  local ans=""
  while :; do
    echo "证书签发方式（Caddy 自动签 TLS 证书，两种方式选一种）："
    echo ""
    echo "  [1] 默认走 80 端口（HTTP-01）← 默认，直接回车就是 1"
    echo "      最简单，什么都不用准备，装完 Caddy 自己签证书、到期自己续。"
    echo "      前提：80 端口必须空闲，域名要指向这台落地机。"
    echo "      适合：单节点、80 没被占的情况。"
    echo ""
    echo "  [2] DNS 验证（Cloudflare，DNS-01）"
    echo "      不用 80 端口，域名不用改来改去，续签全自动，不怕忘。"
    echo "      前提：域名 DNS 在 Cloudflare，要去 Cloudflare 后台开一个只给改 DNS 权限的 API 令牌。"
    echo "      适合：80 被占了、多节点、怕忘续签的情况。"
    echo ""
    echo "请输入你的选择："
    ask "证书签发方式（1=走 80，2=DNS 验证；默认 1，直接回车就是 1）： " CERT_METHOD "1"
    ans="$CERT_METHOD"
    case "$ans" in
      1|http) CERT_METHOD="http"; return 0 ;;
      2|dns) CERT_METHOD="dns"; return 0 ;;
      *) echo "输入不合法：$ans（只能填 1 或 2），请重新输入。"; CERT_METHOD="" ;;
    esac
  done
}

# Cloudflare API 令牌：输入不回显、不打印；空输入重问；格式不对时提醒一次（新版 cfut_ 开头、旧版 40 位都接受）
ask_cf_token() {
  local ans=""
  while :; do
    echo "请填写 Cloudflare API 令牌："
    echo "  去 Cloudflare 后台开：My Profile → API Tokens → Create Token → 用“Edit zone DNS”模板，"
    echo "  只给改 DNS 的权限（Zone:DNS:Edit），不要用 Global API Key。"
    echo "  详细步骤见 CLOUDFLARE_TOKEN.md（新版令牌以 cfut_ 开头）。"
    if [ -t 0 ]; then
      read -rsp "Cloudflare API 令牌（输入时不显示，粘贴后回车）： " ans || true
    elif [ -r /dev/tty ]; then
      read -rsp "Cloudflare API 令牌（输入时不显示，粘贴后回车）： " ans </dev/tty 2>/dev/null || true
    fi
    echo ""
    if [ -z "$ans" ]; then echo "令牌不能为空，请重新输入。"; continue; fi
    # 新版令牌以 cfut_ 开头，旧版是 40 位十六进制；两者都接受，格式不对只提醒、不拦
    case "$ans" in
      cfut_*) ;;
      *) if [ "${#ans}" -ne 40 ]; then echo "提醒：新版令牌以 cfut_ 开头，旧版是 40 位；你填的是 ${#ans} 位，请核对一下（确认无误就继续用，错了证书会签不下来）。"; fi ;;
    esac
    printf -v CLOUDFLARE_API_TOKEN '%s' "$ans"
    return 0
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

# 端口是否被我们自己的节点容器占用（重跑换节点 1 时旧容器还占着端口，不算被占，之后会被重建）
port_owned_by_us() {
  local port="$1"
  [ "$DRY_RUN" = "1" ] && return 1
  command -v docker >/dev/null 2>&1 || return 1
  docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E '^tiktok-(xray(-[0-9]+)?|caddy) ' | grep -q ":${port}->"
}

# ---------- 节点注册表 nodes.conf ----------
# 每节点一组 NODE_<编号>_ 前缀变量；全局设置 GLOBAL_ 前缀。首节点沿用旧文件名
# （config.json / clash.yaml / qr.png，容器 tiktok-xray），追加节点用 -N 后缀。
# nodes.conf 只存本机 root 可读（600），里面有 UUID（等同于密码）。
REG_FILE="nodes.conf"

reg_get() {  # reg_get KEY -> 值（找不到为空）
  local k="$1" line=""
  [ -f "$REG_FILE" ] || return 0
  line="$(grep -m1 "^${k}=" "$REG_FILE" || true)"
  printf '%s' "${line#*=}"
}

reg_set() {  # reg_set KEY VALUE：存在则整行重写，不存在则追加（不用 sed 替换，值里有 & 也不怕）
  local k="$1" v="$2"
  touch "$REG_FILE"
  grep -v "^${k}=" "$REG_FILE" > "$REG_FILE.tmp" || true
  printf '%s=%s\n' "$k" "$v" >> "$REG_FILE.tmp"
  mv "$REG_FILE.tmp" "$REG_FILE"
}

node_indices() {  # 全部节点编号（每行一个，数字升序）
  [ -f "$REG_FILE" ] || return 0
  grep -oE '^NODE_[0-9]+_DOMAIN=' "$REG_FILE" | grep -oE '[0-9]+' | sort -n -u || true
}

node_field() {  # node_field 编号 KEY -> 值
  reg_get "NODE_${1}_${2}"
}

node_count() { node_indices | wc -l | tr -d ' '; }

next_index() {  # 下一个节点编号 = 现有最大 +1（编号不重用，删过的编号留空）
  local max=0 i
  for i in $(node_indices); do [ "$i" -gt "$max" ] && max="$i"; done
  echo $((max + 1))
}

find_node_by_domain() {  # 域名 -> 编号（找不到返回 1）
  local d="$1" i
  for i in $(node_indices); do
    [ "$(node_field "$i" DOMAIN)" = "$d" ] && { echo "$i"; return 0; }
  done
  return 1
}

svc_name() {  # compose 服务名：节点 1 叫 xray，节点 N 叫 xrayN
  if [ "$1" = "1" ]; then echo "xray"; else echo "xray$1"; fi
}

valid_domain() {  # 子域名格式：us1.example.com 这种
  case "$1" in
    *..*|*.-*|*-.*) return 1 ;;
  esac
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
}

# 旧版单节点安装（只有 .env，没有 nodes.conf）迁移成注册表：首节点信息不变，只补一份注册记录
migrate_legacy() {
  [ -f "$REG_FILE" ] && return 0
  [ -f .env ] || return 1
  [ -f config.json ] || { echo "旧版安装记录不完整（找不到 config.json），请先重跑 bash install.sh 装首节点。"; return 1; }
  local _uuid=""
  _uuid="$(grep -oE '"id": *"[^"]+"' config.json | head -1 | cut -d'"' -f4)"
  [ -n "$_uuid" ] || { echo "旧版安装记录不完整（config.json 里找不到 UUID），请先重跑 bash install.sh 装首节点。"; return 1; }
  set -a; . ./.env 2>/dev/null; set +a
  {
    echo "# tiktok-node 节点注册表（install.sh --add-node / --del-node 维护；不要手动改）"
    echo "GLOBAL_TLS_MODE=${TLS_MODE:-1}"
    echo "GLOBAL_CERT_METHOD=${CERT_METHOD:-http}"
    echo "GLOBAL_HTTPS_PORT=${HTTPS_PORT:-443}"
    echo "GLOBAL_SERVER_IP=${SERVER_IP:-}"
    echo "NODE_1_DOMAIN=${DOMAIN:-}"
    echo "NODE_1_TLS_MODE=${TLS_MODE:-1}"
    echo "NODE_1_CERT_METHOD=${CERT_METHOD:-http}"
    echo "NODE_1_WS_PORT=${WS_PORT:-}"
    echo "NODE_1_INTERNAL_PORT=10000"
    echo "NODE_1_UUID=$_uuid"
    echo "NODE_1_WSPATH=${WSPATH:-}"
    echo "NODE_1_CONFIG=config.json"
    echo "NODE_1_CONTAINER=tiktok-xray"
    echo "NODE_1_CLASH=clash.yaml"
    echo "NODE_1_QR=qr.png"
  } > "$REG_FILE"
  chmod 600 "$REG_FILE"
  echo "已把旧版单节点安装迁移成节点注册表（首节点信息不变）。"
  return 0
}

# ---------- 按注册表全量生成 Caddyfile / docker-compose.yml ----------
# Caddyfile：TLS 节点每节点一段 site 配置，共用 GLOBAL_HTTPS_PORT，按域名分流
gen_caddyfile() {
  local i dom cm hp ws intp has_tls=0
  for i in $(node_indices); do
    [ "$(node_field "$i" TLS_MODE)" = "1" ] && has_tls=1
  done
  if [ "$has_tls" = "0" ]; then rm -f Caddyfile; return 0; fi
  : > Caddyfile
  for i in $(node_indices); do
    [ "$(node_field "$i" TLS_MODE)" = "1" ] || continue
    dom="$(node_field "$i" DOMAIN)"
    cm="$(node_field "$i" CERT_METHOD)"
    hp="$(reg_get GLOBAL_HTTPS_PORT)"
    ws="$(node_field "$i" WSPATH)"
    intp="$(node_field "$i" INTERNAL_PORT)"
    {
      echo "$dom:$hp {"
      if [ "$cm" = "dns" ]; then
        echo "    tls {"
        echo "        dns cloudflare {env.CLOUDFLARE_API_TOKEN}"
        echo "    }"
      fi
      echo "    handle /$ws {"
      echo "        reverse_proxy $(svc_name "$i"):$intp"
      echo "    }"
      echo "    handle {"
      echo "        respond \"ok\" 200"
      echo "    }"
      echo "}"
    } >> Caddyfile
  done
}

# docker-compose.yml：每节点一个 xray 服务 + 共用一个 caddy 服务（有 TLS 节点时才有）
gen_compose() {
  local i dom tls_mode cm cfg ctr hp wsp intp has_tls=0
  for i in $(node_indices); do
    [ "$(node_field "$i" TLS_MODE)" = "1" ] && has_tls=1
  done
  {
    echo "services:"
    for i in $(node_indices); do
      cfg="$(node_field "$i" CONFIG)"
      ctr="$(node_field "$i" CONTAINER)"
      tls_mode="$(node_field "$i" TLS_MODE)"
      intp="$(node_field "$i" INTERNAL_PORT)"
      echo "  $(svc_name "$i"):"
      echo "    image: ghcr.io/xtls/xray-core:latest"
      echo "    container_name: $ctr"
      echo "    restart: unless-stopped"
      echo "    logging:"
      echo "      driver: json-file"
      echo "      options:"
      echo "        max-size: \"10m\""
      echo "        max-file: \"3\""
      if [ "$tls_mode" = "0" ]; then
        wsp="$(node_field "$i" WS_PORT)"
        echo "    ports:"
        echo "      - \"$wsp:$intp\""
      fi
      echo "    volumes:"
      echo "      - ./$cfg:/usr/local/etc/xray/config.json:ro"
    done
    if [ "$has_tls" = "1" ]; then
      cm="$(reg_get GLOBAL_CERT_METHOD)"
      hp="$(reg_get GLOBAL_HTTPS_PORT)"
      echo "  caddy:"
      if [ "$cm" = "dns" ]; then
        echo "    image: caddy-cloudflare:latest"
      else
        echo "    image: caddy:2"
      fi
      echo "    container_name: tiktok-caddy"
      echo "    restart: unless-stopped"
      echo "    logging:"
      echo "      driver: json-file"
      echo "      options:"
      echo "        max-size: \"10m\""
      echo "        max-file: \"3\""
      if [ "$cm" = "dns" ]; then
        echo "    environment:"
        echo '      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}'
      fi
      echo "    ports:"
      if [ "$cm" != "dns" ]; then
        echo '      - "80:80"'
      fi
      echo "      - \"$hp:$hp\""
      echo "    volumes:"
      echo "      - ./Caddyfile:/etc/caddy/Caddyfile:ro"
      echo "      - caddy_data:/data"
      echo "      - caddy_config:/config"
      echo "    depends_on:"
      for i in $(node_indices); do
        [ "$(node_field "$i" TLS_MODE)" = "1" ] && echo "      - $(svc_name "$i")"
      done
      echo "volumes:"
      echo "  caddy_data:"
      echo "  caddy_config:"
    fi
  } > docker-compose.yml
}

# ---------- 写单个节点的配置与客户端文件（用全局 NODE_* 变量） ----------
# 调用前设置：N（编号）、NODE_DOMAIN、NODE_TLS_MODE、NODE_CERT_METHOD、NODE_WS_PORT、
# NODE_INTERNAL_PORT、NODE_UUID、NODE_WSPATH、NODE_CONFIG、NODE_CONTAINER、NODE_CLASH、NODE_QR
write_node_files() {
  local cfg="$NODE_CONFIG" clash="$NODE_CLASH"
  cat > "$cfg" <<EOF
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
      "port": $NODE_INTERNAL_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$NODE_UUID" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/$NODE_WSPATH" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
  if [ "$NODE_TLS_MODE" = "1" ]; then
    cat > "$clash" <<EOF
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
    server: $NODE_DOMAIN
    port: $NODE_HTTPS_PORT
    uuid: $NODE_UUID
    tls: true
    servername: $NODE_DOMAIN
    network: ws
    ws-opts:
      path: /$NODE_WSPATH
      headers:
        Host: $NODE_DOMAIN
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "TikTok-Node"
rules:
  - MATCH,PROXY
EOF
    NODE_LINK="vless://$NODE_UUID@$NODE_DOMAIN:$NODE_HTTPS_PORT?encryption=none&security=tls&type=ws&host=$NODE_DOMAIN&path=%2F$NODE_WSPATH#TikTok-Node"
  else
    cat > "$clash" <<EOF
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
    server: $NODE_SERVER_IP
    port: $NODE_WS_PORT
    uuid: $NODE_UUID
    tls: false
    network: ws
    ws-opts:
      path: /$NODE_WSPATH
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "TikTok-Node"
rules:
  - MATCH,PROXY
EOF
    NODE_LINK="vless://$NODE_UUID@$NODE_SERVER_IP:$NODE_WS_PORT?encryption=none&security=none&type=ws&path=%2F$NODE_WSPATH#TikTok-Node"
  fi
  NODE_SUB=$(printf '%s' "$NODE_LINK" | base64 -w0)
}

make_qr() {  # make_qr 链接 输出文件：qrencode 优先，python3 qrcode 兜底，返回 0/1
  local link="$1" out="$2"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -o "$out" -s 8 "$link" && return 0
  elif command -v python3 >/dev/null 2>&1; then
    if python3 - "$link" "$out" <<'PY'
import sys
try:
    import qrcode
except ImportError:
    sys.exit(1)
qrcode.make(sys.argv[1]).save(sys.argv[2])
PY
    then return 0; fi
  fi
  return 1
}

# caddy reload：不断已有节点连接；reload 不行再重启 Caddy 容器
caddy_reload() {
  if [ "$DRY_RUN" = "1" ]; then echo "[dry-run] 跳过 caddy reload"; return 0; fi
  if docker exec tiktok-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null; then
    echo "Caddy 已 reload（已有节点连接不断）"
    return 0
  fi
  echo "caddy reload 没成功，改重启 Caddy 容器..."
  docker compose restart caddy
}

# 新节点 WS 握手拨测（TLS 走 https，明文走 http）
test_node_ws() {
  local proto="$1" host="$2" port="$3" path="$4" code=""
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" "$proto://$host:$port/$path" || true)
  echo "WS 握手 $proto://$host:$port/$path -> HTTP ${code:-无响应}（101 = 正常；200 = Caddy 没转给 xray；400 = xray 拒绝握手）"
}

# 部署单个节点（首节点与追加节点共用）：注册 -> 写配置 -> 生成 Caddyfile/compose -> 启动/重载 -> 拨测 -> 输出链接
# 调用前设置 MODE（fresh/add）与 NODE_* 变量；首节点还要在调用前设好 DOMAIN/TLS_MODE/CERT_METHOD/HTTPS_PORT/WS_PORT/SERVER_IP
deploy_node() {
  local mode="$1"
  echo "== 部署节点 $N（${NODE_DOMAIN:-明文}） =="
  # 注册（存在则整行重写，不存在则追加；追加的节点不碰已有节点记录）
  reg_set "NODE_${N}_DOMAIN" "$NODE_DOMAIN"
  reg_set "NODE_${N}_TLS_MODE" "$NODE_TLS_MODE"
  reg_set "NODE_${N}_CERT_METHOD" "$NODE_CERT_METHOD"
  reg_set "NODE_${N}_WS_PORT" "$NODE_WS_PORT"
  reg_set "NODE_${N}_INTERNAL_PORT" "$NODE_INTERNAL_PORT"
  reg_set "NODE_${N}_UUID" "$NODE_UUID"
  reg_set "NODE_${N}_WSPATH" "$NODE_WSPATH"
  reg_set "NODE_${N}_CONFIG" "$NODE_CONFIG"
  reg_set "NODE_${N}_CONTAINER" "$NODE_CONTAINER"
  reg_set "NODE_${N}_CLASH" "$NODE_CLASH"
  reg_set "NODE_${N}_QR" "$NODE_QR"
  chmod 600 "$REG_FILE"
  write_node_files
  gen_caddyfile
  gen_compose
  if [ "$mode" = "fresh" ] && [ "$N" = "1" ]; then
    # 首节点安装记录（.env）：域名、模式、端口、WS 路径、证书方式，供 check.sh / stop.sh 读
    # .env 里有 Cloudflare API 令牌时只限本机 root 读（600），绝不在输出里打印
    {
      echo "# tiktok-node 安装记录（install.sh 生成；重跑时域名与端口默认沿用上次的）"
      echo "DOMAIN=$DOMAIN"
      echo "TLS_MODE=$TLS_MODE"
      if [ "$TLS_MODE" = "1" ]; then
        echo "HTTPS_PORT=$HTTPS_PORT"
        echo "CERT_METHOD=$CERT_METHOD"
        if [ "$CERT_METHOD" = "dns" ]; then echo "CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN"; fi
      else
        echo "WS_PORT=$WS_PORT"
      fi
      echo "SERVER_IP=$SERVER_IP"
      echo "WSPATH=$WSPATH"
    } > .env
    chmod 600 .env
  fi
  if [ "$DRY_RUN" != "1" ]; then
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
      if [ "$NODE_TLS_MODE" = "1" ]; then
        if [ "$NODE_CERT_METHOD" = "http" ]; then ufw allow 80/tcp >/dev/null; fi
        ufw allow "$NODE_HTTPS_PORT"/tcp >/dev/null
      else ufw allow "$NODE_WS_PORT"/tcp >/dev/null; fi
      echo "ufw 已放行对应端口"
    fi
    # DNS 验证模式：先编带 Cloudflare 插件的 Caddy（官方 builder 镜像现场编，只编一次；已有镜像就跳过）
    if [ "$NODE_TLS_MODE" = "1" ] && [ "$NODE_CERT_METHOD" = "dns" ]; then
      if docker image inspect caddy-cloudflare:latest >/dev/null 2>&1; then
        echo "已找到本地 caddy-cloudflare 镜像，跳过编译"
      else
        echo "正在编译带 Cloudflare 插件的 Caddy（官方 builder 镜像现场编，第一次约 1-3 分钟）..."
        docker build -t caddy-cloudflare:latest -f Dockerfile.caddy . || { echo "Caddy 编译失败：检查本机能否访问 Docker Hub 与 proxy.golang.org，或稍后重跑"; exit 1; }
        echo "Caddy 编译完成：caddy-cloudflare:latest"
      fi
    fi
    if [ "$mode" = "fresh" ]; then
      # 只重建本节点服务（重跑换了 UUID/路径时旧容器必须重建才生效）；
      # TLS 时再起 Caddy（已在跑就 reload 新 Caddyfile，不重建，已有其他节点不断连）
      docker compose up -d --force-recreate "$(svc_name "$N")"
      if [ "$NODE_TLS_MODE" = "1" ]; then
        docker compose up -d caddy
        caddy_reload
      fi
      sleep 3
    else
      docker compose up -d
      sleep 3
      if [ "$NODE_TLS_MODE" = "1" ]; then caddy_reload; fi
    fi
    if [ "$NODE_TLS_MODE" = "1" ]; then
      CODE=""
      for i in $(seq 1 30); do
        CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://$NODE_DOMAIN:$NODE_HTTPS_PORT/" || true)
        [ "$CODE" = "200" ] && break
        sleep 3
      done
      echo "首页 https://$NODE_DOMAIN:$NODE_HTTPS_PORT/ -> HTTP ${CODE:-无响应}（200 = Caddy 与证书正常）"
      test_node_ws "https" "$NODE_DOMAIN" "$NODE_HTTPS_PORT" "$NODE_WSPATH"
    else
      test_node_ws "http" "$NODE_SERVER_IP" "$NODE_WS_PORT" "$NODE_WSPATH"
    fi
  else
    echo "[dry-run] 跳过启动与拨测"
  fi
  # 二维码（qrencode 没有时尝试安装；实在没有就提示手动生成）
  QR_OK=0
  if ! command -v qrencode >/dev/null 2>&1 && [ "$DRY_RUN" != "1" ]; then
    echo "本机没有 qrencode，尝试安装..."
    if command -v apt-get >/dev/null 2>&1; then
      timeout 180 apt-get update -qq >/dev/null 2>&1 || true
      timeout 180 apt-get install -y -qq qrencode >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      timeout 180 yum install -y -q qrencode >/dev/null 2>&1 || true
    fi
  fi
  if make_qr "$NODE_LINK" "$NODE_QR"; then QR_OK=1; fi
  echo ""
  if [ "$mode" = "fresh" ]; then
    echo "================ 部署完成 ================"
  else
    echo "================ 节点 $N 追加完成 ================"
  fi
  if [ "$NODE_TLS_MODE" = "1" ]; then
    if [ "$NODE_CERT_METHOD" = "dns" ]; then
      echo "证书方式：DNS 验证（Cloudflare），续签全自动，不用管 80 端口"
    else
      echo "证书方式：默认走 80（HTTP-01）；证书剩余天数用 bash check.sh 看"
    fi
  fi
  echo "节点链接（小火箭/Clash 可直接导入）："
  echo "$NODE_LINK"
  echo ""
  echo "订阅内容（base64）："
  echo "$NODE_SUB"
  echo ""
  echo "Clash 配置已生成：$(pwd)/$NODE_CLASH（DNS 全走代理、禁 IPv6，直接导入 Clash/Stash）"
  if [ "$QR_OK" = "1" ]; then
    echo "二维码已生成：$(pwd)/$NODE_QR（下载到手机扫码即可）"
  else
    echo "本机没生成二维码：把上面的节点链接发给 Muse，它会回你二维码图片。"
  fi
  echo ""
  echo "注意：链接里的 UUID 就是密码，不要外传。"
}

# ---------- 追加节点 ----------
add_node_flow() {
  echo "== 追加节点 =="
  if [ ! -f "$REG_FILE" ]; then
    migrate_legacy || { echo "还没装过节点：先跑 bash install.sh 装第一个节点，再追加。"; exit 1; }
  fi
  local g_tls g_cm g_hp g_ip
  g_tls="$(reg_get GLOBAL_TLS_MODE)"; [ -n "$g_tls" ] || g_tls=1
  g_cm="$(reg_get GLOBAL_CERT_METHOD)"; [ -n "$g_cm" ] || g_cm=http
  g_hp="$(reg_get GLOBAL_HTTPS_PORT)"; [ -n "$g_hp" ] || g_hp=443
  g_ip="$(reg_get GLOBAL_SERVER_IP)"
  if [ -z "$g_ip" ] && [ -f .env ]; then set -a; . ./.env 2>/dev/null; set +a; g_ip="${SERVER_IP:-}"; fi
  N="$(next_index)"
  NODE_TLS_MODE="$g_tls"
  NODE_CERT_METHOD="$g_cm"
  NODE_HTTPS_PORT="$g_hp"
  NODE_SERVER_IP="$g_ip"
  NODE_INTERNAL_PORT=$((10000 + N - 1))
  if [ "$N" = "1" ]; then
    NODE_CONFIG="config.json"; NODE_CONTAINER="tiktok-xray"; NODE_CLASH="clash.yaml"; NODE_QR="qr.png"
  else
    NODE_CONFIG="config-$N.json"; NODE_CONTAINER="tiktok-xray-$N"; NODE_CLASH="clash-$N.yaml"; NODE_QR="qr-$N.png"
  fi
  if [ "$NODE_TLS_MODE" = "1" ]; then
    echo "再加一个节点（和已有节点共用一个 Caddy 的 $NODE_HTTPS_PORT，按域名分流；各节点 UUID、WS 路径、后端容器都独立）："
    echo "  域名解析：推荐先把泛域名 *.example.com 解析到这台机（一条 A 记录），以后加节点不用再动 DNS。"
    echo "  证书方式沿用首次安装选的：$([ "$NODE_CERT_METHOD" = "dns" ] && echo "DNS 验证（Cloudflare），每个子域名自动签" || echo "默认走 80（HTTP-01），每个子域名自动签")，追加时不再重问。"
    # 新域名可用环境变量 ADD_DOMAIN 预设，或 --add-node 后面直接跟（只认追加参数，不认首装的命令行域名）
    NEW_DOMAIN="${ADD_DOMAIN:-${ADD_ARG:-}}"
    ADD_ARG=""
    while :; do
      echo "请填写新节点的子域名："
      ask "新节点子域名（例如 us2.example.com，必须是已解析到本机的子域名）： " NEW_DOMAIN
      if [ -z "$NEW_DOMAIN" ]; then echo "子域名不能为空，请重新输入。"; NEW_DOMAIN=""; continue; fi
      if ! valid_domain "$NEW_DOMAIN"; then echo "子域名格式不对：$NEW_DOMAIN（例如 us2.example.com），请重新输入。"; NEW_DOMAIN=""; continue; fi
      if find_node_by_domain "$NEW_DOMAIN" >/dev/null 2>&1; then echo "子域名 $NEW_DOMAIN 已经被节点占用了，请换一个子域名。"; NEW_DOMAIN=""; continue; fi
      break
    done
    NODE_DOMAIN="$NEW_DOMAIN"
    NODE_WS_PORT=""
    echo "新节点域名：$NODE_DOMAIN（TLS 模式，共用 $NODE_HTTPS_PORT 端口）"
  else
    echo "再加一个节点（明文模式，不用域名；各节点用不同 WS 端口，UUID、WS 路径、后端容器都独立）："
    # 新端口可用环境变量 ADD_WS_PORT 预设；默认前一节点端口 +1（如 8080、8081）
    local prev_ws=8080
    prev_ws="$(node_field $((N - 1)) WS_PORT)"; [ -n "$prev_ws" ] || prev_ws=8080
    local sugg_ws=$((prev_ws + 1))
    NEW_WS_PORT="${ADD_WS_PORT:-}"
    while :; do
      echo "请填写新节点的 WS 端口："
      ask_port "新节点 WS 端口（默认 $sugg_ws，直接回车就是 $sugg_ws；被占或和已有节点重复时会重问）： " NEW_WS_PORT "$sugg_ws"
      NEW_WS_PORT="${NEW_WS_PORT:-$sugg_ws}"
      local clash=0 i
      for i in $(node_indices); do
        [ "$(node_field "$i" WS_PORT)" = "$NEW_WS_PORT" ] && clash=1
      done
      if [ "$clash" = "1" ]; then echo "端口 $NEW_WS_PORT 已经被已有节点用了，请换一个。"; NEW_WS_PORT=""; continue; fi
      if [ "$DRY_RUN" != "1" ] && port_in_use "$NEW_WS_PORT"; then echo "端口 $NEW_WS_PORT 已被占用："; port_owner "$NEW_WS_PORT"; echo "请换一个端口。"; NEW_WS_PORT=""; continue; fi
      break
    done
    NODE_WS_PORT="$NEW_WS_PORT"
    NODE_DOMAIN=""
    echo "新节点 WS 端口：$NODE_WS_PORT（明文模式）"
  fi
  NODE_UUID="$(cat /proc/sys/kernel/random/uuid)"
  NODE_WSPATH="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
  echo "UUID: $NODE_UUID"
  echo "WS 路径: /$NODE_WSPATH"
  deploy_node add
}

# ---------- 删除单个节点 ----------
del_node_flow() {
  echo "== 删除单个节点 =="
  if [ ! -f "$REG_FILE" ]; then
    migrate_legacy || { echo "还没装过节点：没有可删除的节点。"; exit 1; }
  fi
  local total i
  total="$(node_count)"
  if [ "$total" = "0" ]; then echo "没有可删除的节点。"; exit 1; fi
  echo "本机已有节点（共 $total 个）："
  for i in $(node_indices); do
    local d u hp wsp
    d="$(node_field "$i" DOMAIN)"; u="$(node_field "$i" UUID)"
    if [ "$(node_field "$i" TLS_MODE)" = "1" ]; then
      hp="$(reg_get GLOBAL_HTTPS_PORT)"
      echo "  [$i] $d（TLS，共用 $hp 端口）UUID ${u:0:8}... WS 路径 /$(node_field "$i" WSPATH)"
    else
      wsp="$(node_field "$i" WS_PORT)"
      echo "  [$i] 明文节点（WS 端口 $wsp）UUID ${u:0:8}... WS 路径 /$(node_field "$i" WSPATH)"
    fi
  done
  local pick=""
  if [ -n "$DEL_TARGET" ]; then
    pick="$DEL_TARGET"
  else
    echo "请输入你的选择："
    ask "要删除的节点编号（输编号；直接回车取消）： " DEL_PICK ""
    pick="$DEL_PICK"
    [ -z "$pick" ] && { echo "已取消，没删任何节点。"; exit 0; }
  fi
  local target=""
  if printf '%s' "$pick" | grep -qE '^[0-9]+$'; then
    [ -n "$(node_field "$pick" CONTAINER)" ] && target="$pick"
  else
    target="$(find_node_by_domain "$pick" || true)"
  fi
  if [ -z "$target" ]; then
    echo "找不到节点：$pick（编号或子域名不对）。上面列出的是已有节点，请核对后重跑。"
    exit 1
  fi
  local d_dom d_uuid d_tls d_cm d_hp d_wsp d_cfg d_ctr d_clash d_qr d_wspath
  d_dom="$(node_field "$target" DOMAIN)"
  d_uuid="$(node_field "$target" UUID)"
  d_tls="$(node_field "$target" TLS_MODE)"
  d_cm="$(node_field "$target" CERT_METHOD)"
  d_hp="$(reg_get GLOBAL_HTTPS_PORT)"
  d_wsp="$(node_field "$target" WS_PORT)"
  d_cfg="$(node_field "$target" CONFIG)"
  d_ctr="$(node_field "$target" CONTAINER)"
  d_clash="$(node_field "$target" CLASH)"
  d_qr="$(node_field "$target" QR)"
  d_wspath="$(node_field "$target" WSPATH)"
  echo ""
  echo "将删除以下节点（留底用）："
  if [ "$d_tls" = "1" ]; then
    echo "  域名：$d_dom（TLS，共用 $d_hp 端口；证书方式：$d_cm）"
  else
    echo "  明文节点（WS 端口 $d_wsp）"
  fi
  echo "  UUID：$d_uuid"
  echo "  WS 路径：/$d_wspath"
  echo "  配置文件：$d_cfg / $d_clash / $d_qr"
  echo "  容器：$d_ctr"
  echo "删除后其他节点不受影响。确认删除吗？[y/N，默认 N]"
  local confirm="${DEL_NODE_CONFIRM:-}"
  if [ "$confirm" != "y" ]; then
    ask "确认删除（y=删，N=不删，直接回车就是 N）： " DEL_CONFIRM "N"
    confirm="$DEL_CONFIRM"
  fi
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "已取消，没删任何节点。"
    exit 0
  fi
  echo "正在删除节点 $target（$d_dom）..."
  if [ "$DRY_RUN" != "1" ]; then
    docker rm -f "$d_ctr" >/dev/null 2>&1 || true
    echo "已删除容器 $d_ctr"
  else
    echo "[dry-run] 跳过删除容器 $d_ctr"
  fi
  rm -f "$d_cfg" "$d_clash" "$d_qr"
  echo "已删除配置文件 $d_cfg / $d_clash / $d_qr"
  grep -v "^NODE_${target}_" "$REG_FILE" > "$REG_FILE.tmp" || true
  mv "$REG_FILE.tmp" "$REG_FILE"
  echo "已从节点注册表删除节点 $target"
  if [ "$(node_count)" = "0" ]; then
    echo ""
    echo "已删完最后一个节点。"
    if [ "$DRY_RUN" != "1" ]; then
      docker rm -f tiktok-caddy >/dev/null 2>&1 || true
    fi
    rm -f Caddyfile docker-compose.yml nodes.conf .env
    echo "Caddyfile、docker-compose.yml、nodes.conf、.env 已清理。彻底清理残留请跑 bash stop.sh --remove。"
    echo ""
    echo "已删除节点：$d_dom（UUID $d_uuid）"
    exit 0
  fi
  gen_caddyfile
  gen_compose
  if [ "$DRY_RUN" != "1" ]; then
    # 还有 TLS 节点就 reload 新 Caddyfile；一个 TLS 节点都没了就停掉 Caddy（否则它还用旧配置对外服务）
    _any_tls=0
    for _i2 in $(node_indices); do [ "$(node_field "$_i2" TLS_MODE)" = "1" ] && _any_tls=1; done
    if [ "$_any_tls" = "1" ]; then
      caddy_reload
    else
      docker rm -f tiktok-caddy >/dev/null 2>&1 || true
    fi
    docker compose up -d >/dev/null 2>&1 || true
  else
    echo "[dry-run] 跳过 caddy reload"
  fi
  echo ""
  echo "已删除节点：$d_dom（UUID $d_uuid）"
  echo "逐个核查剩余节点："
  local ok=1 i2
  for i2 in $(node_indices); do
    local r_dom r_tls r_hp r_wsp r_path r_ctr
    r_dom="$(node_field "$i2" DOMAIN)"
    r_tls="$(node_field "$i2" TLS_MODE)"
    r_path="$(node_field "$i2" WSPATH)"
    r_ctr="$(node_field "$i2" CONTAINER)"
    if [ "$DRY_RUN" = "1" ]; then
      if [ -f "$(node_field "$i2" CONFIG)" ] && { [ "$r_tls" = "0" ] || grep -q "$r_dom" Caddyfile 2>/dev/null; }; then
        echo "  [通过] 节点 $i2（$r_dom）：配置文件与 Caddyfile 正常"
      else
        echo "  [风险] 节点 $i2（$r_dom）：配置文件或 Caddyfile 异常"
        ok=0
      fi
      continue
    fi
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$r_ctr"; then
      echo "  [通过] 节点 $i2（$r_dom）：容器 $r_ctr 在运行"
    else
      echo "  [风险] 节点 $i2（$r_dom）：容器 $r_ctr 没在运行"
      ok=0
    fi
    if [ "$r_tls" = "1" ]; then
      r_hp="$(reg_get GLOBAL_HTTPS_PORT)"
      test_node_ws "https" "$r_dom" "$r_hp" "$r_path"
    else
      r_wsp="$(node_field "$i2" WS_PORT)"
      test_node_ws "http" "$(reg_get GLOBAL_SERVER_IP)" "$r_wsp" "$r_path"
    fi
  done
  if [ "$ok" = "1" ]; then
    echo "剩余节点全部正常。"
  else
    echo "注意：有剩余节点异常，上面标了 [风险]，请核对。"
  fi
}

if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] 只生成配置文件，不安装、不改系统"
  [ -n "$SERVER_IP" ] || SERVER_IP="203.0.113.1"
fi

# 删除模式直接走删除流程
if [ "$DEL_NODE" = "1" ]; then
  del_node_flow
  exit $?
fi

echo "== 1/6 检查 Docker =="
if [ "$DRY_RUN" != "1" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "未检测到 Docker，正在安装..."
    curl -fsSL https://get.docker.com | sh
  fi
  docker compose version >/dev/null 2>&1 || { echo "缺少 Docker Compose 插件，请先安装 docker-compose-plugin"; exit 1; }
fi

# 追加模式直接走追加流程
if [ "$ADD_NODE" = "1" ]; then
  add_node_flow
  echo ""
  echo "还要再加一个节点吗？[y/N，默认 N]"
  ask "再加一个节点（y=加，N=不加，直接回车就是 N）： " ADD_MORE "N"
  while [ "$ADD_MORE" = "y" ] || [ "$ADD_MORE" = "Y" ]; do
    add_node_flow
    echo ""
    echo "还要再加一个节点吗？[y/N，默认 N]"
    ADD_MORE=""
    ask "再加一个节点（y=加，N=不加，直接回车就是 N）： " ADD_MORE "N"
  done
  exit 0
fi

echo "== 2/6 域名与端口 =="
# 端口预设优先级：环境变量 > .env > 交互输入（直接回车用默认）
ENV_HTTPS_PORT="${HTTPS_PORT:-}"
ENV_WS_PORT="${WS_PORT:-}"
ENV_CERT_METHOD="${CERT_METHOD:-}"
ENV_CF_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
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
  TLS_MODE=1
  echo "域名：$DOMAIN（TLS 模式）"
fi

# 证书签发方式（TLS 模式才问）：环境变量 CERT_METHOD > .env > 交互输入（直接回车默认 1）
if [ "$TLS_MODE" = "1" ]; then
  CERT_METHOD="${ENV_CERT_METHOD:-${CERT_METHOD:-}}"
  case "$CERT_METHOD" in
    1|http) CERT_METHOD="http" ;;
    2|dns) CERT_METHOD="dns" ;;
    "")
      if [ "$DRY_RUN" != "1" ]; then
        ask_cert_method
      else
        CERT_METHOD="http"
      fi
      ;;
    *) echo "CERT_METHOD=$CERT_METHOD 不合法（只能是 1/http 或 2/dns），请修正后重跑。"; exit 1 ;;
  esac
  if [ "$CERT_METHOD" = "dns" ]; then echo "证书方式：DNS 验证（Cloudflare）"; else echo "证书方式：默认走 80（HTTP-01）"; fi
  # DNS 验证要 Cloudflare API 令牌：环境变量 CLOUDFLARE_API_TOKEN > .env > 交互输入
  # 令牌只存进 .env，绝不在输出里打印；输入时不回显
  CLOUDFLARE_API_TOKEN="${ENV_CF_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
  if [ "$CERT_METHOD" = "dns" ] && [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    if [ "$DRY_RUN" != "1" ]; then
      ask_cf_token
    else
      echo "[dry-run] DNS 验证模式：未预设 CLOUDFLARE_API_TOKEN，.env 里令牌为空（实装时会问）"
    fi
  fi
fi

# 端口：默认 443（TLS）/ 8080（明文），可自定义高位端口避开占用
if [ "$TLS_MODE" = "1" ]; then
  HTTPS_PORT="${ENV_HTTPS_PORT:-${HTTPS_PORT:-}}"
  if [ "$DRY_RUN" != "1" ]; then
    echo "HTTPS 端口用默认 443 还是自定义？（443 被占时可改高位端口，如 8443、24443）："
    ask_port "HTTPS 端口（默认 443，直接回车就是 443）： " HTTPS_PORT "443"
    while [ "$HTTPS_PORT" = "80" ]; do
      if [ "$CERT_METHOD" = "dns" ]; then
        echo "HTTPS 端口不能填 80（80 是 HTTP 端口，HTTPS 跑在 80 上客户端连不上），请换一个："
      else
        echo "HTTPS 端口不能填 80（80 要留给 Caddy 签证书验证用），请换一个："
      fi
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
    if [ "$CERT_METHOD" = "dns" ]; then
      echo "DNS 验证模式：80 端口不用空闲（签证书走 DNS 验证），80 被占也不拦。"
    elif port_in_use 80 && ! port_owned_by_us 80; then
      echo "80 端口已被占用，TLS 装不了（Caddy 签证书走 HTTP-01 验证必须用 80）："
      port_owner 80
      echo "建议：换一台 80 空闲的服务器，或不填域名重跑走明文模式；"
      echo "也可以重跑并选 [2] DNS 验证（要 Cloudflare API 令牌），80 被占也能装。"
      exit 1
    fi
    if port_in_use "$HTTPS_PORT" && ! port_owned_by_us "$HTTPS_PORT"; then
      echo "$HTTPS_PORT 端口已被占用，装不了："
      port_owner "$HTTPS_PORT"
      echo "建议：停掉占用它的程序，或重跑并把 HTTPS 端口改成别的（如 8443、24443）。"
      exit 1
    fi
    if [ "$CERT_METHOD" = "dns" ]; then
      echo "$HTTPS_PORT 端口空闲（80 不用查，DNS 验证模式不走 80）。"
    else
      echo "80 与 $HTTPS_PORT 端口空闲。"
    fi
  else
    if port_in_use "$WS_PORT" && ! port_owned_by_us "$WS_PORT"; then
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
# 首节点变量（沿用旧文件名与容器名；重跑时只换首节点凭据，追加的节点不受影响）
N=1
NODE_DOMAIN="$DOMAIN"
NODE_TLS_MODE="$TLS_MODE"
NODE_CERT_METHOD="${CERT_METHOD:-http}"
NODE_HTTPS_PORT="${HTTPS_PORT:-443}"
NODE_WS_PORT="${WS_PORT:-}"
NODE_INTERNAL_PORT=10000
NODE_UUID="$UUID"
NODE_WSPATH="$WSPATH"
NODE_SERVER_IP="$SERVER_IP"
NODE_CONFIG="config.json"
NODE_CONTAINER="tiktok-xray"
NODE_CLASH="clash.yaml"
NODE_QR="qr.png"
# 全局设置（追加节点沿用；重跑时更新）
reg_set "GLOBAL_TLS_MODE" "$TLS_MODE"
reg_set "GLOBAL_CERT_METHOD" "$NODE_CERT_METHOD"
reg_set "GLOBAL_HTTPS_PORT" "$NODE_HTTPS_PORT"
reg_set "GLOBAL_SERVER_IP" "$SERVER_IP"
# DNS 验证用的 Dockerfile（只在 dns 模式写；旧版没有这个文件时补一个）
if [ "$TLS_MODE" = "1" ] && [ "$CERT_METHOD" = "dns" ]; then
  cat > Dockerfile.caddy <<'DCEOF'
# 带 Cloudflare DNS 插件的 Caddy：官方 caddy:2-builder 现场编，插件源码来自 github.com/caddy-dns/cloudflare
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare
FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
DCEOF
fi

echo "== 6/6 启动并拨测 =="
deploy_node fresh
echo ""
echo "下一步：运行 bash check.sh 做泄漏自检，再按 README 配手机端。"
# check.sh 由 install.sh 内嵌生成（远程一键时只有一个文件）
cat > check.sh <<'CHECK_EOF'
#!/usr/bin/env bash
# TikTok 节点泄漏自检：在节点服务器上运行，检查 IP 纯净度、地区、IPv6、DNS、TikTok 可达性、节点端口
# 手机端的 DNS/WebRTC 泄漏需在手机上验证（脚本末尾会给出检查方法）
# 多节点：有 nodes.conf（install.sh --add-node 维护）时逐节点检查；没有就按旧版单节点（.env / clash.yaml）检查
set -uo pipefail

pass() { echo "  [通过] $1"; }
warn() { echo "  [注意] $1"; }
fail() { echo "  [风险] $1"; }

echo "== 1/7 节点 IP 与地区 =="
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
echo "== 2/7 IPv6 是否禁用 =="
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
echo "== 3/7 DNS 解析路径 =="
if command -v dig >/dev/null 2>&1; then
  RESOLVER="$(dig +short whoami.akamai.net @1.1.1.1 2>/dev/null | head -1)"
  [ -n "$RESOLVER" ] && echo "  经 1.1.1.1 解析的出口解析器 IP：$RESOLVER（应为 Cloudflare 的 IP，非国内运营商）"
  [ -z "$RESOLVER" ] && warn "dig 查询无返回，检查本机出站 UDP/TCP 53 是否被墙"
else
  warn "本机无 dig，跳过解析器核对（apt install dnsutils 可装）"
fi
echo "  xray 已配置 DoH(1.1.1.1/8.8.8.8)+TCP 兜底、只解析 IPv4，服务端不再走明文 UDP 53"

echo ""
echo "== 4/7 TikTok 可达性（从节点 IP 出口测） =="
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
echo "== 5/7 手机端自查（在手机上开着节点做） =="
echo "  节点只能管服务端这一半，手机端泄漏要这样验："
echo "  1) 打开 https://www.dnsleaktest.com 点 Extended test："
echo "     全部 DNS 服务器 IP 应该都是节点所在国家/机房的，出现中国运营商 DNS = 泄漏"
echo "  2) 打开 https://browserleaks.com/ip："
echo "     不能出现你的真实 IP、不能出现 IPv6 地址、时区/语言要和节点地区一致"
echo "  3) TikTok 里刷几个视频再看个人主页地区：应与节点地区一致"
echo "  4) 手机设置核对（见 README）：已拔国内 SIM 卡、时区语言=节点地区、定位已关"
echo ""
echo "== 6/7 节点端口连通性 =="
# 节点列表：有 nodes.conf 时逐节点读（install.sh --add-node 维护）；没有就按旧版单节点（.env / clash.yaml）读
CK_DIR="$(cd "$(dirname "$0")" && pwd)"
CK_REG="$CK_DIR/nodes.conf"
ck_reg_get() {
  local k="$1" line=""
  [ -f "$CK_REG" ] || return 0
  line="$(grep -m1 "^${k}=" "$CK_REG" || true)"
  printf '%s' "${line#*=}"
}
ck_node_field() { ck_reg_get "NODE_${1}_${2}"; }
ck_node_indices() {
  [ -f "$CK_REG" ] || return 0
  grep -oE '^NODE_[0-9]+_DOMAIN=' "$CK_REG" | grep -oE '[0-9]+' | sort -n -u || true
}
ck_ws_handshake() {  # ck_ws_handshake 节点名 协议 地址 端口 路径
  local name="$1" proto="$2" host="$3" port="$4" path="$5" code=""
  echo "  节点 $name：$proto://$host:$port/$path"
  code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" "$proto://$host:$port/$path" || true)"
  echo "  WS 握手 -> HTTP $code"
  if [ "$code" = "101" ]; then
    pass "节点 $name：WS 握手 101，节点端口正常"
  elif [ "$code" = "400" ]; then
    pass "节点 $name：WS 端口已响应（400 = xray 已响应，正常）"
  elif [ "$code" = "200" ]; then
    fail "节点 $name：WS 握手返回 200：Caddy 没把请求转给 xray，跑 docker compose down && docker compose up -d 重建"
  else
    fail "节点 $name：WS 握手无响应（HTTP $code）：检查端口 $port 是否放行、容器是否在跑"
  fi
}
if [ -f "$CK_REG" ]; then
  CK_HTTPS="$(ck_reg_get GLOBAL_HTTPS_PORT)"; [ -n "$CK_HTTPS" ] || CK_HTTPS=443
  CK_IP="$(ck_reg_get GLOBAL_SERVER_IP)"
  for _ni in $(ck_node_indices); do
    _tls="$(ck_node_field "$_ni" TLS_MODE)"
    _dom="$(ck_node_field "$_ni" DOMAIN)"
    _path="$(ck_node_field "$_ni" WSPATH)"
    if [ "$_tls" = "1" ]; then
      ck_ws_handshake "节点 $_ni（$_dom）" "https" "$_dom" "$CK_HTTPS" "$_path"
    else
      _wp="$(ck_node_field "$_ni" WS_PORT)"
      ck_ws_handshake "节点 $_ni（明文）" "http" "${CK_IP:-127.0.0.1}" "$_wp" "$_path"
    fi
  done
  unset _ni _tls _dom _path _wp
else
  # 旧版单节点：读安装记录（install.sh 写下的实际端口），没有就读 clash.yaml，再没有回退默认
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
    ck_ws_handshake "节点 1" "$CK_PROTO" "$CK_HOST" "$CK_PORT" "${CK_PATH#/}"
  else
    echo "  节点地址：$CK_PROTO://$CK_HOST:$CK_PORT/"
    CK_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$CK_PROTO://$CK_HOST:$CK_PORT/" || true)"
    echo "  首页 -> HTTP $CK_CODE"
    if [ "$CK_CODE" = "200" ]; then pass "节点端口 $CK_PORT 可达"; else fail "节点端口 $CK_PORT 不可达（HTTP $CK_CODE）"; fi
  fi
fi

echo ""
echo "== 7/7 证书与续签 =="
# 证书方式与到期天数：TLS 节点逐个查；有 nodes.conf 时逐节点读，没有就按旧版单节点（.env）读
ck_cert_days() {  # ck_cert_days 节点名 域名 HTTPS端口 证书方式
  local name="$1" dom="$2" hp="$3" cm="$4"
  if [ "$cm" = "dns" ]; then
    echo "  节点 $name（$dom）：证书方式 DNS 验证（Cloudflare），续签全自动，不用管 80 端口"
  else
    echo "  节点 $name（$dom）：证书方式默认走 80（HTTP-01），续签要走 80 端口"
    echo "  注意：如果域名现在指向中转、且 80 没转到这台机，续签会失败，见 README“手动续签”一节"
  fi
  if command -v openssl >/dev/null 2>&1; then
    local end="" end_epoch="" now_epoch="" days=""
    end="$(timeout 10 openssl s_client -connect "127.0.0.1:$hp" -servername "$dom" </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    if [ -n "$end" ]; then
      end_epoch="$(date -d "$end" +%s 2>/dev/null || echo "")"
      now_epoch="$(date +%s)"
      if [ -n "$end_epoch" ]; then
        days="$(( (end_epoch - now_epoch) / 86400 ))"
        echo "  证书到期日：$end（剩余约 $days 天）"
        if [ "$days" -lt 0 ]; then
          fail "节点 $name：证书已过期 $(( -days )) 天！节点已不可用，立即按 README“手动续签”处理"
        elif [ "$days" -le 14 ]; then
          warn "节点 $name：证书 14 天内到期；Caddy 会在到期前 30 天内自动续签，到期还没续上就按 README“手动续签”处理"
        elif [ "$days" -le 30 ]; then
          pass "节点 $name：证书剩余 $days 天，Caddy 会自动续签"
        else
          pass "节点 $name：证书剩余 $days 天，Caddy 会在到期前 30 天内自动续签"
        fi
      else
        warn "节点 $name：读到证书但解析不到期日：$end"
      fi
    else
      warn "节点 $name：读不到证书（Caddy 可能没起来，或证书还没签好）；等几分钟再跑 check.sh"
    fi
  else
    warn "本机无 openssl，看不到证书剩余天数（apt install openssl 可装）"
  fi
}
if [ -f "$CK_REG" ]; then
  CK_HTTPS="$(ck_reg_get GLOBAL_HTTPS_PORT)"; [ -n "$CK_HTTPS" ] || CK_HTTPS=443
  _any_tls=0
  for _ni in $(ck_node_indices); do
    if [ "$(ck_node_field "$_ni" TLS_MODE)" = "1" ]; then
      _any_tls=1
      ck_cert_days "节点 $_ni" "$(ck_node_field "$_ni" DOMAIN)" "$CK_HTTPS" "$(ck_node_field "$_ni" CERT_METHOD)"
    else
      echo "  节点 $_ni（明文）：没有证书（补域名重跑 install.sh 可升级 TLS）"
    fi
  done
  [ "$_any_tls" = "0" ] && echo "  全部节点都是明文模式，没有证书（补域名重跑 install.sh 可升级 TLS）"
  unset _ni _any_tls
elif [ "${TLS_MODE:-}" != "1" ]; then
  echo "  明文模式，没有证书（补域名重跑 install.sh 可升级 TLS）"
else
  if [ "${CERT_METHOD:-http}" = "dns" ]; then
    echo "  证书方式：DNS 验证（Cloudflare），续签全自动，不用管 80 端口"
  else
    echo "  证书方式：默认走 80（HTTP-01），续签要走 80 端口"
    echo "  注意：如果域名现在指向中转、且 80 没转到这台机，续签会失败，见 README“手动续签”一节"
  fi
  if [ -n "${DOMAIN:-}" ]; then
    ck_cert_days "节点 1" "${DOMAIN:-}" "${HTTPS_PORT:-443}" "${CERT_METHOD:-http}"
  else
    warn "没找到域名（.env 不在），看不到证书剩余天数"
  fi
fi

echo ""
echo "自检完成。"
CHECK_EOF
chmod +x check.sh

if [ "$DRY_RUN" != "1" ]; then
  echo ""
  bash check.sh || true
fi

echo ""
echo "还要再加一个节点吗？[y/N，默认 N]"
echo "  再加一个节点，和首节点共用一个 Caddy 的 $HTTPS_PORT，按域名分流；"
echo "  每个节点一个子域名（推荐先把泛域名 *.example.com 解析到这台机），UUID、WS 路径、后端容器都独立。"
ask "再加一个节点（y=加，N=不加，直接回车就是 N）： " ADD_MORE "N"
while [ "$ADD_MORE" = "y" ] || [ "$ADD_MORE" = "Y" ]; do
  add_node_flow
  echo ""
  echo "还要再加一个节点吗？[y/N，默认 N]"
  ADD_MORE=""
  ask "再加一个节点（y=加，N=不加，直接回车就是 N）： " ADD_MORE "N"
done
