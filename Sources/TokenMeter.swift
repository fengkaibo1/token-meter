import Cocoa
import Foundation

// ============================================================================
//  TokenMeter — 菜单栏显示模型 API 余额 / 额度
//  DeepSeek 为主（/user/balance），OpenAI、Anthropic 为可配置扩展。
//  配置文件 config.json 与可执行文件在同一目录，或用 TOKENMETER_CONFIG 指定。
// ============================================================================

// ---------------- 配置模型（容错解码：缺字段用默认值） ----------------
struct ProviderConfig: Codable {
    var enabled: Bool
    var api_key: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        api_key = try c.decodeIfPresent(String.self, forKey: .api_key) ?? ""
    }
    init(enabled: Bool = true, api_key: String = "") {
        self.enabled = enabled
        self.api_key = api_key
    }
}

struct AppConfig: Codable {
    var refresh_minutes: Double
    var tokens_per_cny: Double
    var providers: [String: ProviderConfig]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refresh_minutes = try c.decodeIfPresent(Double.self, forKey: .refresh_minutes) ?? 10
        tokens_per_cny = try c.decodeIfPresent(Double.self, forKey: .tokens_per_cny) ?? 0
        providers = try c.decodeIfPresent([String: ProviderConfig].self, forKey: .providers) ?? [:]
    }
    init() {
        refresh_minutes = 10
        tokens_per_cny = 0
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
}

// ---------------- 余额结果 ----------------
struct ProviderBalance {
    let name: String       // 短名：DeepSeek / OpenAI / Anthropic
    let symbol: String     // 菜单栏前缀：DS / OA / AN
    let display: String    // 菜单里的展示文本
    let currency: String?
    let amount: Double?
    let error: Bool
    let detail: String?    // 附加信息（错误描述等）
}

// ---------------- HTTP 小工具（同步，带超时） ----------------
func httpGET(_ url: String, headers: [String: String], timeout: TimeInterval = 12) -> (Data?, Error?) {
    guard let u = URL(string: url) else { return (nil, nil) }
    var request = URLRequest(url: u, timeoutInterval: timeout)
    request.httpMethod = "GET"
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    let sem = DispatchSemaphore(value: 0)
    var data: Data? = nil
    var err: Error? = nil
    URLSession.shared.dataTask(with: request) { d, _, e in
        data = d
        err = e
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 2)
    return (data, err)
}

// ---------------- 各提供方余额接口 ----------------
func fetchDeepSeek(key: String) -> ProviderBalance {
    let name = "DeepSeek", sym = "DS"
    if key.isEmpty {
        return ProviderBalance(name: name, symbol: sym, display: "需配置 API Key",
                               currency: nil, amount: nil, error: true,
                               detail: "在 config.json 的 deepseek.api_key 填入你的密钥")
    }
    let (data, _) = httpGET("https://api.deepseek.com/user/balance",
                            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"])
    guard let data = data else {
        return ProviderBalance(name: name, symbol: sym, display: "连接失败",
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
    if let r = try? JSONDecoder().decode(Resp.self, from: data),
       let bi = r.balance_infos?.first {
        let cur = bi.currency ?? "CNY"
        let total = bi.total_balance ?? "?"
        return ProviderBalance(name: name, symbol: sym, display: "\(cur) \(total)",
                               currency: cur, amount: Double(total), error: false,
                               detail: "赠送 \(bi.granted_balance ?? "-") · 充值 \(bi.topped_up_balance ?? "-")")
    }
    return ProviderBalance(name: name, symbol: sym, display: "查询失败",
                           currency: nil, amount: nil, error: true,
                           detail: "接口未返回余额，请检查 API Key")
}

func fetchOpenAI(key: String) -> ProviderBalance {
    let name = "OpenAI", sym = "OA"
    if key.isEmpty {
        return ProviderBalance(name: name, symbol: sym, display: "需配置 API Key",
                               currency: nil, amount: nil, error: true,
                               detail: "在 config.json 的 openai.api_key 填入你的密钥")
    }
    let (data, _) = httpGET("https://api.openai.com/dashboard/billing/credit_grants",
                            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"])
    guard let data = data else {
        return ProviderBalance(name: name, symbol: sym, display: "连接失败",
                               currency: nil, amount: nil, error: true, detail: "无法访问 OpenAI API")
    }
    struct Resp: Decodable { let total_available: Double? }
    if let r = try? JSONDecoder().decode(Resp.self, from: data), let avail = r.total_available {
        return ProviderBalance(name: name, symbol: sym, display: "US$\(String(format: "%.2f", avail / 100))",
                               currency: "USD", amount: avail / 100, error: false,
                               detail: "OpenAI 积分（信用额度）")
    }
    return ProviderBalance(name: name, symbol: sym, display: "查询失败",
                           currency: nil, amount: nil, error: true,
                           detail: "OpenAI 未返回额度，或需浏览器会话/管理员权限")
}

func fetchAnthropic(key: String) -> ProviderBalance {
    let name = "Anthropic", sym = "AN"
    if key.isEmpty {
        return ProviderBalance(name: name, symbol: sym, display: "需配置 API Key",
                               currency: nil, amount: nil, error: true,
                               detail: "在 config.json 的 anthropic.api_key 填入你的密钥")
    }
    // Anthropic 无公开消费者余额接口；仅能通过组织管理员接口查询用量，这里诚实提示。
    return ProviderBalance(name: name, symbol: sym, display: "暂不支持查询",
                           currency: nil, amount: nil, error: true,
                           detail: "Anthropic 没有公开余额接口，暂无法自动读取（需管理员用量接口）")
}

// ---------------- 主应用 ----------------
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var config: AppConfig = AppConfig()
    let lastUpdated = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = AppConfig.load()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "… 加载中"

        refresh()

        let seconds = max(60, config.refresh_minutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let cfg = AppConfig.load()
        let barItem = statusItem
        DispatchQueue.global(qos: .utility).async {
            var results: [ProviderBalance] = []
            for (name, pc) in cfg.providers where pc.enabled {
                let bal: ProviderBalance
                switch name {
                case "deepseek":  bal = fetchDeepSeek(key: pc.api_key)
                case "openai":    bal = fetchOpenAI(key: pc.api_key)
                case "anthropic": bal = fetchAnthropic(key: pc.api_key)
                default:          bal = ProviderBalance(name: name, symbol: "?", display: "未知提供方",
                                                        currency: nil, amount: nil, error: true,
                                                        detail: "不支持提供方 '\(name)'")
                }
                results.append(bal)
            }
            DispatchQueue.main.async {
                self.render(results: results, cfg: cfg)
            }
            _ = barItem
        }
    }

    func render(results: [ProviderBalance], cfg: AppConfig) {
        // 菜单栏标题：显示第一个成功/启用提供方的余额
        var title = "⏳"
        if let first = results.first {
            title = first.display
            if first.error { title = "⚠️ " + (results.first?.symbol ?? "") + " " + (first.display.count > 12 ? (first.display.prefix(12) + "…") : first.display) }
        }
        // 用第一个有值的作为主标题
        if let primary = results.first(where: { !$0.error }) ?? results.first {
            let short = primary.display.count > 14 ? String(primary.display.prefix(14)) + "…" : primary.display
            title = primary.symbol != "?" ? "\(primary.symbol) \(short)" : short
        }
        statusItem.button?.title = title
        if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] == "1" {
            print("TokenMeter DEBUG menu-title => \(title)")
            fflush(stdout)
        }

        // 构建菜单
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

        // token 估算（配置了 tokens_per_cny 才显示）
        if cfg.tokens_per_cny > 0, let deep = results.first(where: { $0.name.lowercased() == "deepseek" && ($0.currency?.uppercased() == "CNY" || $0.currency == nil) }),
           let amount = deep.amount {
            let est = amount * cfg.tokens_per_cny
            let t = NSMenuItem(title: "≈ \(Int(est)) tokens 可调用", action: nil, keyEquivalent: "")
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
