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
