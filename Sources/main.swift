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
    var note: String? = nil  // shown before the reset countdown
    var percentLeft: Double { max(0, 100 - percentUsed) }
}

/// One product's part of this week's usage, as reported by the usage API.
struct ProductShare {
    var name: String
    var percent: Double
}

/// One model's estimated part of this week's Claude Code usage.
struct ModelShare {
    var name: String
    var share: Double
}

/// Output of bin/claude-usage-models, which works this out from local logs.
struct ModelEstimate {
    var models: [ModelShare] = []
    var hosts: [String] = []
    var unreachable: [String] = []
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
    var products: [ProductShare] = []
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
        case .noCredentials:   return "Not connected to Claude yet \u{2013} open Setup from the menu"
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
    /// Cloudflare now answers `Retry-After: 0`, which is useless as a hint.
    /// Measured 2026-09-04: a 2-minute poll kept the block armed indefinitely;
    /// it cleared after 2.5-5 min of silence. So: honour a real Retry-After if
    /// it is larger, otherwise 5 → 10 → 15 min.
    private static func holdSeconds(advertised: Double, strike: Int) -> TimeInterval {
        let backoff = min(900, 300 * pow(2, Double(max(0, strike - 1))))
        return max(advertised + 3, backoff)
    }

    static func rateLimitMessage(until: Date) -> String {
        "Usage API rate limited \u{2013} next try \(Style.clock(until))"
    }

    /// Appends one line per network outcome to ~/Library/Logs/ClaudeUsage.log
    /// (kept under ~200 KB). No numbers or tokens, just status and timing.
    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClaudeUsage.log")
    private static let logFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    static func log(_ line: String) {
        let text = "\(logFormatter.string(from: Date())) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int, size > 200_000 {
            try? fm.removeItem(at: logURL)
        }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    /// Runs `security find-generic-password`, optionally pinned to one account.
    /// Shells out to /usr/bin/security on purpose: that binary already holds the
    /// ACL grant, so this never triggers a "wants to access" prompt of its own.
    private static func readItem(account: String?) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var args = ["find-generic-password", "-s", "Claude Code-credentials"]
        if let account = account { args += ["-a", account] }
        args.append("-w")
        proc.arguments = args
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    /// Reads the OAuth blob Claude Code stores in the login Keychain.
    private static func credentials() throws -> (token: String, expires: Date, tier: String, plan: String) {
        // Several items can share the service name "Claude Code-credentials"
        // (an `unknown` stub with empty tokens sits alongside the real one keyed
        // by the macOS short user name). An unpinned lookup returns whichever
        // comes first, so try the user's own item, then the unpinned lookup, and
        // take the first blob that actually carries a token.
        for account in [NSUserName(), nil] {
            guard let data = readItem(account: account),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = root["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String,
                  !token.isEmpty
            else { continue }

            let ms = (oauth["expiresAt"] as? Double) ?? 0
            return (token,
                    Date(timeIntervalSince1970: ms / 1000),
                    (oauth["rateLimitTier"] as? String) ?? "",
                    (oauth["subscriptionType"] as? String) ?? "")
        }
        throw UsageError.noCredentials
    }

    /// True when Claude Code has saved a login. Reads only the item's
    /// attributes (no -w), so it never asks for Keychain access.
    static func hasLogin() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
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

            if let error = error {
                log("transport error: \(error.localizedDescription)")
                s.error = error.localizedDescription; return completion(s)
            }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 429 {
                let header = http?.value(forHTTPHeaderField: "Retry-After") ?? ""
                let advertised = Double(header) ?? 0
                strikes += 1
                let secs = holdSeconds(advertised: advertised, strike: strikes)
                let until = Date().addingTimeInterval(secs)
                holdUntil = until
                log("429 retry-after=\(header.isEmpty ? "-" : header) strike=\(strikes) hold=\(Int(secs))s")
                s.error = rateLimitMessage(until: until)
                return completion(s)
            }
            guard (200..<300).contains(code) else {
                log("HTTP \(code)")
                s.error = UsageError.http(code).errorDescription
                return completion(s)
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { s.error = UsageError.badPayload.errorDescription; return completion(s) }

            s.gauges = parseGauges(json)
            s.products = parseProducts(json)
            s.extra = parseExtra(json)
            s.fetchedAt = Date()
            log("200 after \(strikes) strike(s)")
            strikes = 0
            if s.gauges.isEmpty { s.error = UsageError.badPayload.errorDescription }
            completion(s)
        }.resume()
    }

    private static func prettyPlan(plan: String, tier: String) -> String {
        // Max 20x is now sold as Ultra and Max 5x as Max, but tokens keep the old tier id.
        if tier.hasSuffix("max_20x") { return "Ultra" }
        return plan.isEmpty ? "" : plan.prefix(1).uppercased() + plan.dropFirst()
    }

    /// Prefers the newer `limits[]` array; falls back to the flat five_hour /
    /// seven_day objects if a future build drops it.
    private static func parseGauges(_ json: [String: Any]) -> [Gauge] {
        var out: [Gauge] = []

        if let limits = json["limits"] as? [[String: Any]] {
            // Fable's cap comes as a share of the week, in a list indexed by limit.
            var allowance: [Int: Double] = [:]
            for share in (json["weekly_scoped_shares"] as? [[String: Any]]) ?? [] {
                if let i = share["limit_index"] as? Int,
                   let a = share["allowance_percent_of_weekly"] as? Double { allowance[i] = a }
            }

            for (index, l) in limits.enumerated() {
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
                    var name = "scoped"
                    if let scope = l["scope"] as? [String: Any] {
                        if let m = scope["model"] as? [String: Any],
                           let d = m["display_name"] as? String, !d.isEmpty { name = d }
                        else if let sf = scope["surface"] as? [String: Any],
                                let d = sf["display_name"] as? String, !d.isEmpty { name = d }
                    }
                    out.append(Gauge(key: "weekly_" + name.lowercased(), label: "Week \u{00B7} " + name,
                                     percentUsed: pct, resetsAt: resets, isActive: active,
                                     note: allowance[index].map { String(format: "up to %.0f%% of week", $0) }))
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

    private static func parseProducts(_ json: [String: Any]) -> [ProductShare] {
        let breakdown = json["seven_day_breakdown"] as? [String: Any]
        let rows = (breakdown?["rows"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let name = row["display_name"] as? String,
                  let pct = row["percent"] as? Double, pct > 0 else { return nil }
            return ProductShare(name: name, percent: pct)
        }
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

    /// Mac health colour. The panel and menu bar apply it only when the level
    /// is not ok, so a healthy machine adds no colour at all.
    static func tint(forHealth level: HealthLevel) -> NSColor {
        switch level {
        case .ok:       return .systemGreen
        case .warn:     return .systemYellow
        case .critical: return .systemRed
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
// Per-model estimate
// ─────────────────────────────────────────────────────────────────────────────

enum ModelEstimator {
    /// Runs the bundled script. Calls back with nil if it fails, and never on the main queue.
    static func run(since: Date, completion: @escaping (ModelEstimate?) -> Void) {
        // /usr/bin/python3 is only a stub until the developer tools are
        // installed, and calling the stub pops an install dialog.
        guard hasPython, let script = Bundle.main.url(forResource: "claude-usage-models", withExtension: nil) else {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            let out = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [script.path, "--json", "--since", ISO8601DateFormatter().string(from: since)]
            proc.standardOutput = out
            proc.standardError = FileHandle.nullDevice
            proc.qualityOfService = .utility
            do { try proc.run() } catch {
                UsageFetcher.log("model estimate: could not start (\(error.localizedDescription))")
                completion(nil)
                return
            }
            let killer = DispatchWorkItem { proc.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            killer.cancel()
            let estimate = proc.terminationStatus == 0 ? parse(data) : nil
            if estimate == nil { UsageFetcher.log("model estimate: failed, exit \(proc.terminationStatus)") }
            completion(estimate)
        }
    }

    private static let hasPython: Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }()

    private static func parse(_ data: Data) -> ModelEstimate? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["models"] as? [[String: Any]] else { return nil }
        return ModelEstimate(
            models: rows.compactMap { row in
                guard let name = row["name"] as? String, let share = row["share"] as? Double else { return nil }
                return ModelShare(name: name, share: share)
            },
            hosts: (json["hosts"] as? [String]) ?? [],
            unreachable: (json["unreachable"] as? [String]) ?? [])
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Menu bar widget (redrawn 2026-11-09): a ring for the week with an inner ring
// for the 5-hour session, then small stacked columns, label over value:
// 5H 22% · WEEK 66%, and a RAM or DISK column only while the Mac is in trouble.
// The rings fill with what is LEFT, so a full green ring means plenty.
// ─────────────────────────────────────────────────────────────────────────────

struct BarReading {
    var sessionUsed: Double?
    var weekUsed: Double?
    var offline = false
    var mac: (label: String, value: String, level: HealthLevel)?
}

extension BarReading {
    /// The worst non-ok health detail as a short column, or nil when fine.
    static func macColumn(_ h: HealthAssessment?) -> (label: String, value: String, level: HealthLevel)? {
        guard let h = h, h.level != .ok,
              let top = h.details.filter({ $0.level != .ok }).max(by: { $0.level < $1.level }) else { return nil }
        let s = h.sample
        switch top.metric {
        case .memory: return ("RAM", s.memFreePct.map { "\($0)%" } ?? "!", top.level)
        case .disk:   return ("DISK", s.disk.map { "\($0.freeBytes / 1_000_000_000)G" } ?? "!", top.level)
        case .load:   return ("CPU", s.loadPerCore.map { String(format: "%.1f", $0) } ?? "!", top.level)
        default:      return ("MAC", "!", top.level)
        }
    }
}

func statusImage(_ r: BarReading) -> NSImage {
    let h: CGFloat = max(18, NSStatusBar.system.thickness - 2)
    let labelFont = NSFont.systemFont(ofSize: 7, weight: .heavy)
    let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)

    typealias Col = (label: String, value: String, tint: NSColor?)
    var cols: [Col] = []
    if r.offline {
        cols = [("CLAUDE", "\u{2013}\u{2013}", nil)]
    } else if let w = r.weekUsed {
        if let s = r.sessionUsed {
            cols.append(("5H", String(format: "%.0f%%", max(0, 100 - s)), s >= 80 ? Style.tint(forUsed: s) : nil))
        }
        cols.append(("WEEK", String(format: "%.0f%%", max(0, 100 - w)), w >= 80 ? Style.tint(forUsed: w) : nil))
    } else {
        cols = [("CLAUDE", "\u{2026}", nil)]
    }
    if let m = r.mac { cols.append((m.label, m.value, Style.tint(forHealth: m.level))) }

    func width(_ s: String, _ f: NSFont, kern: CGFloat = 0) -> CGFloat {
        ceil(NSAttributedString(string: s, attributes: [.font: f, .kern: kern]).size().width)
    }
    let widths = cols.map { max(width($0.label, labelFont, kern: 0.6), width($0.value, valueFont)) }
    let ring: CGFloat = 16, afterRing: CGFloat = 5, colGap: CGFloat = 7
    let total = ring + afterRing + widths.reduce(0, +) + colGap * CGFloat(max(0, cols.count - 1))

    let img = NSImage(size: NSSize(width: total, height: h), flipped: false) { _ in
        // Rings
        let c = NSPoint(x: ring / 2, y: h / 2)
        func arc(radius: CGFloat, line: CGFloat, used: Double?) {
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = line
            NSColor.labelColor.withAlphaComponent(0.2).setStroke()
            track.stroke()
            guard let used = used else { return }
            let left = min(100, max(0, 100 - used))
            guard left > 0 else { return }
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(left) / 100, clockwise: true)
            p.lineWidth = line
            p.lineCapStyle = .round
            Style.tint(forUsed: used).setStroke()
            p.stroke()
        }
        if r.sessionUsed != nil && !r.offline {
            arc(radius: 6.9, line: 2.2, used: r.weekUsed)
            arc(radius: 3.3, line: 2.2, used: r.sessionUsed)
        } else {
            arc(radius: 6.6, line: 2.8, used: r.offline ? nil : r.weekUsed)
        }

        // Columns: label on top, value below, both left-aligned.
        var x = ring + afterRing
        let valueY = (h - 20) / 2 - 1.5
        for (i, col) in cols.enumerated() {
            NSAttributedString(string: col.label, attributes: [
                .font: labelFont, .kern: 0.6,
                .foregroundColor: (col.tint ?? NSColor.labelColor).withAlphaComponent(col.tint == nil ? 0.55 : 0.9),
            ]).draw(at: NSPoint(x: x, y: valueY + 12.2))
            NSAttributedString(string: col.value, attributes: [
                .font: valueFont, .foregroundColor: col.tint ?? NSColor.labelColor,
            ]).draw(at: NSPoint(x: x, y: valueY))
            x += widths[i] + colGap
        }
        return true
    }
    img.isTemplate = false
    img.cacheMode = .never     // re-resolve label colours when the menu bar flips light/dark
    return img
}

// ─────────────────────────────────────────────────────────────────────────────
// Dropdown panel
// ─────────────────────────────────────────────────────────────────────────────

final class PanelView: NSView {
    static let width: CGFloat = 312
    private let pad: CGFloat = 14
    private let rowH: CGFloat = 47

    var snapshot = Snapshot() { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    // Mac health section: appears once the first sample is in.
    private let healthRowH: CGFloat = 36
    private let healthHeaderH: CGFloat = 30
    var healthState = HealthPanelState() { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; styleFreeButton() } }
    private var health: HealthAssessment? { healthState.assessment }

    // Two real buttons under the MAC rows (menu item views pass clicks to their
    // controls): Speed Up for memory and CPU, the daily one, tinted by those;
    // Disk for maintenance, tinted only by the disk.
    private let freeRowH: CGFloat = 42
    let freeButton = NSButton(title: "Speed Up Mac", target: nil, action: nil)
    var onFreeMemory: (() -> Void)?
    let diskButton = NSButton(title: "Disk Space", target: nil, action: nil)
    var onDisk: (() -> Void)?
    // Refresh lives in the footer, next to the time it changes.
    let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    var onRefresh: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        freeButton.bezelStyle = .rounded
        freeButton.controlSize = .large
        freeButton.font = .systemFont(ofSize: 13, weight: .semibold)
        freeButton.target = self
        freeButton.action = #selector(freeClicked)
        freeButton.isHidden = true
        freeButton.toolTip = "Clears leaked background processes now, then shows the sessions, jobs and apps holding memory."
        addSubview(freeButton)

        diskButton.bezelStyle = .rounded
        diskButton.controlSize = .large
        diskButton.font = .systemFont(ofSize: 13, weight: .regular)
        diskButton.target = self
        diskButton.action = #selector(diskClicked)
        diskButton.isHidden = true
        diskButton.toolTip = "Maintenance: clears caches that rebuild themselves. Worth it every few weeks."
        addSubview(diskButton)

        refreshButton.isBordered = false
        refreshButton.font = .systemFont(ofSize: 10.5, weight: .medium)
        refreshButton.contentTintColor = .secondaryLabelColor
        refreshButton.alignment = .right
        let rp = NSMutableParagraphStyle(); rp.alignment = .right
        refreshButton.attributedTitle = NSAttributedString(string: "Refresh", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: rp])
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        refreshButton.toolTip = "Ask Claude for fresh usage numbers (they also update every 5 minutes). \u{2318}R"
        addSubview(refreshButton)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The app icon from the bundle (nil for a bare debug binary).
    static let appIcon: NSImage? = Bundle.main.image(forResource: "AppIcon")

    @objc private func freeClicked() { onFreeMemory?() }
    @objc private func diskClicked() { onDisk?() }
    @objc private func refreshClicked() { onRefresh?() }

    private func styleFreeButton() {
        freeButton.isHidden = health == nil
        diskButton.isHidden = health == nil
        // Speed Up follows memory, load and the Claude stack; disk has its own button.
        // Quiet until the overall level (after hysteresis) moves off ok, like the rows.
        let speedReasons = health.map { h in h.level == .ok ? [] : h.details.filter { $0.metric != .disk && $0.level != .ok } } ?? []
        let lvl = speedReasons.map(\.level).max() ?? .ok
        // The red or orange MAC header right above already names the problem.
        freeButton.title = "Speed Up Mac"
        freeButton.bezelColor = lvl == .critical ? .systemRed : lvl == .warn ? .systemOrange : nil
        let disk = health?.level(for: .disk) ?? .ok
        diskButton.bezelColor = disk == .critical ? .systemRed : disk == .warn ? .systemOrange : nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // The row sits right above the footer, which is where the MAC section ends.
        let diskW: CGFloat = 92
        freeButton.frame = NSRect(x: pad, y: pad + 24 + 6, width: bounds.width - pad * 2 - diskW - 8, height: 32)
        diskButton.frame = NSRect(x: bounds.width - pad - diskW, y: pad + 24 + 6, width: diskW, height: 32)
        refreshButton.frame = NSRect(x: bounds.width - pad - 80, y: pad + 3, width: 80, height: 16)
    }

    // Rows under the gauges: where usage came from, and the split by model.
    private let productH: CGFloat = 18
    private let modelHeaderH: CGFloat = 26
    private let modelRowH: CGFloat = 30
    private let modelNoteH: CGFloat = 32
    var estimate: ModelEstimate? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var modelRows: [ModelShare] { estimate?.models ?? [] }

    private var rowCount: Int {
        var n = snapshot.gauges.count
        if let e = snapshot.extra, e.enabled { n += 1 }
        return n
    }

    private var healthRowCount: Int { health.map { healthRows($0).count } ?? 0 }

    // Cards: the Claude and Mac sections each sit on a soft rounded plate.
    private let headerH: CGFloat = 32
    private let inset: CGFloat = 10          // card edge to row text
    private let cardTop: CGFloat = 8
    private let cardTitleH: CGFloat = 20
    private let cardBottom: CGFloat = 6
    private let cardGap: CGFloat = 10

    private var claudeCardH: CGFloat {
        var h = cardTop + cardTitleH + CGFloat(rowCount) * rowH
        if !snapshot.products.isEmpty { h += productH }
        if !modelRows.isEmpty { h += modelHeaderH + CGFloat(modelRows.count) * modelRowH + modelNoteH }
        if rowCount == 0 && snapshot.error == nil { h += 30 }
        return h + cardBottom
    }
    private var macCardH: CGFloat { cardTop + cardTitleH + CGFloat(healthRowCount) * healthRowH + cardBottom }

    override var intrinsicContentSize: NSSize {
        var h = pad + headerH
        if snapshot.error != nil { h += 38 }
        h += claudeCardH
        if health != nil { h += cardGap + macCardH + freeRowH }
        h += 24 + pad                              // footer
        return NSSize(width: PanelView.width, height: h)
    }

    private func card(_ rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.07).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private func sectionTitle(_ title: String, symbol: String, right: String? = nil, rightColor: NSColor = .tertiaryLabelColor,
                              y: CGFloat, x: CGFloat, width: CGFloat) {
        var tx = x
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r); NSColor.secondaryLabelColor.set(); r.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: x, y: y + 4, width: img.size.width, height: img.size.height))
            tx += img.size.width + 5
        }
        draw(title, font: .systemFont(ofSize: 10, weight: .bold), color: .secondaryLabelColor, kern: 0.9,
             in: NSRect(x: tx, y: y + 3, width: width - (tx - x), height: 15))
        if let right = right {
            draw(right, font: .systemFont(ofSize: 10, weight: .semibold), color: rightColor, align: .right,
                 in: NSRect(x: x, y: y + 3, width: width, height: 15))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let W = bounds.width
        var y = bounds.height - pad

        // Header: icon, name, plan pill.
        y -= 24
        var nameX = pad
        if let icon = PanelView.appIcon {
            icon.draw(in: NSRect(x: pad - 2, y: y - 1, width: 26, height: 26))
            nameX += 28
        }
        draw("Headroom", font: .systemFont(ofSize: 15, weight: .bold), color: .labelColor,
             in: NSRect(x: nameX, y: y + 2, width: 140, height: 20))
        if !snapshot.plan.isEmpty {
            let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            let tw = ceil(NSAttributedString(string: snapshot.plan, attributes: [.font: font]).size().width)
            let pill = NSRect(x: W - pad - tw - 16, y: y + 3, width: tw + 16, height: 18)
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
            draw(snapshot.plan, font: font, color: .controlAccentColor, align: .center,
                 in: NSRect(x: pill.minX, y: pill.minY + 2, width: pill.width, height: 14))
        }
        y -= headerH - 24

        // Error banner
        if let err = snapshot.error {
            y -= 34
            let box = NSRect(x: pad, y: y, width: W - pad * 2, height: 30)
            // Red means "no numbers"; amber means "numbers shown, but stale".
            let tint: NSColor = snapshot.stale ? .systemOrange : .systemRed
            tint.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            draw(err, font: .systemFont(ofSize: 11), color: tint, lines: 2,
                 in: box.insetBy(dx: 9, dy: 5))
            y -= 4
        }

        // Claude card
        let cx = pad + inset, cw = W - pad * 2 - inset * 2
        card(NSRect(x: pad, y: y - claudeCardH, width: W - pad * 2, height: claudeCardH))
        y -= cardTop + cardTitleH
        sectionTitle("CLAUDE", symbol: "sparkle", y: y, x: cx, width: cw)

        for g in snapshot.gauges {
            y -= rowH
            drawGaugeRow(g, in: NSRect(x: cx, y: y, width: cw, height: rowH))
        }

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
                         in: NSRect(x: cx, y: y, width: cw, height: rowH))
        }

        if rowCount == 0 && snapshot.error == nil {
            y -= 30
            draw("Fetching\u{2026}", font: .systemFont(ofSize: 12), color: .secondaryLabelColor,
                 in: NSRect(x: cx, y: y, width: cw, height: 20))
        }

        if !snapshot.products.isEmpty {
            y -= productH
            let text = snapshot.products
                .map { String(format: "%@ %.0f%%", $0.name, $0.percent) }
                .joined(separator: " \u{00B7} ")
            draw("This week: " + text, font: .systemFont(ofSize: 10.5), color: .secondaryLabelColor,
                 in: NSRect(x: cx + 12, y: y + 3, width: cw - 12, height: 14))
        }

        if !modelRows.isEmpty, let e = estimate {
            y -= modelHeaderH
            draw("WEEK BY MODEL", font: .systemFont(ofSize: 9.5, weight: .semibold),
                 color: .tertiaryLabelColor, kern: 0.9,
                 in: NSRect(x: cx + 12, y: y + 4, width: cw - 12, height: 15))
            draw("estimate", font: .systemFont(ofSize: 9.5, weight: .semibold),
                 color: .tertiaryLabelColor, align: .right,
                 in: NSRect(x: cx, y: y + 4, width: cw, height: 15))
            for m in modelRows {
                y -= modelRowH
                drawModelRow(m, in: NSRect(x: cx, y: y, width: cw, height: modelRowH))
            }
            y -= modelNoteH
            var note = "Share of Claude Code tokens, weighted by API price. From "
                + e.hosts.joined(separator: " + ") + "."
            if !e.unreachable.isEmpty { note += " " + e.unreachable.joined(separator: ", ") + " not reachable." }
            draw(note, font: .systemFont(ofSize: 10), color: .tertiaryLabelColor, lines: 2,
                 in: NSRect(x: cx + 12, y: y + 2, width: cw - 12, height: 28))
        }
        y -= cardBottom

        // Mac card
        if let h = health {
            y -= cardGap
            card(NSRect(x: pad, y: y - macCardH, width: W - pad * 2, height: macCardH))
            y -= cardTop + cardTitleH
            sectionTitle("MAC", symbol: "laptopcomputer",
                         right: h.level != .ok ? h.reasons.first : "running smoothly",
                         rightColor: h.level != .ok ? Style.tint(forHealth: h.level) : .tertiaryLabelColor,
                         y: y, x: cx, width: cw)
            for row in healthRows(h) {
                y -= healthRowH
                drawKeyValueRow(row, in: NSRect(x: cx, y: y, width: cw, height: healthRowH))
            }
            y -= cardBottom
            y -= freeRowH          // the Speed Up and Disk buttons (subviews, see layout())
        }

        // Footer
        y -= 20
        var stamp = snapshot.fetchedAt == nil ? "not yet updated"
                                              : "updated \(Style.clock(snapshot.fetchedAt))"
        if snapshot.stale { stamp += " \u{00B7} last known good" }
        draw(stamp, font: .systemFont(ofSize: 10), color: .tertiaryLabelColor,
             in: NSRect(x: pad, y: y, width: W - pad * 2, height: 14))
    }

    private func drawGaugeRow(_ g: Gauge, in rect: NSRect) {
        drawMeterRow(title: g.label,
                     value: String(format: "%.0f%% left", g.percentLeft),
                     sub: (g.note.map { $0 + " \u{00B7} " } ?? "") + Style.countdown(to: g.resetsAt),
                     percentUsed: g.percentUsed,
                     tint: Style.tint(forUsed: g.percentUsed),
                     active: g.isActive,
                     in: rect)
    }

    private func drawModelRow(_ m: ModelShare, in rect: NSRect) {
        let gutter: CGFloat = 12
        let top = NSRect(x: rect.minX + gutter, y: rect.maxY - 17, width: rect.width - gutter, height: 15)
        draw(m.name, font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor, in: top)
        draw(m.share < 1 ? "<1%" : String(format: "%.0f%%", m.share),
             font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
             color: .secondaryLabelColor, align: .right, in: top)

        let h: CGFloat = 4
        let track = NSRect(x: rect.minX + gutter, y: rect.maxY - 25, width: rect.width - gutter, height: h)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
        let fw = max(h, track.width * CGFloat(min(100, max(0, m.share))) / 100)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: fw, height: h),
                     xRadius: h / 2, yRadius: h / 2).fill()
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

    // MARK: Mac health rows

    private struct KeyValueRow {
        var title: String
        var value: String
        var sub: String
        var level: HealthLevel = .ok       // colours the value and lights the dot when not ok
    }

    private func healthRows(_ h: HealthAssessment) -> [KeyValueRow] {
        let s = h.sample
        let st = healthState
        // Quiet when the machine is fine: per-row colour only once the overall
        // level (after hysteresis) has moved off ok.
        func lvl(_ m: HealthMetric) -> HealthLevel { h.level == .ok ? .ok : h.level(for: m) }

        // A reading the sensor could not take is shown as exactly that.
        var memSub: [String] = []
        if let k = s.kernelPressure { memSub.append("kernel: \(k)") }   // first: it must never truncate
        if let swap = s.swap {
            memSub.append(swap.totalBytes > 0
                          ? "swap \(Style.gb(swap.usedBytes)) of \(Style.gb(swap.totalBytes)) GB" : "no swap")
        } else {
            memSub.append("swap n/a")
        }
        if let vm = s.vm { memSub.append("compressed \(Style.bytes(vm.compressedBytes))") }
        let memory = KeyValueRow(
            title: "Memory",
            value: s.memFreePct.map { "\($0)% free" } ?? "unavailable",
            sub: memSub.joined(separator: " \u{00B7} "),
            level: lvl(.memory))

        let load: KeyValueRow
        if let l = s.load, let perCore = s.loadPerCore {
            load = KeyValueRow(
                title: "Load",
                value: String(format: "%.1f per core", perCore),
                sub: String(format: "1m %.1f \u{00B7} 5m %.1f \u{00B7} 15m %.1f \u{00B7} %d cores",
                            l.load1, l.load5, l.load15, s.ncpu),
                level: lvl(.load))
        } else {
            load = KeyValueRow(title: "Load", value: "unavailable", sub: "getloadavg failed", level: lvl(.load))
        }

        // Disk always carries its colour: low space is worth seeing even when
        // nothing else is wrong yet.
        var disk: KeyValueRow?
        if let d = s.disk {
            let usedPct = d.totalBytes > 0 ? Int((d.totalBytes - d.freeBytes) * 100 / d.totalBytes) : 0
            disk = KeyValueRow(
                title: "Disk",
                value: "\(Style.bytes(d.freeBytes)) free",
                sub: "\(usedPct)% used of \(Style.bytes(d.totalBytes))"
                    + (h.level(for: .disk) == .ok ? "" : " \u{00B7} Disk Space clears caches"),
                level: h.level(for: .disk))
        }

        let n = s.claude.interactiveSessions.count, m = s.claude.summarizers.count
        var claudeSub = "\(Style.bytes(s.claude.totalRSS)) resident"
        if let oldest = s.claude.oldestSession {
            claudeSub += " \u{00B7} oldest session \(Style.duration(oldest.age))"
        }
        let claude = KeyValueRow(
            title: "Claude",
            value: "\(n) session\(n == 1 ? "" : "s") \u{00B7} \(m) summarizer\(m == 1 ? "" : "s")",
            sub: claudeSub,
            level: lvl(.claude))

        // "Last action" says only what is true: leaks it is not allowed to
        // touch, an inspection it could not complete, what it terminated in
        // this session, or a clean check.
        let checked = "checked \(Style.clock(st.lastCheck ?? s.sampledAt))"
        let k = st.suspected.count
        let action: KeyValueRow
        if k > 0 && !st.autoReap {
            action = KeyValueRow(title: "Last action", value: "auto-reap off",
                                 sub: "\(k) suspected leak\(k == 1 ? "" : "s") \u{00B7} \(checked)", level: .warn)
        } else if s.memFreePct == nil {
            action = KeyValueRow(title: "Last action", value: "inspection incomplete",
                                 sub: "memory metric unavailable \u{00B7} \(checked)", level: .warn)
        } else if let r = st.sessionReap, r.terminated > 0 {
            action = KeyValueRow(title: "Last action", value: "\(r.terminated) terminated",
                                 sub: "\(Style.bytes(r.bytesResident)) was resident \u{00B7} \(Style.dayClock(r.at))")
        } else if k == 0 {
            action = KeyValueRow(title: "Last action", value: "no leaks found", sub: checked)
        } else {
            action = KeyValueRow(title: "Last action", value: "\(k) suspected leak\(k == 1 ? "" : "s")",
                                 sub: checked)
        }
        return [memory, load] + (disk.map { [$0] } ?? []) + [claude, action]
    }

    /// Two-column row without a meter: title left, value right, sub below.
    /// Same fonts, gutter and dot as `drawMeterRow`; the dot lights only on trouble.
    private func drawKeyValueRow(_ row: KeyValueRow, in rect: NSRect) {
        let top = NSRect(x: rect.minX, y: rect.maxY - 17, width: rect.width, height: 15)
        let gutter: CGFloat = 12
        let tint: NSColor? = row.level == .ok ? nil : Style.tint(forHealth: row.level)
        if let tint = tint {
            let d: CGFloat = 6
            tint.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX, y: top.maxY - 8 - d / 2,
                                        width: d, height: d)).fill()
        }
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let titleW = ceil(NSAttributedString(string: row.title, attributes: [.font: titleFont]).size().width)
        draw(row.title, font: titleFont, color: .labelColor,
             in: NSRect(x: rect.minX + gutter, y: top.minY, width: titleW + 2, height: top.height))
        let valueX = rect.minX + gutter + titleW + 10
        draw(row.value, font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
             color: tint ?? .labelColor, align: .right,
             in: NSRect(x: valueX, y: top.minY, width: rect.maxX - valueX, height: top.height))
        draw(row.sub, font: .systemFont(ofSize: 10.5), color: .tertiaryLabelColor,
             in: NSRect(x: rect.minX + gutter, y: rect.maxY - 33,
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

    /// The widget is also the leak reaper, so it must not stay down. launchd
    /// relaunches it after a crash, a signal or a jetsam kill (any unsuccessful
    /// exit), 30 s apart at most; Quit exits 0 and stays quit. On 2026-11-06 it
    /// was down for 1h40 and 56 summarizers piled up meanwhile.
    static func plist(executable exe: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 30,
            "ProcessType": "Interactive",
        ]
    }

    /// Plists written before auto-restart existed lack KeepAlive: rewrite them
    /// in place. launchd picks the change up at the next login or bootstrap
    /// (build.sh does one), never by killing the running copy.
    static func upgradeIfNeeded() {
        guard isEnabled,
              let data = try? Data(contentsOf: plistURL),
              let old = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let oldExe = (old["ProgramArguments"] as? [String])?.first
        else { return }
        // Also follow a rename (Claude Usage.app became Headroom.app on 2026-11-09).
        let current = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.executableURL?.path : nil
        let exe = current ?? oldExe
        guard old["KeepAlive"] == nil || exe != oldExe,
              let out = try? PropertyListSerialization.data(fromPropertyList: plist(executable: exe),
                                                            format: .xml, options: 0)
        else { return }
        try? out.write(to: plistURL)
    }

    static func setEnabled(_ on: Bool) {
        let fm = FileManager.default
        if on {
            let exe = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
            let plist = plist(executable: exe)
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
    private var autoReapToggle: NSMenuItem!
    private var warnToggle: NSMenuItem!
    private var wakeObserver: NSObjectProtocol?

    // Mac health: its own poll timer (health.pollSeconds, default 30 s), the
    // memory-pressure dispatch source and the reap policy live in the monitor.
    private let healthMonitor = HealthMonitor()
    private var healthState = HealthPanelState()
    private var health: HealthAssessment? { healthState.assessment }

    func applicationDidFinishLaunching(_ note: Notification) {
        LoginItem.upgradeIfNeeded()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        render()

        buildMenu()
        statusItem.menu = menu
        panel.onFreeMemory = { [weak self] in self?.freeMemory() }
        panel.onDisk = { [weak self] in self?.openDisk() }
        // A click on a warning notification opens the window it names.
        HealthNotifier.onOpen = { [weak self] target in
            target == "disk" ? self?.openDisk() : self?.freeMemory()
        }
        panel.onRefresh = { [weak self] in self?.refresh(force: true) }
        // Debug: open Clean Up at launch (for screenshots of the live window).
        if CommandLine.arguments.contains("--relief-window") {
            if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            let disk = CommandLine.arguments.contains("--disk")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                disk ? self?.openDisk() : self?.freeMemory()
            }
        }

        // Health first: it must never wait behind a slow Keychain call.
        healthMonitor.onUpdate = { [weak self] state in
            guard let self = self else { return }
            self.healthState = state
            self.panel.healthState = state
            self.panel.frame = NSRect(origin: .zero, size: self.panel.intrinsicContentSize)
            self.render()
        }
        healthMonitor.start()

        // The setup page made a fresh usage call: show it now, not in 5 minutes.
        NotificationCenter.default.addObserver(forName: Setup.connected, object: nil, queue: .main) { [weak self] note in
            guard let snap = note.object as? Snapshot else { return }
            self?.lastFetchStarted = Date()
            self?.apply(snap)
        }
        // First launch (from the DMG): the setup window. Debug: --setup-window N.
        if let i = CommandLine.arguments.firstIndex(of: "--setup-window") {
            let page = CommandLine.arguments.count > i + 1 ? Int(CommandLine.arguments[i + 1]) ?? 0 : 0
            if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Setup.open(page: page) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Setup.showIfNeeded {} }
        }

        refresh()
        // 5 min: the endpoint's limiter is shared with Claude Code's own calls,
        // and a 2-minute cadence was measured to keep it armed once tripped.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 10

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh(); self?.healthMonitor.poll() }
    }

    func applicationWillTerminate(_ note: Notification) {
        if let token = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        wakeObserver = nil
        healthMonitor.stop()
    }

    private func buildMenu() {
        menu = NSMenu()
        menu.delegate = self

        let panelItem = NSMenuItem()
        panel.frame = NSRect(origin: .zero, size: panel.intrinsicContentSize)
        panelItem.view = panel
        menu.addItem(panelItem)
        menu.addItem(.separator())

        let speedItem = NSMenuItem(title: "Speed Up Mac\u{2026}", action: #selector(freeMemory), keyEquivalent: "u")
        speedItem.target = self
        speedItem.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil)
        speedItem.toolTip = "For a slow Mac: clears leaked processes now, then shows the sessions, jobs and apps holding memory."
        menu.addItem(speedItem)

        let diskItem = NSMenuItem(title: "Free Up Disk Space\u{2026}", action: #selector(openDisk), keyEquivalent: "d")
        diskItem.target = self
        diskItem.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)
        diskItem.toolTip = "Maintenance: clears caches that rebuild themselves. Worth it every few weeks."
        menu.addItem(diskItem)
        menu.addItem(.separator())

        // ⌘R still works while the menu is open; the visible control is the
        // Refresh button in the panel footer.
        let refreshItem = NSMenuItem(title: "Refresh Usage", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isHidden = true
        refreshItem.allowsKeyEquivalentWhenHidden = true
        menu.addItem(refreshItem)

        warnToggle = NSMenuItem(title: "Warn Before It Slows Down", action: #selector(toggleWarn), keyEquivalent: "")
        warnToggle.target = self
        warnToggle.toolTip = "Watches how fast memory falls and swap grows, and sends a notification a few minutes before the Mac starts to stutter."
        menu.addItem(warnToggle)

        autoReapToggle = NSMenuItem(title: "Clear Leaks Automatically", action: #selector(toggleAutoReap),
                                    keyEquivalent: "")
        autoReapToggle.target = self
        autoReapToggle.toolTip = "Every 30 seconds, closes leaked claude-mem summarizers and stray headless Chrome. Never touches your sessions or apps."
        menu.addItem(autoReapToggle)

        loginToggle = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin),
                                 keyEquivalent: "")
        loginToggle.target = self
        menu.addItem(loginToggle)

        menu.addItem(.separator())
        let setupItem = NSMenuItem(title: "Setup & About\u{2026}", action: #selector(openSetup), keyEquivalent: ",")
        setupItem.target = self
        setupItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(setupItem)
        let credit = NSMenuItem(title: "Headroom \(Setup.version) \u{00B7} made by \(Setup.author)", action: nil, keyEquivalent: "")
        credit.isEnabled = false
        menu.addItem(credit)
        let quit = NSMenuItem(title: "Quit Headroom", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginToggle.state = LoginItem.isEnabled ? .on : .off
        autoReapToggle.state = HealthPrefs.autoReap ? .on : .off
        warnToggle.state = HealthPrefs.earlyWarning ? .on : .off
        panel.frame = NSRect(origin: .zero, size: panel.intrinsicContentSize)
        panel.needsDisplay = true
        refresh()
        healthMonitor.poll()
    }

    private var lastFetchStarted = Date.distantPast
    private var lastEstimateStarted = Date.distantPast

    @objc private func refreshNow() { refresh(force: true) }

    /// One click: clears the leaks at once, then opens Speed Up Mac, which
    /// lists what else holds memory and measures again after each close.
    @objc private func freeMemory() {
        menu.cancelTracking()
        let low = (health?.level(for: .memory) ?? .ok) != .ok
        // Let the menu finish closing before a window takes focus.
        DispatchQueue.main.async { [weak self] in
            Relief.open(.speed, lowMemory: low) { self?.healthMonitor.poll() }
        }
    }

    /// Maintenance: the rebuildable caches, disk before and now.
    @objc private func openDisk() {
        menu.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            Relief.open(.disk) { self?.healthMonitor.poll() }
        }
    }

    @objc private func toggleWarn() {
        HealthPrefs.earlyWarning.toggle()
        warnToggle.state = HealthPrefs.earlyWarning ? .on : .off
    }

    @objc private func toggleAutoReap() {
        HealthPrefs.autoReap.toggle()
        autoReapToggle.state = HealthPrefs.autoReap ? .on : .off
    }

    @objc private func toggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        loginToggle.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSetup() {
        menu.cancelTracking()
        DispatchQueue.main.async { Setup.open(page: 0) }
    }

    private func refresh(force: Bool = false) {
        // The usage endpoint 429s under rapid polling; menu opens are throttled.
        // ⌘R still forces a fetch, but a backoff hold blocks even that.
        if !force && Date().timeIntervalSince(lastFetchStarted) < 120 { return }
        lastFetchStarted = Date()

        UsageFetcher.fetch { [weak self] snap in
            DispatchQueue.main.async { self?.apply(snap) }
        }
    }

    private func apply(_ fresh: Snapshot) {
        var snap = fresh
        // Keep the last good reading visible through a transient failure.
        if snap.error != nil, snap.gauges.isEmpty, !self.snapshot.gauges.isEmpty {
            snap.gauges = self.snapshot.gauges
            snap.products = self.snapshot.products
            snap.extra = self.snapshot.extra
            snap.fetchedAt = self.snapshot.fetchedAt
            snap.stale = true
        }
        self.snapshot = snap
        self.panel.snapshot = snap
        self.panel.frame = NSRect(origin: .zero, size: self.panel.intrinsicContentSize)
        self.render()
        self.refreshEstimate()
    }

    /// The week starts seven days before it resets. Reading the logs costs no API
    /// call, but it does wake every listed Mac, so every 15 minutes is plenty.
    private func refreshEstimate() {
        guard let resets = snapshot.weekly?.resetsAt,
              Date().timeIntervalSince(lastEstimateStarted) >= 900 else { return }
        lastEstimateStarted = Date()
        ModelEstimator.run(since: resets.addingTimeInterval(-7 * 86400)) { [weak self] estimate in
            guard let estimate = estimate else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.panel.estimate = estimate
                self.panel.frame = NSRect(origin: .zero, size: self.panel.intrinsicContentSize)
            }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let s = snapshot.session?.percentUsed
        let w = snapshot.weekly?.percentUsed
        let offline = snapshot.error != nil && snapshot.gauges.isEmpty
        button.image = statusImage(BarReading(sessionUsed: s, weekUsed: w, offline: offline,
                                              mac: BarReading.macColumn(health)))
        button.title = ""
        button.imagePosition = .imageOnly

        var tip = snapshot.error ?? (s == nil
            ? String(format: "Claude left this week: %.0f%%", max(0, 100 - (w ?? 100)))
            : String(format: "Claude left: %.0f%% of the session, %.0f%% of the week", max(0, 100 - s!), max(0, 100 - (w ?? 100))))
        if let h = health, h.level != .ok, let top = h.reasons.first { tip += "\nMac: \(top)" }
        button.toolTip = tip
        button.setAccessibilityLabel("Headroom. " + tip)
    }
}

/// "● " tinted yellow or red; `text` already starts with a space.
func healthDot(_ level: HealthLevel) -> NSAttributedString {
    NSAttributedString(string: "\u{25CF}", attributes: [
        .font: NSFont.systemFont(ofSize: 9, weight: .bold),
        .foregroundColor: Style.tint(forHealth: level),
        .baselineOffset: 1,
    ])
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

// Debug: the KERN_PROCARGS2 parser and fingerprint scanners against fixtures.
if CommandLine.arguments.contains("--argv-selftest") {
    exit(HealthDebug.argvSelfTest() == 0 ? 0 : 1)
}

// Debug: one Mac health sample + assessment as JSON, timing on stderr, exit.
// Assessed twice, the first copy backdated past the promotion age, so the
// printed level is the steady state rather than the hysteresis floor.
if CommandLine.arguments.contains("--health-json") {
    let sample = HealthSensor.sample()
    var earlier = sample
    earlier.sampledAt = sample.sampledAt.addingTimeInterval(-HealthScorer.promotionAge)
    _ = HealthScorer.assess(earlier)
    let assessment = HealthScorer.assess(sample)
    print(HealthDebug.json(assessment))
    FileHandle.standardError.write(String(format: "sample took %.1f ms\n", sample.sampleMillis).data(using: .utf8)!)
    exit(0)
}

// Debug: list what a reap would kill right now, and exit without killing.
if CommandLine.arguments.contains("--reap-dry-run") {
    let sample = HealthSensor.sample()
    print(HealthDebug.dryRun(sample))
    FileHandle.standardError.write(String(format: "sample took %.1f ms\n", sample.sampleMillis).data(using: .utf8)!)
    exit(0)
}

// Debug: what Clean Up would list right now, no action.
if CommandLine.arguments.contains("--relief-dry-run") {
    print(Relief.dryRun())
    exit(0)
}

// Debug: render the Clean Up window with synthetic rows to a PNG (light only).
if let i = CommandLine.arguments.firstIndex(of: "--relief-snapshot"),
   CommandLine.arguments.count > i + 1 {
    NSApplication.shared.setActivationPolicy(.prohibited)
    ReliefWindow.snapshot(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]),
                          mode: CommandLine.arguments.contains("--disk") ? .disk : .speed)
    exit(0)
}

// Debug: post one test notification through the same path the reaper uses.
if CommandLine.arguments.contains("--notify-test") {
    NSApplication.shared.setActivationPolicy(.prohibited)
    HealthNotifier.requestAuthorization()
    HealthNotifier.post(title: "Headroom reaped leaks", body: "37 summarizers terminated \u{00B7} 2.1 GB was resident (test)") {
        print($0)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    exit(0)
}

// Debug: render the menu bar item to a PNG and exit.
if let i = CommandLine.arguments.firstIndex(of: "--mascot"),
   CommandLine.arguments.count > i + 1 {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let mood: Mascot.Mood = CommandLine.arguments.contains("--sluggish") ? .sluggish : .fast
    renderPNG(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]), size: Mascot.canvas, scale: 2, dark: false) { r in
        Mascot.draw(mood, in: r)
    }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--icon"),
   CommandLine.arguments.count > i + 1 {
    let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let dark = CommandLine.arguments.contains("--dark")
    NSApplication.shared.setActivationPolicy(.prohibited)
    let sessionUsed: Double? = CommandLine.arguments.contains("--session") ? 78 : nil
    var mac: (label: String, value: String, level: HealthLevel)?
    if let h = CommandLine.arguments.firstIndex(of: "--health"), CommandLine.arguments.count > h + 1 {
        mac = CommandLine.arguments[h + 1] == "critical" ? ("RAM", "9%", .critical) : ("RAM", "24%", .warn)
    }
    let img = statusImage(BarReading(sessionUsed: sessionUsed, weekUsed: 34, mac: mac))
    let size = NSSize(width: img.size.width + 24, height: 24)
    renderPNG(to: out, size: size, scale: 4, dark: dark) { rect in
        (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
        rect.fill()
        img.draw(at: NSPoint(x: 12, y: (rect.height - img.size.height) / 2),
                 from: .zero, operation: .sourceOver, fraction: 1)
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
        snap.plan = "Ultra"
        snap.fetchedAt = Date()
        snap.gauges = [
            Gauge(key: "weekly", label: "Week \u{00B7} all models", percentUsed: 34,
                  resetsAt: Date().addingTimeInterval(3.4 * 86400), isActive: true),
            Gauge(key: "weekly_fable", label: "Week \u{00B7} Fable", percentUsed: 12,
                  resetsAt: Date().addingTimeInterval(3.4 * 86400), isActive: false,
                  note: "up to 50% of week"),
        ]
        if CommandLine.arguments.contains("--session") {
            snap.gauges.insert(Gauge(key: "session", label: "Session \u{00B7} 5 hours", percentUsed: 78,
                                     resetsAt: Date().addingTimeInterval(77 * 60), isActive: true), at: 0)
        }
        snap.products = [ProductShare(name: "Claude Code", percent: 92), ProductShare(name: "Chats", percent: 8)]
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
    if CommandLine.arguments.contains("--demo") {
        view.estimate = ModelEstimate(
            models: [ModelShare(name: "Opus 5.5", share: 71), ModelShare(name: "Fable 5.1", share: 18),
                     ModelShare(name: "Sonnet 5.5", share: 10), ModelShare(name: "Haiku 5.5", share: 0.6)],
            hosts: ["This Mac", "Mini"], unreachable: [])
    } else if let resets = snap.weekly?.resetsAt {
        let sema = DispatchSemaphore(value: 0)
        ModelEstimator.run(since: resets.addingTimeInterval(-7 * 86400)) { view.estimate = $0; sema.signal() }
        _ = sema.wait(timeout: .now() + 70)
    }
    if CommandLine.arguments.contains("--demo") {
        // A Mac under pressure, so the section shows its colour in the shot.
        let now = Date()
        func proc(_ pid: pid_t, age: TimeInterval, mb: UInt64, _ args: [String]) -> ProcInfo {
            let start = now.addingTimeInterval(-age)
            return ProcInfo(pid: pid, ppid: 1, rss: mb << 20,
                            startSec: Int64(start.timeIntervalSince1970), startUsec: 0, started: start,
                            path: "/Users/me/.local/share/claude/versions/2.1.277", args: args)
        }
        var stack = ClaudeStack()
        stack.interactiveSessions = (0..<5).map { proc(2000 + pid_t($0), age: 3.05 * 86400 - Double($0) * 40000, mb: 300, ["claude"]) }
        stack.summarizers = (0..<37).map { proc(9000 + pid_t($0), age: 3 * 3600, mb: 58, ["claude", "--output-format", "stream-json"]) }
        stack.totalRSS = (stack.interactiveSessions + stack.summarizers).reduce(0) { $0 + $1.rss }
        let sample = HealthSample(
            memFreePct: 11, memSource: "kern.memorystatus_level",
            vm: VMStats(freeBytes: 380 << 20, compressedBytes: 3_300 << 20, wiredBytes: 3_600 << 20, inactiveBytes: 900 << 20),
            swap: SwapStats(usedBytes: 4_500 << 20, totalBytes: 9_200 << 20),
            load: LoadStats(load1: 62.9, load5: 32.8, load15: 4.5), ncpu: 14,
            kernelPressure: "critical", sampledAt: now, claude: stack, sampleMillis: 12,
            validity: Validity(memory: true, vm: true, swap: true, load: true, disk: true),
            disk: DiskStats(freeBytes: 14 << 30, totalBytes: 926 << 30))
        var earlier = sample
        earlier.sampledAt = now.addingTimeInterval(-HealthScorer.promotionAge)
        _ = HealthScorer.assess(earlier)
        var reap = ReapResult()
        reap.summarizersKilled = 37; reap.signalled = 37; reap.bytesResident = 2_150 << 20
        reap.at = now.addingTimeInterval(-8 * 60)
        view.healthState = HealthPanelState(assessment: HealthScorer.assess(sample), suspected: [],
                                            autoReap: true, sessionReap: reap, lastCheck: now)
    } else {
        let sample = HealthSensor.sample()
        var earlier = sample
        earlier.sampledAt = sample.sampledAt.addingTimeInterval(-HealthScorer.promotionAge)
        _ = HealthScorer.assess(earlier)
        let assessment = HealthScorer.assess(sample)
        view.healthState = HealthPanelState(
            assessment: assessment,
            suspected: HealthAction.targets(in: sample, emergency: assessment.emergency).all,
            autoReap: HealthPrefs.autoReap, sessionReap: nil, lastCheck: sample.sampledAt)
    }
    view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
    renderPNG(to: out, size: view.bounds.size, scale: 2, dark: dark) { rect in
        (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
        rect.fill()
        view.draw(rect)
        // The buttons are subviews; draw() alone leaves them out.
        view.layout()
        // Offscreen caching paints controls on an opaque white plate, so draw
        // look-alikes: a filled capsule for the bezel buttons, text for Refresh.
        for btn in [view.freeButton, view.diskButton] where !btn.isHidden {
            let f = btn.frame.insetBy(dx: 0, dy: 2)
            (btn.bezelColor ?? NSColor.labelColor.withAlphaComponent(0.12)).setFill()
            NSBezierPath(roundedRect: f, xRadius: f.height / 2, yRadius: f.height / 2).fill()
            let p = NSMutableParagraphStyle(); p.alignment = .center
            NSAttributedString(string: btn.title, attributes: [
                .font: btn.font ?? .systemFont(ofSize: 13), .paragraphStyle: p,
                .foregroundColor: btn.bezelColor == nil ? NSColor.labelColor : NSColor.white,
            ]).draw(in: NSRect(x: f.minX, y: f.midY - 9, width: f.width, height: 18))
        }
        view.refreshButton.attributedTitle.draw(in: view.refreshButton.frame)
    }
    print("wrote \(out.path)  \(Int(view.bounds.width))x\(Int(view.bounds.height))")
    exit(0)
}

// One menu bar icon only: launch-at-login plus a manual open must not double up.
if let me = Bundle.main.bundleIdentifier, !CommandLine.arguments.contains("--setup-window") {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: me)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty { exit(0) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
