import Cocoa
import Foundation

// ============================================================================
//  TokenMeter — 菜单栏两个图标：DeepSeek 余额 + ChatGPT Plus 用量
//  Providers:
//    - deepseek : GET /user/balance (API key)            图标: deepseek.png (官方蓝鲸)
//    - chatgpt  : GET /backend-api/wham/usage (OAuth token) 图标: chatgpt.png (官方结)
//    - openai / anthropic : 可选
//  每个 provider 独占一个菜单栏项（官方 logo + 各自信息 + 各自菜单）。
//  连接统一走 config.proxy；为空则用系统代理/直连。
//  图标与 config.json 位于可执行文件同目录。
// ============================================================================

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
    var providers: [String: ProviderConfig]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refresh_minutes = try c.decodeIfPresent(Double.self, forKey: .refresh_minutes) ?? 10
        tokens_per_cny = try c.decodeIfPresent(Double.self, forKey: .tokens_per_cny) ?? 0
        proxy = try c.decodeIfPresent(String.self, forKey: .proxy)
        providers = try c.decodeIfPresent([String: ProviderConfig].self, forKey: .providers) ?? [:]
    }
    init() {
        refresh_minutes = 10
        tokens_per_cny = 0
        proxy = nil
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
        if let env = ProcessInfo.processInfo.environment["TOKENMETER_CONFIG"], !env.isEmpty { return env }
        return appDir() + "/config.json"
    }
    var proxyParts: (String, Int)? {
        guard let proxy = proxy, !proxy.isEmpty else { return nil }
        let parts = proxy.split(separator: ":").map(String.init)
        if parts.count == 2, let port = Int(parts[1]) { return (parts[0], port) }
        return nil
    }
    static let order = ["deepseek", "chatgpt", "openai", "anthropic"]
}

func appDir() -> String { (CommandLine.arguments[0] as NSString).deletingLastPathComponent }

// ---------------- 结果 ----------------
struct ProviderBalance {
    let key: String        // 配置键
    let name: String       // 显示名
    let symbol: String     // 菜单行前缀
    let menuTitle: String  // 菜单栏标题文本（图标已表明身份）
    let display: String    // 菜单行主文案
    let currency: String?
    let amount: Double?
    let error: Bool
    let detail: String?
}

// ---------------- 网络 ----------------
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
        httpSession = URLSession(configuration: .default)
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
        data = d; err = e; sem.signal()
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
        return ProviderBalance(key: "deepseek", name: "DeepSeek", symbol: "DS", menuTitle: "⚠︎",
                               display: "需配置 API Key", currency: nil, amount: nil, error: true,
                               detail: "在 config.json 的 deepseek.api_key 填入你的密钥")
    }
    let (data, _) = httpGET("https://api.deepseek.com/user/balance",
                            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"])
    guard let data = data else {
        return ProviderBalance(key: "deepseek", name: "DeepSeek", symbol: "DS", menuTitle: "⚠︎",
                               display: "连接失败", currency: nil, amount: nil, error: true,
                               detail: "无法访问 DeepSeek API")
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
        return ProviderBalance(key: "deepseek", name: "DeepSeek", symbol: "DS", menuTitle: "¥\(total)",
                               display: "余额 \(cur) \(total)", currency: cur, amount: Double(total), error: false,
                               detail: "赠送 \(bi.granted_balance ?? "-") · 充值 \(bi.topped_up_balance ?? "-")")
    }
    return ProviderBalance(key: "deepseek", name: "DeepSeek", symbol: "DS", menuTitle: "⚠︎",
                           display: "查询失败", currency: nil, amount: nil, error: true,
                           detail: "接口未返回余额，请检查 API Key")
}

// ---------------- ChatGPT Plus ----------------
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
        return ProviderBalance(key: key, name: "ChatGPT", symbol: "GP", menuTitle: "⚠︎",
                               display: "无会话凭证", currency: nil, amount: nil, error: true,
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
        return ProviderBalance(key: key, name: "ChatGPT", symbol: "GP", menuTitle: "⚠︎",
                               display: "连接失败", currency: nil, amount: nil, error: true,
                               detail: "无法访问 chatgpt.com，请确认代理已开启")
    }
    guard let w = try? JSONDecoder().decode(Wham.self, from: respData), let rl = w.rate_limit else {
        let errMsg = ((try? JSONSerialization.jsonObject(with: respData) as? [String: Any])?["error"] as? String)
                     ?? "接口未返回用量（token 可能过期）"
        return ProviderBalance(key: key, name: "ChatGPT", symbol: "GP", menuTitle: "⚠︎",
                               display: "查询失败", currency: nil, amount: nil, error: true, detail: errMsg)
    }
    let plan = (w.plan_type ?? "?").uppercased()
    let used5 = rl.primary_window?.used_percent ?? 0
    let rem5 = max(0, 100 - used5)
    let cd = fmtCountdown(rl.primary_window?.reset_after_seconds ?? 0)
    let used7 = rl.secondary_window?.used_percent ?? 0
    let rem7 = max(0, 100 - used7)
    let resets = w.rate_limit_reset_credits?.available_count ?? 0

    let menuTitle = "剩\(rem5)%(5h)·\(rem7)%(7d)"
    var detail = "5h窗口剩余\(rem5)%（\(cd)后重置） · 7天窗口剩余\(rem7)% · 重置额度\(resets)次"
    if used5 >= 100 { detail = "5h窗口已达上限（\(cd)后重置） · 7天窗口剩余\(rem7)% · 重置额度\(resets)次" }
    let display = "\(plan) 剩\(rem5)%(5h) · 剩\(rem7)%(7d) · \(cd)"
    return ProviderBalance(key: key, name: "ChatGPT", symbol: "GP", menuTitle: menuTitle,
                           display: display, currency: nil, amount: nil, error: false, detail: detail)
}

// ---------------- OpenAI ----------------
func fetchOpenAI(key: String) -> ProviderBalance {
    if key.isEmpty {
        return ProviderBalance(key: "openai", name: "OpenAI", symbol: "OA", menuTitle: "⚠︎",
                               display: "需配置 API Key", currency: nil, amount: nil, error: true,
                               detail: "在 config.json 的 openai.api_key 填入你的密钥")
    }
    let (data, _) = httpGET("https://api.openai.com/dashboard/billing/credit_grants",
                            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"])
    guard let data = data else {
        return ProviderBalance(key: "openai", name: "OpenAI", symbol: "OA", menuTitle: "⚠︎",
                               display: "连接失败", currency: nil, amount: nil, error: true,
                               detail: "无法访问 OpenAI API")
    }
    struct Resp: Decodable { let total_available: Double? }
    if let r = try? JSONDecoder().decode(Resp.self, from: data), let avail = r.total_available {
        return ProviderBalance(key: "openai", name: "OpenAI", symbol: "OA",
                               menuTitle: "US$\(String(format: "%.2f", avail / 100))",
                               display: "US$\(String(format: "%.2f", avail / 100))",
                               currency: "USD", amount: avail / 100, error: false,
                               detail: "OpenAI 积分（信用额度）")
    }
    return ProviderBalance(key: "openai", name: "OpenAI", symbol: "OA", menuTitle: "⚠︎",
                           display: "查询失败", currency: nil, amount: nil, error: true,
                           detail: "OpenAI 未返回额度，或需浏览器会话/管理员权限")
}

// ---------------- Anthropic ----------------
func fetchAnthropic(key: String) -> ProviderBalance {
    if key.isEmpty {
        return ProviderBalance(key: "anthropic", name: "Anthropic", symbol: "AN", menuTitle: "⚠︎",
                               display: "需配置 API Key", currency: nil, amount: nil, error: true,
                               detail: "在 config.json 的 anthropic.api_key 填入你的密钥")
    }
    return ProviderBalance(key: "anthropic", name: "Anthropic", symbol: "AN", menuTitle: "⚠︎",
                           display: "暂不支持查询", currency: nil, amount: nil, error: true,
                           detail: "Anthropic 没有公开余额接口，暂无法自动读取")
}

// ---------------- 主应用 ----------------
class AppDelegate: NSObject, NSApplicationDelegate {
    var items: [String: NSStatusItem] = [:]
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureSession()
        let cfg = AppConfig.load()

        for key in AppConfig.order {
            guard let pc = cfg.providers[key], pc.enabled else { continue }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "…"
            applyIcon(to: item, key: key)
            items[key] = item
        }

        refresh()
        let seconds = max(60, cfg.refresh_minutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func applyIcon(to item: NSStatusItem, key: String) {
        let fileName: String?
        switch key {
        case "deepseek": fileName = "deepseek.png"
        case "chatgpt":  fileName = "chatgpt.png"
        default:         fileName = nil
        }
        guard let name = fileName,
              let img = NSImage(contentsOfFile: appDir() + "/" + name) else { return }
        // 缩到菜单栏高度 ~17pt，保留等比
        let targetH: CGFloat = 17
        let s = targetH / img.size.height
        img.size = NSSize(width: img.size.width * s, height: targetH)
        item.button?.image = img
        item.button?.imagePosition = .imageLeading
        if key == "chatgpt" { img.isTemplate = true } // 深色菜单栏自动变白
    }

    func refresh() {
        let cfg = AppConfig.load()
        let order = AppConfig.order
        DispatchQueue.global(qos: .utility).async {
            var results: [String: ProviderBalance] = [:]
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
                results[name] = bal
            }
            DispatchQueue.main.async { self.apply(results: results, cfg: cfg) }
        }
    }

    func apply(results: [String: ProviderBalance], cfg: AppConfig) {
        if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] == "1" {
            for (key, bal) in results {
                print("TokenMeter DEBUG => [\(key)] title=\(bal.menuTitle) | row=\(bal.display) | \(bal.detail ?? "")")
            }
            fflush(stdout)
        }
        for (key, item) in items {
            guard let bal = results[key] else { continue }
            item.button?.title = bal.menuTitle
            item.menu = buildMenu(for: bal, cfg: cfg)
        }
    }

    func buildMenu(for bal: ProviderBalance, cfg: AppConfig) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let main = NSMenuItem(title: bal.display, action: nil, keyEquivalent: "")
        main.isEnabled = false
        menu.addItem(main)
        if let detail = bal.detail {
            let d = NSMenuItem(title: "        \(detail)", action: nil, keyEquivalent: "")
            d.isEnabled = false
            menu.addItem(d)
        }
        if cfg.tokens_per_cny > 0, let amount = bal.amount, bal.currency?.uppercased() == "CNY" {
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
        return menu
    }

    @objc func doRefresh() { refresh() }
    @objc func openConfig() {
        NSWorkspace.shared.open(URL(fileURLWithPath: AppConfig.configPath()))
    }
    @objc func quit() { NSApplication.shared.terminate(nil) }
}

// ---------------- 入口 ----------------
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
