# 接入指南（给朋友）

> 我的 AI 中转配置说明。你只需要跟着做完这 6 步，大约 5 分钟。
> 遇到问题先看最后的「常见报错」，还不行就把报错截图发我。

**我提供给你的两样东西：**

| | 示例 | 说明 |
|---|---|---|
| 服务器地址 | `100.x.y.z` | 我 tailnet 里那台机器的 IP |
| 你的 API Key | `sk-xxxxxxxx` | 每人一把，各不相同 |

---

## 第 1 步：加入我的 tailnet

tailnet 相当于一个「私有局域网」，只有被邀请的设备之间能互相访问，公网上看不到这台机器。

1. 点我发你的 **Tailscale 邀请链接**，登录（Google / GitHub / Microsoft 账号都行）
2. 装客户端：<https://tailscale.com/download>（Windows / macOS / Linux / 手机都有）
3. 用同一个账号登录，看到设备列表里有我的机器和你自己的设备，就算通了

## 第 2 步：确认网络能通

```bash
ping 100.x.y.z
```

- 能 ping 通 → 进第 3 步
- 不通 → 看 Tailscale 客户端是不是显示 `Connected`；公司或校园网可能挡 UDP，会自动走中继（速度慢一点但能用）

## 第 3 步：一条命令初始化（Linux / macOS）

```bash
curl -O https://raw.githubusercontent.com/lq6733/self-hosted-socat/main/scripts/laptop-setup.sh
bash laptop-setup.sh 100.x.y.z sk-xxxxxxxx
```

它会自动完成：

1. 从我服务器拉取自签证书（并校验是不是我签发的，防中间人）
2. 装进系统信任库（自动识别 Arch / Debian / Fedora 系）
3. 装进浏览器（Chromium / Firefox，需要 `certutil`）
4. 写好 `~/.config/cpa/client.env`
5. 用你的 key 发一个真实请求验活

看到这行就成功了：

```
✓ API KEY 可用（HTTP 200）
```

> **Windows 用户**：可以装 WSL 跑上面的命令；或者手动双击 `ca.crt` 导入到「受信任的根证书颁发机构」。

## 第 4 步：配置你的客户端

```bash
source ~/.config/cpa/client.env
```

| 客户端 | 怎么配 |
|---|---|
| **Claude Code** | 不用额外配，它自动读 `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` |
| **Codex CLI** | 同上（读 `OPENAI_BASE_URL` / `OPENAI_API_KEY`） |
| **任意 OpenAI SDK** | `base_url = https://100.x.y.z:8443/v1`，`api_key = sk-xxxxxxxx` |
| **Cherry Studio / LobeChat / OpenWebUI** | Base URL 填 `https://100.x.y.z:8443/v1`，模型填 `gpt-6-luna` |

模型名填哪个？先看有哪些：

```bash
curl --cacert $CPA_CA_FILE $OPENAI_BASE_URL/models \
  -H "Authorization: Bearer $OPENAI_API_KEY"
```

挑带 `luna` / `mini` 的档位最稳（其它档位可能对你的账号类型不支持）。

## 第 5 步：手动验证一次

```bash
source ~/.config/cpa/client.env
curl --cacert $CPA_CA_FILE $OPENAI_BASE_URL/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-6-luna","messages":[{"role":"user","content":"说句话"}],"max_tokens":32}'
```

返回带 `"content"` 的 JSON 就一切正常。

## 第 6 步：三条规矩

1. **key 不要外传**。一人一把，我把你的那把吊销了你就断了，不会影响别人。
2. **只用 API，不要问管理面板密码**。面板只有我能进。
3. **省着用**。上游是免费/共享额度，批量翻译、贴大文件、跑长任务很容易触发限流（会有 `retry-after`，等几百秒才恢复）。

---

## 常见报错

| 报错 | 原因 | 怎么解决 |
|---|---|---|
| `curl: (60) SSL certificate problem` | 证书没装进信任库 | 加 `--cacert ~/.config/cpa/cpa-local-ca.crt`，或重跑初始化脚本 |
| `HTTP 401` / `unauthorized_client` | key 拼错或已被吊销 | 找我确认 key |
| `Connection refused` / 超时 | 不在 tailnet，或我的 IP 变了 | `tailscale status` 看连接状态；找我要新 IP |
| 浏览器「您的连接不是私密连接」 | 浏览器没导入证书（Chrome/Firefox 用 NSS 库） | `sudo apt install -y libnss3-tools`（Debian/Ubuntu）后重跑脚本 |
| `model_not_found` / `not supported when using Codex` | 这个模型不支持你的账号类型 | 换 `luna` / `mini` 之类的档位 |
| `server_is_overloaded` + `retry-after: 367` | 上游限流了 | 等 `retry-after` 秒；或换个模型再试 |
| `✓` 之后过一段时间又 401 | 我这边上游凭据被吊销了 | 找我，我重新导入 |

## 我不会提供的东西

- 管理面板密码（面板只有我能登录）
- 别人的 key
- 任何形式的「稳定 SLA」——这是个人自建服务，我随时可能重启、换方案或关停
