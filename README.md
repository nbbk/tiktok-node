# TikTok 运营节点一键包（VLESS + WS + TLS，DNS 防泄漏）

在你自己的墙外服务器上跑一条命令，节点即上线。包里已把 DNS 防泄漏做全，装完自带泄漏自检。

## 前置条件

- 一台墙外服务器（你机场现有的机器就行），Ubuntu/Debian，root 权限
- 一个域名，已解析（A 记录）到这台机器，80/443 端口放行——**有域名强烈建议用**，Caddy 会自动签 TLS 证书
  - 没有域名也能跑：直接回车跳过，用 IP + 8080 明文 WS（能用，但不如 TLS 隐蔽，之后补域名重跑即可升级）
- 服务器地区 = 你要做的 TikTok 地区（美区、东南亚、英国……），**节点 IP 的地区必须和运营地区一致**，否则直接限流
- IP 尽量干净：住宅/ISP 的 IP 最好；机房 IP 也能跑，但 TikTok 风控更严，`check.sh` 会告诉你当前 IP 是不是机房 IP

## 使用步骤

### 远程一键安装（推荐，不用传包）

服务器上直接跑一条命令（把 `yinni.930327.xyz` 换成你的域名，不给域名则现场问）：

```
curl -fsSL https://raw.githubusercontent.com/nbbk/tiktok-node/main/install.sh | bash -s yinni.930327.xyz
```

### 本地安装（传包）

1. 把本包传到服务器并解压，进入目录
2. 运行：`bash install.sh`
3. 有域名就输入域名，没有直接回车
4. 脚本会自动：装 Docker → 禁用 IPv6 → 生成 UUID 和随机 WS 路径 → 启动 xray + Caddy → 拨测 → 输出节点链接、base64 订阅内容、`clash.yaml`，并在服务器上生成 `qr.png`（没有 qrencode 时自动用 apt/yum 安装；实在装不上就把节点链接发给 Muse，它会回你二维码图片），最后自动跑一遍 `check.sh` 自检

## 手机端（关键：节点只解决网络这一半）

TikTok 从 IP、DNS、时区、SIM 卡几个地方一起判断地区，节点配好只算完成一半，手机端必须配套：

1. **拔卡**：拔掉国内 SIM 卡（或用无 SIM 的备用机）；双卡手机只留目标地区卡，没有就空着用 Wi-Fi
2. **时区语言**：手机时区、语言、地区全部改成节点所在地区，和 IP 地区一致
3. **关定位**：关掉 TikTok 的定位权限，系统定位服务也建议关掉
4. **导入节点**：
   - 小火箭（Shadowrocket）：扫 `qr.png`，或导入脚本输出的 `vless://` 链接；然后在配置的 DNS 设置里开启远程解析（通过代理解析），不要用本地 DNS
   - Clash/Stash：直接导入随包生成的 `clash.yaml`，它已经配好全部流量走节点、全部 DNS 走代理 DoH、禁用 IPv6
5. **验证泄漏**（开着节点，在手机浏览器里做）：
   - 打开 https://www.dnsleaktest.com → Extended test：全部 DNS 服务器 IP 都应该是节点所在国家/机房的，出现中国运营商 DNS = 泄漏
   - 打开 https://browserleaks.com/ip：不能出现你的真实 IP、不能出现 IPv6 地址、时区和语言要和节点地区一致
   - 刷几个 TikTok 视频，看个人主页显示的地区是否和节点地区一致

## 这个包防泄漏是怎么做的

- **服务端 xray**：自身解析走 DoH（1.1.1.1/8.8.8.8）+ TCP 兜底，不走明文 UDP 53；`queryStrategy=UseIPv4` 只解析 A 记录，不产生 IPv6 解析路径
- **主机级**：写 sysctl 持久化禁用 IPv6，堵死 IPv6 泄漏口
- **客户端 Clash 配置**：`ipv6: false`；DNS 全部走代理 DoH（`proxy-server-nameserver`），TikTok 域名强制走代理解析；规则 `MATCH,PROXY`，全部流量走节点，不分流
- **自检**：`bash check.sh` 会查节点 IP 的地区、运营商、是不是机房 IP、IPv6 状态、TikTok 从节点出口是否可达

## 排障

- **节点没网、手机全打不开**：先在服务器上测 WS 握手（装完脚本会自动测）：
  `curl -s -i -N --max-time 10 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" https://你的域名/WS路径`
  返回 `101` = 正常；返回 `200 ok` = Caddy 没把请求转给 xray，跑 `docker compose down && docker compose up -d` 重建容器再测；返回 `400` = xray 拒绝握手，核对手机上的 UUID 和 WS 路径跟 config.json 是否一致。
- **Caddy 拿不到证书**：核对域名 A 记录指到本机 IP、云厂商安全组放行 80/443；看日志 `docker logs tiktok-caddy --tail 20`。

## 说明

- 架构：有域名时 Caddy 在 443 终止 TLS，只把随机 WS 路径反代到 xray，其余请求返回普通网页响应（伪装）
- 链接里的 UUID 等同于密码，不要外传；泄露了重跑脚本即可换一套
- 停止/卸载：在目录里运行 `docker compose down`；恢复 IPv6：删掉 `/etc/sysctl.d/99-tiktok-node.conf` 后执行 `sysctl -p`
- 如果 `check.sh` 显示 hosting=true（机房 IP）且之后出现 0 播放/限流，优先换住宅/ISP 的干净 IP，换节点比调参数管用
