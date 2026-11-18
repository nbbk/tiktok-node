# Cloudflare API 令牌怎么开（DNS-01 签证书用）

## 什么时候需要令牌，什么时候不需要

- 落地安装选 **[2] DNS 验证（DNS-01）** 时要；选默认走 80（HTTP-01）不要。
- 中转面板绑域名开 HTTPS 时要；面板只用 IP 访问（自签证书）不要。

**令牌是干什么的（一句话）**：Caddy / 面板用它往你的域名下写一条 `_acme-challenge` TXT 记录，证明这个域名是你的，Let's Encrypt 就发证书，验证完记录自动删掉。所以令牌只需要改 DNS 的权限，别的不需要。

## 前置条件

域名 DNS 必须托管在 Cloudflare（域名的 NS 是 Cloudflare 的）。不在 Cloudflare 就先把 NS 改过去，等生效再继续。

## 一步一步开令牌（按 Cloudflare 最新界面）

1. 打开 Cloudflare 后台 [dash.cloudflare.com](https://dash.cloudflare.com)，确认你的域名已经在 Cloudflare 里（没有先点 Add site，把 NS 改成 Cloudflare 给的那两个，等生效）。
2. 右上角头像 → My Profile → API Tokens（用户令牌；直接打开 [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens) 也行）。
3. 点 **Create Token**。
4. 先给令牌起个名字，写清楚用途，例如 `DNS-01 for example.com`。
5. 选模板：点 **“Edit zone DNS”** 那行的 **Use template**。
6. 建 policy：政策类型选 **Zone**，再选资源规则。
7. 权限只留两条：**Zone | DNS | Edit**、**Zone | Zone | Read**（模板自带就是这两条；多了删掉，少了补上）。
8. Zone Resources 选 **Include** → **Specific zone** → 下拉选你的域名（只选一个 zone；多个域名各开一个令牌；**不要选 All zones**）。
9. 可选的 **Token expiration**（过期时间）和 **Client IP Address Filtering**（限制来源 IP）留空就行。
10. 点 **Continue to summary**，核对一遍（权限是上面两条、zone 是你的域名）。
11. 点 **Create Token**。
12. 立刻复制 secret：**只显示一次**，关掉页面就再也看不到。复制下来，先贴到安装脚本或面板里。

新开的令牌以 `cfut_` 开头（旧版是 40 位十六进制，现在新开的都是 `cfut_` 格式）。

## 验证令牌有没有生效

创建完成后，页面上会附一条 curl 测试命令，照着跑就行（把 `<API_TOKEN>` 换成你的令牌）：

```bash
curl "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  --header "Authorization: Bearer <API_TOKEN>"
```

返回里 `status` 是 `active` 就说明令牌有效，例如：

```json
{
  "result": {
    "status": "active"
  },
  "success": true
}
```

## 怎么用

- **落地安装**：选 DNS 验证时脚本问令牌，直接粘贴（输入不回显，看不到自己输了什么，粘贴后回车就行）。
- 也可以提前用环境变量预设（会进 shell 历史，交互粘贴更安全）：

```bash
CERT_METHOD=dns CLOUDFLARE_API_TOKEN=你的令牌 curl -fsSL https://raw.githubusercontent.com/nbbk/tiktok-node/main/install.sh | bash -s example.com
```

- **中转面板**：设置 → Cloudflare Token 里填进去，再开 HTTPS 绑域名。

## 安全

- 令牌只存服务器 `.env`（600 权限，只有 root 能读）或面板配置里，脚本和面板不会把它打印出来。
- 泄露了去 API Tokens 页删掉重建一个，旧的立即失效。
- **绝不用 Global API Key**（等于账号密码，泄露了整个账号都危险）。
- 不要把令牌发给别人或贴到群里。

## 签证书失败时怎么排错

- 核对令牌：新版以 `cfut_` 开头、复制完整（没多空格、没少字符）；用上面那条 curl 命令验一下，`status` 是不是 `active`。
- 核对权限：令牌要有 Zone:DNS:Edit；Zone Resources 选的是你的域名那个 zone，不是 All zones，也不是别的域名。
- 核对域名 DNS 确实在 Cloudflare（NS 是 Cloudflare 的）。
- 看日志：落地跑 `docker logs tiktok-caddy --tail 20` 或 `docker logs singbox-caddy --tail 20`；面板直接看报错提示。

## 换令牌

API Tokens 页删除旧令牌（或点 Roll 轮换），把新的填进 `.env` / 面板设置，重启 Caddy（`docker restart tiktok-caddy` 或 `docker restart singbox-caddy`）或重启面板即可；证书不用重签（令牌只在签发和续签时用）。

## 官方文档

- Cloudflare 官方教程：<https://developers.cloudflare.com/fundamentals/api/get-started/create-token/>（2026-11-06 更新，本文按该版界面写）
