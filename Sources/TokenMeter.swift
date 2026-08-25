import Cocoa
import Foundation

// ============================================================================
//  TokenMeter — 菜单栏显示模型 API 余额 / ChatGPT Plus 用量
//  Providers:
//    - deepseek : GET /user/balance (API key)
//    - chatgpt  : GET /backend-api/wham/usage (ChatGPT OAuth access token, 走 Codex auth.json)
//    - openai   : GET /dashboard/billing/credit_grants (API key)
//    - anthropic: 占位
//  连接统一走 config.proxy (如 "127.0.0.1:10808")；为空则用系统代理/直连。
//  配置文件 config.json 与可执行文件同目录，或用 TOKENMETER_CONFIG 指定。
// ============================================================================

// ---------------- 配置模型（容错解码，缺字段用默认值） ----------------
struct ProviderConfig: Codable {
    var enabled: Bool
    var api_key: String
    var token_path: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        api_key = try c.decodeIfPresent(String.self, forKey: .api_key) ?? ""
        token_path = try c.decodeIfPresent(String.self, forKey: .token_path)
    }
    init(enabled: Bool = true, api_key: String = "", token_path: String? = nil) {
        self.enabled = enabled
        self.api_key = api_key
        self.token_path = token_path
    }
}

struct AppConfig: Codable {
    var refresh_minutes: Double
    var tokens_per_cny: Double
    var proxy: String?
    var title_provider: String
    var providers: [String: ProviderConfig]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refresh_minutes = try c.decodeIfPresent(Double.self, forKey: .refresh_minutes) ?? 10
        tokens_per_cny = try c.decodeIfPresent(Double.self, forKey: .tokens_per_cny) ?? 0
        proxy = try c.decodeIfPresent(String.self, forKey: .proxy)
        title_provider = try c.decodeIfPresent(String.self, forKey: .title_provider) ?? "deepseek"
        providers = try c.decodeIfPresent([String: ProviderConfig].self, forKey: .providers) ?? [:]
    }
    init() {
        refresh_minutes = 10
        tokens_per_cny = 0
        proxy = nil
        title_provider = "deepseek"
        providers = [:]
    }

    static func load() -> AppConfig {
        let path = configPath()
        guard let data = FileManager.default.contents(atPath: path),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return cfg
    }

    static func configPath() -> String {
        if let env = ProcessInfo.processInfo.environment["TOKENMETER_CONFIG"], !env.isEmpty {
            return env
        }
        let dir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        return dir + "/config.json"
    }

    // proxy "host:port" -> (host, port)，否则 nil（走系统代理/直连）
    var proxyParts: (String, Int)? {
        guard let proxy = proxy, !proxy.isEmpty else { return nil }
        let parts = proxy.split(separator: ":").map(String.init)
        if parts.count == 2, let port = Int(parts[1]) { return (parts[0], port) }
        return nil
    }

    // 默认遍历顺序，保证菜单栏标题稳定
    static let order = ["deepseek", "chatgpt", "openai", "anthropic"]
}

// ---------------- 余额结果 ----------------
struct ProviderBalance {
    let key: String        // 配置键：deepseek / chatgpt / openai / anthropic
    let name: String       // 显示名：DeepSeek / ChatGPT / OpenAI / Anthropic
    let symbol: String     // 菜单栏前缀：DS / GP / OA / AN
    let display: String    // 菜单行文案
    let currency: String?
    let amount: Double?
    let error: Bool
    let detail: String?
}

// ---------------- 网络会话（走代理，全局一次） ----------------
var httpSession: URLSession = URLSession(configuration: .default)

func configureSession() {
    if let (host, port) = AppConfig.load().proxyParts {
        let cfg = URLSessionConfiguration.default
        cfg.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port,
        ]
        httpSession = URLSession(configuration: cfg)
    } else {
        httpSession = URLSession(configuration: .default) // 用系统代理/直连
    }
}

func httpGET(_ url: String, headers: [String: String], timeout: TimeInterval = 12) -> (Data?, Error?) {
    guard let u = URL(string: url) else { return (nil, nil) }
    var request = URLRequest(url: u, timeoutInterval: timeout)
    request.httpMethod = "GET"
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    let sem = DispatchSemaphore(value: 0)
    var data: Data? = nil
    var err: Error? = nil
    httpSession.dataTask(with: request) { d, _, e in
        data = d
        err = e
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 2)
    return (data, err)
}

func fmtCountdown(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s < 3600 { return "\(s / 60)m" }
    let h = s / 3600
    let m = (s % 3600) / 60
    return m == 0 ? "\(h)h" : "\(h)h \(m)m"
}

// ---------------- DeepSeek ----------------
func fetchDeepSeek(key: String) -> ProviderBalance {
    if key.isEmpty {
        return ProviderBalance(key: "deepseek", name: "DeepSeek", symbol: "DS", display: "需配置 API Key",
                               currency: nil, amount: nil, error: true,
                               detail: "在 config.json 的 deepseek.api_key 填入你的密钥")
    }
    let (data, _) = httpGET("https://api.deepseek.com/user/balance",
                            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"])
    guard let data = data else {
        return ProviderBalance(key: "deepseek", name: "DeepSeek", symbol: "DS", display: "连接失败",
                               currency: nil, amount: nil, error: true, detail: "无法访问 DeepSeek API")
    }
    struct Resp: Decodable {
        let is_available: Bool?
        let balance_infos: [Info]?
        struct Info: Decodable {
            let currency: String?
            let total_balance: String?
            let granted_balance: String?
            let topped_up_balance: String?
        }
    }
    if let r = try? JSONDecoder().decode(Resp.self, from: data), let bi = r.balance_infos?.first {
        let cur = bi.currency ?? "CNY"
        let total = bi.total_balance ?? "?"
        return ProviderBalance(key: "deepseek", name: "DeepSeek", symbol: "DS", display: "\(cur) \(total)",
                               currency: cur, amount: Double(total), error: false,
                               detail: "赠送 \(bi.granted_balance ?? "-") · 充值 \(bi.topped_up_balance ?? "-")")
    }
    return ProviderBalance(key: "deepseek", name: "DeepSeek", symbol: "DS", display: "查询失败",
                           currency: nil, amount: nil, error: true, detail: "接口未返回余额，请检查 API Key")
}

// ---------------- ChatGPT Plus 用量 ----------------
func fetchChatGPT(tokenPath: String?) -> ProviderBalance {
    let key = "chatgpt"
    let authPath = (tokenPath?.isEmpty == false) ? (tokenPath! as NSString).expandingTildeInPath
                  : NSHomeDirectory() + "/.codex/auth.json"
    struct ChatAuth: Decodable { let tokens: Tokens?
        struct Tokens: Decodable { let access_token: String? }
    }
    guard let data = FileManager.default.contents(atPath: authPath),
          let auth = try? JSONDecoder().decode(ChatAuth.self, from: data),
          let tok = auth.tokens?.access_token, !tok.isEmpty else {
        return ProviderBalance(key: key, name: "ChatGPT", symbol: "GP", display: "无会话凭证",
                               currency: nil, amount: nil, error: true,
                               detail: "未找到凭证 \(authPath)，请先运行 codex login")
    }
    struct Wham: Decodable {
        let plan_type: String?
        let rate_limit: RateLimit?
        let rate_limit_reset_credits: RC?
        struct RateLimit: Decodable {
            struct Window: Decodable { let used_percent: Int?; let reset_after_seconds: Int? }
            let primary_window: Window?
            let secondary_window: Window?
        }
        struct RC: Decodable { let available_count: Int? }
    }
    let (respData, _) = httpGET("https://chatgpt.com/backend-api/wham/usage",
                            headers: ["Authorization": "Bearer \(tok)",
                                      "Accept": "application/json",
                                      "User-Agent": "TokenMeter/1.0"])
    guard let respData = respData else {
        return ProviderBalance(key: key, name: "ChatGPT", symbol: "GP", display: "连接失败",
                               currency: nil, amount: nil, error: true,
                               detail: "无法访问 chatgpt.com，请确认代理已开启")
    }
    guard let w = try? JSONDecoder().decode(Wham.self, from: respData), let rl = w.rate_limit else {
        let errMsg = ((try? JSONSerialization.jsonObject(with: respData) as? [String: Any])?["error"] as? String)
                     ?? "接口未返回用量（token 可能过期）"
        return ProviderBalance(key: key, name: "ChatGPT", symbol: "GP", display: "查询失败",
                               currency: nil, amount: nil, error: true, detail: errMsg)
    }
    let plan = (w.plan_type ?? "?").uppercased()
    let used = rl.primary_window?.used_percent ?? 0
    let countdown = fmtCountdown(rl.primary_window?.reset_after_seconds ?? 0)
    let used7 = rl.secondary_window?.used_percent ?? 0
    let resets = w.rate_limit_reset_credits?.available_count ?? 0
    let display = "\(plan) \(used)% · \(countdown)"
    var detail = "主窗口(5h)已用\(used)% · \(countdown)后重置 · 7天窗口\(used7)% · 重置额度\(resets)次"
    if used >= 100 { detail += "（已达上限）" }
    return ProviderBalance(key: key, name: "ChatGPT", symbol: "GP", display: display,
                           currency: nil, amount: nil, error: false, detail: detail)
}

// ---------------- OpenAI ----------------
func fetchOpenAI(key: String) -> ProviderBalance {
    if key.isEmpty {
        return ProviderBalance(key: "openai", name: "OpenAI", symbol: "OA", display: "需配置 API Key",
                               currency: nil, amount: nil, error: true,
                               detail: "在 config.json 的 openai.api_key 填入你的密钥")
    }
    let (data, _) = httpGET("https://api.openai.com/dashboard/billing/credit_grants",
                            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"])
    guard let data = data else {
        return ProviderBalance(key: "openai", name: "OpenAI", symbol: "OA", display: "连接失败",
                               currency: nil, amount: nil, error: true, detail: "无法访问 OpenAI API")
    }
    struct Resp: Decodable { let total_available: Double? }
    if let r = try? JSONDecoder().decode(Resp.self, from: data), let avail = r.total_available {
        return ProviderBalance(key: "openai", name: "OpenAI", symbol: "OA", display: "US$\(String(format: "%.2f", avail / 100))",
                               currency: "USD", amount: avail / 100, error: false,
                               detail: "OpenAI 积分（信用额度）")
    }
    return ProviderBalance(key: "openai", name: "OpenAI", symbol: "OA", display: "查询失败",
                           currency: nil, amount: nil, error: true,
                           detail: "OpenAI 未返回额度，或需浏览器会话/管理员权限")
}

// ---------------- Anthropic ----------------
func fetchAnthropic(key: String) -> ProviderBalance {
    if key.isEmpty {
        return ProviderBalance(key: "anthropic", name: "Anthropic", symbol: "AN", display: "需配置 API Key",
                               currency: nil, amount: nil, error: true,
                               detail: "在 config.json 的 anthropic.api_key 填入你的密钥")
    }
    return ProviderBalance(key: "anthropic", name: "Anthropic", symbol: "AN", display: "暂不支持查询",
                           currency: nil, amount: nil, error: true,
                           detail: "Anthropic 没有公开余额接口，暂无法自动读取")
}

// ---------------- 主应用 ----------------
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    let lastUpdated = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureSession()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "… 加载中"

        refresh()

        let seconds = max(60, AppConfig.load().refresh_minutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let cfg = AppConfig.load()
        let order = AppConfig.order
        DispatchQueue.global(qos: .utility).async {
            var results: [ProviderBalance] = []
            for name in order {
                guard let pc = cfg.providers[name], pc.enabled else { continue }
                let bal: ProviderBalance
                switch name {
                case "deepseek":  bal = fetchDeepSeek(key: pc.api_key)
                case "chatgpt":   bal = fetchChatGPT(tokenPath: pc.token_path)
                case "openai":    bal = fetchOpenAI(key: pc.api_key)
                case "anthropic": bal = fetchAnthropic(key: pc.api_key)
                default:          continue
                }
                results.append(bal)
            }
            DispatchQueue.main.async {
                self.render(results: results, cfg: cfg)
            }
        }
    }

    func render(results: [ProviderBalance], cfg: AppConfig) {
        // 菜单栏标题：优先 title_provider 对应的提供方，其次第一个成功的
        var primary: ProviderBalance?
        if !cfg.title_provider.isEmpty {
            let tp = cfg.title_provider
            if let m = results.first(where: { $0.key == tp && !$0.error }) { primary = m }
            else if let m = results.first(where: { $0.key == tp }) { primary = m }
        }
        if primary == nil { primary = results.first(where: { !$0.error }) ?? results.first }

        var title = "⏳"
        if let p = primary {
            let short = p.display.count > 30 ? String(p.display.prefix(30)) + "…" : p.display
            title = p.symbol != "?" ? "\(p.symbol) \(short)" : short
        }
        statusItem.button?.title = title
        if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] == "1" {
            print("TokenMeter DEBUG menu-title => \(title)")
            for r in results {
                print("TokenMeter DEBUG row => [\(r.key)] \(r.symbol)  \(r.display)  || \(r.detail ?? "")")
            }
            fflush(stdout)
        }

        // 菜单
        let menu = NSMenu()
        menu.autoenablesItems = false

        if results.isEmpty {
            let item = NSMenuItem(title: "未启用任何提供方", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for r in results {
                let item = NSMenuItem(title: "\(r.symbol)  \(r.display)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                if let detail = r.detail {
                    let d = NSMenuItem(title: "        \(detail)", action: nil, keyEquivalent: "")
                    d.isEnabled = false
                    menu.addItem(d)
                }
            }
        }

        if cfg.tokens_per_cny > 0, let deep = results.first(where: { $0.key == "deepseek" && ($0.currency?.uppercased() == "CNY" || $0.currency == nil) }),
           let amount = deep.amount {
            let t = NSMenuItem(title: "≈ \(Int(amount * cfg.tokens_per_cny)) tokens 可调用", action: nil, keyEquivalent: "")
            t.isEnabled = false
            menu.addItem(t)
        }

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "刷新", action: #selector(doRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openCfg = NSMenuItem(title: "打开配置文件", action: #selector(openConfig), keyEquivalent: ",")
        openCfg.target = self
        menu.addItem(openCfg)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "退出 TokenMeter", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc func doRefresh() { refresh() }
    @objc func openConfig() {
        let path = AppConfig.configPath()
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        if !FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: AppConfig.configPath()).deletingLastPathComponent())
        }
    }
    @objc func quit() { NSApplication.shared.terminate(nil) }
}

// ---------------- 入口 ----------------
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
