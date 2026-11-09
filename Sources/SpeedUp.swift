import Cocoa

// ─────────────────────────────────────────────────────────────────────────────
// Speed Up…
//
// One dialog for a slow Mac, added 2026-11-07 after a Lumos UI test in the
// iPhone simulator (114 runnable processes) drove the load average to 515 on
// a disk at 99%. It lists, as checkboxes:
//   - leaks the reaper already knows about (ticked: they are always safe),
//   - heavy jobs: Xcode builds and tests, booted simulators, ffmpeg renders
//     (never ticked: they belong to someone's work, the click is the consent),
//   - rebuildable caches with their sizes (ticked only while the disk is low).
// Nothing runs until "Speed Up" is pressed. Every job is re-identified by its
// full command line just before it is signalled; caches come from a fixed list.
// Actions are logged to ~/.claude-mem/hygiene.log like the reaper's.
// ─────────────────────────────────────────────────────────────────────────────

enum SpeedUp {

    // MARK: Model

    struct Job {
        enum Kind { case xcodebuild(pid: pid_t), render(pid: pid_t), simulator(udid: String) }
        let kind: Kind
        let title: String          // "Stop Xcode test: Lumos (scheme Lumos)"
        let detail: String         // "24m · 114 processes · 380% CPU"
        let command: String        // the root's full command line, re-checked before any signal
        let cpu: Double
    }

    struct Cache {
        let name: String
        let path: String
        let bytes: UInt64?         // nil: not measured in time
        let viaUV: Bool
    }

    struct Offer {
        var jobs: [Job] = []
        var caches: [Cache] = []
    }

    static let home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()

    /// Caches that rebuild themselves on next use. Fixed list, nothing else is
    /// ever deleted. Xcode DeviceSupport and DerivedData are left out on
    /// purpose (Martin's call, 2026-11-07).
    static var cacheList: [(name: String, path: String, viaUV: Bool)] {[
        ("uv package cache", home + "/.cache/uv", true),
        ("Codex cache", home + "/Library/Caches/com.openai.codex", false),
        ("Playwright browsers", home + "/Library/Caches/ms-playwright", false),
        ("Adobe Camera Raw cache", home + "/Library/Caches/Adobe Camera Raw 2", false),
        ("pip cache", home + "/Library/Caches/pip", false),
    ]}

    static let minCacheBytes: UInt64 = 100 << 20     // smaller ones are not worth a line

    // MARK: Gathering (off the main thread)

    struct Proc { let pid: pid_t; let ppid: pid_t; let age: TimeInterval; let cpu: Double; let command: String }

    static func processTable() -> [Proc] {
        guard let out = run("/bin/ps", ["-axww", "-o", "pid=,ppid=,etime=,pcpu=,command="], timeout: 10) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard f.count == 5, let pid = pid_t(f[0]), let ppid = pid_t(f[1]), let cpu = Double(f[3]) else { return nil }
            return Proc(pid: pid, ppid: ppid, age: elapsed(String(f[2])), cpu: cpu, command: String(f[4]))
        }
    }

    /// ps etime: [[dd-]hh:]mm:ss
    static func elapsed(_ s: String) -> TimeInterval {
        var days = 0.0, rest = Substring(s)
        if let dash = s.firstIndex(of: "-") { days = Double(s[..<dash]) ?? 0; rest = s[s.index(after: dash)...] }
        let parts = rest.split(separator: ":").map { Double($0) ?? 0 }
        let secs = parts.reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
        return days * 86400 + secs
    }

    static func gather() -> Offer {
        let procs = processTable()
        var children: [pid_t: [pid_t]] = [:]
        var byPid: [pid_t: Proc] = [:]
        for p in procs { children[p.ppid, default: []].append(p.pid); byPid[p.pid] = p }
        func tree(_ root: pid_t) -> (count: Int, cpu: Double) {
            var stack = [root], n = 0, cpu = 0.0, seen = Set<pid_t>()
            while let p = stack.popLast() {
                guard seen.insert(p).inserted, let info = byPid[p] else { continue }
                n += 1; cpu += info.cpu
                stack += children[p] ?? []
            }
            return (n, cpu)
        }
        func detail(_ p: Proc, _ t: (count: Int, cpu: Double)) -> String {
            var d = Style.duration(p.age)
            if t.count > 1 { d += " \u{00B7} \(t.count) processes" }
            return d + String(format: " \u{00B7} %.0f%% CPU", t.cpu)
        }

        var offer = Offer()
        for p in procs {
            let argv = p.command.split(separator: " ").map(String.init)
            guard let exe = argv.first else { continue }
            if exe.hasSuffix("/xcodebuild") {
                func value(_ flag: String) -> String? {
                    argv.firstIndex(of: flag).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
                }
                let project = (value("-workspace") ?? value("-project"))
                    .map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
                let isTest = argv.contains("test") || argv.contains("test-without-building")
                var title = "Stop Xcode \(isTest ? "test" : "build")"
                if let project = project { title += ": \(project)" }
                if let scheme = value("-scheme"), scheme != project { title += " (scheme \(scheme))" }
                let t = tree(p.pid)
                offer.jobs.append(Job(kind: .xcodebuild(pid: p.pid), title: title, detail: detail(p, t),
                                      command: p.command, cpu: t.cpu))
            } else if (exe as NSString).lastPathComponent == "ffmpeg" {
                let t = tree(p.pid)
                offer.jobs.append(Job(kind: .render(pid: p.pid), title: "Stop ffmpeg render (pid \(p.pid))",
                                      detail: detail(p, t), command: p.command, cpu: t.cpu))
            }
        }

        for sim in bootedSimulators() {
            // Every process of a simulated device descends from its launchd_sim.
            let root = procs.first { $0.command.contains("launchd_sim") && $0.command.contains(sim.udid) }
            let t: (count: Int, cpu: Double) = root.map { tree($0.pid) } ?? (count: 0, cpu: 0)
            let d = root.map { detail($0, t) } ?? "booted"
            offer.jobs.append(Job(kind: .simulator(udid: sim.udid), title: "Shut down simulator: \(sim.name)",
                                  detail: d, command: sim.udid, cpu: t.cpu))
        }
        offer.jobs.sort { $0.cpu > $1.cpu }

        // Sizes in parallel, 15 s cap: a dialog that never opens is worse
        // than one that says "size not measured".
        let list = cacheList.filter { FileManager.default.fileExists(atPath: $0.path) }
        var sizes = [UInt64?](repeating: nil, count: list.count)
        let lock = NSLock(), group = DispatchGroup()
        for (i, c) in list.enumerated() {
            DispatchQueue.global(qos: .utility).async(group: group) {
                let kb = run("/usr/bin/du", ["-sk", c.path], timeout: 15)?
                    .split(separator: "\t").first.flatMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
                lock.lock(); sizes[i] = kb.map { $0 * 1024 }; lock.unlock()
            }
        }
        _ = group.wait(timeout: .now() + 16)
        lock.lock(); let measured = sizes; lock.unlock()
        for (i, c) in list.enumerated() {
            let b = measured[i]
            if let b = b, b < minCacheBytes { continue }
            offer.caches.append(Cache(name: c.name, path: c.path, bytes: b, viaUV: c.viaUV))
        }
        return offer
    }

    static func bootedSimulators() -> [(name: String, udid: String)] {
        guard let out = run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"], timeout: 15),
              let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]] else { return [] }
        return runtimes.values.flatMap { $0 }.compactMap { d in
            guard (d["state"] as? String) == "Booted", let name = d["name"] as? String,
                  let udid = d["udid"] as? String else { return nil }
            return (name, udid)
        }
    }

    // MARK: Dialog (main thread)

    private static var busy = false

    static func present(suspected: [ProcInfo], assessment: HealthAssessment?,
                        reapLeaks: @escaping () -> Void, recheck: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let offer = gather()
            DispatchQueue.main.async {
                defer { busy = false }
                show(offer, suspected: suspected, assessment: assessment, reapLeaks: reapLeaks, recheck: recheck)
            }
        }
    }

    private static func show(_ offer: Offer, suspected: [ProcInfo], assessment: HealthAssessment?,
                             reapLeaks: @escaping () -> Void, recheck: @escaping () -> Void) {
        let d = makeDialog(offer, suspected: suspected, assessment: assessment)
        NSApp.activate(ignoringOtherApps: true)
        guard d.alert.runModal() == .alertFirstButtonReturn, !d.nothing else { return }

        let (reap, jobs, caches) = d.chosen()
        if reap { reapLeaks() }
        guard !jobs.isEmpty || !caches.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let summary = perform(jobs: jobs, caches: caches)
            DispatchQueue.main.async {
                HealthNotifier.post(title: "Speed Up", body: summary)
                recheck()
            }
        }
    }

    struct Dialog {
        let alert: NSAlert
        let nothing: Bool
        let chosen: () -> (reap: Bool, jobs: [Job], caches: [Cache])
    }

    /// Builds the alert without running it, so `--speedup-snapshot` can render it.
    static func makeDialog(_ offer: Offer, suspected: [ProcInfo], assessment: HealthAssessment?) -> Dialog {
        let diskLow = (assessment?.level(for: .disk) ?? .ok) != .ok
        let alert = NSAlert()
        alert.messageText = "Speed Up"
        if let icon = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "Speed Up") {
            alert.icon = icon.withSymbolConfiguration(.init(pointSize: 48, weight: .regular))
        }
        var info = assessment.map { a in
            a.reasons.isEmpty ? "The Mac looks fine right now." : "Now: " + a.reasons.prefix(4).joined(separator: " \u{00B7} ")
        } ?? ""
        let nothing = suspected.isEmpty && offer.jobs.isEmpty && offer.caches.isEmpty
        info += nothing ? "\n\nNothing to stop or clear." : "\n\nTick what to do. Nothing runs until you press Speed Up."
        alert.informativeText = info

        let width: CGFloat = 470
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        func header(_ s: String) {
            let l = NSTextField(labelWithString: s.uppercased())
            l.font = .systemFont(ofSize: 10, weight: .semibold)
            l.textColor = .secondaryLabelColor
            stack.addArrangedSubview(l)
            stack.setCustomSpacing(4, after: l)
        }
        func box(_ title: String, _ sub: String, on: Bool) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            b.state = on ? .on : .off
            b.lineBreakMode = .byTruncatingTail
            b.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
            stack.addArrangedSubview(b)
            if !sub.isEmpty {
                // Indented under the checkbox text by a fixed spacer: the
                // outer stack already pins every leading edge.
                let l = NSTextField(labelWithString: sub)
                l.font = .systemFont(ofSize: 11)
                l.textColor = .secondaryLabelColor
                l.lineBreakMode = .byTruncatingMiddle
                l.widthAnchor.constraint(lessThanOrEqualToConstant: width - 20).isActive = true
                let spacer = NSView()
                spacer.widthAnchor.constraint(equalToConstant: 14).isActive = true
                let row = NSStackView(views: [spacer, l])
                row.orientation = .horizontal
                row.spacing = 6
                stack.addArrangedSubview(row)
                stack.setCustomSpacing(8, after: row)
            }
            return b
        }

        var leakBox: NSButton?
        if !suspected.isEmpty {
            header("Leaks")
            let bytes = suspected.reduce(0) { $0 + $1.rss }
            leakBox = box("Reap \(suspected.count) leaked process\(suspected.count == 1 ? "" : "es") (\(Style.bytes(bytes)))",
                          "claude-mem summarizers and orphaned headless Chrome", on: true)
        }
        var jobBoxes: [(NSButton, Job)] = []
        if !offer.jobs.isEmpty {
            header("Heavy jobs")
            for j in offer.jobs { jobBoxes.append((box(j.title, j.detail, on: false), j)) }
        }
        var cacheBoxes: [(NSButton, Cache)] = []
        if !offer.caches.isEmpty {
            header(diskLow ? "Rebuildable caches (disk is low)" : "Rebuildable caches")
            for c in offer.caches {
                let size = c.bytes.map { Style.bytes($0) } ?? "size not measured"
                cacheBoxes.append((box("Clear \(c.name) (\(size))", abbreviate(c.path), on: diskLow), c))
            }
        }

        if !nothing {
            let fit = stack.fittingSize
            stack.frame = NSRect(x: 0, y: 0, width: width, height: fit.height)
            alert.accessoryView = stack
            alert.addButton(withTitle: "Speed Up")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "OK")
        }
        return Dialog(alert: alert, nothing: nothing) {
            (leakBox?.state == .on,
             jobBoxes.filter { $0.0.state == .on }.map(\.1),
             cacheBoxes.filter { $0.0.state == .on }.map(\.1))
        }
    }

    /// Debug: the dialog with synthetic rows (the 2026-11-07 situation), as a PNG.
    static func snapshot(to url: URL, dark: Bool) {
        var offer = Offer()
        offer.jobs = [
            Job(kind: .simulator(udid: "demo"), title: "Shut down simulator: iPhone 18 Pro Max",
                detail: "23m \u{00B7} 146 processes \u{00B7} 412% CPU", command: "demo", cpu: 412),
            Job(kind: .xcodebuild(pid: 0), title: "Stop Xcode test: Lumos",
                detail: "24m \u{00B7} 3 processes \u{00B7} 38% CPU", command: "demo", cpu: 38),
            Job(kind: .xcodebuild(pid: 0), title: "Stop Xcode build: RobotAlive (scheme RobotAliveStudio)",
                detail: "1m \u{00B7} 9 processes \u{00B7} 290% CPU", command: "demo", cpu: 290),
        ]
        offer.caches = [
            Cache(name: "uv package cache", path: home + "/.cache/uv", bytes: 39 << 30, viaUV: true),
            Cache(name: "Codex cache", path: home + "/Library/Caches/com.openai.codex", bytes: 4_900 << 20, viaUV: false),
            Cache(name: "Playwright browsers", path: home + "/Library/Caches/ms-playwright", bytes: 2_900 << 20, viaUV: false),
        ]
        let now = Date()
        let leak = ProcInfo(pid: 9000, ppid: 5735, rss: 1_870 << 20, startSec: Int64(now.timeIntervalSince1970) - 3600,
                            startUsec: 0, started: now.addingTimeInterval(-3600), path: "/demo/claude", args: ["claude"],
                            ownerPid: 5735, owner: "claude-mem worker")
        let sample = HealthSample(memFreePct: 14, memSource: "kern.memorystatus_level", vm: nil,
                                  swap: SwapStats(usedBytes: 11_200 << 20, totalBytes: 12_288 << 20),
                                  load: LoadStats(load1: 515, load5: 477, load15: 319), ncpu: 14,
                                  kernelPressure: nil, sampledAt: now, claude: ClaudeStack(), sampleMillis: 1,
                                  validity: Validity(memory: true, vm: false, swap: true, load: true, disk: true),
                                  disk: DiskStats(freeBytes: 8_500 << 20, totalBytes: 926 << 30))
        let d = makeDialog(offer, suspected: [leak], assessment: HealthScorer.assess(sample))
        d.alert.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        d.alert.layout()
        guard let view = d.alert.window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)  \(Int(view.bounds.width))x\(Int(view.bounds.height))")
    }

    // MARK: Actions (off the main thread)

    static func perform(jobs: [Job], caches: [Cache]) -> String {
        var done: [String] = [], failed: [String] = []
        for j in jobs {
            switch j.kind {
            case .xcodebuild(let pid), .render(let pid):
                // Same pid, same full command line, or nothing is signalled.
                let now = run("/bin/ps", ["-ww", "-o", "command=", "-p", "\(pid)"], timeout: 5)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if now == j.command, kill(pid, SIGTERM) == 0 {
                    done.append(j.title.replacingOccurrences(of: "Stop ", with: "stopped "))
                    HealthAction.log("speed-up: SIGTERM \(pid) \(j.title)")
                } else {
                    failed.append(j.title + " (already gone or changed)")
                }
            case .simulator(let udid):
                if run("/usr/bin/xcrun", ["simctl", "shutdown", udid], timeout: 60) != nil {
                    done.append(j.title.replacingOccurrences(of: "Shut down", with: "shut down"))
                    HealthAction.log("speed-up: simctl shutdown \(udid) \(j.title)")
                } else {
                    failed.append(j.title)
                }
            }
        }
        var freed: UInt64 = 0
        for c in caches {
            guard isAllowedCache(c.path) else { failed.append(c.name); continue }
            var ok = false
            if c.viaUV, let uv = uvBinary() {
                ok = run(uv, ["cache", "clean"], timeout: 600) != nil
            }
            if !ok {
                ok = (try? FileManager.default.removeItem(atPath: c.path)) != nil
                    || !FileManager.default.fileExists(atPath: c.path)
            }
            if ok {
                freed += c.bytes ?? 0
                done.append("cleared \(c.name)")
                HealthAction.log("speed-up: cleared \(c.path) (\(c.bytes.map { Style.bytes($0) } ?? "size unknown"))")
            } else {
                failed.append(c.name)
            }
        }
        var s = done.isEmpty ? "Nothing changed" : done.joined(separator: ", ").capitalizedFirst
        if freed > 0 { s += " \u{00B7} about \(Style.bytes(freed)) freed" }
        if !failed.isEmpty { s += " \u{00B7} not done: " + failed.joined(separator: ", ") }
        return s
    }

    /// Only an exact entry of `cacheList`: a path that drifted is never deleted.
    static func isAllowedCache(_ path: String) -> Bool {
        cacheList.contains { $0.path == path } && path.hasPrefix(home + "/") && path.count > home.count + 8
    }

    static func uvBinary() -> String? {
        [home + "/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv", home + "/.cargo/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func abbreviate(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Runs a tool and returns stdout, or nil on a non-zero exit or timeout.
    @discardableResult
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var data = Data()
        let reader = DispatchQueue(label: "speedup.read")
        let readDone = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if readDone.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Debug

    static func dryRun() -> String {
        let offer = gather()
        var lines = ["heavy jobs (\(offer.jobs.count)):"]
        lines += offer.jobs.map { "  \($0.title)  [\($0.detail)]" }
        lines.append("rebuildable caches (\(offer.caches.count)):")
        lines += offer.caches.map { "  \($0.name)  \($0.bytes.map { Style.bytes($0) } ?? "not measured")  \(abbreviate($0.path))" }
        if let d = HealthSensor.diskStats() {
            lines.append("disk: \(Style.bytes(d.freeBytes)) free of \(Style.bytes(d.totalBytes))")
        }
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
