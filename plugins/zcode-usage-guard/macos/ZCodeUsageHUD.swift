// ============================================================================
// 文件作用：GLM Coding Plan 用量悬浮窗（macOS 原生实现）
//
// 当前版本：v1.1
//   - 无边框圆角悬浮面板，始终置顶，可用鼠标任意位置拖拽
//   - 全局快捷键（默认 Ctrl+G）随时唤出 / 收起
//   - 菜单栏图标兜底，快捷键失效时也能操作
//   - 窗口位置自动记忆，下次弹出保持在上次拖到的地方
//   - v1.1 查询失败时可在面板内直接配置 API Key（服务商下拉 + 粘贴 Key），
//     免去手工编辑 config.json 的门槛；菜单栏也常驻「配置 API Key…」入口
//   - v1.2 手动凭据改存 ~/.zcode/zcode-usage-manual.json，与 Windows 悬浮窗及
//     CLI 查询共用同一份；config.json 里的手填字段仍兼容，但优先级低于共享文件
//
// 为什么这样做：
//   - 用 Swift + AppKit，Mac 自带 Command Line Tools 即可编译，零第三方依赖
//   - 数据不自己请求接口，而是复用官方 zcode-usage.mjs 脚本的 --json 输出，
//     保证显示口径和终端里 /zcode-usage:usage 完全一致，脚本升级后无需改这里
//   - 全局快捷键走 Carbon RegisterEventHotKey，不需要「辅助功能」授权
//   - 手动凭据通过环境变量传给脚本而不是 --key 参数，Key 不会出现在 ps 进程列表
//
// 支持范围：macOS 12+，Apple Silicon / Intel 均可
//
// 注意事项：
//   - 应用以 accessory 模式运行，不占 Dock，不抢焦点
//   - 配置文件 ~/.zcode/zcode-usage-hud/config.json 可改快捷键和刷新间隔
// ============================================================================

import AppKit
import Carbon.HIToolbox

// MARK: - 全局常量与路径

enum HUDPaths {
    static let home = NSHomeDirectory()
    static var baseDir: String { home + "/.zcode/zcode-usage-hud" }
    static var configPath: String { baseDir + "/config.json" }
    /// 官方查询脚本所在的插件缓存根目录
    static var pluginCacheDir: String { home + "/.zcode/cli/plugins/cache" }
    /// 🔑 界面保存的手动凭据，与 Windows 悬浮窗、CLI 查询共用同一份
    static var manualCredPath: String { home + "/.zcode/zcode-usage-manual.json" }
}

enum HUDMetrics {
    static let width: CGFloat = 372
    static let height: CGFloat = 306
    static let pad: CGFloat = 18
    static let corner: CGFloat = 16
}

// MARK: - 配置读写

/// 悬浮窗配置，保存在 config.json，允许用户手工编辑
struct HUDConfig {
    var hotkey: String = "ctrl+g"
    var autoShowOnStart: Bool = true
    var refreshIntervalMinutes: Double = 5
    var originX: Double? = nil
    var originY: Double? = nil
    var nodePath: String? = nil
    /// 独立使用（不依赖 ZCode 登录态）时手工填写的凭据，会以环境变量传给查询脚本
    var apiKey: String? = nil
    var apiBase: String? = nil

    static func load() -> HUDConfig {
        var cfg = HUDConfig()
        guard let data = FileManager.default.contents(atPath: HUDPaths.configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return cfg
        }
        if let v = obj["hotkey"] as? String, !v.isEmpty { cfg.hotkey = v }
        if let v = obj["autoShowOnStart"] as? Bool { cfg.autoShowOnStart = v }
        if let v = obj["refreshIntervalMinutes"] as? Double, v > 0 { cfg.refreshIntervalMinutes = v }
        if let v = obj["originX"] as? Double { cfg.originX = v }
        if let v = obj["originY"] as? Double { cfg.originY = v }
        if let v = obj["nodePath"] as? String, !v.isEmpty { cfg.nodePath = v }
        if let v = obj["apiKey"] as? String, !v.isEmpty { cfg.apiKey = v }
        if let v = obj["apiBase"] as? String, !v.isEmpty { cfg.apiBase = v }
        return cfg
    }

    func save() {
        var obj: [String: Any] = [
            "hotkey": hotkey,
            "autoShowOnStart": autoShowOnStart,
            "refreshIntervalMinutes": refreshIntervalMinutes,
        ]
        if let x = originX { obj["originX"] = x }
        if let y = originY { obj["originY"] = y }
        if let n = nodePath { obj["nodePath"] = n }
        // 凭据显式写 null 而不是省略：清除 Key 时要把旧值从文件里覆盖掉，
        // 否则 load() 会一直读到残留的旧 Key
        obj["apiKey"] = apiKey ?? NSNull()
        obj["apiBase"] = apiBase ?? NSNull()
        try? FileManager.default.createDirectory(atPath: HUDPaths.baseDir,
                                                 withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: obj,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: HUDPaths.configPath))
        }
    }
}

// MARK: - 手动凭据（与 Windows 悬浮窗、CLI 查询共用）

enum ManualCredential {
    static func load() -> (key: String, base: String)? {
        guard let data = FileManager.default.contents(atPath: HUDPaths.manualCredPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let k = obj["apiKey"] as? String, !k.isEmpty,
              let b = obj["apiBase"] as? String, !b.isEmpty else { return nil }
        return (k, b)
    }

    static func save(key: String, base: String) {
        try? FileManager.default.createDirectory(atPath: HUDPaths.baseDir,
                                                 withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["apiKey": key, "apiBase": base],
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: HUDPaths.manualCredPath))
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: HUDPaths.manualCredPath)
    }
}

// MARK: - 官方脚本 JSON 的数据模型

struct UsageDetailDTO: Codable {
    let modelCode: String?
    let usage: Int?
}

struct QuotaLimitDTO: Codable {
    let type: String?
    let unit: Int?
    let number: Int?
    let percentage: Double?
    let usage: Int?
    let currentValue: Int?
    let remaining: Int?
    let nextResetTime: Double?
    let usageDetails: [UsageDetailDTO]?
}

struct QuotaDTO: Codable {
    let limits: [QuotaLimitDTO]?
    let level: String?
}

struct ModelSummaryDTO: Codable {
    let modelName: String?
    let totalTokens: Double?
}

struct TotalUsageDTO: Codable {
    let totalModelCallCount: Double?
    let totalTokensUsage: Double?
    let modelSummaryList: [ModelSummaryDTO]?
}

struct ModelUsageDTO: Codable {
    let totalUsage: TotalUsageDTO?
}

/// 当日用量拆分:高峰期(工作日 14–18 时)/ 非高峰,由 zcode-usage.mjs 计算好
struct UsageSplitSideDTO: Codable {
    let calls: Int?
    let tokens: Double?
}

struct UsageSplitDTO: Codable {
    let peak: UsageSplitSideDTO?
    let offPeak: UsageSplitSideDTO?
}

struct UsageRootDTO: Codable {
    let quota: QuotaDTO?
    let modelUsage: ModelUsageDTO?
    let usageSplit: UsageSplitDTO?
}

// MARK: - 展示用的格式化工具

enum Fmt {
    /// 接口实测：unit 3/5/6 对应 小时/月/周，与官方脚本保持一致
    static let unitName: [Int: String] = [3: "小时", 5: "个月", 6: "周"]

    static func period(_ unit: Int?, _ number: Int?) -> String {
        let n = number ?? 0
        guard let u = unit, let name = unitName[u] else { return "\(n)×unit\(unit ?? -1)" }
        return "\(n)\(name)"
    }

    /// 行标题，规则对齐官方脚本 labelFor()
    static func label(for l: QuotaLimitDTO) -> String {
        let p = period(l.unit, l.number)
        if l.type == "TIME_LIMIT" { return "MCP 工具调用（\(p)）" }
        if p.contains("小时") { return "\(l.number ?? 5) 小时 Prompt 池" }
        if p.contains("周") { return "每周额度" }
        return "\(p)额度"
    }

    static func icon(for l: QuotaLimitDTO) -> String {
        if l.type == "TIME_LIMIT" { return "🔧" }
        return period(l.unit, l.number).contains("小时") ? "🕐" : "📅"
    }

    /// token 数量的中文缩写，1.25 亿 / 9.2 万
    static func tokens(_ n: Double) -> String {
        if n >= 1e8 { return String(format: "%.2f 亿", n / 1e8) }
        if n >= 1e4 { return String(format: "%.1f 万", n / 1e4) }
        return String(format: "%.0f", n)
    }

    /// 千分位整数
    static func int(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// 毫秒时间戳 -> "09/04 18:22"
    static func clock(_ ms: Double) -> String {
        let df = DateFormatter()
        df.dateFormat = "MM/dd HH:mm"
        return df.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// 高峰横幅的警示橙(与 Windows 版 #FFA94D 一致)
    static let peakTint = NSColor(srgbRed: 1.0, green: 0.6627, blue: 0.3020, alpha: 1.0)

    /// 毫秒时间戳 -> "5 天 3 小时 13 分钟后"
    static func countdown(_ ms: Double) -> String {
        let sec = Int(ms / 1000 - Date().timeIntervalSince1970)
        if sec <= 0 { return "即将重置" }
        let d = sec / 86400, h = (sec % 86400) / 3600, m = (sec % 3600) / 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d) 天") }
        if h > 0 { parts.append("\(h) 小时") }
        if m > 0 { parts.append("\(m) 分钟") }
        if parts.isEmpty { parts.append("不到 1 分钟") }
        return parts.joined(separator: " ") + "后"
    }

    /// 按已用比例给进度条配色：越接近用尽越警示
    static func tint(_ usedPercent: Double) -> NSColor {
        if usedPercent >= 85 { return .systemRed }
        if usedPercent >= 60 { return .systemOrange }
        return NSColor(calibratedRed: 0.20, green: 0.72, blue: 0.45, alpha: 1.0)
    }
}

// MARK: - 数据抓取：调用官方 zcode-usage.mjs --json

enum FetchResult {
    case success(UsageRootDTO)
    case failure(String)
}

final class UsageFetcher {

    private static var cachedNode: String?

    /// 定位 node 可执行文件。应用可能被 Finder/launchd 拉起，PATH 很干净，必须自己找。
    static func resolveNode(preferred: String?) -> String? {
        if let c = cachedNode, FileManager.default.isExecutableFile(atPath: c) { return c }
        let fm = FileManager.default
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["GLM_HUD_NODE"] { candidates.append(env) }
        if let p = preferred { candidates.append(p) }
        // nvm 安装的版本，按版本号从新到旧
        let nvmDir = HUDPaths.home + "/.nvm/versions/node"
        if let vers = try? fm.contentsOfDirectory(atPath: nvmDir) {
            let sorted = vers.sorted { a, b in
                a.compare(b, options: .numeric) == .orderedDescending
            }
            candidates.append(contentsOf: sorted.map { nvmDir + "/" + $0 + "/bin/node" })
        }
        candidates.append(contentsOf: ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"])
        for c in candidates where fm.isExecutableFile(atPath: c) {
            cachedNode = c
            return c
        }
        // 兜底：走一次登录 shell 问 PATH
        if let out = runSync("/bin/zsh", ["-lc", "command -v node"], timeout: 8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !out.isEmpty, fm.isExecutableFile(atPath: out) {
            cachedNode = out
            return out
        }
        return nil
    }

    /// 定位官方查询脚本：
    ///   1. 优先找应用包旁边自带的 scripts/zcode-usage.mjs（分享给别人的机器也能用）
    ///   2. 回退到本机 ZCode 插件缓存，插件版本升级后自动选最新
    static func resolveScript() -> String? {
        let fm = FileManager.default
        // Bundle.main.bundleURL 是 …/ZCodeUsageHUD.app/，上一级就是应用所在目录
        let local = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("scripts/zcode-usage.mjs").path
        if fm.fileExists(atPath: local) { return local }

        let root = HUDPaths.pluginCacheDir
        guard let markets = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        var found: [(version: String, path: String)] = []
        for market in markets {
            let skillRoot = root + "/" + market + "/zcode-usage"
            guard let versions = try? fm.contentsOfDirectory(atPath: skillRoot) else { continue }
            for v in versions {
                let p = skillRoot + "/" + v + "/skills/zcode-usage/scripts/zcode-usage.mjs"
                if fm.fileExists(atPath: p) { found.append((v, p)) }
            }
        }
        return found.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
            .first?.path
    }

    /// 同步执行外部命令，带超时保护；env 非 nil 时以该环境变量集启动子进程
    private static func runSync(_ exe: String, _ args: [String], timeout: TimeInterval,
                                env: [String: String]? = nil) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: exe)
        task.arguments = args
        if let env = env { task.environment = env }
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do { try task.run() } catch { return nil }

        // 超时看门狗，避免网络卡死时悬浮窗一直转圈
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()

        if task.terminationStatus != 0 {
            let err = String(data: errData, encoding: .utf8) ?? ""
            let out = String(data: outData, encoding: .utf8) ?? ""
            let msg = (err + "\n" + out).trimmingCharacters(in: .whitespacesAndNewlines)
            UsageFetcher.lastStderr = msg
            return nil
        }
        return String(data: outData, encoding: .utf8)
    }

    static var lastStderr: String = ""

    /// 后台线程抓取数据，完成后回主线程回调
    static func fetch(config: HUDConfig, completion: @escaping (FetchResult, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let script = resolveScript() else {
                DispatchQueue.main.async {
                    completion(.failure("找不到 zcode-usage.mjs，请确认 zcode-usage 插件已安装"), nil)
                }
                return
            }
            guard let node = resolveNode(preferred: config.nodePath) else {
                DispatchQueue.main.async {
                    completion(.failure("找不到 node，可在面板里配置 API Key 或安装 Node.js"), nil)
                }
                return
            }
            lastStderr = ""
            let args = [script, "--json"]
            // 手动凭据优先共享文件(与 Windows 悬浮窗/CLI 共用)，其次 config.json 手填字段。
            // 走 env 而不是 --key 参数：命令行参数对本机所有用户可见(ps)，env 不可见。
            var env: [String: String]? = nil
            let manual = ManualCredential.load()
            if let k = config.apiKey ?? manual?.key, let b = config.apiBase ?? manual?.base {
                var e = ProcessInfo.processInfo.environment
                e["ANTHROPIC_AUTH_TOKEN"] = k
                e["ANTHROPIC_BASE_URL"] = b
                env = e
            }
            guard let raw = runSync(node, args, timeout: 25, env: env) else {
                let detail = lastStderr.split(separator: "\n").first.map(String.init) ?? "脚本执行失败"
                DispatchQueue.main.async { completion(.failure(detail), node) }
                return
            }
            // 脚本理论上只输出纯 JSON，这里仍从第一个 { 开始截，避免混入额外日志
            guard let start = raw.firstIndex(of: "{"),
                  let data = String(raw[start...]).data(using: .utf8),
                  let dto = try? JSONDecoder().decode(UsageRootDTO.self, from: data) else {
                DispatchQueue.main.async { completion(.failure("返回内容解析失败"), node) }
                return
            }
            DispatchQueue.main.async { completion(.success(dto), node) }
        }
    }
}

// MARK: - 进度条视图

final class BarView: NSView {
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }
    var tint: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        guard r.height > 0 else { return }
        let radius = r.height / 2

        NSColor.labelColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()

        let ratio = max(0, min(1, progress))
        guard ratio > 0 else { return }
        // 比例极小时也保证画出一个圆点，视觉上不至于「什么都没有」
        let w = max(ratio * r.width, r.height)
        tint.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: r.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}

// MARK: - 单条额度行

final class QuotaRowView: NSView {
    let titleLabel = HUDContentView.makeLabel(12.5, .semibold, .labelColor)
    let valueLabel = HUDContentView.makeLabel(12, .medium, .secondaryLabelColor, align: .right)
    let bar = BarView()
    let subLabel = HUDContentView.makeLabel(10.5, .regular, .tertiaryLabelColor)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(bar)
        addSubview(subLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    static let rowHeight: CGFloat = 46

    override func layout() {
        super.layout()
        let w = bounds.width
        titleLabel.frame = NSRect(x: 0, y: 0, width: w - 110, height: 16)
        valueLabel.frame = NSRect(x: w - 110, y: 0, width: 110, height: 16)
        bar.frame = NSRect(x: 0, y: 20, width: w, height: 6)
        subLabel.frame = NSRect(x: 0, y: 30, width: w, height: 14)
    }

    func apply(_ l: QuotaLimitDTO) {
        let used = l.percentage ?? 0
        titleLabel.stringValue = "\(Fmt.icon(for: l))  \(Fmt.label(for: l))"
        bar.progress = CGFloat(used / 100)
        bar.tint = Fmt.tint(used)

        if l.type == "TIME_LIMIT", let total = l.usage, let cur = l.currentValue {
            valueLabel.stringValue = "\(Fmt.int(cur)) / \(Fmt.int(total)) 次"
        } else {
            valueLabel.stringValue = String(format: "剩余 %.1f%%", max(0, 100 - used))
        }

        var sub: [String] = []
        if l.type == "TIME_LIMIT", let rem = l.remaining { sub.append("剩余 \(Fmt.int(rem))") }
        if let reset = l.nextResetTime {
            sub.append("↻ \(Fmt.clock(reset)) 重置 · \(Fmt.countdown(reset))")
        }
        subLabel.stringValue = sub.joined(separator: " · ")
    }
}

// MARK: - 面板内容视图

final class HUDContentView: NSView {

    static func makeLabel(_ size: CGFloat,
                          _ weight: NSFont.Weight,
                          _ color: NSColor,
                          align: NSTextAlignment = .left) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = align
        l.lineBreakMode = .byTruncatingTail
        l.isSelectable = false
        return l
    }

    let titleLabel = makeLabel(14, .bold, .labelColor)
    let metaLabel = makeLabel(10.5, .regular, .tertiaryLabelColor)
    let refreshButton = NSButton()
    let closeButton = NSButton()
    var rows: [QuotaRowView] = []
    let separator = NSBox()
    // 高峰期横幅(工作日 14:00–18:00 常驻,结束自动收起):橙色倒计时 + 时段进度条
    let peakBannerLabel = makeLabel(10.5, .semibold, Fmt.peakTint)
    let peakBannerValue = makeLabel(10.5, .regular, Fmt.peakTint, align: .right)
    let peakBannerBar = BarView()
    let footerLabel = makeLabel(11.5, .medium, .labelColor)
    let peakLabel = makeLabel(10.5, .regular, .tertiaryLabelColor)
    let peakValue = makeLabel(10.5, .regular, .secondaryLabelColor, align: .right)
    let offPeakLabel = makeLabel(10.5, .regular, .tertiaryLabelColor)
    let offPeakValue = makeLabel(10.5, .regular, .secondaryLabelColor, align: .right)
    let footerSubLabel = makeLabel(10.5, .regular, .tertiaryLabelColor)
    let hintLabel = makeLabel(10, .regular, .quaternaryLabelColor)
    // 查询失败时的兜底入口:点开后面板内直接选服务商 + 粘贴 API Key
    let configKeyButton = NSButton()
    let setupView = CredentialSetupView()

    var isSetupVisible: Bool { !setupView.isHidden }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.stringValue = "⚡ GLM Coding Plan"
        metaLabel.stringValue = "正在读取…"

        configureIconButton(refreshButton, title: "↻", tooltip: "立即刷新")
        configureIconButton(closeButton, title: "✕", tooltip: "收起面板")

        configKeyButton.title = "🔑 配置 API Key"
        configKeyButton.bezelStyle = .rounded
        configKeyButton.controlSize = .small
        configKeyButton.font = .systemFont(ofSize: 11, weight: .medium)
        configKeyButton.toolTip = "手动选择服务商并粘贴 API Key"
        configKeyButton.isHidden = true

        separator.boxType = .separator

        peakBannerLabel.stringValue = "⚡ 高峰期进行中"
        peakBannerBar.tint = Fmt.peakTint
        [peakBannerLabel, peakBannerValue, peakBannerBar].forEach { $0.isHidden = true }

        peakLabel.stringValue = "高峰期(工作日 14–18 时)"
        offPeakLabel.stringValue = "非高峰期"

        for _ in 0..<3 {
            let r = QuotaRowView()
            rows.append(r)
            addSubview(r)
        }
        setupView.isHidden = true
        [titleLabel, metaLabel, refreshButton, closeButton,
         separator, peakBannerLabel, peakBannerValue, peakBannerBar,
         footerLabel, peakLabel, peakValue, offPeakLabel, offPeakValue,
         footerSubLabel, hintLabel, configKeyButton, setupView].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func configureIconButton(_ b: NSButton, title: String, tooltip: String) {
        b.title = title
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.font = .systemFont(ofSize: 13, weight: .medium)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tooltip
        b.setButtonType(.momentaryChange)
    }

    override func layout() {
        super.layout()
        let pad = HUDMetrics.pad
        let w = bounds.width - pad * 2
        var y = pad - 2

        titleLabel.frame = NSRect(x: pad, y: y, width: w - 60, height: 20)
        closeButton.frame = NSRect(x: bounds.width - pad - 20, y: y, width: 20, height: 20)
        refreshButton.frame = NSRect(x: bounds.width - pad - 46, y: y, width: 20, height: 20)
        y += 21
        metaLabel.frame = NSRect(x: pad, y: y, width: w, height: 14)
        y += 14 + 12

        // 配置态:表单占据头部以下的全部区域,其余区块已隐藏,无需再排版
        if !setupView.isHidden {
            setupView.frame = NSRect(x: pad, y: y + 2, width: w,
                                     height: CredentialSetupView.viewHeight)
            return
        }

        if !peakBannerLabel.isHidden {
            peakBannerLabel.frame = NSRect(x: pad, y: y, width: w, height: 14)
            peakBannerValue.frame = NSRect(x: pad, y: y, width: w, height: 14)
            y += 15
            peakBannerBar.frame = NSRect(x: pad, y: y, width: w, height: 4)
            y += 4 + 8
        }

        for r in rows {
            r.frame = NSRect(x: pad, y: y, width: w, height: QuotaRowView.rowHeight)
            r.needsLayout = true
            y += QuotaRowView.rowHeight + 8
        }

        y += 2
        separator.frame = NSRect(x: pad, y: y, width: w, height: 1)
        y += 11
        // 失败态下 footer 行右侧放「配置 API Key」按钮,文案行相应收窄
        let keyBtnW: CGFloat = 126
        footerLabel.frame = NSRect(x: pad, y: y,
                                   width: configKeyButton.isHidden ? w : w - keyBtnW - 10,
                                   height: 16)
        if !configKeyButton.isHidden {
            configKeyButton.frame = NSRect(x: bounds.width - pad - keyBtnW, y: y - 4,
                                           width: keyBtnW, height: 22)
        }
        y += 17
        if !peakLabel.isHidden {
            peakLabel.frame = NSRect(x: pad, y: y, width: w, height: 15)
            peakValue.frame = NSRect(x: pad, y: y, width: w, height: 15)
            y += 16
            offPeakLabel.frame = NSRect(x: pad, y: y, width: w, height: 15)
            offPeakValue.frame = NSRect(x: pad, y: y, width: w, height: 15)
            y += 16
        }
        footerSubLabel.frame = NSRect(x: pad, y: y, width: w, height: 14)
        y += 15
        hintLabel.frame = NSRect(x: pad, y: y, width: w, height: 13)
    }

    /// 内容高度随实际行数变化，用于自适应窗口高度
    var preferredHeight: CGFloat {
        if !setupView.isHidden {
            return HUDMetrics.pad - 2 + 21 + 14 + 12 + 2
                + CredentialSetupView.viewHeight + HUDMetrics.pad
        }
        let visibleRows = rows.filter { !$0.isHidden }.count
        // 高峰横幅隐藏时不占高度:14+1 + 4+8
        let bannerH: CGFloat = peakBannerLabel.isHidden ? 0 : 27
        // 拆分行隐藏(查询失败)时不占高度:15+1+15+1
        let splitH: CGFloat = peakLabel.isHidden ? 0 : 32
        return HUDMetrics.pad - 2 + 21 + 14 + 12
            + bannerH
            + CGFloat(visibleRows) * (QuotaRowView.rowHeight + 8)
            + 2 + 1 + 11 + 16 + 1 + splitH + 14 + 1 + 13 + HUDMetrics.pad
    }

    /// 高峰期(周一至周五 14:00–18:00)常驻橙色横幅:倒计时 + 时段进度,结束自动收起。
    /// 挂在每分钟的 countdownTimer 上,与额度倒计时同频刷新,不新增定时器。
    func updatePeakBanner() {
        let cal = Calendar.current
        let now = Date()
        let dow = cal.component(.weekday, from: now)   // 1=周日 … 7=周六
        let start = cal.startOfDay(for: now).addingTimeInterval(14 * 3600)
        let end = start.addingTimeInterval(4 * 3600)
        let views = [peakBannerLabel, peakBannerValue, peakBannerBar]
        guard dow >= 2 && dow <= 6, now >= start, now < end else {
            views.forEach { $0.isHidden = true }
            needsLayout = true
            return
        }
        let left = Int(end.timeIntervalSince(now))
        if left < 60 { peakBannerValue.stringValue = "即将结束" }
        else if left >= 3600 { peakBannerValue.stringValue = "还剩 \(left / 3600) 小时 \((left % 3600) / 60) 分" }
        else { peakBannerValue.stringValue = "还剩 \((left % 3600) / 60) 分" }
        peakBannerBar.progress = CGFloat(max(0, min(1, now.timeIntervalSince(start) / (4 * 3600))))
        views.forEach { $0.isHidden = false }
        needsLayout = true
    }

    func render(_ dto: UsageRootDTO, hotkeyText: String) {
        setupView.isHidden = true
        updatePeakBanner()
        let level = (dto.quota?.level ?? "").uppercased()
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        metaLabel.stringValue = (level.isEmpty ? "" : "\(level) 套餐 · ")
            + "更新于 \(df.string(from: Date()))"

        let limits = dto.quota?.limits ?? []
        for (i, row) in rows.enumerated() {
            if i < limits.count {
                row.isHidden = false
                row.apply(limits[i])
            } else {
                row.isHidden = true
            }
        }

        if let total = dto.modelUsage?.totalUsage {
            let calls = Int(total.totalModelCallCount ?? 0)
            let tk = total.totalTokensUsage ?? 0
            footerLabel.stringValue = "📊  当日　\(Fmt.int(calls)) 次 · \(Fmt.tokens(tk)) tokens"
            let models = (total.modelSummaryList ?? []).compactMap { m -> String? in
                guard let name = m.modelName else { return nil }
                return "\(name) \(Fmt.tokens(m.totalTokens ?? 0))"
            }
            footerSubLabel.stringValue = models.isEmpty ? "" : models.joined(separator: " · ")
        } else {
            footerLabel.stringValue = "📊  当日用量暂不可用"
            footerSubLabel.stringValue = ""
        }
        // 高峰(工作日 14–18 时)/非高峰拆分;usageSplit 缺省(拆分查询失败)时收起两行
        let splitViews = [peakLabel, peakValue, offPeakLabel, offPeakValue]
        if let split = dto.usageSplit {
            splitViews.forEach { $0.isHidden = false }
            let pc = Int(split.peak?.calls ?? 0), pt = split.peak?.tokens ?? 0
            let oc = Int(split.offPeak?.calls ?? 0), ot = split.offPeak?.tokens ?? 0
            peakValue.stringValue = "\(Fmt.int(pc)) 次 · \(Fmt.tokens(pt)) tokens"
            offPeakValue.stringValue = "\(Fmt.int(oc)) 次 · \(Fmt.tokens(ot)) tokens"
        } else {
            splitViews.forEach { $0.isHidden = true }
        }
        separator.isHidden = false
        configKeyButton.isHidden = true
        hintLabel.isHidden = false
        hintLabel.stringValue = "\(hotkeyText) 唤出 / 收起 · 拖拽面板可移动位置"
        needsLayout = true
    }

    func renderError(_ message: String, hotkeyText: String) {
        setupView.isHidden = true
        updatePeakBanner()
        metaLabel.stringValue = "读取失败"
        for row in rows { row.isHidden = true }
        rows.first?.isHidden = false
        rows.first?.titleLabel.stringValue = "⚠️  查询失败"
        rows.first?.valueLabel.stringValue = ""
        rows.first?.bar.progress = 0
        rows.first?.subLabel.stringValue = message
        footerLabel.stringValue = "点 ↻ 重试，或手动配置 Key"
        footerSubLabel.stringValue = ""
        [peakLabel, peakValue, offPeakLabel, offPeakValue].forEach { $0.isHidden = true }
        separator.isHidden = false
        configKeyButton.isHidden = false
        hintLabel.isHidden = false
        hintLabel.stringValue = "\(hotkeyText) 唤出 / 收起 · 拖拽面板可移动位置"
        needsLayout = true
    }

    func renderLoading() {
        metaLabel.stringValue = "正在读取…"
    }

    // MARK: 凭据配置态

    /// 显示面板内配置表单（查询失败兜底 / 菜单栏主动打开共用）
    func showSetup(apiKey: String?, apiBase: String?) {
        for r in rows { r.isHidden = true }
        [peakBannerLabel, peakBannerValue, peakBannerBar,
         separator, footerLabel, peakLabel, peakValue, offPeakLabel, offPeakValue,
         footerSubLabel, hintLabel, configKeyButton].forEach { $0.isHidden = true }
        setupView.isHidden = false
        setupView.prefill(apiKey: apiKey, apiBase: apiBase)
        metaLabel.stringValue = "手动配置"
        needsLayout = true
    }

    /// 收起配置表单。数据区各控件的可见性由随后的 render()/renderError() 全量接管
    func hideSetup() {
        setupView.isHidden = true
        needsLayout = true
    }
}

// MARK: - 凭据手动配置视图（查询失败时的兜底表单）

/// 面板内直接选服务商 + 粘贴 API Key，保存进 config.json 后立即重查。
/// 此前手动凭据只能手工编辑 ~/.zcode/zcode-usage-hud/config.json，普通用户跨不过这个门槛。
final class CredentialSetupView: NSView {

    /// 服务商下拉的可选项：文案展示给用户，base 是传给脚本的完整 baseURL
    static let baseChoices: [(label: String, base: String)] = [
        ("智谱开放平台（bigmodel.cn）", "https://open.bigmodel.cn/api/anthropic"),
        ("智谱国际（z.ai）", "https://api.z.ai/api/anthropic"),
    ]

    /// 表单总高度，供 HUDContentView 排版与自适应窗口高度
    static let viewHeight: CGFloat = 194

    let titleLabel = HUDContentView.makeLabel(13, .semibold, .labelColor)
    let reasonLabel = HUDContentView.makeLabel(10.5, .regular, .secondaryLabelColor)
    let baseLabel = HUDContentView.makeLabel(11, .medium, .labelColor)
    let basePopup = NSPopUpButton()
    let keyLabel = HUDContentView.makeLabel(11, .medium, .labelColor)
    let keyField = NSSecureTextField()
    let saveButton = NSButton()
    let clearButton = NSButton()
    let hintLabel = NSTextField(labelWithString: "")

    /// (apiKey, apiBase)
    var onSave: ((String, String) -> Void)?
    var onClear: (() -> Void)?

    override var isFlipped: Bool { true }
    /// 面板是非激活窗口，第一次点击就要能落到输入框上，不被当作「激活窗口」吞掉
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.stringValue = "🔑 手动配置 API Key"
        reasonLabel.stringValue = "未自动找到 Coding Plan 凭据，填一次即可，仅保存在本机"

        baseLabel.stringValue = "服务商"
        basePopup.addItems(withTitles: CredentialSetupView.baseChoices.map { $0.label })
        basePopup.controlSize = .small
        basePopup.font = .systemFont(ofSize: 11.5)

        keyLabel.stringValue = "API Key"
        keyField.placeholderString = "在此粘贴 API Key"
        keyField.font = .systemFont(ofSize: 12)
        keyField.setFocusRingType(.exterior)

        saveButton.title = "保存并查询"
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.font = .systemFont(ofSize: 11.5, weight: .semibold)
        saveButton.keyEquivalent = "\r"   // 输入框里按回车即保存
        saveButton.target = self
        saveButton.action = #selector(saveAction)

        clearButton.title = "清除已存 Key"
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.font = .systemFont(ofSize: 11)
        clearButton.toolTip = "删掉已保存的 Key，恢复自动探测 ZCode 配置"
        clearButton.target = self
        clearButton.action = #selector(clearAction)

        hintLabel.stringValue = "Key 来自智谱开放平台「API Keys」页；ZCode 用户也可在 ZCode 模型设置中查看"
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .quaternaryLabelColor
        hintLabel.lineBreakMode = .byWordWrapping

        [titleLabel, reasonLabel, baseLabel, basePopup,
         keyLabel, keyField, saveButton, clearButton, hintLabel].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 回填：域名按已存 apiBase 预选；Key 不回显（安全），但已存时允许「清除」
    func prefill(apiKey: String?, apiBase: String?) {
        keyField.stringValue = ""
        let idx = (apiBase ?? "").contains("z.ai") ? 1 : 0
        basePopup.selectItem(at: idx)
        clearButton.isEnabled = !(apiKey ?? "").isEmpty
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        titleLabel.frame  = NSRect(x: 0, y: 0,   width: w, height: 18)
        reasonLabel.frame = NSRect(x: 0, y: 20,  width: w, height: 13)
        baseLabel.frame   = NSRect(x: 0, y: 41,  width: w, height: 14)
        basePopup.frame   = NSRect(x: 0, y: 56,  width: w, height: 24)
        keyLabel.frame    = NSRect(x: 0, y: 88,  width: w, height: 14)
        keyField.frame    = NSRect(x: 0, y: 103, width: w, height: 24)
        saveButton.frame  = NSRect(x: 0, y: 135, width: 112, height: 24)
        clearButton.frame = NSRect(x: 120, y: 135, width: 132, height: 24)
        hintLabel.frame   = NSRect(x: 0, y: 167, width: w, height: 26)
    }

    @objc private func saveAction() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            NSApp.beep()
            hintLabel.stringValue = "请先粘贴 API Key 再保存"
            return
        }
        onSave?(key, CredentialSetupView.baseChoices[basePopup.indexOfSelectedItem].base)
    }

    @objc private func clearAction() {
        onClear?()
    }
}

// MARK: - 悬浮面板

final class HUDPanel: NSPanel {
    // 无边框窗口默认不能成为 key window，这里放开以便响应 Esc / 输入框获得焦点
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 全局快捷键（Carbon，不需要辅助功能授权）

final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onFire: (() -> Void)?

    /// 解析 "ctrl+g" / "cmd+shift+u" 这类描述
    static func parse(_ text: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let parts = text.lowercased()
            .split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " })
            .map(String.init)
        guard let keyToken = parts.last else { return nil }
        var mods: UInt32 = 0
        for p in parts.dropLast() {
            switch p {
            case "ctrl", "control", "^": mods |= UInt32(controlKey)
            case "cmd", "command", "meta": mods |= UInt32(cmdKey)
            case "shift": mods |= UInt32(shiftKey)
            case "alt", "option", "opt": mods |= UInt32(optionKey)
            default: return nil
            }
        }
        guard let code = keyCodeMap[keyToken] else { return nil }
        return (code, mods)
    }

    static let keyCodeMap: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "space": 49, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    /// 人类可读的快捷键文案，用于面板底部提示
    static func display(_ text: String) -> String {
        var out = ""
        for p in text.lowercased().split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " }) {
            switch p {
            case "ctrl", "control": out += "⌃"
            case "cmd", "command": out += "⌘"
            case "shift": out += "⇧"
            case "alt", "option", "opt": out += "⌥"
            default: out += p.uppercased()
            }
        }
        return out
    }

    @discardableResult
    func register(_ text: String) -> Bool {
        unregister()
        guard let (code, mods) = HotKeyCenter.parse(text) else { return false }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { HotKeyCenter.shared.onFire?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        // signature 用四字符码 'GLMH' 标识本应用的热键
        let hotKeyID = EventHotKeyID(signature: OSType(0x474C_4D48), id: 1)
        let status = RegisterEventHotKey(code, mods, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }
}

// MARK: - 应用主体

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var panel: HUDPanel!
    private var content: HUDContentView!
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var config = HUDConfig.load()
    private var lastData: UsageRootDTO?
    private var hotkeyOK = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildPanel()
        buildStatusItem()
        setupHotKey()

        if config.autoShowOnStart { showPanel() }
        refresh()
        startTimers()
    }

    /// 再次 open 本应用时（ZCode 每次启动会调一次），把面板重新弹出来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel()
        refresh()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregister()
    }

    // MARK: 界面搭建

    private func buildPanel() {
        let rect = NSRect(x: 0, y: 0, width: HUDMetrics.width, height: HUDMetrics.height)
        panel = HUDPanel(contentRect: rect,
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered,
                         defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true   // 面板任意位置都能拖拽
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.delegate = self

        let effect = NSVisualEffectView(frame: rect)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = HUDMetrics.corner
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        effect.autoresizingMask = [.width, .height]

        content = HUDContentView(frame: rect)
        content.autoresizingMask = [.width, .height]
        content.refreshButton.target = self
        content.refreshButton.action = #selector(refreshAction)
        content.closeButton.target = self
        content.closeButton.action = #selector(hidePanel)
        content.configKeyButton.target = self
        content.configKeyButton.action = #selector(openCredentialSetup)
        content.setupView.onSave = { [weak self] key, base in
            self?.saveCredential(key: key, base: base)
        }
        content.setupView.onClear = { [weak self] in self?.clearCredential() }
        effect.addSubview(content)

        panel.contentView = effect
        restoreFrame()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚡"
        statusItem.button?.toolTip = "GLM Coding Plan 用量"

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "显示 / 收起面板", action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshAction), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let keyItem = NSMenuItem(title: "配置 API Key…", action: #selector(openCredentialSetup), keyEquivalent: "")
        keyItem.target = self
        menu.addItem(keyItem)
        menu.addItem(.separator())
        let cfgItem = NSMenuItem(title: "打开配置文件夹", action: #selector(openConfigDir), keyEquivalent: "")
        cfgItem.target = self
        menu.addItem(cfgItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func setupHotKey() {
        HotKeyCenter.shared.onFire = { [weak self] in self?.togglePanel() }
        hotkeyOK = HotKeyCenter.shared.register(config.hotkey)
        if !hotkeyOK {
            // 快捷键被别的应用占用时不阻塞使用，菜单栏图标依然可用
            statusItem.button?.toolTip = "GLM 用量（快捷键 \(config.hotkey) 注册失败，可能被占用）"
        }
    }

    private func startTimers() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: config.refreshIntervalMinutes * 60,
                                            repeats: true) { [weak self] _ in
            guard let self = self, self.panel.isVisible else { return }
            // 正在填 Key 时不要自动刷新，避免表单被结果渲染冲掉
            guard !self.content.isSetupVisible else { return }
            self.refresh()
        }
        // 每分钟只重画倒计时文案与高峰横幅,不重新请求接口
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self, self.panel.isVisible else { return }
            guard !self.content.isSetupVisible else { return }
            if let d = self.lastData {
                self.content.render(d, hotkeyText: self.hotkeyText)
            } else {
                self.content.updatePeakBanner()
            }
            self.resizeToContent()
        }
    }

    private var hotkeyText: String {
        hotkeyOK ? HotKeyCenter.display(config.hotkey) : "菜单栏 ⚡"
    }

    // MARK: 窗口位置

    private func restoreFrame() {
        let size = NSSize(width: HUDMetrics.width, height: HUDMetrics.height)
        var origin: NSPoint
        if let x = config.originX, let y = config.originY,
           isOnAnyScreen(NSRect(origin: NSPoint(x: x, y: y), size: size)) {
            origin = NSPoint(x: x, y: y)
        } else if let screen = NSScreen.main {
            // 默认停在主屏右上角
            let f = screen.visibleFrame
            origin = NSPoint(x: f.maxX - size.width - 24, y: f.maxY - size.height - 24)
        } else {
            origin = NSPoint(x: 100, y: 100)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func isOnAnyScreen(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
    }

    func windowDidMove(_ notification: Notification) {
        config.originX = Double(panel.frame.origin.x)
        config.originY = Double(panel.frame.origin.y)
        config.save()
    }

    // MARK: 行为

    @objc private func togglePanel() {
        // 配置表单展开时不顺带刷新,避免结果渲染把用户正在填的 Key 冲掉(定时器有同样的 guard)
        if panel.isVisible { hidePanel() } else { showPanel(); if !content.isSetupVisible { refresh() } }
    }

    @objc func showPanel() {
        if !isOnAnyScreen(panel.frame) { restoreFrame() }
        resizeToContent()
        panel.orderFrontRegardless()   // 不抢占前台应用焦点
    }

    @objc private func hidePanel() {
        panel.orderOut(nil)
    }

    @objc private func refreshAction() {
        // 同 togglePanel:配置态下点 ↻ 不刷新,表单不被冲掉;保存成功后会自动重查
        guard !content.isSetupVisible else { return }
        refresh()
    }

    @objc private func openConfigDir() {
        NSWorkspace.shared.open(URL(fileURLWithPath: HUDPaths.baseDir))
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: 凭据手动配置

    /// 打开面板内配置表单。用户点按钮进来是明确要打字的，激活一次应用
    /// 保证非激活面板里的输入框能拿到键盘焦点（仅此场景抢一次焦点）。
    @objc private func openCredentialSetup() {
        let m = ManualCredential.load()
        content.hideSetup()
        content.showSetup(apiKey: m?.key ?? config.apiKey, apiBase: m?.base ?? config.apiBase)
        showPanel()
        resizeToContent()
        NSApp.activate(ignoringOtherApps: false)
        panel.makeKey()
        panel.makeFirstResponder(content.setupView.keyField)
    }

    /// 写入共享的手动凭据文件：悬浮窗、CLI 查询都会用它
    private func saveCredential(key: String, base: String) {
        ManualCredential.save(key: key, base: base)
        content.hideSetup()
        refresh()
    }

    /// 清掉手动凭据，恢复自动探测 ZCode 配置
    private func clearCredential() {
        ManualCredential.clear()
        config.apiKey = nil   // 顺带清掉旧版手填字段，避免残留继续覆盖
        config.apiBase = nil
        config.save()
        content.hideSetup()
        refresh()
    }

    // MARK: 刷新

    private func resizeToContent() {
        let h = max(content.preferredHeight, 120)
        guard abs(h - panel.frame.height) > 0.5 else { return }
        // 保持左上角不动地改变高度，视觉上不跳
        var f = panel.frame
        f.origin.y += f.height - h
        f.size.height = h
        panel.setFrame(f, display: true)
    }

    private func refresh() {
        content.renderLoading()
        UsageFetcher.fetch(config: config) { [weak self] result, node in
            guard let self = self else { return }
            if let n = node, self.config.nodePath != n {
                self.config.nodePath = n
                self.config.save()
            }
            switch result {
            case .success(let dto):
                self.lastData = dto
                self.content.render(dto, hotkeyText: self.hotkeyText)
            case .failure(let msg):
                self.content.renderError(msg, hotkeyText: self.hotkeyText)
            }
            self.resizeToContent()
        }
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
