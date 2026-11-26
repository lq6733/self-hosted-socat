# 用 CLIProxyAPI + Tailscale 搭一个「只给自己和朋友用」的 AI 中转

> 不租 VPS、不买域名、不开端口映射，把家里一台常开的 Linux 变成 Claude Code / Codex / 任意 OpenAI 兼容客户端的统一入口。
> 管理面只在自己 tailnet 内可达，朋友只拿到一条 URL 和一把 key。
>
> 文中所有 IP、域名、密钥均为占位符，请替换成你自己的值。

---

## 0. 最终形态

```
朋友的笔记本 ──Tailscale(WireGuard)──► 家里的 Linux ──► 上游 Claude / Codex / Gemini
```

| 项目 | 取值示例 | 谁能访问 |
|---|---|---|
| 客户端入口 | `https://100.x.y.z:8443/v1` | tailnet 内任意设备（凭 api-key） |
| 管理面板 | `https://100.x.y.z:8443/management.html` | 只有你自己（面板密码 + 管理密钥） |
| 本机回环 | `http://127.0.0.1:8317` | 只有本机进程 |
| 公网端口 | 无 | —— |

客户端只要两条环境变量：

```bash
export OPENAI_BASE_URL=https://100.x.y.z:8443/v1
export OPENAI_API_KEY=sk-xxxxxxxx        # 每人一把，可单独吊销
```

Claude Code 也直接可用，它读 `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`。

---

## 1. 方案选型：为什么最终是 Tailscale

原本最直觉的方案是「域名 + Cloudflare Tunnel + Caddy 反代」，我实际配了一遍，**全线失败**，复盘后换成 Tailscale。三种方案的对比：

| 维度 | 域名 + CF Tunnel + Caddy | 公网 IP + 端口映射 + Caddy | **Tailscale + socat** |
|---|---|---|---|
| 需要域名 | 必须，且域名真的托管在 CF | 不必须（可自签） | 不需要 |
| 需要公网 IP / 端口映射 | 不需要（出站隧道） | 需要，且 NAT 后还得改路由 | 不需要 |
| 证书 | CF 自动签 | ACME 或自签 | 自签（一次导入 CA） |
| 准入控制 | Cloudflare Access / 自己写 basic_auth | 自己写 | **tailnet 身份本身就是一层** |
| 被扫描/爆破风险 | 公网暴露面 | 公网暴露面 | 零（除 tailnet 外不可达） |
| 依赖外部服务 | Cloudflare 账户 + zone | 无 | Tailscale 协调服务器（控制面） |
| 适合谁 | 要给**非 tailnet 用户**用 | 有公网 IP 且有运维经验 | 自己和少数朋友 |

### 1.1 那次失败踩到的坑（都是真实报错）

| 症状 | 根因 | 教训 |
|---|---|---|
| 域名 `dig` 返回 NXDOMAIN | 域名 NS 还在原 DNS 服务商，Cloudflare 里 zone 是 **Pending** 状态 | 加进 CF 账户 ≠ 已激活，必须改 NS |
| 强制打 CF 边缘返回 `error code: 1016` | CF 侧没有该主机名的 DNS 记录（隧道 CNAME 未建/未代理） | Public Hostname 保存后要去 DNS 页确认橙色云 |
| 修好 DNS 后仍是 404 | 隧道 ingress 的 `path` 字段被填成了 `"HTTP"`（正则匹配不到任何路径），落到兜底 `http_status:404` | **Path 留空**，协议在 Service 的 scheme 里写 |
| 面板白屏 | Caddy 用 `basic_auth` 保护了 `/v8/management*`，而面板 JS 用 `Authorization: Bearer` 调同一路径，两个头互相顶掉 | 静态面板用 basic_auth，`/v8` 交给应用自己的密钥 |
| 重启后隧道 502 | `caddy.service` 是 `disabled` | 自建链路必须逐个确认 `is-enabled` |

结论：**给 tailnet 内的人用，Cloudflare 那一整套是纯负债**。Tailscale 方案上线只花了十几分钟，且没有任何公网暴露面。

---

## 2. 架构与安全模型

```
        ┌─ 朋友的笔电（tailnet） ─┐
        │  https://100.x.y.z:8443 │  TLS 1.3，自签 CA
        └───────────┬─────────────┘
                    │ WireGuard（直连或 DERP 中继）
        ┌───────────▼─────────────┐
        │  tailscale0  100.x.y.z  │  ← socat 只 bind 这个地址
        │      socat (TLS 终结)   │
        └───────────┬─────────────┘
                    │ http://127.0.0.1:8317
        ┌───────────▼─────────────┐
        │     cli-proxy-api       │  ← 只 bind 127.0.0.1
        │  鉴权 / 多凭据轮询 / 协议转换 │
        └───────────┬─────────────┘
                    │ 可选：本机代理出海
        ┌───────────▼─────────────┐
        │  上游 Claude / Codex …  │
        └─────────────────────────┘
```

### 三道边界

1. **网络边界**：`8443` 只 bind 在 tailnet 地址上。局域网、公网、其他网段都连不上（实测局域网 IP 直接 connection refused）。
2. **传输边界**：只有 8443 是 TLS；`8317` 永远只在回环，明文不出本机。
3. **应用边界**：进 tailnet 之后，客户端要 `api-key`（每人一把），管理面要面板密码 + 管理密钥（bcrypt 存储）。

### 为什么不用 `tailscale serve` 的真证书

`tailscale serve` 能用 TS 签发的 Let's Encrypt 证书，体验更好，但它要求**客户端能解析 `*.ts.net` 域名**（MagicDNS）。如果机器上的 DNS 被 NetworkManager / systemd-resolved / 代理接管，`tailscale dns status` 会显示 `Use Tailscale DNS: disabled`，域名解析不了，真证书也用不上（证书只对域名有效，对 IP 无效）。

所以本项目用 **IP + 自签 CA**，完全不依赖 DNS。想用真证书的话，先确认：

```bash
tailscale status --json | grep CertDomains   # 非空才说明 tailnet 开了 HTTPS 证书
getent hosts <节点名>.tailxxxx.ts.net         # 能解析才谈得上用域名
```

---

## 3. 服务器侧部署（逐步）

### 3.1 装 CLIProxyAPI

```bash
VER=v8.1.4
cd /tmp && curl -sLO https://github.com/router-for-me/CLIProxyAPI/releases/download/$VER/CLIProxyAPI_${VER#v}_linux_amd64.tar.gz
curl -sLO https://github.com/router-for-me/CLIProxyAPI/releases/download/$VER/checksums.txt
sha256sum -c <(grep linux_amd64.tar.gz checksums.txt)     # 必须先校验
tar xzf CLIProxyAPI_${VER#v}_linux_amd64.tar.gz
install -m 755 cli-proxy-api ~/.local/bin/
cli-proxy-api --help | head -5
```

> 校验和这一步别省。二进制是直接跑在你机器上的。

### 3.2 配置文件

v8 的配置结构（`config-version: 8`）与老版本差异较大，最小可用配置：

```yaml
config-version: 8

server:
  host: "127.0.0.1"     # 绝对不要写 "" 或 0.0.0.0
  port: 8317

management:
  allow-remote: false    # 配合 socat 回源，tailnet 访问面板照样可用
  secret-key: "请替换成随机串"   # 首次启动后会被改写成 bcrypt 哈希

access:
  api-keys:
    - "sk-请替换"                 # 客户端 key
    # friend-1 — 朋友1（吊销时删掉这两行）
    - "sk-请替换2"

oauth:
  auth-dir: "~/.config/cliproxyapi/auth"   # OAuth 凭据落盘位置

# 可选：所有上游请求走本机代理（中国大陆常见）
# requests:
#   proxy-url: "http://127.0.0.1:7890"
```

配置项详解见官方 `config.example.yaml`（顺带一提：它自己就会解释每个字段，比文档好用）。

### 3.3 systemd 用户服务（不需要 root）

`~/.config/systemd/user/cliproxyapi.service`：

```ini
[Unit]
Description=CLIProxyAPI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/cli-proxy-api -config %h/.config/cliproxyapi/config.yaml
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now cliproxyapi
loginctl enable-linger $USER      # 关键：否则退出登录/重启后服务就没了
```

### 3.4 自签 CA + TLS 前置

```bash
./scripts/cpa-gen-cert.sh --name node.tailxxxx.ts.net \
    --ip 100.x.y.z --ip 192.168.1.10
# 输出到 ~/.config/cliproxyapi/tls/
#   ca.crt / ca.key（私钥不要外发）
#   server.crt / server.key / fullchain.pem
```

`socat` 做 TLS 终结，用脚本动态取 tailnet IP，避免 IP 变了就失效：

`~/.config/systemd/user/cpa-tls.service`：

```ini
[Unit]
Description=CPA TLS front (tailnet only)
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=simple
ExecStart=%h/.local/bin/cpa-tls-front
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
```

```bash
systemctl --user enable --now cpa-tls
ss -tlnp | grep 8443      # 应只看到 100.x.y.z:8443
```

**为什么用 socat 而不是 nginx/caddy**：它是纯字节转发，SSE 流式响应和 WebSocket 都不会被缓冲，配置只有一个命令行；缺点是每连接 fork 一个进程、backlog 只有 5，个人/小团队完全够。真要高并发再换 Caddy。

### 3.5 接入上游凭据

两种方式，任选：

**A. 交互式 OAuth（能开浏览器时）**

```bash
cli-proxy-api -config ~/.config/cliproxyapi/config.yaml -codex-login
# 无图形界面的服务器：
cli-proxy-api -config ... -codex-device-login    # 设备码，跨设备完成
cli-proxy-api -config ... -claude-login -no-browser
```

网络需要代理时加 `-login-proxy http://127.0.0.1:7890`（它会同时写进该凭据的 `proxy_url`）。

**B. 导入认证文件（只能转移文件时）**

管理面板 → 认证文件 → 上传 JSON；或者用 `cpa-import-codex`：

```bash
cpa-import-codex ~/auth.json           # 自动识别格式 → 备份旧文件 → 热加载 → 真实调用验活
cpa-import-codex --rotate-check        # 只检查现有凭据还能不能用
```

凭据目录**有文件监听**，新增/删除/替换都会热加载，不用重启：

```
auth file changed (CREATE): xxx@y.com.json, processing incrementally
```

### 3.6 给每个人发 key

```bash
cpa-key add friend-1 朋友1     # 生成 + 写入 + 重启 + 验活
cpa-key list --show
cpa-key rm friend-1           # 万一要吊销
```

---

## 4. 自研脚本

目录 `scripts/`，全部无第三方依赖（bash / python3 / curl / openssl / socat / systemctl）。

| 脚本 | 用途 | 关键设计 |
|---|---|---|
| `cpa-gen-cert.sh` | 生成 CA + 服务器证书 | SAN 自动包含各 IP；`ca.key` 权限 600 |
| `cpa-tls-front` | socat TLS 前置包装器 | 动态 `tailscale ip -4`，证书缺失时明确报错 |
| `cpa-key` | 客户端 key 增删查验 | 用 YAML 注释做标签，按人精确吊销；改完自动重启并轮询就绪 |
| `cpa-import-codex` | 导入/转换 Codex 凭据 | 兼容 codex CLI 与 CPA 两种格式；从 JWT 解邮箱/计划/到期；旧文件自动备份 |
| `cpa-smoke-test` | 全链路 15 项自检 | 自动挑一个「该账号真的支持」的模型；区分「本地配置坏了」和「上游限流」 |
| `laptop-setup.sh` | 客户端一键初始化 | **用证书链校验代替硬编码指纹**；按发行版试三种信任库并实测生效 |

### 4.1 `cpa-smoke-test` 的输出长这样

```
1. 用户服务       ✓ cliproxyapi active / 开机自启 / linger
2. 监听面         ✓ 8317 仅回环   ✓ 8443 在听
3. 凭据           ✓ 1 个认证文件  ✓ xxx@y.com
4. 模型列表       ✓ 可见 15 个模型
5. 鉴权拒绝       ✓ 无 key → 401   ✓ 错误 key → 401
6. 真实对话       ✓ gpt-6-luna 回复: 收到
7. 流式 SSE       ttfb=1.2s   ✓ 收到 8 个分片（未被缓冲）
结果: 15 通过, 0 失败
```

换凭据、改配置、重启之后跑一遍，比翻日志快。
加 `--quick` 跳过真实调用（不消耗额度）。

### 4.2 `laptop-setup.sh` 的防中间人设计

早期版本硬编码了 CA 指纹，一旦换证书就得改脚本。现在改成**动态校验链**：

```bash
openssl s_client -connect HOST:PORT -servername HOST | openssl x509 -out served.crt
openssl verify -CAfile ca.crt served.crt      # 不过就中止
```

服务器出示的证书必须由刚下载的 CA 签发，否则说明有人在中间替换证书。

---

## 5. 朋友接入教程

完整版（不含架构细节，可直接转发给朋友）见 **[docs/friends.md](docs/friends.md)**。

六步走完：加入 tailnet → 验证连通 → 一条命令初始化 → 配置客户端 → 手动验证 → 三条规矩。
核心命令就两条：

```bash
curl -O https://raw.githubusercontent.com/lq6733/self-hosted-socat/main/scripts/laptop-setup.sh
bash laptop-setup.sh 100.x.y.z sk-xxxxxxxx     # 看到 ✓ API KEY 可用（HTTP 200）即成功
```

初始化脚本会自动拉 CA、校验证书链、装系统与浏览器信任库、写 `~/.config/cpa/client.env`、真实验活。
之后 `source ~/.config/cpa/client.env`，Claude Code / OpenAI SDK / 各类 GUI 客户端都能直接用。

> 朋友只需要 **URL + 自己那把 key**，不需要也不应该拿到管理面板密码。

## 6. 日常运维

```bash
systemctl --user status cliproxyapi cpa-tls
journalctl --user -u cliproxyapi -f      # 主程序
journalctl --user -u cpa-tls -f          # 每个 TLS 连接
cpa-smoke-test                           # 15 项链路自检
cpa-key list / add / rm                  # key 管理
cpa-import-codex --rotate-check          # 凭据是否还活着
```

| 场景 | 操作 |
|---|---|
| 改了 `config.yaml` | 多数项热加载；不确定就 `systemctl --user restart cliproxyapi` |
| tailnet IP 变了 | `systemctl --user restart cpa-tls`（脚本会重新取 IP） |
| 证书到期（默认 10 年） | 重跑 `cpa-gen-cert.sh`，重启 `cpa-tls`，把新 `ca.crt` 发给朋友 |
| 怀疑凭据被吊销 | `cpa-import-codex --rotate-check`，失败就重新登录/导入 |
| 想让某人的 key 失效 | `cpa-key rm friend-2` |

---

## 7. 踩坑清单

| # | 坑 | 正解 |
|---|---|---|
| 1 | CF zone 处于 Pending，域名 NXDOMAIN | 域名 NS 必须真的指向 Cloudflare |
| 2 | Tunnel ingress 的 Path 填了协议名 | Path 留空 |
| 3 | Caddy `basic_auth` 与面板的 `Authorization: Bearer` 冲突 | 只保护静态面板，别保护 `/v8/management*` |
| 4 | `management.allow-remote: false` 会不会挡住反代访问 | 不会，反代从回环回源 |
| 5 | `server.host: ""` 等于监听所有网卡 | 只写 `127.0.0.1`，否则明文 API 直接上局域网 |
| 6 | 用户服务重启后消失 | `loginctl enable-linger $USER` |
| 7 | `socat OPENSSL-LISTEN` 不支持 `compression` 选项 | 删掉该参数（1.8.x） |
| 8 | 脚本 `set -e` 遇到 `sudo cp` 失败直接退出 | 改成「尝试 → 实测校验 → 失败继续」 |
| 9 | 服务重启后立刻验活拿到 `000` | 轮询 `127.0.0.1:8317` 直到有 HTTP 响应 |
| 10 | fish 里多行命令第二行被当命令执行 | 反斜杠后不能有空格；或直接写单行 |
| 11 | `grep -c` 无匹配时返回 1，`$(...)` 里被拼成 `0\n0` | 用 `\|\| true` 再给默认值 |
| 12 | Codex 凭据突然全部 401 | `refresh_token_invalidated`：多设备共享会被上游主动撤销，重新登录/导入 |
| 13 | 模型目录刷新后脚本挑到不可用模型 | 冒烟测试逐个试，遇到 `model_not_found` 自动换下一个 |
| 14 | `tailscale cert` 报 `Access denied` | `sudo tailscale set --operator=$USER` 一次 |

---

## 8. 已知限制（务必知道）

1. **免费/共享账号的额度不可观测**：CLIProxyAPI 没有 per-key 用量统计和限额，上游也不返回 `x-ratelimit-*`。你只会在用光时突然收到 `429` / `server_is_overloaded`（附 `retry-after`，见过 300~400 秒）。想真正管控只能自己加计量，或改用按量计费的 API key 上游。
2. **共享同一账号会被吊销**：把同一个 ChatGPT/Codex 账号给多人用，OpenAI 会撤销 refresh token，表现为所有人同时 401。要稳，就得「每人各自 OAuth 到同一台机器，各用各的额度」。
3. **socat 不是生产级反代**：单连接单进程、backlog 5、无连接复用。个人用没问题，几十人并发就该换 Caddy/Nginx。
4. **自签 CA 的一次性成本**：每个新设备都要导一次证书。这是不用域名的代价。
5. **Tailscale 是控制面依赖**：协调服务器挂了新连接建立不了（已建立的直连还能撑一段）。完全自主可控要上 Headscale。
6. **不要把这个入口当公网服务**：它只有 tailnet 边界 + 一把共享 key，没有速率限制、没有 WAF、没有审计。

---

## 9. 仓库结构

```
.
├── README.md                  # 本文（架构 / 部署 / 运维 / 踩坑）
├── LICENSE                    # MIT
├── docs/
│   └── friends.md             # 给朋友的接入教程（可直接转发）
└── scripts/
    ├── cpa-gen-cert.sh        # 生成 CA + 服务器证书
    ├── cpa-tls-front          # socat TLS 前置（tailnet 专用）
    ├── cpa-key                # 客户端 key 增删查验
    ├── cpa-import-codex       # Codex 凭据导入/转换
    ├── cpa-smoke-test         # 15 项全链路自检
    └── laptop-setup.sh        # 客户端一键初始化（发给朋友这个）
```

安装：

```bash
git clone https://github.com/lq6733/self-hosted-socat.git
cd self-hosted-socat && install -m 755 scripts/* ~/.local/bin/     # 或者只挑需要的
```

`.gitignore` 已经排除 `tls/`、`auth/`、`config.yaml`、`*.bak.*`，**永远不要**把凭据提交上来。

---

## 10. 免责声明

本项目只是把你自己合法拥有的账号/额度做协议转换与网络接入，不提供任何账号、不绕过任何付费。

- 共享账号给多人使用可能违反上游服务条款，账号被封/令牌被吊销的风险自负。
- 自签 CA 只应用于你自己的设备，不要把它装到任何不受你控制的机器上。
- 生产环境请自行补充：限流、审计、密钥轮换、监控告警。

---

## 参考

- CLIProxyAPI：<https://github.com/router-for-me/CLIProxyAPI> · 文档 <https://help.router-for.me/cn/>
- Tailscale：<https://tailscale.com/kb/>
- socat：<https://www.dest-unreach.org/socat/doc/socat.html>

---

## License

[MIT](LICENSE)
