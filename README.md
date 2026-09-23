# TokenMeter

常驻 macOS 菜单栏的小工具，用**两枚官方图标**分别显示 **DeepSeek 余额** 与 **ChatGPT Plus 用量**：

```
🐳 ¥49.18          🧩 剩0%(5h)·84%(7d)
```

- **DeepSeek 鲸鱼图标** + `¥49.18`：DeepSeek 账户余额（CNY），点击弹出 DeepSeek 明细菜单
- **ChatGPT 六边形结图标** + `剩0%(5h)·84%(7d)`：ChatGPT Plus **5小时窗口剩余量** + **周额度剩余量**，点击弹出用量明细菜单

两个图标分别独立，各带自己的 logo、信息与菜单。

## 支持的数据源

| key | 图标 | 显示内容 | 凭据来源 |
|---|---|---|---|
| `deepseek` | 官方蓝鲸 | API 账户余额（CNY） | `deepseek.api_key`（API key） |
| `chatgpt` | 官方六边形结 | ChatGPT Plus：5h 主窗口剩余量%（+重置倒计时）、7 天窗口剩余量%、手动重置额度 | 读 `~/.codex/auth.json` 的 ChatGPT OAuth access token（Codex 会话，无需手工登录） |
| `openai` | 无 | OpenAI API 积分 | `openai.api_key`（需 OpenAI API key + 代理） |
| `anthropic` | 无 | 占位（无公开余额接口） | 暂不支持 |

> 前提说明：
> - DeepSeek 走**直连**（国内可直连，无需代理）；ChatGPT/OpenAI 走 `config.json` 的 `proxy`。所以重启后即便代理没开，DeepSeek 余额也会正常显示；ChatGPT 则提示「代理可能未启动」。
> - ChatGPT Plus 用量通过 `GET https://chatgpt.com/backend-api/wham/usage` 读取（Codex CLI 同款端点），**不是**用 OpenAI API key。access token 由 Codex 保留在 `~/.codex/auth.json`，有效期约 10 天，失效时重新 `codex login` 即可。
> - ChatGPT/OpenAI 域名在部分网络（如国内）被墙，需走代理；代理客户端请设为**登录时自动启动**，否则重启后 ChatGPT 项需手动开代理才显示。

## 目录结构

```
token-meter/
├── Sources/TokenMeter.swift    # 主程序（原生 Swift / NSStatusItem）
├── deepseek.png                # DeepSeek 官方蓝鲸图标（菜单栏用，透明底）
├── chatgpt.png                 # ChatGPT 官方六边形结图标（菜单栏用，透明底）
├── config.example.json         # 配置模板（无密钥）
├── config.json                 # 你的配置（含密钥，已被 .gitignore 忽略）
├── build.sh                    # 编译脚本
├── install-launchd.sh          # 注册为登录启动项
├── token-meter                 # 编译产物（.gitignore 忽略）
└── README.md
```

## 构建

```bash
cd ~/Documents/Hermes/token-meter
./build.sh          # 生成 ./token-meter
```

## 配置

打开 `config.json`：

```json
{
  "refresh_minutes": 10,
  "tokens_per_cny": 0,
  "proxy": "127.0.0.1:10808",
  "providers": {
    "deepseek": { "enabled": true,  "api_key": "sk-XXXX" },
    "chatgpt":  { "enabled": true,  "api_key": "", "token_path": "~/.codex/auth.json" },
    "openai":   { "enabled": false, "api_key": "" },
    "anthropic":{ "enabled": false, "api_key": "" }
  }
}
```

- `refresh_minutes`：多久刷新一次。每个启用的 provider 各占一个菜单栏项。
- `proxy`：ChatGPT/OpenAI 用的 HTTP 代理 `host:port`（DeepSeek 始终直连、不经代理）。
  - **务必填成你当前代理实际在用的端口**（换代理后要同步改这里），例如 `127.0.0.1:1082`。
  - 注意：经代理访问 `chatgpt.com` 较慢（实测约 17~20 秒），故 `httpGET` 超时设为 **30 秒**；若你的代理更慢，可把 `Sources/TokenMeter.swift` 里 `httpGET` 的 `timeout` 再调大，否则会间歇性显示"连接失败"。
- `tokens_per_cny`：>0 时，按人民币金额估算可调用 token 数（出现在菜单里）。
- `providers`：`enabled=true` 的 provider 会出现在菜单栏（deepseek/chatgpt 带官方图标）。

> 配置查找顺序：环境变量 `TOKENMETER_CONFIG` 指定的路径 → 可执行文件同目录下的 `config.json`。

## 运行

单独运行：

```bash
cd ~/Documents/Hermes/token-meter
./token-meter
```

开机自启（建议）：

```bash
./install-launchd.sh
```

卸除开机自启：

```bash
launchctl bootout gui/$(id -u)/com.fkbo.tokenmeter
rm ~/Library/LaunchAgents/com.fkbo.tokenmeter.plist
```

## 说明

- 原生 Swift 菜单栏应用，无 Dock 图标，无需 Python 运行时。
- 图标来源：DeepSeek 蓝鲸与 ChatGPT 六边形结取自官方 SVG（Wikimedia Commons / DeepSeek 官方标），已裁成透明底小图适配菜单栏。ChatGPT 图标设为模板图，深色菜单栏自动变白。
- 手动刷新：点任一图标 → 「刷新」；或改 `refresh_minutes`。
- 调试：`TOKENMETER_DEBUG=1 ./token-meter`，把每个菜单栏项的标题与明细打印到 stdout。
- 注意：`config.json` 含密钥、`token-meter` 为产物，均已被 `.gitignore` 忽略，不会提交到版本库。
