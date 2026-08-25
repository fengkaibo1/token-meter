# TokenMeter

一个常驻 macOS 菜单栏的小工具，**用一枚自定义 App 图标 + 双拼文字实时显示 DeepSeek 余额 与 ChatGPT Plus 用量**。

菜单栏显示形如：

```
[speedometer 图标]  DS ¥49.66 | GP 剩0%(5h)·84%(7d)
```

- `DS ¥49.66`：DeepSeek 账户余额（CNY）
- `GP 剩0%(5h)·84%(7d)`：ChatGPT Plus **5 小时窗口剩余量** + **周额度剩余量**

点击图标弹出菜单，查看各提供方明细（含重置倒计时、7天窗口）、刷新、打开配置、退出。

## 支持的数据源

| key | 显示内容 | 凭据来源 |
|---|---|---|
| `deepseek` | API 账户余额（CNY） | `deepseek.api_key`（API key） |
| `chatgpt` | **ChatGPT Plus 用量**：5h 主窗口剩余量%（+重置倒计时）、7 天窗口剩余量%、手动重置额度 | 读 `~/.codex/auth.json` 的 ChatGPT OAuth access token（Codex 会话，无需手工登录） |
| `openai` | OpenAI API 积分 | `openai.api_key`（需 OpenAI API key + 代理） |
| `anthropic` | 占位（无公开余额接口） | 暂不支持 |

> 前提说明：
> - ChatGPT Plus 用量通过 `GET https://chatgpt.com/backend-api/wham/usage` 读取（Codex CLI 同款端点），**不是**用 OpenAI API key。access token 由 Codex 保留在 `~/.codex/auth.json`，有效期约 10 天，失效时重新 `codex login` 即可。
> - ChatGPT/OpenAI 域名在部分网络（如国内）被墙，需走代理。App 统一通过 `config.json` 的 `proxy` 字段路由（如 `127.0.0.1:10808`）；留空则用系统代理/直连。

## 目录结构

```
token-meter/
├── Sources/TokenMeter.swift    # 主程序（原生 Swift / NSStatusItem）
├── Sources/gen_icon.swift      # 图标生成脚本（可重新生成图标）
├── assets/                     # 图标源文件（icon.png 菜单栏用, icon_1024.png 主图标）
├── icon.png                    # 菜单栏图标（与可执行文件同目录）
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

- `refresh_minutes`：多久刷新一次。菜单栏标题是**所有启用提供方的自动双拼**（用 ` | ` 连接）。
- `proxy`：HTTP 代理 `host:port`。留空则用系统代理/直连。**默认 `127.0.0.1:10808`，用于访问 chatgpt.com。**
- `tokens_per_cny`：>0 时，按人民币金额估算可调用 token 数（出现在菜单里）。
- `providers`：`enabled=true` 的提供方会显示在标题与菜单里。

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
- 图标为自定义绘制的「仪表盘/余额仪」logo（渐变圆角方块 + 白色指针），自动适配明暗菜单栏。改图标：改 `Sources/gen_icon.swift` 后 `swiftc -swift-version 5 -o /tmp/gen_icon Sources/gen_icon.swift && /tmp/gen_icon`。
- 手动刷新：点菜单栏图标 → 「刷新」；或改 `refresh_minutes`。
- 调试：`TOKENMETER_DEBUG=1 ./token-meter`，把渲染的标题与各提供方文案打印到 stdout。
- 注意：`config.json` 含密钥、`token-meter` 为产物，均已被 `.gitignore` 忽略，不会提交到版本库。
