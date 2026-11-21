> **已合并**：本仓库已合并到 [nbbk/landing-node](https://github.com/nbbk/landing-node)，新仓一键安装第一步先选核心（[1] Xray 或 [2] sing-box 二选一）。新一键命令：
>
> ```bash
> curl -fsSL https://raw.githubusercontent.com/nbbk/landing-node/main/install.sh | bash -s [域名]
> ```
>
> 旧一键命令重跑会自动装新版。已装好的机器不受影响：本地安装目录里的旧版 `install.sh` 不动，已跑起来的节点不用重装；想用新版管理脚本接管旧目录，见新仓 README“老机器接管”一节。

# TikTok 运营节点一键包（VLESS + WS + TLS，DNS 防泄漏）

**核心：Xray**（xray-core），VLESS + WS + TLS 单协议。

> 想要一个核心管所有协议的 sing-box 版本？看 [sing-box-node](https://github.com/nbbk/sing-box-node)（核心：sing-box，VLESS/Trojan/VMess/Shadowsocks/Hysteria2/TUIC 多协议合一）。

## 相关仓库

- [tiktok-node](https://github.com/nbbk/tiktok-node)（本仓库）：落地节点，Xray 内核，VLESS + WS + TLS 单协议
- [sing-box-node](https://github.com/nbbk/sing-box-node)：落地节点，sing-box 内核，VLESS/Trojan/VMess/Shadowsocks/Hysteria2/TUIC 6 协议合一
- [relay-node](https://github.com/nbbk/relay-node)：中转，realm 纯转发，落地线路不好时提速

在你自己的墙外服务器上跑一条命令，节点即上线。包里已把 DNS 防泄漏做全，装完自带泄漏自检。

## 前置条件

- 一台墙外服务器（你机场现有的机器就行），Ubuntu/Debian，root 权限
- 一个域名，已解析（A 记录）到这台机器，**有域名强烈建议用**，Caddy 会自动签 TLS 证书；443 端口放行
  - 证书签发方式安装时二选一（见“证书签发方式”一节）：默认走 80 方式时 **80 端口必须空闲**（Caddy 签证书走 HTTP-01 验证必须用 80；80 被占 TLS 装不了）；选 DNS 验证时 80 不用空闲
  - **端口可以自定义**：HTTPS 端口默认 443、明文 WS 端口默认 8080；默认端口被占时安装会让你改一个高位端口（如 8443、24443、30000），直接回车就是默认值
  - 没有域名也能跑：直接回车跳过，用 IP + 明文 WS（默认 8080，可改高位端口；能用，但不如 TLS 隐蔽，之后补域名重跑即可升级）
- 服务器地区 = 你要做的 TikTok 地区（美区、东南亚、英国……），**节点 IP 的地区必须和运营地区一致**，否则直接限流
- IP 尽量干净：住宅/ISP 的 IP 最好；机房 IP 也能跑，但 TikTok 风控更严，`check.sh` 会告诉你当前 IP 是不是机房 IP

## 使用步骤

### 远程一键安装（推荐，不用传包）

服务器上直接跑一条命令，运行后会问域名，输入这台服务器的域名就行：

```
curl -fsSL https://raw.githubusercontent.com/nbbk/tiktok-node/main/install.sh | bash
```

也可以把域名直接跟在命令后面（比如 `... | bash -s example.com`）。换服务器、换地区时不用改脚本：域名先解析到新服务器，再跑同一条命令、输入新域名即可；每次运行都会生成新的 UUID 和 WS 路径，每个服务器一套独立的节点。

**重跑会换掉第一个节点**：不带参数重跑 `install.sh` 只换第一个节点的 UUID 和 WS 路径（旧链接失效），已追加的第 2 个及以后节点不受影响。要在一台机上再加一个节点不要重跑，用下面的“多节点”方法（`--add-node`）。

**自定义端口**：安装时会问 HTTPS 端口（TLS 模式）或 WS 端口（明文模式），直接回车用默认（443 / 8080）；默认端口被占就填个高位端口，如 8443、24443、30000。也可以提前预设好，安装时不再问：

```
HTTPS_PORT=8443 curl -fsSL https://raw.githubusercontent.com/nbbk/tiktok-node/main/install.sh | bash -s example.com
WS_PORT=9080 bash install.sh
```

注意：选默认走 80 方式时 **80 端口必须空闲**，Caddy 签证书走 HTTP-01 验证必须用 80；如果 80 被占，TLS 装不了，要么换一台服务器，要么不填域名走明文模式，要么重跑并选 [2] DNS 验证（要 Cloudflare API 令牌）。

### 本地安装（传包）

1. 把本包传到服务器并解压，进入目录
2. 运行：`bash install.sh`
3. 有域名就输入域名，没有直接回车
4. 脚本会自动：装 Docker → 禁用 IPv6 → 生成 UUID 和随机 WS 路径 → 启动 xray + Caddy → 拨测 → 输出节点链接、base64 订阅内容、`clash.yaml`，并在服务器上生成 `qr.png`（没有 qrencode 时自动用 apt/yum 安装；实在装不上就把节点链接发给 Muse，它会回你二维码图片），最后自动跑一遍 `check.sh` 自检

## 证书签发方式（安装时二选一，默认走 80）

有域名时安装会问一次，每个选项下面都有解释，直接回车就是默认：

- **[1] 默认走 80（HTTP-01）**：最简单，什么都不用准备，装完 Caddy 自己签证书、到期自己续。前提是 80 端口必须空闲、域名要指向这台落地机。适合单节点、80 没被占的情况。
- **[2] DNS 验证（Cloudflare，DNS-01）**：不用 80 端口，域名不用改来改去，续签全自动，不怕忘。前提是域名 DNS 在 Cloudflare，要去 Cloudflare 后台开一个只给改 DNS 权限的 API 令牌。适合 80 被占了、多节点、怕忘续签的情况。

开令牌的详细步骤见 [CLOUDFLARE_TOKEN.md](CLOUDFLARE_TOKEN.md)（按 Cloudflare 最新界面一步一步写，权限只留 Zone:DNS:Edit 和 Zone:Zone:Read，新版令牌以 `cfut_` 开头）。**不要用 Global API Key**（权限太大，泄露了整个账号都危险）。令牌只存在服务器的 `.env` 里（600 权限，只有 root 能读），脚本不会把它打印出来。

也可以提前预设好，安装时不再问（令牌放命令行会进 shell 历史，不放心就安装时交互粘贴，输入时不回显）：

```
CERT_METHOD=dns CLOUDFLARE_API_TOKEN=你的令牌 curl -fsSL https://raw.githubusercontent.com/nbbk/tiktok-node/main/install.sh | bash -s example.com
```

选 DNS 验证后 80 的变化：Caddy 不再把 80 映射到主机，80 被别的程序占着也不影响安装和续签；Caddy 容器会换成现场编译的带 Cloudflare 插件版本（官方 builder 镜像编，第一次约 1-3 分钟，之后复用），证书续签全自动。

## 多节点（一台落地机多个节点）

一台落地机可以跑多个节点，每个节点一个子域名、自己的 UUID 和 WS 路径，手机上当成几个独立节点导入。多个节点共用一个 Caddy 的 443 端口，Caddy 按域名（Host/SNI）分流到各自的 xray 后端。

### 泛域名解析（一次配好）

每个节点一个子域名，比如 `us1.example.com`、`us2.example.com`、`us3.example.com`，都指向同一台落地机。最省事是加一条泛域名 A 记录：

- 主机记录：`*`，记录类型：`A`，记录值：落地机 IP（例如 203.0.113.1）

加完之后任意子域名都自动指向这台机，以后加节点不用再改 DNS。也可以每个子域名单独加一条 A 记录，效果一样，就是每次加节点都要多改一次。

### 追加节点

两种办法：

1. **装完直接加**：第一个节点装完会问“还要再加一个节点吗？[y/N，默认 N]”，回 `y` 就接着装下一个，再问、再加，可以一直加下去。
2. **事后追加**：在节点目录里跑：

   ```
   bash install.sh --add-node
   ```

   也可以把新子域名直接跟在后面，省一次输入：`bash install.sh --add-node us2.example.com`

追加节点只会问新节点的事（子域名、端口），**不会覆盖已有节点**，也不会重问证书方式：追加沿用第一次安装选的证书方式。

### 证书两种方式（追加时怎么走）

- **默认走 80（HTTP-01）**：每个子域名 Caddy 单独签一张证书。加节点前确认新子域名的 A 记录已经指向这台落地机（泛域名配好就不用管），Caddy 追加后自动签，签好新节点才上线。
- **DNS 验证（Cloudflare，DNS-01）**：一张泛域名证书 `*.example.com` 通吃所有子域名，签一次就够，加节点不用再签、不用改 DNS、80 也不用空闲。

### 中转侧不用动

同一台落地机的多个节点共用中转一条 443 转发，靠域名区分：中转的 relay.conf 里这台落地机还是一条规则，域名指向中转机后，`us1.example.com` 和 `us2.example.com` 的流量都走同一条转发，到落地后 Caddy 再按域名分给各自的 xray。**不用给第二个节点再加中转规则**，也不用改中转配置。

### 续签说明

证书还是 Let's Encrypt 90 天，Caddy 到期前 30 天内自动续签。默认走 80 方式时续签要走 80 端口验证：如果域名现在指向中转机、80 又没转到这台落地机，续签会失败，见上面“手动续签”一节（每个节点都要单独续，续哪个就把哪个子域名的 A 记录临时改回落地机）。选 DNS 验证的节点续签全自动，不用管。

### 删除单个节点

```
bash install.sh --del-node
```

会列出全部节点让你选一个（也可以直接传域名：`bash install.sh --del-node us2.example.com`）。删除前会显示该节点的域名和 UUID 做二次确认（[y/N]，默认 N），确认后删除该节点的 xray 容器、Caddyfile 里对应的配置段、节点记录，然后 reload Caddy；其他节点不受影响，删除后脚本会逐个核查剩余节点仍正常（端口监听、WS 握手）。删除时会把被删节点的信息打印出来，方便你留底。`bash stop.sh` 还是全停全删，不动单个节点。

### 明文模式（没有域名）

没有域名也能追加节点：追加时不用填域名，各节点用不同的 WS 端口（默认在前一个节点端口上加 1，比如 8080、8081；也可以自己填）。证书那一节不适用，明文节点没有证书。

## 手动续签（证书快到期、自动续签失败时）

证书是 Let's Encrypt 的 90 天证书，Caddy 会在到期前 30 天内自动续签，平时不用你管。**只有一种情况要手动续签**：签证书走默认 80 方式（HTTP-01）、且域名现在指向中转机、80 又没转到这台落地机时——也就是中转后面第 2 个及以后的落地。Caddy 续签要走 80 端口验证，验证请求到了中转的 80，却转给了第 1 个落地，续不上。**选了 DNS 验证的落地不需要手动续签**，续签全自动。

手动续签的步骤（到期前 2 周内做，别太早——Caddy 只在到期前 30 天内才开始续）：

1. 先看证书还剩几天：在落地机上跑 `cd ~/tiktok-node-kit && bash check.sh`，看“证书与续签”一节（剩 30 天以内才能续）
2. 把域名 A 记录改回指向落地机 IP（在 Cloudflare DNS 里改这条 A 记录）
3. 等 DNS 生效（TTL 一般 5 分钟）；核对：`dig +short example.com` 返回的应该是落地机 IP（例如 203.0.113.1）
4. 重启 Caddy 触发续签：在落地机目录里跑 `cd ~/tiktok-node-kit && docker compose restart caddy`（或 `docker restart tiktok-caddy`）
5. 核对新到期日：再跑 `bash check.sh`，看“证书与续签”一节，剩余天数应该回到 90 天左右
6. 把域名 A 记录改回指向中转机 IP，完事

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
  `curl -s -i -N --max-time 10 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" https://你的域名:端口/WS路径`
  （端口是安装时选的 HTTPS 端口，默认 443；用默认端口时 `:443` 可省略）返回 `101` = 正常；返回 `200 ok` = Caddy 没把请求转给 xray，跑 `docker compose down && docker compose up -d` 重建容器再测；返回 `400` = xray 拒绝握手，核对手机上的 UUID 和 WS 路径跟 config.json 是否一致。
- **Caddy 拿不到证书**：走 80 方式时核对域名 A 记录指到本机 IP、云厂商安全组放行 80 和 HTTPS 端口、**80 端口没有被别的程序占**；选 DNS 验证时核对 Cloudflare 令牌没错、权限够（Zone:DNS:Edit）、域名 DNS 确实在 Cloudflare；看日志 `docker logs tiktok-caddy --tail 20`。

## 日志上限（防爆盘）

- 每个容器（xray、caddy）的日志都有限制：单个文件最多 10MB、最多留 3 份，写满自动轮转，不会像没上限的 json 日志那样一直长到撑爆磁盘。
- **限制只对重建后的容器生效**：已经在跑的容器要重建一次才限流——在节点目录里跑 `docker compose down && docker compose up -d`（配置不动，只重建容器），或重跑安装命令。
- 定期看一眼各容器日志占了多少：`docker system df`，或 `du -sh /var/lib/docker/containers/* | sort -rh | head`。

## 停止 / 删除节点

- **停止（保留配置，可再启动）**：在节点目录里跑 `bash stop.sh`，会停掉**全部节点**的容器并检查实际用的端口（按 `nodes.conf` 里的记录；旧版单节点按 `.env` 里的记录，默认 80/443/8080）是否已释放；再启动跑 `docker compose up -d`。远程一键（不用先下载）：`curl -fsSL https://raw.githubusercontent.com/nbbk/tiktok-node/main/stop.sh | bash`
- **删除单个节点**：`bash install.sh --del-node`，只删选中的一个节点，其他节点不受影响（见“多节点”一节）。
- **彻底删除**：`bash stop.sh --remove`，会删**全部节点**的容器、数据卷、配置目录，并恢复 IPv6（删 `/etc/sysctl.d/99-tiktok-node.conf`）。远程一键：`curl -fsSL https://raw.githubusercontent.com/nbbk/tiktok-node/main/stop.sh | bash -s -- --remove`
- **手动停**：`docker compose down`（保留配置）或 `docker compose down -v`（连数据卷一起删）
- stop.sh 停完会逐个检查端口：如果某个端口仍被占用，会直接列出占用它的进程，照着处理就行；如果占用它的是别的程序，先停掉那个程序或换一台服务器。

## 说明

- 架构：有域名时 Caddy 在 HTTPS 端口（默认 443，可改高位端口）终止 TLS，只把随机 WS 路径反代到 xray，其余请求返回普通网页响应（伪装）；80 端口只用于证书验证（选 DNS 验证时不用 80，见“证书签发方式”一节）
- 链接里的 UUID 等同于密码，不要外传；泄露了重跑脚本即可换一套
- 如果 `check.sh` 显示 hosting=true（机房 IP）且之后出现 0 播放/限流，优先换住宅/ISP 的干净 IP，换节点比调参数管用
