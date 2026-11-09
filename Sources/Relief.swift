import Cocoa

// ─────────────────────────────────────────────────────────────────────────────
// Clean Up (added 2026-11-09 as Free Up Memory; Speed Up folded in the same day)
//
// The one place to make the Mac fast again. On 2026-11-09, six minutes after
// a reboot, the claude-mem worker started 25 summarizers inside one minute
// (about 12 GB footprint, swap 11 of 12 GB, load 140). Clearing them took
// memory free from 30% to 75%.
//
// The click does two things:
//   1. At once, with no further question: the leaks the reaper already owns
//      (claude-mem summarizers, orphaned headless Chrome). While memory is low
//      the summarizer age limit drops to zero, because the click is the consent.
//   2. Opens one window listing what slows the Mac, in five sections: Claude
//      Code sessions, heavy jobs (builds, simulators, renders), apps,
//      background processes, and disk space (rebuildable caches). Memory is
//      measured as physical footprint, the number Activity Monitor calls
//      "Memory". Each row has its own button; nothing runs without a click on
//      that row, or on "Clean Up Suggested", which covers only rows marked
//      suggested.
// After every action the window waits for memory to settle, samples again and
// shows before and now side by side. Recheck samples on demand.
//
// Safety: a process is signalled only if its pid and start time (sec + usec),
// or for jobs its full command line, still match the scan. Apps get
// NSRunningApplication.terminate(), so they can ask to save. A second click on
// a row that survived escalates (SIGKILL, forceTerminate). Every action is
// logged to ~/.claude-mem/hygiene.log.
// ─────────────────────────────────────────────────────────────────────────────

enum Relief {

    // MARK: Readings

    struct Reading {
        let freePct: Int?
        let swapUsed: UInt64?
        let compressed: UInt64?
        let diskFree: UInt64?
        let loadPerCore: Double?
        let at: Date
        init(_ s: HealthSample) {
            freePct = s.memFreePct; swapUsed = s.swap?.usedBytes
            compressed = s.vm?.compressedBytes; diskFree = s.disk?.freeBytes
            loadPerCore = s.loadPerCore; at = s.sampledAt
        }
        init(freePct: Int?, swapUsed: UInt64?, compressed: UInt64?, diskFree: UInt64?, loadPerCore: Double?, at: Date) {
            self.freePct = freePct; self.swapUsed = swapUsed; self.compressed = compressed
            self.diskFree = diskFree; self.loadPerCore = loadPerCore; self.at = at
        }
        var level: HealthLevel {
            guard let f = freePct else { return .warn }
            return f < HealthScorer.memCriticalPct ? .critical : f < HealthScorer.memWarnPct ? .warn : .ok
        }
        var diskLow: Bool { (diskFree ?? .max) < HealthScorer.diskWarnBytes }
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
        case sessions, heavy, apps, background, disk
        var title: String {
            switch self {
            case .sessions:   return "Claude Code sessions"
            case .heavy:      return "Heavy jobs"
            case .apps:       return "Apps"
            case .background: return "Background processes"
            case .disk:       return "Disk space"
            }
        }
        /// When the section matters, in one sentence.
        var explanation: String {
            switch self {
            case .sessions:
                return "Each open session holds half a gigabyte to two with its tools. Closing one keeps its history, and claude --resume brings it back."
            case .heavy:
                return "Builds, tests, simulators and renders. These make the Mac hot and slow even when memory looks fine."
            case .apps:
                return "Quit asks the app to close, so it can offer to save first."
            case .background:
                return "Servers and tools started outside any app. Stop one only if you won't need it in the next hour."
            case .disk:
                return "Caches that rebuild themselves when next needed. Clear them when the disk is nearly full, since macOS keeps swap on the same disk."
            }
        }
    }

    enum Action {
        case closePane(paneID: String, claude: Proc)
        case terminate(Proc)
        case quitApp(NSRunningApplication)
        case shutdownSimulator(udid: String)
        case stopJob(SpeedUp.Job)
        case clearCache(SpeedUp.Cache)
    }

    struct Candidate {
        let id: String
        let section: Section
        let title: String
        let detail: String
        let bytes: UInt64
        var metric: String? = nil   // shown instead of the size (CPU for jobs)
        let suggested: String?      // why it is suggested, nil when it is not
        let warning: String?
        let action: Action
        var button: String {
            switch action {
            case .closePane:         return "Close"
            case .terminate:         return section == .sessions ? "Close" : "Stop"
            case .quitApp:           return "Quit"
            case .shutdownSimulator: return "Shut Down"
            case .stopJob:           return "Stop"
            case .clearCache:        return "Clear"
            }
        }
        var shown: String { metric ?? Style.bytes(bytes) }
    }

    static let minAppBytes: UInt64 = 300 << 20
    static let minBackgroundBytes: UInt64 = 800 << 20
    static let idleSuggest: TimeInterval = 3 * 3600
    static let busyJobCPU: Double = 100         // a job using a full core or more is suggested

    /// Everything except caches (those take seconds to measure; see `caches`).
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
            if let pane = pane, !pane.attached { why = "Detached, so no window shows it." }
            else if let i = idle, i > idleSuggest { why = "Nobody has typed in it for \(Style.duration(i))." }
            let action: Action = pane.map { .closePane(paneID: $0.id, claude: p) } ?? .terminate(p)
            out.append(Candidate(id: p.identity, section: .sessions, title: "Claude session in \(folder)",
                                 detail: parts.joined(separator: " \u{00B7} "), bytes: size.bytes,
                                 suggested: why, warning: nil, action: action))
        }

        // Heavy jobs: Xcode builds/tests and ffmpeg renders (by CPU), then
        // booted simulators (every process of a device descends from its launchd_sim).
        let simRunning = t.values.contains { ($0.path as NSString).lastPathComponent == "launchd_sim" }
        let xcodeOrRender = t.values.contains {
            let n = ($0.path as NSString).lastPathComponent
            return n == "xcodebuild" || n == "ffmpeg"
        }
        let ps = (simRunning || xcodeOrRender) ? SpeedUp.processTable() : []
        if xcodeOrRender {
            for j in SpeedUp.gatherJobs(ps) {
                let busy = j.cpu >= busyJobCPU
                out.append(Candidate(id: "job-\(j.pid)", section: .heavy, title: j.title, detail: j.detail,
                                     bytes: tree(j.pid).bytes, metric: String(format: "%.0f%% CPU", j.cpu),
                                     suggested: busy ? "Using \(Int(j.cpu / 100)) core\(j.cpu >= 200 ? "s" : "") right now." : nil,
                                     warning: nil, action: .stopJob(j)))
            }
        }
        if simRunning {
            for sim in SpeedUp.bootedSimulators() {
                let root = ps.first { $0.command.contains("launchd_sim") && $0.command.contains(sim.udid) }
                let size = root.map { tree($0.pid) } ?? (bytes: 0, count: 0)
                var detail = "simulator, booted"
                if let r = root { detail = "simulator, booted \(Style.duration(r.age)) \u{00B7} \(size.count) processes" }
                out.append(Candidate(id: "sim-" + sim.udid, section: .heavy, title: sim.name, detail: detail,
                                     bytes: size.bytes, suggested: "A booted simulator keeps a whole iPhone in memory.",
                                     warning: nil, action: .shutdownSimulator(udid: sim.udid)))
            }
        }

        // Apps. Helpers (Safari Web Content, renderers) live inside another
        // bundle or under /System/Library and count with their app. Sessions
        // running inside a terminal are counted above, not here.
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

        // Big background processes started by launchd (ML servers, dev
        // servers). Never suggested: they are somebody's work.
        let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/Library/Apple/"]
        let claimed = sessionPids.union(appPids)
        for p in t.values where p.ppid == 1 && p.pid != me && !claimed.contains(p.pid) {
            guard !systemPrefixes.contains(where: p.path.hasPrefix) else { continue }
            let size = tree(p.pid, stop: claimed)
            guard size.bytes >= minBackgroundBytes else { continue }
            let cmd = command(p.pid)
            if cmd.contains("worker-service.cjs") || (p.path as NSString).lastPathComponent == "tmux" { continue }
            var detail = "running \(Style.duration(p.age))"
            if size.count > 1 { detail += " \u{00B7} \(size.count) processes" }
            detail += " \u{00B7} pid \(p.pid)"
            out.append(Candidate(id: p.identity, section: .background, title: describe(cmd, path: p.path),
                                 detail: detail, bytes: size.bytes, suggested: nil,
                                 warning: "If a launch agent keeps it alive, it starts again on its own.",
                                 action: .terminate(p)))
        }

        return sorted(out)
    }

    static func sorted(_ list: [Candidate]) -> [Candidate] {
        list.sorted { a, b in
            a.section != b.section ? a.section.rawValue < b.section.rawValue : a.bytes > b.bytes
        }
    }

    /// Rebuildable caches as rows; suggested only while the disk is low.
    static func caches(diskLow: Bool) -> [Candidate] {
        SpeedUp.gatherCaches().map { c in
            Candidate(id: "cache-" + c.path, section: .disk, title: c.name,
                      detail: SpeedUp.abbreviate(c.path), bytes: c.bytes ?? 0,
                      metric: c.bytes == nil ? "not measured" : nil,
                      suggested: diskLow ? "The disk is nearly full." : nil, warning: nil, action: .clearCache(c))
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
            if force { kill(claude.pid, SIGKILL); HealthAction.log("clean-up: SIGKILL \(claude.identity) \(c.title)"); return nil }
            guard let tmux = tmuxBinary, SpeedUp.run(tmux, ["kill-pane", "-t", paneID], timeout: 10) != nil else {
                return "tmux would not close the pane"
            }
            HealthAction.log("clean-up: tmux kill-pane \(paneID) (\(claude.identity)) \(c.title)")
            return nil
        case .terminate(let p):
            guard stillSame(p) else { return nil }
            let sig = force ? SIGKILL : SIGTERM
            guard kill(p.pid, sig) == 0 else { return "the signal was refused" }
            HealthAction.log("clean-up: \(force ? "SIGKILL" : "SIGTERM") \(p.identity) \(c.title)")
            return nil
        case .quitApp(let app):
            var ok = false
            DispatchQueue.main.sync { ok = app.isTerminated || (force ? app.forceTerminate() : app.terminate()) }
            HealthAction.log("clean-up: \(force ? "force-quit" : "quit") app \(c.title) (pid \(app.processIdentifier))")
            return ok ? nil : "it did not accept the request"
        case .shutdownSimulator(let udid):
            guard SpeedUp.run("/usr/bin/xcrun", ["simctl", "shutdown", udid], timeout: 60) != nil else {
                return "simctl could not shut it down"
            }
            HealthAction.log("clean-up: simctl shutdown \(udid) \(c.title)")
            return nil
        case .stopJob(let j):
            return SpeedUp.stop(j, force: force)
        case .clearCache(let cache):
            return SpeedUp.clear(cache)
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
                    w.status = "Cleared \(result.what) that had leaked, \(Style.bytes(result.bytesResident)) in memory."
                    HealthPrefs.lastReap = result
                } else {
                    w.status = "No leaked processes this time. Anything else worth closing is listed below."
                }
                onChange()
                w.recheck(after: result.killedAnything ? 2 : 0)
                w.measureCaches()
            }
        }
    }

    // MARK: Debug

    static func dryRun() -> String {
        let s = HealthSensor.sample()
        let r = Reading(s)
        var lines = ["memory: \(s.memFreePct.map { "\($0)% free" } ?? "n/a") \u{00B7} swap \(s.swap.map { Style.bytes($0.usedBytes) } ?? "n/a")"
                     + " \u{00B7} disk \(s.disk.map { Style.bytes($0.freeBytes) } ?? "n/a") free"]
        lines.append("leaks: \(s.claude.summarizers.count) summarizers, \(s.claude.headlessChrome.count) headless Chrome")
        var section: Section?
        for c in gather() + caches(diskLow: r.diskLow) {
            if c.section != section { section = c.section; lines.append(c.section.title.uppercased()) }
            lines.append("  \(c.shown.padding(toLength: 12, withPad: " ", startingAt: 0)) \(c.title)  [\(c.detail)]"
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
    private var cacheRows: [Relief.Candidate] = []
    private var cachesMeasuring = false
    private var attempted: Set<String> = []
    private var working: Set<String> = []
    private var errors: [String: String] = [:]
    private var scanning = true
    private let onChange: () -> Void
    private let demo: Bool

    private let beforeValue = NSTextField(labelWithString: "\u{2013}")
    private let beforeSub = NSTextField(labelWithString: "")
    private let nowValue = NSTextField(labelWithString: "\u{2013}")
    private let nowSub = NSTextField(labelWithString: "")
    private let machineLine = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let list = NSStackView()
    private let suggestedButton = NSButton(title: "Clean Up Suggested", target: nil, action: nil)
    private let recheckButton = NSButton(title: "Recheck", target: nil, action: nil)

    static let width: CGFloat = 580

    private var rows: [Relief.Candidate] { Relief.sorted(candidates + cacheRows) }

    init(onChange: @escaping () -> Void, demo: Bool = false) {
        self.onChange = onChange
        self.demo = demo
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ReliefWindow.width, height: 640),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "Clean Up Mac"
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: ReliefWindow.width, height: 420)
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

        // The top band sits on a faint tinted card so the numbers read first.
        let band = NSVisualEffectView()
        band.material = .headerView
        band.blendingMode = .withinWindow
        band.state = .active

        func caption(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s.uppercased())
            l.font = .systemFont(ofSize: 10.5, weight: .semibold)
            l.textColor = .secondaryLabelColor
            return l
        }
        func column(_ title: String, _ value: NSTextField, _ sub: NSTextField) -> NSStackView {
            value.font = .monospacedDigitSystemFont(ofSize: 32, weight: .semibold)
            sub.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            sub.textColor = .secondaryLabelColor
            let v = NSStackView(views: [caption(title), value, sub])
            v.orientation = .vertical; v.alignment = .leading; v.spacing = 2
            return v
        }
        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.right", accessibilityDescription: "to") ?? NSImage())
        arrow.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        arrow.contentTintColor = .tertiaryLabelColor
        let readout = NSStackView(views: [column("Memory before", beforeValue, beforeSub), arrow,
                                          column("Memory now", nowValue, nowSub)])
        readout.orientation = .horizontal; readout.alignment = .centerY; readout.spacing = 24

        machineLine.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        machineLine.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 12.5)
        statusLabel.textColor = .labelColor
        statusLabel.stringValue = status
        statusLabel.preferredMaxLayoutWidth = ReliefWindow.width - 48

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = doc

        suggestedButton.target = self; suggestedButton.action = #selector(cleanSuggested)
        suggestedButton.keyEquivalent = "\r"
        recheckButton.target = self; recheckButton.action = #selector(recheckClicked)
        let done = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        done.keyEquivalent = "\u{1b}"
        let monitor = NSButton(title: "Activity Monitor", target: self, action: #selector(openMonitor))
        for b in [suggestedButton, recheckButton, done, monitor] { b.bezelStyle = .rounded; b.controlSize = .large }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [monitor, spacer, recheckButton, done, suggestedButton])
        buttons.orientation = .horizontal; buttons.spacing = 8

        let sep1 = NSBox(); sep1.boxType = .separator
        let sep2 = NSBox(); sep2.boxType = .separator

        for v in [band, readout, machineLine, statusLabel, sep1, scroll, sep2, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        let m: CGFloat = 24
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: content.topAnchor),
            band.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            band.bottomAnchor.constraint(equalTo: sep1.topAnchor),
            readout.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            readout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            machineLine.topAnchor.constraint(equalTo: readout.bottomAnchor, constant: 10),
            machineLine.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            statusLabel.topAnchor.constraint(equalTo: machineLine.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            sep1.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
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
            list.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: m),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -m),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -12),
        ])
        renderReadout()
        renderList()
    }

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    private func describe(_ r: Relief.Reading?) -> (String, String) {
        guard let r = r else { return ("\u{2013}", "measuring\u{2026}") }
        let v = r.freePct.map { "\($0)% free" } ?? "unknown"
        var sub: [String] = []
        if let s = r.swapUsed { sub.append("swap \(Style.bytes(s))") }
        if let c = r.compressed { sub.append("compressed \(Style.bytes(c))") }
        return (v, sub.joined(separator: " \u{00B7} "))
    }

    private func renderReadout() {
        let b = describe(baseline), n = describe(latest)
        beforeValue.stringValue = b.0; beforeSub.stringValue = b.1
        nowValue.stringValue = n.0; nowSub.stringValue = n.1
        beforeValue.textColor = baseline.map { Style.tint(forHealth: $0.level) } ?? .labelColor
        nowValue.textColor = latest.map { $0.level == .ok ? .systemGreen : Style.tint(forHealth: $0.level) } ?? .labelColor
        var parts: [String] = []
        if let r = latest ?? baseline {
            if let d = r.diskFree { parts.append("Disk \(Style.bytes(d)) free" + (r.diskLow ? " (low)" : "")) }
            if let l = r.loadPerCore { parts.append(String(format: "load %.1f per core", l)) }
            parts.append("checked \(Style.clock(r.at))")
        }
        machineLine.stringValue = parts.joined(separator: "  \u{00B7}  ")
    }

    private func renderList() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width = ReliefWindow.width - 48
        let all = rows
        if all.isEmpty && !cachesMeasuring {
            let l = NSTextField(wrappingLabelWithString: scanning ? "Measuring what holds memory\u{2026}"
                : "Nothing else is worth closing. Sessions, heavy jobs, apps over 300 MB, background processes over 800 MB and big caches appear here.")
            l.font = .systemFont(ofSize: 12.5); l.textColor = .secondaryLabelColor
            l.preferredMaxLayoutWidth = width
            list.addArrangedSubview(l)
            list.setCustomSpacing(10, after: l)
        }
        for section in Relief.Section.allCases {
            let items = all.filter { $0.section == section }
            let measuringHere = section == .disk && cachesMeasuring && items.isEmpty
            guard !items.isEmpty || measuringHere else { continue }
            if let last = list.arrangedSubviews.last { list.setCustomSpacing(22, after: last) }
            list.addArrangedSubview(sectionHeader(section, items: items, width: width))
            if measuringHere {
                let l = NSTextField(labelWithString: "Measuring cache sizes\u{2026}")
                l.font = .systemFont(ofSize: 12); l.textColor = .tertiaryLabelColor
                list.addArrangedSubview(l)
            }
            for c in items {
                let row = makeRow(c, width: width)
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: width).isActive = true
                list.setCustomSpacing(12, after: row)
            }
        }
        let n = all.filter { $0.suggested != nil && !working.contains($0.id) }.count
        suggestedButton.title = n > 0 ? "Clean Up \(n) Suggested" : "Nothing Suggested"
        suggestedButton.isEnabled = n > 0
        recheckButton.isEnabled = !scanning
    }

    private func sectionHeader(_ s: Relief.Section, items: [Relief.Candidate], width: CGFloat) -> NSView {
        let title = NSTextField(labelWithString: s.title.uppercased())
        title.font = .systemFont(ofSize: 11, weight: .bold)
        title.textColor = .secondaryLabelColor
        let total = items.reduce(UInt64(0)) { $0 + $1.bytes }
        let amount = NSTextField(labelWithString: total > 0 ? Style.bytes(total) + (s == .disk ? " on disk" : "") : "")
        amount.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        amount.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [title, spacer, amount])
        top.orientation = .horizontal
        let explain = NSTextField(wrappingLabelWithString: s.explanation)
        explain.font = .systemFont(ofSize: 11.5)
        explain.textColor = .tertiaryLabelColor
        explain.preferredMaxLayoutWidth = width
        let v = NSStackView(views: [top, explain])
        v.orientation = .vertical; v.alignment = .leading; v.spacing = 3
        v.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        top.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
    }

    private func makeRow(_ c: Relief.Candidate, width: CGFloat) -> NSView {
        let textW = width - 210
        let title = NSTextField(labelWithString: c.title)
        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.widthAnchor.constraint(lessThanOrEqualToConstant: textW).isActive = true
        let detail = NSTextField(wrappingLabelWithString: c.detail)
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = textW
        var lines: [NSView] = [title, detail]
        func note(_ s: String, _ color: NSColor, symbol: String) {
            let l = NSTextField(wrappingLabelWithString: s)
            l.font = .systemFont(ofSize: 11.5); l.textColor = color
            l.preferredMaxLayoutWidth = textW - 16
            guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { lines.append(l); return }
            let icon = NSImageView(image: img)
            icon.symbolConfiguration = .init(pointSize: 10.5, weight: .semibold)
            icon.contentTintColor = color
            let h = NSStackView(views: [icon, l])
            h.orientation = .horizontal; h.alignment = .firstBaseline; h.spacing = 4
            lines.append(h)
        }
        if let e = errors[c.id] { note("Not done: \(e).", .systemRed, symbol: "xmark.circle.fill") }
        else if attempted.contains(c.id) && !working.contains(c.id) {
            note("Still running after the request. Click again to force it.", .systemOrange, symbol: "exclamationmark.circle.fill")
        }
        if let s = c.suggested { note("Suggested. " + s, .controlAccentColor, symbol: "checkmark.circle.fill") }
        if let w = c.warning { note(w, .secondaryLabelColor, symbol: "info.circle") }
        let text = NSStackView(views: lines)
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 3

        let size = NSTextField(labelWithString: c.shown)
        size.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        size.alignment = .right
        size.widthAnchor.constraint(equalToConstant: 84).isActive = true

        let busy = working.contains(c.id)
        let force = attempted.contains(c.id)
        let b = NSButton(title: busy ? "Working\u{2026}" : force ? "Force \(c.button)" : c.button,
                         target: self, action: #selector(rowClicked(_:)))
        b.bezelStyle = .rounded
        b.isEnabled = !busy
        if force { b.bezelColor = .systemOrange }
        b.identifier = NSUserInterfaceItemIdentifier(c.id)
        b.widthAnchor.constraint(equalToConstant: 104).isActive = true

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
                let live = Set((found + self.cacheRows).map(\.id))
                self.attempted.formIntersection(live)
                self.errors = self.errors.filter { live.contains($0.key) }
                self.candidates = found
                self.renderReadout()
                self.renderList()
                self.onChange()
            }
        }
    }

    /// Cache sizes take seconds (du), so they arrive on their own.
    func measureCaches() {
        guard !demo, !cachesMeasuring else { return }
        cachesMeasuring = true
        renderList()
        let diskLow = (latest ?? baseline)?.diskLow ?? false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rows = Relief.caches(diskLow: diskLow)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.cachesMeasuring = false
                self.cacheRows = rows
                self.renderList()
            }
        }
    }

    private func run(_ list: [Relief.Candidate]) {
        guard !list.isEmpty else { return }
        for c in list { working.insert(c.id); errors[c.id] = nil }
        renderList()
        let forced = Set(list.filter { attempted.contains($0.id) }.map(\.id))
        let touchedDisk = list.contains { $0.section == .disk }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var errs: [String: String] = [:]
            for c in list { if let e = Relief.perform(c, force: forced.contains(c.id)) { errs[c.id] = e } }
            DispatchQueue.main.async {
                guard let self = self else { return }
                for c in list { self.working.remove(c.id); self.attempted.insert(c.id) }
                self.errors.merge(errs) { $1 }
                let ok = list.count - errs.count
                self.status = ok > 0 ? "Done: \(ok) item\(ok == 1 ? "" : "s"). Measuring again once memory settles\u{2026}"
                                     : "Nothing was closed."
                self.renderList()
                // Apps may show a save prompt; memory takes a moment to come back.
                self.recheck(after: 3)
                if touchedDisk {
                    self.cacheRows.removeAll { c in list.contains { $0.id == c.id } && errs[c.id] == nil }
                    self.measureCaches()
                }
            }
        }
    }

    @objc private func rowClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let c = rows.first(where: { $0.id == id }) else { return }
        run([c])
    }

    @objc private func cleanSuggested() {
        run(rows.filter { $0.suggested != nil && !working.contains($0.id) })
    }

    @objc private func recheckClicked() {
        status = "Measuring again\u{2026}"
        recheck()
        measureCaches()
    }

    @objc private func doneClicked() { close() }

    @objc private func openMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    // MARK: Debug: the window filled with the 2026-11-09 situation

    static func demo() -> ReliefWindow {
        let w = ReliefWindow(onChange: {}, demo: true)
        let now = Date()
        func proc(_ pid: pid_t) -> Relief.Proc {
            Relief.Proc(pid: pid, ppid: 1, startSec: 0, startUsec: 0, path: "", footprint: 0, tdev: 0, started: now)
        }
        let home = SpeedUp.home
        w.baseline = Relief.Reading(freePct: 23, swapUsed: 11_000 << 20, compressed: 6_100 << 20,
                                    diskFree: 14 << 30, loadPerCore: 9.8, at: now.addingTimeInterval(-40))
        w.latest = Relief.Reading(freePct: 75, swapUsed: 4_900 << 20, compressed: 2_300 << 20,
                                  diskFree: 14 << 30, loadPerCore: 1.6, at: now)
        w.status = "Cleared 25 summarizers that had leaked, 11.8 GB in memory."
        let job = SpeedUp.Job(kind: .xcodebuild(pid: 0), pid: 0, title: "Xcode test: Lumos (scheme Lumos)",
                              detail: "running 24m \u{00B7} 114 processes", command: "demo", cpu: 412)
        w.candidates = [
            .init(id: "a", section: .sessions, title: "Claude session in ~/lumos-ears",
                  detail: "running 3h 12m \u{00B7} no typing for 2h 40m \u{00B7} tmux claude-retry-5531, detached \u{00B7} 9 processes",
                  bytes: 1_900 << 20, suggested: "Detached, so no window shows it.", warning: nil,
                  action: .terminate(proc(1))),
            .init(id: "b", section: .sessions, title: "Claude session in ~/claude-usage-widget",
                  detail: "running 41m \u{00B7} typed in just now \u{00B7} tmux claude-retry-6739 \u{00B7} 6 processes",
                  bytes: 1_200 << 20, suggested: nil, warning: nil, action: .terminate(proc(2))),
            .init(id: "j", section: .heavy, title: job.title, detail: job.detail, bytes: 2_100 << 20,
                  metric: "412% CPU", suggested: "Using 4 cores right now.", warning: nil, action: .stopJob(job)),
            .init(id: "s", section: .heavy, title: "iPhone 18 Pro Max",
                  detail: "simulator, booted 23m \u{00B7} 146 processes", bytes: 3_400 << 20,
                  suggested: "A booted simulator keeps a whole iPhone in memory.", warning: nil,
                  action: .shutdownSimulator(udid: "demo")),
            .init(id: "c", section: .apps, title: "Warp", detail: "open 2h 4m \u{00B7} 8 processes", bytes: 620 << 20,
                  suggested: nil, warning: "Quitting it also ends the 2 Claude sessions running inside it.",
                  action: .quitApp(NSRunningApplication.current)),
            .init(id: "d", section: .apps, title: "Spark Desktop", detail: "open 2h 4m \u{00B7} 7 processes", bytes: 1_400 << 20,
                  suggested: nil, warning: nil, action: .quitApp(NSRunningApplication.current)),
            .init(id: "e", section: .background, title: "ears_server.py (python)",
                  detail: "running 2h 5m \u{00B7} 2 processes \u{00B7} pid 1902", bytes: 6_400 << 20, suggested: nil,
                  warning: "If a launch agent keeps it alive, it starts again on its own.", action: .terminate(proc(5))),
        ]
        w.cacheRows = [
            .init(id: "u", section: .disk, title: "uv package cache", detail: "~/.cache/uv", bytes: 15 << 30,
                  suggested: "The disk is nearly full.", warning: nil,
                  action: .clearCache(SpeedUp.Cache(name: "uv", path: home + "/.cache/uv", bytes: 15 << 30, viaUV: true))),
        ]
        w.attempted = ["d"]
        w.scanning = false
        w.renderReadout(); w.renderList()
        return w
    }

    /// Offscreen render of the demo window (light only: offscreen captures draw
    /// no window background, so dark text lands on white).
    static func snapshot(to url: URL) {
        let w = demo()
        guard let win = w.window, let view = win.contentView else { return }
        win.appearance = NSAppearance(named: .aqua)
        win.setContentSize(NSSize(width: ReliefWindow.width, height: 1180))
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)  \(Int(view.bounds.width))x\(Int(view.bounds.height))")
    }
}
