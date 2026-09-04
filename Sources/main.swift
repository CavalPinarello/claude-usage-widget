import Cocoa

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

struct Gauge {
    var key: String          // "session" | "weekly" | scoped key
    var label: String        // "Session (5h)"
    var percentUsed: Double  // 0...100
    var resetsAt: Date?
    var isActive: Bool
    var percentLeft: Double { max(0, 100 - percentUsed) }
}

struct ExtraCredits {
    var enabled: Bool
    var percentUsed: Double
    var usedMinor: Double
    var limitMinor: Double
    var currency: String
    var exponent: Int
}

struct Snapshot {
    var gauges: [Gauge] = []
    var extra: ExtraCredits?
    var plan: String = ""
    var fetchedAt: Date?
    var error: String?
    var stale = false

    var session: Gauge? { gauges.first { $0.key == "session" } }
    var weekly: Gauge? { gauges.first { $0.key == "weekly" } }
}

enum UsageError: LocalizedError {
    case noCredentials
    case tokenExpired(Date)
    case http(Int)
    case badPayload

    var errorDescription: String? {
        switch self {
        case .noCredentials:   return "No Claude Code login found in Keychain"
        case .tokenExpired:    return "Login expired \u{2013} open Claude Code to refresh"
        case .http(401), .http(403): return "Login rejected \u{2013} open Claude Code to refresh"
        case .http(429):       return "Usage API rate limited \u{2013} will retry"
        case .http(let c):     return "Usage API returned HTTP \(c)"
        case .badPayload:      return "Could not read the usage response"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fetching
// ─────────────────────────────────────────────────────────────────────────────

enum UsageFetcher {

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private static let holdLock = NSLock()
    private static var _holdUntil = Date.distantPast
    private static var _strikes = 0          // consecutive 429s, reset on success
    private static var holdUntil: Date {
        get { holdLock.lock(); defer { holdLock.unlock() }; return _holdUntil }
        set { holdLock.lock(); _holdUntil = newValue; holdLock.unlock() }
    }
    private static var strikes: Int {
        get { holdLock.lock(); defer { holdLock.unlock() }; return _strikes }
        set { holdLock.lock(); _strikes = newValue; holdLock.unlock() }
    }

    /// How long to stay off the endpoint after a 429. The limiter is shared
    /// with Claude Code's own usage calls, and every request made while it is
    /// armed re-arms it, so the hold must be long enough to actually clear it.
    /// Cloudflare now answers `Retry-After: 0`, which is useless as a hint:
    /// measured 2026-09-04, the block clears after ~2.5 min of silence. So:
    /// honour a real Retry-After if it is larger, otherwise 2 → 4 → 8 → 15 min.
    private static func holdSeconds(advertised: Double, strike: Int) -> TimeInterval {
        let backoff = min(900, 120 * pow(2, Double(max(0, strike - 1))))
        return max(advertised + 3, backoff)
    }

    static func rateLimitMessage(until: Date) -> String {
        "Usage API rate limited \u{2013} next try \(Style.clock(until))"
    }

    /// Reads the OAuth blob Claude Code stores in the login Keychain.
    /// Shells out to /usr/bin/security on purpose: that binary already holds the
    /// ACL grant, so this never triggers a "wants to access" prompt of its own.
    private static func credentials() throws -> (token: String, expires: Date, tier: String, plan: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run() } catch { throw UsageError.noCredentials }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, !data.isEmpty else { throw UsageError.noCredentials }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw UsageError.noCredentials }

        let ms = (oauth["expiresAt"] as? Double) ?? 0
        let expires = Date(timeIntervalSince1970: ms / 1000)
        let tier = (oauth["rateLimitTier"] as? String) ?? ""
        let plan = (oauth["subscriptionType"] as? String) ?? ""
        return (token, expires, tier, plan)
    }

    static func fetch(completion: @escaping (Snapshot) -> Void) {
        // Never spend a request during a backoff window: hitting the endpoint
        // while rate limited just re-arms the limiter.
        let hold = holdUntil
        if hold > Date() {
            var s = Snapshot()
            s.error = rateLimitMessage(until: hold)
            return completion(s)
        }

        let creds: (token: String, expires: Date, tier: String, plan: String)
        do { creds = try credentials() }
        catch {
            var s = Snapshot(); s.error = (error as? UsageError)?.errorDescription ?? error.localizedDescription
            return completion(s)
        }

        // 30s of slack: the server is the real authority on expiry.
        if creds.expires.timeIntervalSinceNow < -30 {
            var s = Snapshot()
            s.plan = prettyPlan(plan: creds.plan, tier: creds.tier)
            s.error = UsageError.tokenExpired(creds.expires).errorDescription
            return completion(s)
        }

        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 12
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: req) { data, response, error in
            var s = Snapshot()
            s.plan = prettyPlan(plan: creds.plan, tier: creds.tier)

            if let error = error { s.error = error.localizedDescription; return completion(s) }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 429 {
                let advertised = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0
                strikes += 1
                let until = Date().addingTimeInterval(holdSeconds(advertised: advertised, strike: strikes))
                holdUntil = until
                s.error = rateLimitMessage(until: until)
                return completion(s)
            }
            guard (200..<300).contains(code) else {
                s.error = UsageError.http(code).errorDescription
                return completion(s)
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { s.error = UsageError.badPayload.errorDescription; return completion(s) }

            s.gauges = parseGauges(json)
            s.extra = parseExtra(json)
            s.fetchedAt = Date()
            strikes = 0
            if s.gauges.isEmpty { s.error = UsageError.badPayload.errorDescription }
            completion(s)
        }.resume()
    }

    private static func prettyPlan(plan: String, tier: String) -> String {
        // e.g. plan "max" + tier "default_claude_max_5x" -> "Max 5x"
        var name = plan.isEmpty ? "" : plan.prefix(1).uppercased() + plan.dropFirst()
        if let r = tier.range(of: "max_", options: .backwards) {
            let mult = tier[r.upperBound...]   // "5x" / "20x"
            if !mult.isEmpty { name += " " + mult }
        }
        return name
    }

    /// Prefers the newer `limits[]` array; falls back to the flat five_hour /
    /// seven_day objects if a future build drops it.
    private static func parseGauges(_ json: [String: Any]) -> [Gauge] {
        var out: [Gauge] = []

        if let limits = json["limits"] as? [[String: Any]] {
            for l in limits {
                let kind = (l["kind"] as? String) ?? ""
                let pct = (l["percent"] as? Double) ?? 0
                let active = (l["is_active"] as? Bool) ?? false
                let resets = parseDate(l["resets_at"] as? String)

                switch kind {
                case "session":
                    out.append(Gauge(key: "session", label: "Session \u{00B7} 5 hours",
                                     percentUsed: pct, resetsAt: resets, isActive: active))
                case "weekly_all":
                    out.append(Gauge(key: "weekly", label: "Week \u{00B7} all models",
                                     percentUsed: pct, resetsAt: resets, isActive: active))
                case "weekly_scoped":
                    // Only worth a row once it has actually started moving.
                    guard pct > 0 else { continue }
                    var name = "scoped"
                    if let scope = l["scope"] as? [String: Any] {
                        if let m = scope["model"] as? [String: Any],
                           let d = m["display_name"] as? String, !d.isEmpty { name = d }
                        else if let sf = scope["surface"] as? [String: Any],
                                let d = sf["display_name"] as? String, !d.isEmpty { name = d }
                    }
                    out.append(Gauge(key: "weekly_" + name.lowercased(), label: "Week \u{00B7} " + name,
                                     percentUsed: pct, resetsAt: resets, isActive: active))
                default:
                    continue
                }
            }
        }

        if out.isEmpty {
            if let f = json["five_hour"] as? [String: Any], let u = f["utilization"] as? Double {
                out.append(Gauge(key: "session", label: "Session \u{00B7} 5 hours", percentUsed: u,
                                 resetsAt: parseDate(f["resets_at"] as? String), isActive: true))
            }
            if let w = json["seven_day"] as? [String: Any], let u = w["utilization"] as? Double {
                out.append(Gauge(key: "weekly", label: "Week \u{00B7} all models", percentUsed: u,
                                 resetsAt: parseDate(w["resets_at"] as? String), isActive: false))
            }
        }

        // session first, weekly second, scoped after
        let rank: [String: Int] = ["session": 0, "weekly": 1]
        return out.enumerated().sorted {
            (rank[$0.element.key] ?? 2, $0.offset) < (rank[$1.element.key] ?? 2, $1.offset)
        }.map(\.element)
    }

    private static func parseExtra(_ json: [String: Any]) -> ExtraCredits? {
        guard let spend = json["spend"] as? [String: Any] else { return nil }
        let enabled = (spend["enabled"] as? Bool) ?? false
        let used = spend["used"] as? [String: Any]
        let limit = spend["limit"] as? [String: Any]
        return ExtraCredits(
            enabled: enabled,
            percentUsed: (spend["percent"] as? Double) ?? 0,
            usedMinor: (used?["amount_minor"] as? Double) ?? 0,
            limitMinor: (limit?["amount_minor"] as? Double) ?? 0,
            currency: (limit?["currency"] as? String) ?? "USD",
            exponent: (limit?["exponent"] as? Int) ?? 2
        )
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard var str = s, !str.isEmpty else { return nil }
        // ISO8601DateFormatter caps fractional seconds at 3 digits; the API sends 6.
        if let dot = str.firstIndex(of: "."),
           let plus = str.range(of: "+", range: str.index(after: dot)..<str.endIndex)?.lowerBound
                     ?? str.range(of: "Z", range: str.index(after: dot)..<str.endIndex)?.lowerBound {
            let frac = str[str.index(after: dot)..<plus]
            if frac.count > 3 {
                str.replaceSubrange(str.index(after: dot)..<plus, with: frac.prefix(3))
            }
        }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let d = withFrac.date(from: str) ?? plain.date(from: str) else { return nil }
        return Date(timeIntervalSinceReferenceDate: d.timeIntervalSinceReferenceDate.rounded())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared formatting / colour
// ─────────────────────────────────────────────────────────────────────────────

enum Style {
    static func tint(forUsed pct: Double) -> NSColor {
        switch pct {
        case ..<60:  return .systemGreen
        case ..<80:  return .systemYellow
        case ..<95:  return .systemOrange
        default:     return .systemRed
        }
    }

    static func countdown(to date: Date?) -> String {
        guard let date = date else { return "no reset scheduled" }
        let secs = date.timeIntervalSinceNow
        if secs <= 0 { return "resetting now" }
        let d = Int(secs) / 86400, h = (Int(secs) % 86400) / 3600, m = (Int(secs) % 3600) / 60
        let rel: String
        if d > 0      { rel = "\(d)d \(h)h" }
        else if h > 0 { rel = "\(h)h \(m)m" }
        else          { rel = "\(m)m" }

        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate(secs < 86400 ? "jmm" : "EEE jmm")
        return "resets in \(rel) \u{00B7} \(f.string(from: date))"
    }

    static func clock(_ date: Date?) -> String {
        guard let date = date else { return "never" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: date)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Menu bar icon: two stacked meters (top = session, bottom = week)
// ─────────────────────────────────────────────────────────────────────────────

func meterImage(sessionUsed: Double?, weekUsed: Double?) -> NSImage {
    let w: CGFloat = 17, h: CGFloat = 13
    let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
        let barH: CGFloat = 4.5, gap: CGFloat = 2.5
        let top = NSRect(x: 0, y: h / 2 + gap / 2 - 1, width: w, height: barH)
        let bot = NSRect(x: 0, y: h / 2 - gap / 2 - barH - 1, width: w, height: barH)

        func bar(_ frame: NSRect, _ used: Double?) {
            let r = barH / 2
            NSColor.labelColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: frame, xRadius: r, yRadius: r).fill()
            guard let used = used else { return }
            let clamped = min(100, max(0, used))
            guard clamped > 0 else { return }
            // Keep a sliver visible so "barely used" still reads as a filled meter.
            let fw = max(barH, frame.width * CGFloat(clamped) / 100)
            Style.tint(forUsed: clamped).setFill()
            NSBezierPath(roundedRect: NSRect(x: frame.minX, y: frame.minY, width: fw, height: barH),
                         xRadius: r, yRadius: r).fill()
        }
        bar(top, sessionUsed)
        bar(bot, weekUsed)
        return true
    }
    img.isTemplate = false
    return img
}

// ─────────────────────────────────────────────────────────────────────────────
// Dropdown panel
// ─────────────────────────────────────────────────────────────────────────────

final class PanelView: NSView {
    static let width: CGFloat = 296
    private let pad: CGFloat = 15
    private let rowH: CGFloat = 47

    var snapshot = Snapshot() { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    private var rowCount: Int {
        var n = snapshot.gauges.count
        if let e = snapshot.extra, e.enabled { n += 1 }
        return n
    }

    override var intrinsicContentSize: NSSize {
        var h = pad + 20 + 8                       // header
        h += CGFloat(rowCount) * rowH
        if snapshot.error != nil { h += 38 }
        if rowCount == 0 && snapshot.error == nil { h += 34 }
        h += 24 + pad                              // footer
        return NSSize(width: PanelView.width, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let W = bounds.width
        var y = bounds.height - pad

        // Header
        y -= 15
        draw("CLAUDE USAGE",
             font: .systemFont(ofSize: 10, weight: .semibold),
             color: .secondaryLabelColor, kern: 0.9,
             in: NSRect(x: pad, y: y, width: W - pad * 2, height: 15))
        if !snapshot.plan.isEmpty {
            draw(snapshot.plan,
                 font: .systemFont(ofSize: 10, weight: .semibold),
                 color: .tertiaryLabelColor, align: .right,
                 in: NSRect(x: pad, y: y, width: W - pad * 2, height: 15))
        }
        y -= 13

        // Error banner
        if let err = snapshot.error {
            y -= 34
            let box = NSRect(x: pad, y: y, width: W - pad * 2, height: 30)
            // Red means "no numbers"; amber means "numbers shown, but stale".
            let tint: NSColor = snapshot.stale ? .systemOrange : .systemRed
            tint.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            draw(err, font: .systemFont(ofSize: 11), color: tint, lines: 2,
                 in: box.insetBy(dx: 9, dy: 5))
            y -= 4
        }

        // Gauge rows
        for g in snapshot.gauges {
            y -= rowH
            drawGaugeRow(g, in: NSRect(x: pad, y: y, width: W - pad * 2, height: rowH))
        }

        // Extra usage credits
        if let e = snapshot.extra, e.enabled {
            y -= rowH
            let div = pow(10.0, Double(e.exponent))
            let used = String(format: "$%.2f", e.usedMinor / div)
            let cap = String(format: "$%.0f", e.limitMinor / div)
            drawMeterRow(title: "Extra usage credits",
                         value: "\(used) of \(cap)",
                         sub: "billed beyond plan limits",
                         percentUsed: e.percentUsed,
                         tint: .systemPurple,
                         active: false,
                         in: NSRect(x: pad, y: y, width: W - pad * 2, height: rowH))
        }

        if rowCount == 0 && snapshot.error == nil {
            y -= 30
            draw("Fetching\u{2026}", font: .systemFont(ofSize: 12), color: .secondaryLabelColor,
                 in: NSRect(x: pad, y: y, width: W - pad * 2, height: 20))
        }

        // Footer
        y -= 20
        var stamp = snapshot.fetchedAt == nil ? "not yet updated"
                                              : "updated \(Style.clock(snapshot.fetchedAt))"
        if snapshot.stale { stamp += " \u{00B7} last known good" }
        draw(stamp, font: .systemFont(ofSize: 10), color: .tertiaryLabelColor,
             in: NSRect(x: pad, y: y, width: W - pad * 2, height: 14))
        draw("\u{2318}R to refresh", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor,
             align: .right, in: NSRect(x: pad, y: y, width: W - pad * 2, height: 14))
    }

    private func drawGaugeRow(_ g: Gauge, in rect: NSRect) {
        drawMeterRow(title: g.label,
                     value: String(format: "%.0f%% left", g.percentLeft),
                     sub: Style.countdown(to: g.resetsAt),
                     percentUsed: g.percentUsed,
                     tint: Style.tint(forUsed: g.percentUsed),
                     active: g.isActive,
                     in: rect)
    }

    private func drawMeterRow(title: String, value: String, sub: String,
                              percentUsed: Double, tint: NSColor, active: Bool, in rect: NSRect) {
        let top = NSRect(x: rect.minX, y: rect.maxY - 17, width: rect.width, height: 15)
        let gutter: CGFloat = 12
        if active {
            let d: CGFloat = 6
            tint.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX, y: top.maxY - 8 - d / 2,
                                        width: d, height: d)).fill()
        }
        draw(title, font: .systemFont(ofSize: 12, weight: .medium),
             color: active ? .labelColor : .secondaryLabelColor,
             in: NSRect(x: rect.minX + gutter, y: top.minY,
                        width: rect.width - gutter, height: top.height))
        draw(value, font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
             color: tint, align: .right, in: top)

        // meter
        let h: CGFloat = 6
        let track = NSRect(x: rect.minX + gutter, y: rect.maxY - 27,
                           width: rect.width - gutter, height: h)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
        let clamped = min(100, max(0, percentUsed))
        if clamped > 0 {
            let fw = max(h, track.width * CGFloat(clamped) / 100)
            tint.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: fw, height: h),
                         xRadius: h / 2, yRadius: h / 2).fill()
        }

        draw(sub, font: .systemFont(ofSize: 10.5), color: .tertiaryLabelColor,
             in: NSRect(x: rect.minX + gutter, y: rect.maxY - 43,
                        width: rect.width - gutter, height: 14))
    }

    private func draw(_ s: String, font: NSFont, color: NSColor, kern: CGFloat = 0,
                      align: NSTextAlignment = .left, lines: Int = 1, in rect: NSRect) {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] =
            [.font: font, .foregroundColor: color, .paragraphStyle: p]
        if kern != 0 { attrs[.kern] = kern }
        NSAttributedString(string: s, attributes: attrs).draw(in: rect)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Launch at login (plain LaunchAgent – works for an ad-hoc signed .app)
// ─────────────────────────────────────────────────────────────────────────────

enum LoginItem {
    static let label = Bundle.main.bundleIdentifier ?? "com.claudeusage.widget"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func setEnabled(_ on: Bool) {
        let fm = FileManager.default
        if on {
            let exe = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
            ]
            try? fm.createDirectory(at: plistURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                              format: .xml, options: 0) {
                try? data.write(to: plistURL)
                run(["bootstrap", "gui/\(getuid())", plistURL.path])
            }
        } else {
            run(["bootout", "gui/\(getuid())/\(label)"])
            try? fm.removeItem(at: plistURL)
        }
    }

    private static func run(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// App
// ─────────────────────────────────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let panel = PanelView()
    private var menu: NSMenu!
    private var timer: Timer?
    private var snapshot = Snapshot()
    private var loginToggle: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        render()

        buildMenu()
        statusItem.menu = menu

        refresh()
        // 120s: the endpoint's limiter is shared with Claude Code's own calls
        // and takes ~2.5 min of silence to clear once tripped, so poll slowly.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 10

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    private func buildMenu() {
        menu = NSMenu()
        menu.delegate = self

        let panelItem = NSMenuItem()
        panel.frame = NSRect(origin: .zero, size: panel.intrinsicContentSize)
        panelItem.view = panel
        menu.addItem(panelItem)
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow),
                                     keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        loginToggle = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin),
                                 keyEquivalent: "")
        loginToggle.target = self
        menu.addItem(loginToggle)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Claude Usage", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginToggle.state = LoginItem.isEnabled ? .on : .off
        panel.frame = NSRect(origin: .zero, size: panel.intrinsicContentSize)
        panel.needsDisplay = true
        refresh()
    }

    private var lastFetchStarted = Date.distantPast

    @objc private func refreshNow() { refresh(force: true) }

    @objc private func toggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        loginToggle.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func refresh(force: Bool = false) {
        // The usage endpoint 429s under rapid polling; menu opens are throttled.
        if !force && Date().timeIntervalSince(lastFetchStarted) < 30 { return }
        lastFetchStarted = Date()

        UsageFetcher.fetch { [weak self] snap in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var snap = snap
                // Keep the last good reading visible through a transient failure.
                if snap.error != nil, snap.gauges.isEmpty, !self.snapshot.gauges.isEmpty {
                    snap.gauges = self.snapshot.gauges
                    snap.extra = self.snapshot.extra
                    snap.fetchedAt = self.snapshot.fetchedAt
                    snap.stale = true
                }
                self.snapshot = snap
                self.panel.snapshot = snap
                self.panel.frame = NSRect(origin: .zero, size: self.panel.intrinsicContentSize)
                self.render()
            }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let s = snapshot.session?.percentUsed
        let w = snapshot.weekly?.percentUsed
        button.image = meterImage(sessionUsed: s, weekUsed: w)

        let text: String
        var color = NSColor.labelColor
        if snapshot.error != nil && snapshot.gauges.isEmpty {
            text = " \u{2013}\u{2013}"
            color = .tertiaryLabelColor
        } else if let s = s, let w = w {
            text = String(format: " %.0f%% \u{00B7} %.0f%%", max(0, 100 - s), max(0, 100 - w))
            let worst = max(s, w)
            if worst >= 80 { color = Style.tint(forUsed: worst) }
        } else {
            text = " \u{2026}"
            color = .tertiaryLabelColor
        }

        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: color,
        ])
        button.toolTip = snapshot.error
            ?? "Claude usage remaining \u{2014} session \u{00B7} week"
    }
}

/// Renders `body` into a PNG at `scale`x under an explicit appearance. Shared by
/// the two debug renderers below so documentation shots need no visible screen.
func renderPNG(to out: URL, size: NSSize, scale: CGFloat, dark: Bool,
               _ body: (NSRect) -> Void) {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    appearance.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        body(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
    }
    try? rep.representation(using: .png, properties: [:])?.write(to: out)
}

// Debug: render the menu bar item to a PNG and exit.
if let i = CommandLine.arguments.firstIndex(of: "--icon"),
   CommandLine.arguments.count > i + 1 {
    let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let dark = CommandLine.arguments.contains("--dark")
    NSApplication.shared.setActivationPolicy(.prohibited)
    let sessionUsed = 78.0, weekUsed = 34.0
    renderPNG(to: out, size: NSSize(width: 104, height: 24), scale: 4, dark: dark) { rect in
        (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
        rect.fill()
        let icon = meterImage(sessionUsed: sessionUsed, weekUsed: weekUsed)
        let x: CGFloat = 12
        icon.draw(at: NSPoint(x: x, y: (rect.height - icon.size.height) / 2),
                  from: .zero, operation: .sourceOver, fraction: 1)
        let label = String(format: " %.0f%% \u{00B7} %.0f%%", 100 - sessionUsed, 100 - weekUsed)
        NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]).draw(at: NSPoint(x: x + icon.size.width, y: (rect.height - 14) / 2))
    }
    print("wrote \(out.path)")
    exit(0)
}

// Debug: render the dropdown panel to a PNG and exit.
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"),
   CommandLine.arguments.count > i + 1 {
    let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let dark = CommandLine.arguments.contains("--dark")
    NSApplication.shared.setActivationPolicy(.prohibited)
    var snap = Snapshot()
    if CommandLine.arguments.contains("--demo") {
        // Synthetic data for documentation shots: no network, no real numbers.
        snap.plan = "Max 5x"
        snap.fetchedAt = Date()
        snap.gauges = [
            Gauge(key: "session", label: "Session \u{00B7} 5 hours", percentUsed: 78,
                  resetsAt: Date().addingTimeInterval(77 * 60), isActive: true),
            Gauge(key: "weekly", label: "Week \u{00B7} all models", percentUsed: 34,
                  resetsAt: Date().addingTimeInterval(3.4 * 86400), isActive: false),
            Gauge(key: "weekly_opus", label: "Week \u{00B7} Opus", percentUsed: 56,
                  resetsAt: Date().addingTimeInterval(3.4 * 86400), isActive: false),
        ]
        if CommandLine.arguments.contains("--stale") {
            // Preview the rate-limited state: last good numbers + amber banner.
            snap.fetchedAt = Date().addingTimeInterval(-11 * 60)
            snap.stale = true
            snap.error = UsageFetcher.rateLimitMessage(until: Date().addingTimeInterval(4 * 60))
        }
    } else {
        let sema = DispatchSemaphore(value: 0)
        UsageFetcher.fetch { snap = $0; sema.signal() }
        _ = sema.wait(timeout: .now() + 20)
    }

    let view = PanelView()
    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    view.snapshot = snap
    view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
    renderPNG(to: out, size: view.bounds.size, scale: 2, dark: dark) { rect in
        (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
        rect.fill()
        view.draw(rect)
    }
    print("wrote \(out.path)  \(Int(view.bounds.width))x\(Int(view.bounds.height))")
    exit(0)
}

// One menu bar icon only: launch-at-login plus a manual open must not double up.
if let me = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: me)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty { exit(0) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
