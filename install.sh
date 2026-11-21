#!/usr/bin/env bash
# 已合并：本仓库已合并到 nbbk/landing-node，安装请用新仓一键命令。
#   curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/install.sh | bash -s [域名]
# 旧一键命令重跑会自动装新版（参数原样透传到新仓 install.sh）。
# 注意：已装机器本地安装目录里的 install.sh 是旧版文件，不受仓库垫片影响；
#   --add-node / --del-node 请继续在安装目录里用旧版 install.sh，
#   或按新仓 README“老机器接管”一节用新版接管旧目录后再管理。
set -euo pipefail
echo "提示：tiktok-node 已合并到 nbbk/landing-node，正在用新版安装（参数原样透传）..."
curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/install.sh | bash -s "$@"
