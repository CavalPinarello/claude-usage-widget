import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Heavy jobs and rebuildable caches
//
// Added 2026-11-07 as the "Speed Up" dialog, after a Lumos UI test in the
// iPhone simulator (114 runnable processes) drove the load average to 515 on
// a disk at 99%. Since 2026-11-09 these are two sections of the one Clean Up
// window (Relief.swift); this file only finds them and acts on them.
//   - heavy jobs: Xcode builds and tests, ffmpeg renders. Stopped with
//     SIGTERM only if the pid still runs the same full command line.
//   - caches: a FIXED list of folders that rebuild themselves on next use.
//     Nothing outside the list is ever deleted.
// Actions are logged to ~/.claude-mem/hygiene.log like the reaper's.
// ─────────────────────────────────────────────────────────────────────────────

enum SpeedUp {

    struct Job {
        enum Kind { case xcodebuild(pid: pid_t), render(pid: pid_t) }
        let kind: Kind
        let pid: pid_t
        let title: String          // "Xcode test: Lumos (scheme Lumos)"
        let detail: String         // "24m · 114 processes"
        let command: String        // the root's full command line, re-checked before any signal
        let cpu: Double
    }

    struct Cache {
        let name: String
        let path: String
        let bytes: UInt64?         // nil: not measured in time
        let viaUV: Bool
    }

    static let home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()

    /// Caches that rebuild themselves on next use. Xcode DeviceSupport and
    /// DerivedData are left out on purpose (Martin's call, 2026-11-07).
    static var cacheList: [(name: String, path: String, viaUV: Bool)] {[
        ("uv package cache", home + "/.cache/uv", true),
        ("Codex cache", home + "/Library/Caches/com.openai.codex", false),
        ("Playwright browsers", home + "/Library/Caches/ms-playwright", false),
        ("Adobe Camera Raw cache", home + "/Library/Caches/Adobe Camera Raw 2", false),
        ("pip cache", home + "/Library/Caches/pip", false),
    ]}

    static let minCacheBytes: UInt64 = 100 << 20     // smaller ones are not worth a line

    // MARK: Finding

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

    /// Xcode builds/tests and ffmpeg renders, busiest first.
    static func gatherJobs(_ procs: [Proc]) -> [Job] {
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
            "running \(Style.duration(p.age))" + (t.count > 1 ? " \u{00B7} \(t.count) processes" : "")
        }

        var jobs: [Job] = []
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
                var title = "Xcode \(isTest ? "test" : "build")"
                if let project = project { title += ": \(project)" }
                if let scheme = value("-scheme"), scheme != project { title += " (scheme \(scheme))" }
                let t = tree(p.pid)
                jobs.append(Job(kind: .xcodebuild(pid: p.pid), pid: p.pid, title: title,
                                detail: detail(p, t), command: p.command, cpu: t.cpu))
            } else if (exe as NSString).lastPathComponent == "ffmpeg" {
                let t = tree(p.pid)
                jobs.append(Job(kind: .render(pid: p.pid), pid: p.pid, title: "ffmpeg render",
                                detail: detail(p, t) + " \u{00B7} pid \(p.pid)", command: p.command, cpu: t.cpu))
            }
        }
        return jobs.sorted { $0.cpu > $1.cpu }
    }

    /// Sizes in parallel with a 15 s cap: a row that says "size not measured"
    /// beats a window that waits.
    static func gatherCaches() -> [Cache] {
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
        var out: [Cache] = []
        for (i, c) in list.enumerated() {
            let b = measured[i]
            if let b = b, b < minCacheBytes { continue }
            out.append(Cache(name: c.name, path: c.path, bytes: b, viaUV: c.viaUV))
        }
        return out.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
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

    // MARK: Acting (off the main thread). nil means done.

    static func stop(_ j: Job, force: Bool) -> String? {
        // Same pid, same full command line, or nothing is signalled.
        let now = run("/bin/ps", ["-ww", "-o", "command=", "-p", "\(j.pid)"], timeout: 5)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = now, !current.isEmpty else { return nil }          // already gone
        guard current == j.command else { return "it is now running something else" }
        guard kill(j.pid, force ? SIGKILL : SIGTERM) == 0 else { return "the signal was refused" }
        HealthAction.log("clean-up: \(force ? "SIGKILL" : "SIGTERM") \(j.pid) \(j.title)")
        return nil
    }

    static func clear(_ c: Cache) -> String? {
        guard isAllowedCache(c.path) else { return "it is not on the list of rebuildable caches" }
        var ok = false
        if c.viaUV, let uv = uvBinary() {
            ok = run(uv, ["cache", "clean"], timeout: 600) != nil
        }
        if !ok {
            ok = (try? FileManager.default.removeItem(atPath: c.path)) != nil
                || !FileManager.default.fileExists(atPath: c.path)
        }
        guard ok else { return "the folder could not be removed" }
        HealthAction.log("clean-up: cleared \(c.path) (\(c.bytes.map { Style.bytes($0) } ?? "size unknown"))")
        return nil
    }

    /// Only an exact entry of `cacheList`: a path that drifted is never deleted.
    static func isAllowedCache(_ path: String) -> Bool {
        cacheList.contains { $0.path == path } && path.hasPrefix(home + "/") && path.count > home.count + 8
    }

    static func uvBinary() -> String? {
        [home + "/.local/bin/uv", home + "/.homebrew/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv", home + "/.cargo/bin/uv"]
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
}
