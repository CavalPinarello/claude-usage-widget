import Cocoa

// ─────────────────────────────────────────────────────────────────────────────
// Free Up Memory (added 2026-11-09)
//
// One click from the panel. On 2026-11-09, six minutes after a reboot, the
// claude-mem worker started 25 summarizers inside one minute (about 12 GB
// footprint, swap 11 of 12 GB, load 140). The reaper left them alone because
// they were minutes old. Clearing them took memory free from 30% to 75%.
//
// The click does two things:
//   1. At once, with no further question: the leaks the reaper already owns
//      (claude-mem summarizers, orphaned headless Chrome). While memory is low
//      the summarizer age limit drops to zero, because the click is the consent.
//   2. Opens a window that measures what else holds memory (Claude sessions,
//      booted simulators, apps, big background processes) by physical
//      footprint, the number Activity Monitor calls "Memory". Each row has its
//      own button; nothing there runs without a click on that row (or on
//      "Close suggested", which covers only rows marked suggested).
// After every action the window waits for memory to settle, samples again and
// shows before and now side by side. Recheck samples on demand.
//
// Safety: a process is signalled only if its pid and start time (sec + usec)
// still match the scan. Apps get NSRunningApplication.terminate(), so they can
// ask to save. A second click on a row that survived escalates (SIGKILL,
// forceTerminate). Every action is logged to ~/.claude-mem/hygiene.log.
// ─────────────────────────────────────────────────────────────────────────────

enum Relief {

    // MARK: Readings

    struct Reading {
        let freePct: Int?
        let swapUsed: UInt64?
        let compressed: UInt64?
        let at: Date
        init(_ s: HealthSample) {
            freePct = s.memFreePct; swapUsed = s.swap?.usedBytes
            compressed = s.vm?.compressedBytes; at = s.sampledAt
        }
        init(freePct: Int?, swapUsed: UInt64?, compressed: UInt64?, at: Date) {
            self.freePct = freePct; self.swapUsed = swapUsed; self.compressed = compressed; self.at = at
        }
        var level: HealthLevel {
            guard let f = freePct else { return .warn }
            return f < HealthScorer.memCriticalPct ? .critical : f < HealthScorer.memWarnPct ? .warn : .ok
        }
    }

    // MARK: Process table (libproc, our uid only)

    struct Proc {
        let pid: pid_t
        let ppid: pid_t
        let startSec: Int64
        let startUsec: Int64
        let path: String
        let footprint: UInt64
        let tdev: UInt32
        let started: Date
        var age: TimeInterval { max(0, Date().timeIntervalSince(started)) }
        var identity: String { "\(pid)@\(startSec)." + String(format: "%06d", startUsec) }
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size ? bsd : nil
    }

    /// Physical footprint: what Activity Monitor shows as "Memory", including
    /// compressed and swapped pages. RSS undercounts badly under pressure.
    static func footprint(_ pid: pid_t) -> UInt64 {
        var info = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return r == 0 ? info.ri_phys_footprint : 0
    }

    static func table() -> [pid_t: Proc] {
        let uid = getuid()
        let need = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard need > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(need) / MemoryLayout<pid_t>.size + 64)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [:] }
        var out: [pid_t: Proc] = [:]
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(got) / MemoryLayout<pid_t>.size) where pid > 1 {
            guard let bsd = bsdInfo(pid), bsd.pbi_uid == uid else { continue }
            let n = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let started = Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1e6)
            out[pid] = Proc(pid: pid, ppid: pid_t(bsd.pbi_ppid),
                            startSec: Int64(bsd.pbi_start_tvsec), startUsec: Int64(bsd.pbi_start_tvusec),
                            path: n > 0 ? String(cString: pathBuf) : "", footprint: footprint(pid),
                            tdev: bsd.e_tdev, started: started)
        }
        return out
    }

    /// Same pid, same start time: the process we scanned, not a recycled pid.
    static func stillSame(_ p: Proc) -> Bool {
        guard let bsd = bsdInfo(p.pid) else { return false }
        return Int64(bsd.pbi_start_tvsec) == p.startSec && Int64(bsd.pbi_start_tvusec) == p.startUsec
    }

    static func cwd(_ pid: pid_t) -> String? {
        var vpi = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, size) == size else { return nil }
        let s = withUnsafePointer(to: &vpi.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return s.isEmpty ? nil : s
    }

    /// Seconds since the terminal last read a keystroke (what `w` calls idle).
    static func ttyIdle(_ tdev: UInt32) -> TimeInterval? {
        guard tdev != 0, tdev != UInt32.max, let name = devname(dev_t(bitPattern: tdev), S_IFCHR) else { return nil }
        var st = stat()
        guard stat("/dev/" + String(cString: name), &st) == 0 else { return nil }
        return max(0, Date().timeIntervalSince1970 - Double(st.st_atimespec.tv_sec))
    }

    static func command(_ pid: pid_t) -> String {
        SpeedUp.run("/bin/ps", ["-ww", "-o", "command=", "-p", "\(pid)"], timeout: 5)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: tmux

    static var tmuxBinary: String? {
        [HealthSensor.home + "/.homebrew/bin/tmux", "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Pane { let id: String; let session: String; let attached: Bool }

    static func tmuxPanes() -> [pid_t: Pane] {
        guard let tmux = tmuxBinary,
              let out = SpeedUp.run(tmux, ["list-panes", "-a", "-F",
                                           "#{pane_pid}\t#{pane_id}\t#{session_name}\t#{session_attached}"], timeout: 5)
        else { return [:] }
        var panes: [pid_t: Pane] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init)
            guard f.count == 4, let pid = pid_t(f[0]) else { continue }
            panes[pid] = Pane(id: f[1], session: f[2], attached: (Int(f[3]) ?? 0) > 0)
        }
        return panes
    }

    // MARK: Candidates

    enum Section: Int, CaseIterable {
        case sessions, simulators, apps, background
        var title: String {
            switch self {
            case .sessions:   return "Claude Code sessions"
            case .simulators: return "Simulators"
            case .apps:       return "Apps"
            case .background: return "Background processes"
            }
        }
    }

    enum Action {
        case closePane(paneID: String, claude: Proc)
        case terminate(Proc)
        case quitApp(NSRunningApplication)
        case shutdownSimulator(udid: String)
    }

    struct Candidate {
        let id: String
        let section: Section
        let title: String
        let detail: String
        let bytes: UInt64
        let suggested: String?   // why it is suggested, nil when it is not
        let warning: String?
        let action: Action
        var button: String {
            switch action {
            case .closePane, .terminate: return section == .sessions ? "Close" : "Stop"
            case .quitApp:               return "Quit"
            case .shutdownSimulator:     return "Shut Down"
            }
        }
    }

    static let minAppBytes: UInt64 = 300 << 20
    static let minBackgroundBytes: UInt64 = 800 << 20
    static let idleSuggest: TimeInterval = 3 * 3600

    static func gather() -> [Candidate] {
        let t = table()
        var kids: [pid_t: [pid_t]] = [:]
        for p in t.values { kids[p.ppid, default: []].append(p.pid) }
        let me = getpid()

        func ancestors(_ pid: pid_t) -> [pid_t] {
            var out: [pid_t] = [], cur = t[pid]?.ppid ?? 1, guardN = 0
            while cur > 1, guardN < 64, let p = t[cur] { out.append(cur); cur = p.ppid; guardN += 1 }
            return out
        }
        /// Footprint of a process and its descendants, not descending into `stop`.
        func tree(_ root: pid_t, stop: Set<pid_t> = []) -> (bytes: UInt64, count: Int) {
            var stack = [root], seen = Set<pid_t>(), bytes: UInt64 = 0, n = 0
            while let p = stack.popLast() {
                guard seen.insert(p).inserted, let info = t[p] else { continue }
                if p != root && stop.contains(p) { continue }
                bytes += info.footprint; n += 1
                stack += kids[p] ?? []
            }
            return (bytes, n)
        }
        func home(_ path: String) -> String {
            let h = HealthSensor.home
            return path == h ? "~" : path.hasPrefix(h + "/") ? "~" + path.dropFirst(h.count) : path
        }

        var out: [Candidate] = []

        // Claude Code sessions, with their MCP servers and tools.
        let stack = HealthSensor.claudeStack()
        let sessionPids = Set(stack.interactiveSessions.map(\.pid))
        let panes = tmuxPanes()
        var sessionsByAncestor: [pid_t: Int] = [:]
        for s in stack.interactiveSessions {
            guard let p = t[s.pid] else { continue }
            let up = ancestors(s.pid)
            for a in up { sessionsByAncestor[a, default: 0] += 1 }
            let size = tree(s.pid)
            let pane = ([s.pid] + up).lazy.compactMap { panes[$0] }.first
            let folder = cwd(s.pid).map(home) ?? "unknown folder"
            let idle = ttyIdle(p.tdev)
            var parts = ["running \(Style.duration(p.age))"]
            if let i = idle { parts.append(i < 120 ? "typed in just now" : "no typing for \(Style.duration(i))") }
            if let pane = pane { parts.append("tmux \(pane.session)" + (pane.attached ? "" : ", detached")) }
            if size.count > 1 { parts.append("\(size.count) processes") }
            var why: String?
            if let pane = pane, !pane.attached { why = "Detached, so no window shows it. It can be resumed with claude --resume." }
            else if let i = idle, i > idleSuggest { why = "Nobody has typed in it for \(Style.duration(i)). It can be resumed with claude --resume." }
            let action: Action = pane.map { .closePane(paneID: $0.id, claude: p) } ?? .terminate(p)
            out.append(Candidate(id: p.identity, section: .sessions, title: "Claude session in \(folder)",
                                 detail: parts.joined(separator: " \u{00B7} "), bytes: size.bytes,
                                 suggested: why, warning: nil, action: action))
        }

        // Booted simulators: every process of a device descends from its launchd_sim.
        // simctl only when a simulated device is actually running.
        let simRunning = t.values.contains { ($0.path as NSString).lastPathComponent == "launchd_sim" }
        let sims = simRunning ? SpeedUp.bootedSimulators() : []
        if !sims.isEmpty {
            let ps = SpeedUp.processTable()
            for sim in sims {
                let root = ps.first { $0.command.contains("launchd_sim") && $0.command.contains(sim.udid) }
                let size = root.map { tree($0.pid) } ?? (bytes: 0, count: 0)
                var detail = "booted"
                if let r = root { detail = "booted \(Style.duration(r.age)) \u{00B7} \(size.count) processes" }
                out.append(Candidate(id: "sim-" + sim.udid, section: .simulators, title: sim.name, detail: detail,
                                     bytes: size.bytes, suggested: "A booted simulator keeps a whole iOS in memory.",
                                     warning: nil, action: .shutdownSimulator(udid: sim.udid)))
            }
        }

        // Apps. Sessions running inside a terminal are counted above, not here.
        // Real apps only: helpers (Safari Web Content, renderers) live inside
        // another bundle or under /System and are counted with their app.
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy != .prohibited, let url = app.bundleURL?.path else { return false }
            return !url.hasPrefix("/System/Library/") && !url.dropLast(4).contains(".app/")
        }
        let appPids = Set(apps.map(\.processIdentifier))
        for app in apps {
            let pid = app.processIdentifier
            guard pid != me, app.bundleIdentifier != "com.apple.finder", let p = t[pid] else { continue }
            let size = tree(pid, stop: sessionPids)
            guard size.bytes >= minAppBytes else { continue }
            let name = app.localizedName ?? (p.path as NSString).lastPathComponent
            var detail = "open \(Style.duration(p.age))"
            if size.count > 1 { detail += " \u{00B7} \(size.count) processes" }
            if app.isHidden { detail += " \u{00B7} hidden" }
            var warning: String?
            if let n = sessionsByAncestor[pid], n > 0 {
                warning = "Quitting it also ends the \(n) Claude session\(n == 1 ? "" : "s") running inside it."
            }
            out.append(Candidate(id: p.identity, section: .apps, title: name, detail: detail, bytes: size.bytes,
                                 suggested: nil, warning: warning, action: .quitApp(app)))
        }

        // Big background processes started by launchd (ML servers, renders, dev
        // servers). Never suggested: they are somebody's work.
        let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/Library/Apple/"]
        let claimed = sessionPids.union(appPids)
        for p in t.values where p.ppid == 1 && p.pid != me && !claimed.contains(p.pid) {
            guard !systemPrefixes.contains(where: p.path.hasPrefix) else { continue }
            let size = tree(p.pid, stop: claimed)
            guard size.bytes >= minBackgroundBytes else { continue }
            let cmd = command(p.pid)
            if cmd.contains("worker-service.cjs") || (p.path as NSString).lastPathComponent == "tmux" { continue }
            let title = describe(cmd, path: p.path)
            var detail = "running \(Style.duration(p.age))"
            if size.count > 1 { detail += " \u{00B7} \(size.count) processes" }
            detail += " \u{00B7} pid \(p.pid)"
            out.append(Candidate(id: p.identity, section: .background, title: title, detail: detail, bytes: size.bytes,
                                 suggested: nil,
                                 warning: "If a launch agent keeps it alive, it starts again on its own.",
                                 action: .terminate(p)))
        }

        return out.sorted { a, b in
            a.section != b.section ? a.section.rawValue < b.section.rawValue : a.bytes > b.bytes
        }
    }

    /// "ears_server.py (python)" for interpreters, the executable name otherwise.
    static func describe(_ cmd: String, path: String) -> String {
        let exe = (path as NSString).lastPathComponent
        let interpreters = ["python", "node", "bun", "ruby", "deno", "java"]
        if interpreters.contains(where: { exe.lowercased().hasPrefix($0) }) {
            let args = cmd.split(separator: " ").dropFirst().map(String.init)
            if let script = args.first(where: { !$0.hasPrefix("-") && $0.contains(".") }) {
                let short = (script as NSString).lastPathComponent
                let kind = interpreters.first { exe.lowercased().hasPrefix($0) } ?? exe
                return "\(short) (\(kind))"
            }
        }
        return exe.isEmpty ? (cmd.split(separator: " ").first.map(String.init) ?? "process") : exe
    }

    // MARK: Actions

    /// Runs off the main thread except app quits, which AppKit wants on main.
    /// Returns nil on success, or what went wrong in a few words.
    static func perform(_ c: Candidate, force: Bool) -> String? {
        switch c.action {
        case .closePane(let paneID, let claude):
            guard stillSame(claude) else { return nil }          // already gone
            if force { kill(claude.pid, SIGKILL); HealthAction.log("free-memory: SIGKILL \(claude.identity) \(c.title)"); return nil }
            guard let tmux = tmuxBinary, SpeedUp.run(tmux, ["kill-pane", "-t", paneID], timeout: 10) != nil else {
                return "tmux would not close the pane"
            }
            HealthAction.log("free-memory: tmux kill-pane \(paneID) (\(claude.identity)) \(c.title)")
            return nil
        case .terminate(let p):
            guard stillSame(p) else { return nil }
            let sig = force ? SIGKILL : SIGTERM
            guard kill(p.pid, sig) == 0 else { return "the signal was refused" }
            HealthAction.log("free-memory: \(force ? "SIGKILL" : "SIGTERM") \(p.identity) \(c.title)")
            return nil
        case .quitApp(let app):
            var ok = false
            DispatchQueue.main.sync { ok = app.isTerminated || (force ? app.forceTerminate() : app.terminate()) }
            HealthAction.log("free-memory: \(force ? "force-quit" : "quit") app \(c.title) (pid \(app.processIdentifier))")
            return ok ? nil : "it did not accept the request"
        case .shutdownSimulator(let udid):
            guard SpeedUp.run("/usr/bin/xcrun", ["simctl", "shutdown", udid], timeout: 60) != nil else {
                return "simctl could not shut it down"
            }
            HealthAction.log("free-memory: simctl shutdown \(udid) \(c.title)")
            return nil
        }
    }

    /// Step one of the click: the leaks the reaper owns, any age while memory is low.
    static func clearLeaks(lowMemory: Bool, completion: @escaping (ReapResult, HealthSample) -> Void) {
        HealthAction.queue.async {
            let s = HealthSensor.sample()
            let low = lowMemory || Reading(s).level != .ok
            HealthAction.reap(sample: s, summarizerAge: low ? 0 : nil, on: HealthAction.queue) { r in
                completion(r, s)
            }
        }
    }

    // MARK: Entry point

    static func open(lowMemory: Bool, onChange: @escaping () -> Void) {
        if let w = ReliefWindow.current {
            NSApp.activate(ignoringOtherApps: true)
            w.window?.makeKeyAndOrderFront(nil)
            w.recheck()
            return
        }
        let w = ReliefWindow(onChange: onChange)
        ReliefWindow.current = w
        w.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        w.window?.makeKeyAndOrderFront(nil)
        clearLeaks(lowMemory: lowMemory) { result, before in
            DispatchQueue.main.async {
                w.baseline = Reading(before)
                if result.killedAnything {
                    w.status = "Cleared \(result.what), \(Style.bytes(result.bytesResident)) resident."
                    HealthPrefs.lastReap = result
                } else {
                    w.status = "No leaked summarizers or headless Chrome to clear."
                }
                onChange()
                w.recheck(after: result.killedAnything ? 2 : 0)
            }
        }
    }

    // MARK: Debug

    static func dryRun() -> String {
        let s = HealthSensor.sample()
        var lines = ["memory: \(s.memFreePct.map { "\($0)% free" } ?? "n/a") \u{00B7} swap \(s.swap.map { Style.bytes($0.usedBytes) } ?? "n/a")"]
        lines.append("leaks: \(s.claude.summarizers.count) summarizers, \(s.claude.headlessChrome.count) headless Chrome")
        var section: Section?
        for c in gather() {
            if c.section != section { section = c.section; lines.append(c.section.title.uppercased()) }
            lines.append("  \(Style.bytes(c.bytes).padding(toLength: 8, withPad: " ", startingAt: 0)) \(c.title)  [\(c.detail)]"
                         + (c.suggested != nil ? "  SUGGESTED" : ""))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Window

final class ReliefWindow: NSWindowController, NSWindowDelegate {

    static var current: ReliefWindow?

    var baseline: Relief.Reading?
    var latest: Relief.Reading?
    var status = "Clearing leaks\u{2026}" { didSet { statusLabel.stringValue = status } }

    private var candidates: [Relief.Candidate] = []
    private var attempted: Set<String> = []
    private var working: Set<String> = []
    private var errors: [String: String] = [:]
    private var scanning = false
    private let onChange: () -> Void
    private let demo: Bool

    private let beforeValue = NSTextField(labelWithString: "\u{2013}")
    private let beforeSub = NSTextField(labelWithString: "")
    private let nowValue = NSTextField(labelWithString: "\u{2013}")
    private let nowSub = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let list = NSStackView()
    private let suggestedButton = NSButton(title: "Close Suggested", target: nil, action: nil)
    private let recheckButton = NSButton(title: "Recheck", target: nil, action: nil)

    static let width: CGFloat = 560

    init(onChange: @escaping () -> Void, demo: Bool = false) {
        self.onChange = onChange
        self.demo = demo
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ReliefWindow.width, height: 600),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Free Up Memory"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: ReliefWindow.width, height: 380)
        super.init(window: win)
        win.delegate = self
        build()
        win.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        if ReliefWindow.current === self { ReliefWindow.current = nil }
    }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }

        func caption(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s.uppercased())
            l.font = .systemFont(ofSize: 10.5, weight: .semibold)
            l.textColor = .secondaryLabelColor
            return l
        }
        func column(_ title: String, _ value: NSTextField, _ sub: NSTextField) -> NSStackView {
            value.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
            sub.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            sub.textColor = .secondaryLabelColor
            let v = NSStackView(views: [caption(title), value, sub])
            v.orientation = .vertical; v.alignment = .leading; v.spacing = 2
            return v
        }
        let arrow = NSTextField(labelWithString: "\u{2192}")
        arrow.font = .systemFont(ofSize: 22, weight: .light)
        arrow.textColor = .tertiaryLabelColor
        let readout = NSStackView(views: [column("Before", beforeValue, beforeSub), arrow, column("Now", nowValue, nowSub)])
        readout.orientation = .horizontal; readout.alignment = .centerY; readout.spacing = 22

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = status
        statusLabel.preferredMaxLayoutWidth = ReliefWindow.width - 40

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false

        suggestedButton.target = self; suggestedButton.action = #selector(closeSuggested)
        recheckButton.target = self; recheckButton.action = #selector(recheckClicked)
        let done = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        done.keyEquivalent = "\u{1b}"
        let monitor = NSButton(title: "Activity Monitor", target: self, action: #selector(openMonitor))
        for b in [suggestedButton, recheckButton, done, monitor] { b.bezelStyle = .rounded }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [monitor, spacer, recheckButton, suggestedButton, done])
        buttons.orientation = .horizontal; buttons.spacing = 8

        let sep1 = NSBox(); sep1.boxType = .separator
        let sep2 = NSBox(); sep2.boxType = .separator

        for v in [readout, statusLabel, sep1, scroll, sep2, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        let m: CGFloat = 20
        NSLayoutConstraint.activate([
            readout.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            readout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            statusLabel.topAnchor.constraint(equalTo: readout.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            sep1.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            sep1.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sep1.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sep1.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sep2.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            sep2.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sep2.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: sep2.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor, constant: 6),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: m),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -m),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -10),
        ])
        renderReadout()
        renderList()
    }

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    private func describe(_ r: Relief.Reading?) -> (String, String) {
        guard let r = r else { return ("\u{2013}", "") }
        let v = r.freePct.map { "\($0)% free" } ?? "unknown"
        var sub: [String] = []
        if let s = r.swapUsed { sub.append("swap \(Style.bytes(s))") }
        if let c = r.compressed { sub.append("compressed \(Style.bytes(c))") }
        return (v, sub.joined(separator: " \u{00B7} "))
    }

    private func renderReadout() {
        let b = describe(baseline), n = describe(latest)
        beforeValue.stringValue = b.0; beforeSub.stringValue = b.1
        nowValue.stringValue = n.0
        nowSub.stringValue = n.1 + (latest.map { " \u{00B7} \(Style.clock($0.at))" } ?? "")
        beforeValue.textColor = baseline.map { Style.tint(forHealth: $0.level) } ?? .labelColor
        nowValue.textColor = latest.map { $0.level == .ok ? .systemGreen : Style.tint(forHealth: $0.level) } ?? .labelColor
    }

    private func renderList() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width = ReliefWindow.width - 40
        if candidates.isEmpty {
            let l = NSTextField(wrappingLabelWithString: scanning ? "Measuring what holds memory\u{2026}"
                : "Nothing else holds a lot of memory. Sessions, simulators, apps over 300 MB and background processes over 800 MB appear here.")
            l.font = .systemFont(ofSize: 12.5); l.textColor = .secondaryLabelColor
            l.preferredMaxLayoutWidth = width
            list.addArrangedSubview(l)
            list.setCustomSpacing(10, after: l)
        }
        var section: Relief.Section?
        for c in candidates {
            if c.section != section {
                section = c.section
                let total = candidates.filter { $0.section == c.section }.reduce(0) { $0 + $1.bytes }
                let h = NSTextField(labelWithString: "\(c.section.title.uppercased())  \u{00B7}  \(Style.bytes(total))")
                h.font = .systemFont(ofSize: 10.5, weight: .semibold)
                h.textColor = .secondaryLabelColor
                if list.arrangedSubviews.last != nil { list.setCustomSpacing(16, after: list.arrangedSubviews.last!) }
                list.addArrangedSubview(h)
                list.setCustomSpacing(6, after: h)
            }
            let row = makeRow(c, width: width)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: width).isActive = true
            list.setCustomSpacing(10, after: row)
        }
        let n = candidates.filter { $0.suggested != nil && !working.contains($0.id) }.count
        suggestedButton.title = n > 0 ? "Close \(n) Suggested" : "Close Suggested"
        suggestedButton.isEnabled = n > 0
        recheckButton.isEnabled = !scanning
    }

    private func makeRow(_ c: Relief.Candidate, width: CGFloat) -> NSView {
        let title = NSTextField(labelWithString: c.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        let textW = width - 200
        let detail = NSTextField(wrappingLabelWithString: c.detail)
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = textW
        var lines: [NSView] = [title, detail]
        func note(_ s: String, _ color: NSColor) {
            let l = NSTextField(wrappingLabelWithString: s)
            l.font = .systemFont(ofSize: 11.5); l.textColor = color
            l.preferredMaxLayoutWidth = textW
            lines.append(l)
        }
        if let e = errors[c.id] { note("Not done: \(e).", .systemRed) }
        else if attempted.contains(c.id) && !working.contains(c.id) { note("Still running after the request. Click again to force it.", .systemOrange) }
        if let s = c.suggested { note("Suggested. " + s, .controlAccentColor) }
        if let w = c.warning { note(w, .tertiaryLabelColor) }
        title.widthAnchor.constraint(lessThanOrEqualToConstant: textW).isActive = true
        let text = NSStackView(views: lines)
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 2

        let size = NSTextField(labelWithString: Style.bytes(c.bytes))
        size.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        size.alignment = .right
        size.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let busy = working.contains(c.id)
        let force = attempted.contains(c.id)
        let b = NSButton(title: busy ? "Working\u{2026}" : force ? "Force \(c.button)" : c.button,
                         target: self, action: #selector(rowClicked(_:)))
        b.bezelStyle = .rounded
        b.isEnabled = !busy
        b.identifier = NSUserInterfaceItemIdentifier(c.id)
        b.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [text, spacer, size, b])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        return row
    }

    // MARK: Behaviour

    func recheck(after delay: TimeInterval = 0) {
        guard !demo else { return }
        scanning = true
        recheckButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            let sample = HealthSensor.sample()
            let found = Relief.gather()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.scanning = false
                self.latest = Relief.Reading(sample)
                if self.baseline == nil { self.baseline = self.latest }
                let live = Set(found.map(\.id))
                self.attempted.formIntersection(live)
                self.errors = self.errors.filter { live.contains($0.key) }
                self.candidates = found
                self.renderReadout()
                self.renderList()
                self.onChange()
            }
        }
    }

    private func run(_ list: [Relief.Candidate]) {
        guard !list.isEmpty else { return }
        for c in list { working.insert(c.id); errors[c.id] = nil }
        renderList()
        let forced = Set(list.filter { attempted.contains($0.id) }.map(\.id))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var errs: [String: String] = [:]
            for c in list { if let e = Relief.perform(c, force: forced.contains(c.id)) { errs[c.id] = e } }
            DispatchQueue.main.async {
                guard let self = self else { return }
                for c in list { self.working.remove(c.id); self.attempted.insert(c.id) }
                self.errors.merge(errs) { $1 }
                let ok = list.count - errs.count
                self.status = ok > 0 ? "Closed \(ok) item\(ok == 1 ? "" : "s"). Measuring again once memory settles\u{2026}"
                                     : "Nothing was closed."
                self.renderList()
                // Apps may show a save prompt; memory takes a moment to come back.
                self.recheck(after: 3)
            }
        }
    }

    @objc private func rowClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let c = candidates.first(where: { $0.id == id }) else { return }
        run([c])
    }

    @objc private func closeSuggested() {
        run(candidates.filter { $0.suggested != nil && !working.contains($0.id) })
    }

    @objc private func recheckClicked() {
        status = "Measuring again\u{2026}"
        recheck()
    }

    @objc private func doneClicked() { close() }

    @objc private func openMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    // MARK: Debug snapshot

    /// The window filled with the 2026-11-09 situation, as a PNG.
    static func snapshot(to url: URL, dark: Bool) {
        let w = ReliefWindow(onChange: {}, demo: true)
        let now = Date()
        func proc(_ pid: pid_t, age: TimeInterval) -> Relief.Proc {
            Relief.Proc(pid: pid, ppid: 1, startSec: 0, startUsec: 0, path: "", footprint: 0, tdev: 0,
                        started: now.addingTimeInterval(-age))
        }
        w.baseline = Relief.Reading(freePct: 23, swapUsed: 11_000 << 20, compressed: 6_100 << 20, at: now.addingTimeInterval(-40))
        w.latest = Relief.Reading(freePct: 75, swapUsed: 4_900 << 20, compressed: 2_300 << 20, at: now)
        w.status = "Cleared 25 summarizers, 11.8 GB resident. 1 suggested item left below."
        let resume = " It can be resumed with claude --resume."
        w.candidates = [
            .init(id: "a", section: .sessions, title: "Claude session in ~/lumos-ears",
                  detail: "running 3 h 12 m \u{00B7} no typing for 2 h 40 m \u{00B7} tmux claude-retry-5531, detached \u{00B7} 9 processes",
                  bytes: 1_900 << 20, suggested: "Detached, so no window shows it." + resume, warning: nil,
                  action: .terminate(proc(1, age: 0))),
            .init(id: "b", section: .sessions, title: "Claude session in ~/claude-usage-widget",
                  detail: "running 41 m \u{00B7} typed in just now \u{00B7} tmux claude-retry-6739 \u{00B7} 6 processes",
                  bytes: 1_200 << 20, suggested: nil, warning: nil, action: .terminate(proc(2, age: 0))),
            .init(id: "c", section: .apps, title: "Warp", detail: "open 2 h 4 m \u{00B7} 3 processes", bytes: 620 << 20,
                  suggested: nil, warning: "Quitting it also ends the 2 Claude sessions running inside it.",
                  action: .quitApp(NSRunningApplication.current)),
            .init(id: "d", section: .apps, title: "Safari", detail: "open 2 h 4 m", bytes: 398 << 20,
                  suggested: nil, warning: nil, action: .quitApp(NSRunningApplication.current)),
            .init(id: "e", section: .background, title: "ears_server.py (python)",
                  detail: "running 2 h 5 m \u{00B7} pid 1902", bytes: 5_760 << 20, suggested: nil,
                  warning: "If a launch agent keeps it alive, it starts again on its own.", action: .terminate(proc(5, age: 0))),
            .init(id: "f", section: .background, title: "ryan_server.py (python)",
                  detail: "running 2 h 5 m \u{00B7} pid 1898", bytes: 3_200 << 20, suggested: nil,
                  warning: "If a launch agent keeps it alive, it starts again on its own.", action: .terminate(proc(6, age: 0))),
        ]
        w.attempted = ["d"]
        guard let win = w.window, let view = win.contentView else { return }
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.setContentSize(NSSize(width: ReliefWindow.width, height: 700))
        w.renderReadout(); w.renderList()
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)  \(Int(view.bounds.width))x\(Int(view.bounds.height))")
    }
}
