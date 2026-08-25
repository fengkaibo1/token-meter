# TokenMeter

一个常驻 macOS 菜单栏的小工具，**实时显示你的模型 API 余额**（默认 DeepSeek，可扩展 OpenAI / Anthropic）。

菜单栏显示形如 `DS CNY 50.76`，点击图标弹出菜单查看各提供方余额明细、刷新、打开配置、退出。

## 目录结构

```
token-meter/
├── Sources/TokenMeter.swift    # 主程序（原生 Swift / NSStatusItem）
├── config.example.json         # 配置模板（无密钥）
├── config.json                 # 你的配置（含 API Key，已被 .gitignore 忽略）
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

打开 `config.json`，填入 DeepSeek API Key 即可：

```json
{
  "refresh_minutes": 10,
  "tokens_per_cny": 0,
  "providers": {
    "deepseek": { "enabled": true,  "api_key": "sk-XXXX" },
    "openai":   { "enabled": false, "api_key": "" },
    "anthropic":{ "enabled": false, "api_key": "" }
  }
}
```

- `refresh_minutes`：多久刷新一次（最小 1 分钟）。
- `tokens_per_cny`：>0 时，额外按人民币金额估算可调用 token 数（如 700000 表示每 1 元约 70 万 token，按你的模型单价调整）。
- `providers`：`enabled=true` 的提供方会出现在菜单栏/菜单。DeepSeek 走 `/user/balance`；OpenAI 走 `dashboard/billing/credit_grants`；Anthropic 无公开消费者余额接口，暂仅提示。

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

卸载开机自启：

```bash
launchctl unload ~/Library/LaunchAgents/com.fkbo.tokenmeter.plist
```

## 说明

- 原生 Swift 菜单栏应用，无需 Python 运行时。
- 无 Dock 图标，纯菜单栏常驻。
- 调试方法：`TOKENMETER_DEBUG=1 ./token-meter`，会把渲染的菜单栏标题打印到 stdout。
