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
