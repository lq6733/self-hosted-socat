# 接入指南（给朋友）

> 我的 AI 中转配置说明。跟着做完 5 步，大约 3 分钟。
> 遇到问题先看最后的「常见报错」，还不行就把报错截图发我。

**我提供给你的两样东西：**

| | 示例 | 说明 |
|---|---|---|
| Base URL | `https://node.tailxxxx.ts.net` | 没有端口号，末尾不要加 `/v1` |
| 你的 API Key | `sk-xxxxxxxx` | 每人一把，各不相同 |

**不需要做的事**：不用装证书、不用配代理、不用改系统设置。

---

## 第 1 步：加入我的 tailnet

tailnet 相当于一个「私有局域网」，只有被邀请的设备能互相访问，公网上看不到这台机器。

1. 点我发你的 **Tailscale 邀请链接**，登录（Google / GitHub / Microsoft 账号都行）
2. 装客户端：<https://tailscale.com/download>
3. 用同一账号登录，看到设备列表里有我的机器和你自己的设备，就算通了

## 第 2 步：确认能解析到我的机器

```bash
ping -c1 node.tailxxxx.ts.net
```

能解析到 `100.x.y.z` 就继续。

**如果解析不了**（公司网络或本地代理会干扰 MagicDNS），加一行 hosts 即可，效果完全一样：

```bash
# Linux / macOS
echo "100.x.y.z node.tailxxxx.ts.net" | sudo tee -a /etc/hosts

# Windows（管理员 PowerShell）
Add-Content C:\Windows\System32\drivers\etc\hosts "100.x.y.z node.tailxxxx.ts.net"
```

## 第 3 步：验证一次（可选，但建议）

```bash
curl https://node.tailxxxx.ts.net/v1/models \
  -H "Authorization: Bearer sk-你的key"
```

返回一大串模型名就通了。返回 `401` 说明 key 不对；超时说明第 1/2 步没过。

> 证书是 Let's Encrypt 签的，系统默认信任，**不要**加 `-k`，加了反而看不出问题。

## 第 4 步：配置你的客户端

| 客户端 | 怎么配 |
|---|---|
| **CCS** | Base URL 填上表那个地址，API Key 填你的 key，模型名填 `gpt-6-luna`（或用 `/v1/models` 里的任意 `gpt-*`） |
| **Claude Code** | `export ANTHROPIC_BASE_URL=https://node.tailxxxx.ts.net`、`export ANTHROPIC_AUTH_TOKEN=sk-...` |
| **Codex CLI** | `export OPENAI_BASE_URL=https://node.tailxxxx.ts.net/v1`、`export OPENAI_API_KEY=sk-...` |
| **任意 OpenAI SDK** | `base_url=.../v1`，`api_key=sk-...` |
| **Cherry Studio / LobeChat / OpenWebUI** | Base URL 填 `.../v1`，模型填 `gpt-6-luna` |

注意两种前缀习惯：**OpenAI 系要 `.../v1`，Anthropic 系不要**（Claude Code 自己会拼 `/v1/messages`）。

## 第 5 步：三条规矩

1. **key 不要外传**。一人一把，吊销你那把只会影响你自己，不会连累别人。
2. **只用 API，不要问管理面板密码**。面板只有我能进。
3. **省着用**。上游是免费/共享额度，批量翻译、贴大文件、跑长任务很容易触发限流（会返回 `retry-after`，等几分钟恢复）。

---

## 常见报错

| 报错 | 原因 | 怎么解决 |
|---|---|---|
| `Could not resolve host` / ping 不通 | 解析不到我的机器 | 按第 2 步加 hosts，或检查 Tailscale 是否 `Connected` |
| `Connection refused` / 超时 | 不在 tailnet，或我换了地址 | `tailscale status` 看连接；找我要新地址 |
| `HTTP 401` / `unauthorized_client` | key 拼错或已被吊销 | 找我确认 key |
| `self-signed certificate in certificate chain` | **你用的是旧地址**（IP:8443），不是新域名 | 换回第 1 步那个 `https://….ts.net` 地址 |
| 浏览器「您的连接不是私密连接」 | 同上，旧地址 | 换成 `https://….ts.net` |
| `model_not_found` / `not supported when using Codex` | 这个模型不支持我的账号类型 | 先用 `gpt-6-luna`；不要选 `*-image-*`、`*-review`、`*-sol` |
| `server_is_overloaded` + `retry-after: 367` | 上游额度被打满 | 等 `retry-after` 秒再试，或换个 `gpt-*` 模型 |
| 昨天好用今天全 401 | 我这边上游凭据被吊销了 | 找我，我重新导入 |
| GUI 客户端连不上但 curl 正常 | 客户端把地址拼错（多写了 `/v1` 或少写了） | OpenAI 系要 `/v1`，Anthropic 系不要 |

## 我不会提供的东西

- 管理面板密码（面板只有我能登录）
- 别人的 key
- 任何稳定 SLA —— 这是个人自建服务，随时可能重启、换方案或关停
