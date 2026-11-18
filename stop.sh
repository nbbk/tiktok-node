#!/usr/bin/env bash
# 停止或删除 TikTok 节点（Xray），释放端口
#   bash stop.sh            停止节点，保留配置（之后在目录里 docker compose up -d 可再启动）
#   bash stop.sh --remove   彻底删除节点（容器、数据卷、配置目录全部删除）
# 远程一键（不用先下载）：
#   curl -fsSL https://raw.githubusercontent.com/nbbk/tiktok-node/main/stop.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/nbbk/tiktok-node/main/stop.sh | bash -s -- --remove
set -euo pipefail

REMOVE=0
[ "${1:-}" = "--remove" ] && REMOVE=1

# 找到 docker-compose.yml 所在的目录（解析为绝对路径）
COMPOSE_DIR=""
for d in "$(dirname "$0")" "$PWD" "$HOME/tiktok-node-kit"; do
  if [ -f "$d/docker-compose.yml" ]; then COMPOSE_DIR="$(cd "$d" && pwd)"; break; fi
done

# ---------- 1. 停容器 ----------
if [ -n "$COMPOSE_DIR" ]; then
  echo "在 $COMPOSE_DIR 停止节点..."
  cd "$COMPOSE_DIR"
  if [ "$REMOVE" = "1" ]; then
    docker compose down -v 2>/dev/null || true
  else
    docker compose down 2>/dev/null || true
  fi
fi
# 兜底：按容器名直接删除（compose 文件丢了也能释放端口）
for c in tiktok-xray tiktok-caddy; do
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
    docker rm -f "$c" >/dev/null 2>&1 || true
    echo "已删除容器 $c"
  fi
done

# ---------- 2. 验证端口是否已释放 ----------
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

echo ""
echo "端口检查："
# 按安装记录（.env）里的实际端口查，没有记录回退默认 80/443/8080
CHECK_PORTS="80 443 8080"
if [ -n "$COMPOSE_DIR" ] && [ -f "$COMPOSE_DIR/.env" ]; then
  set -a; . "$COMPOSE_DIR/.env" 2>/dev/null; set +a
  if [ "${TLS_MODE:-}" = "1" ]; then
    # DNS 验证模式没映射 80，80 不用查
    if [ "${CERT_METHOD:-http}" = "dns" ]; then CHECK_PORTS="${HTTPS_PORT:-443}";
    else CHECK_PORTS="80 ${HTTPS_PORT:-443}"; fi
  elif [ "${TLS_MODE:-}" = "0" ]; then CHECK_PORTS="${WS_PORT:-8080}"; fi
fi
STILL_HELD=""
for p in $CHECK_PORTS; do
  if port_in_use "$p"; then
    echo "  端口 $p 仍被占用："
    if command -v ss >/dev/null 2>&1; then
      ss -tlnp 2>/dev/null | grep -E "[:.]${p}[[:space:]]" | sed 's/^/    /' || true
    fi
    STILL_HELD="$STILL_HELD $p"
  else
    echo "  端口 $p 已释放"
  fi
done

echo ""
if [ -n "$STILL_HELD" ]; then
  echo "注意：端口$STILL_HELD 仍被占用（上面列出了占用它的进程）。"
  echo "如果占用它的是本节点的容器，说明容器没停干净，请手动执行："
  echo "  docker ps -a | grep -E 'tiktok-xray|tiktok-caddy'"
  echo "  docker rm -f <容器名>"
  echo "如果是别的程序占了这些端口，需要先停掉那个程序，或换一台服务器。"
else
  echo "端口 $CHECK_PORTS 已全部释放，装新节点不会再报端口占用。"
fi

# ---------- 3. 彻底删除时清理系统改动与目录 ----------
if [ "$REMOVE" = "1" ]; then
  echo ""
  echo "彻底删除："
  if [ -f /etc/sysctl.d/99-tiktok-node.conf ]; then
    rm -f /etc/sysctl.d/99-tiktok-node.conf
    sysctl -p >/dev/null 2>&1 || true
    echo "  已删除 /etc/sysctl.d/99-tiktok-node.conf（IPv6 与网络调优已恢复）"
  fi
  # DNS 验证模式用的自定义 Caddy 镜像也一并删（别的容器还在用就删不掉，不报错）
  if docker image inspect caddy-cloudflare:latest >/dev/null 2>&1; then
    if docker rmi caddy-cloudflare:latest >/dev/null 2>&1; then
      echo "  已删除自定义 Caddy 镜像 caddy-cloudflare（DNS 验证模式用的）"
    else
      echo "  自定义 Caddy 镜像 caddy-cloudflare 还在被别的容器用，这次没删"
    fi
  fi
  # 只删名字里带 tiktok-node-kit 的目录，脚本退出后再删（避免删正在执行的文件）
  if [ -n "$COMPOSE_DIR" ] && [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then
    case "$COMPOSE_DIR" in
      *tiktok-node-kit*)
        trap 'rm -rf "$COMPOSE_DIR"' EXIT
        echo "  节点目录 $COMPOSE_DIR 将在脚本退出后删除"
        ;;
      *)
        echo "  节点目录 $COMPOSE_DIR 请手动删除：rm -rf $COMPOSE_DIR"
        ;;
    esac
  fi
  echo ""
  echo "节点已彻底删除。"
else
  echo ""
  echo "节点已停止（配置保留）。"
  if [ -n "$COMPOSE_DIR" ]; then
    echo "再启动：cd $COMPOSE_DIR && docker compose up -d"
  fi
fi
