import Cocoa
import UserNotifications

// ─────────────────────────────────────────────────────────────────────────────
// Mac health
//
// Senses the machine natively (Mach + libproc: no `ps`, no shell), scores it,
// and reaps the two Claude-side leaks that took this Mac down on 2026-09-19:
//   1. claude-mem's worker (`bun …/plugin/scripts/worker-service.cjs`) spawns
//      one headless `claude --output-format stream-json --input-format
//      stream-json` summarizer per session and never reaps it (144 of them:
//      8.5 GB resident, load average 88). Only the worker's own children
//      count: the args alone are a public CLI mode anyone's script may use,
//      and the worker itself already kills any ppid-1 leftover every 5 min.
//   2. headless Chrome on a throwaway profile (/tmp, /var/folders) orphaned
//      to launchd by screenshot automation.
// The fingerprints are a strict subset of ~/.local/bin/claude-hygiene's, so
// the widget never kills what the bash tool would keep; both append to
// ~/.claude-mem/hygiene.log. Every signal re-verifies identity and fingerprint,
// and an unknown reading never authorises a kill.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Model

struct ProcInfo: Encodable {
    let pid: pid_t
    let ppid: pid_t
    let rss: UInt64
    let startSec: Int64     // pbi_start_tvsec, raw: the identity check compares these
    let startUsec: Int64    // pbi_start_tvusec
    let started: Date       // for display
    let path: String        // resolved executable (proc_pidpath)
    let args: [String]      // argv as invoked (KERN_PROCARGS2)
    var ownerPid: pid_t?    // summarizers only: the worker that vouches for it
    var owner: String?      // "claude-mem worker"

    var age: TimeInterval { max(0, Date().timeIntervalSince(started)) }

    /// "52692@1758300000.123456": what the audit log records per kill.
    var identityString: String { "\(pid)@\(startSec)." + String(format: "%06d", startUsec) }

    private enum CodingKeys: String, CodingKey { case pid, ppid, rss, started, age, path, args, ownerPid, owner }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pid, forKey: .pid)
        try c.encode(ppid, forKey: .ppid)
        try c.encode(rss, forKey: .rss)
        try c.encode(started, forKey: .started)
        try c.encode(Int(age), forKey: .age)
        try c.encode(path, forKey: .path)
        try c.encode(Array(args.prefix(3)), forKey: .args)   // keep the JSON short
        try c.encodeIfPresent(ownerPid, forKey: .ownerPid)
        try c.encodeIfPresent(owner, forKey: .owner)
    }
}

struct ClaudeStack: Encodable {
    var interactiveSessions: [ProcInfo] = []   // never killed
    var summarizers: [ProcInfo] = []           // the claude-mem worker's own stream-json children
    var headlessChrome: [ProcInfo] = []        // orphaned (ppid 1) mains on a throwaway profile
    var chromeChildren: [ProcInfo] = []        // every direct child of those mains (helpers or not)
    var headlessChromeIgnored = 0              // orphaned headless mains on a persistent profile
    var totalRSS: UInt64 = 0                   // sum of everything above

    var oldestSession: ProcInfo? { interactiveSessions.min { $0.started < $1.started } }
}

struct VMStats: Encodable { var freeBytes: UInt64; var compressedBytes: UInt64; var wiredBytes: UInt64; var inactiveBytes: UInt64 }
struct SwapStats: Encodable { var usedBytes: UInt64; var totalBytes: UInt64 }
struct LoadStats: Encodable { var load1: Double; var load5: Double; var load15: Double }
/// The data volume, as `df` reports it (f_bavail: what a normal process can
/// still write, purgeable space not counted). Swap files live on the same
/// container, so this is also the room swap has left to grow.
struct DiskStats: Encodable { var freeBytes: UInt64; var totalBytes: UInt64 }

/// Which readings are real. A sensor that failed is nil in the sample and
/// false here; nothing downstream may treat a missing reading as a number.
struct Validity: Encodable { var memory: Bool; var vm: Bool; var swap: Bool; var load: Bool; var disk: Bool = false }

struct HealthSample: Encodable {
    var memFreePct: Int?         // kern.memorystatus_level (what `memory_pressure` prints), or a vm_stat fallback
    var memSource: String        // "kern.memorystatus_level" | "vm_stat fallback" | "unavailable"
    var vm: VMStats?
    var swap: SwapStats?
    var load: LoadStats?
    var ncpu: Int
    var kernelPressure: String?  // "critical" | "warning" when a kernel pressure event triggered this sample
    var sampledAt: Date
    var claude: ClaudeStack
    var sampleMillis: Double     // how long the sample took
    var validity: Validity
    var disk: DiskStats? = nil

    var loadPerCore: Double? {
        guard let l = load else { return nil }
        return ncpu > 0 ? l.load1 / Double(ncpu) : l.load1
    }
}

// MARK: - Sensing

enum HealthSensor {

    private static let SZOMB: UInt32 = 5           // sys/proc.h; zombies have no argv or path
    private static let pathCapacity = 4 * Int(MAXPATHLEN)   // PROC_PIDPATHINFO_MAXSIZE
    static let maxArgc = 4096

    /// $HOME as the environment says (launchd sets it), not the passwd entry,
    /// so the install paths below resolve for the user who is logged in.
    /// Read once: building the environment dictionary per process is slow.
    static let home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    static let claudeVersionsDir: String = home + "/.local/share/claude/versions/"
    static let claudeLocalBin: String = home + "/.local/bin/claude"
    static let chromeMainSuffix = "/Google Chrome.app/Contents/MacOS/Google Chrome"

    static func sample(kernelPressure: String? = nil) -> HealthSample {
        let t0 = DispatchTime.now()

        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var pageSize: vm_size_t = 0
        let page: UInt64 = host_page_size(host, &pageSize) == KERN_SUCCESS && pageSize > 0
            ? UInt64(pageSize) : 16384

        var vmRaw = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmRaw) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let vm: VMStats? = kr == KERN_SUCCESS
            ? VMStats(freeBytes: UInt64(vmRaw.free_count) * page,
                      compressedBytes: UInt64(vmRaw.compressor_page_count) * page,
                      wiredBytes: UInt64(vmRaw.wire_count) * page,
                      inactiveBytes: UInt64(vmRaw.inactive_count) * page)
            : nil

        var xsw = xsw_usage()
        var xswSize = MemoryLayout<xsw_usage>.size
        let swap: SwapStats? = sysctlbyname("vm.swapusage", &xsw, &xswSize, nil, 0) == 0
            && xswSize == MemoryLayout<xsw_usage>.size
            ? SwapStats(usedBytes: xsw.xsu_used, totalBytes: xsw.xsu_total) : nil

        var loads = [Double](repeating: 0, count: 3)
        let load: LoadStats? = getloadavg(&loads, 3) == 3
            ? LoadStats(load1: loads[0], load5: loads[1], load15: loads[2]) : nil

        let ncpu = Int(sysctlInt32("hw.ncpu") ?? Int32(ProcessInfo.processInfo.activeProcessorCount))

        // kern.memorystatus_level is the kernel's own "available memory" figure.
        // If it is missing, approximate from the page counts (free already
        // includes speculative on Darwin); if those are missing too, say so.
        let memFreePct: Int?
        let memSource: String
        if let level = sysctlInt32("kern.memorystatus_level"), (0...100).contains(level) {
            memFreePct = Int(level); memSource = "kern.memorystatus_level"
        } else if let vm = vm, ProcessInfo.processInfo.physicalMemory > 0 {
            let avail = vm.freeBytes + vm.inactiveBytes
            memFreePct = Int(min(100, avail * 100 / ProcessInfo.processInfo.physicalMemory))
            memSource = "vm_stat fallback"
        } else {
            memFreePct = nil; memSource = "unavailable"
        }

        let disk = diskStats()
        let stack = claudeStack()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6

        return HealthSample(
            memFreePct: memFreePct, memSource: memSource,
            vm: vm, swap: swap, load: load, ncpu: ncpu,
            kernelPressure: kernelPressure,
            sampledAt: Date(), claude: stack, sampleMillis: ms,
            validity: Validity(memory: memFreePct != nil, vm: vm != nil, swap: swap != nil,
                               load: load != nil, disk: disk != nil),
            disk: disk)
    }

    /// statfs on the data volume (where $HOME and the swap files live); "/" is
    /// the sealed system snapshot on modern macOS and always looks full.
    static func diskStats() -> DiskStats? {
        for path in ["/System/Volumes/Data", "/"] {
            var st = statfs()
            guard statfs(path, &st) == 0, st.f_blocks > 0 else { continue }
            let bs = UInt64(st.f_bsize)
            return DiskStats(freeBytes: UInt64(st.f_bavail) * bs, totalBytes: UInt64(st.f_blocks) * bs)
        }
        return nil
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else { return nil }
        return v
    }

    // MARK: Process enumeration (libproc)

    /// Walks every process we own once. The resolved executable path decides
    /// whether argv is fetched at all: only the Claude Code binary and the
    /// Chrome main binary are candidates. Anything that fails a call (exited,
    /// zombie, permission) is skipped silently, exactly like `ps` would drop it.
    static func claudeStack() -> ClaudeStack {
        let uid = getuid()
        var stack = ClaudeStack()

        let need = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard need > 0 else { return stack }
        var pids = [pid_t](repeating: 0, count: Int(need) / MemoryLayout<pid_t>.size + 64)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return stack }
        pids.removeLast(pids.count - Int(got) / MemoryLayout<pid_t>.size)

        var argBuf = [UInt8](repeating: 0, count: Int(sysctlInt32("kern.argmax") ?? 262_144))
        var pathBuf = [CChar](repeating: 0, count: pathCapacity)
        var mine: [(pid: pid_t, ppid: pid_t)] = []      // for the Chrome-children pass
        mine.reserveCapacity(pids.count)
        var parents: [pid_t: (path: String, args: [String])?] = [:]   // one lookup per parent per scan

        for pid in pids where pid > 1 {
            guard let (bsd, path) = probe(pid, uid: uid, pathBuf: &pathBuf) else { continue }
            let ppid = pid_t(bsd.pbi_ppid)
            mine.append((pid, ppid))

            guard isCandidatePath(path) else { continue }
            guard let args = arguments(pid, into: &argBuf) else { continue }   // unparseable argv fails closed
            let kind = classify(path: path, args: args, ppid: ppid) { parent in
                if let cached = parents[parent] { return cached }
                let fetched = parentInfo(parent, pathBuf: &pathBuf, argBuf: &argBuf)
                parents[parent] = fetched
                return fetched
            }

            switch kind {
            case .other:
                continue
            case .chromeIgnored:
                stack.headlessChromeIgnored += 1
                continue
            case .session, .summarizer, .chrome:
                break
            }
            var info = ProcInfo(pid: pid, ppid: ppid, rss: residentSize(pid),
                                startSec: Int64(bsd.pbi_start_tvsec), startUsec: Int64(bsd.pbi_start_tvusec),
                                started: startDate(bsd), path: path, args: args)
            switch kind {
            case .session:
                stack.interactiveSessions.append(info)
            case .summarizer(let owner):
                info.ownerPid = ppid
                info.owner = owner
                stack.summarizers.append(info)
            case .chrome:
                stack.headlessChrome.append(info)
            case .chromeIgnored, .other:
                break
            }
        }

        // Every direct child of an orphaned headless Chrome. Helpers die with
        // it; the reaper signals only real helpers and counts the rest as skipped.
        let mains = Set(stack.headlessChrome.map(\.pid))
        if !mains.isEmpty {
            for (pid, ppid) in mine where mains.contains(ppid) {
                guard let (bsd, path) = probe(pid, uid: uid, pathBuf: &pathBuf) else { continue }
                let args = arguments(pid, into: &argBuf) ?? []
                stack.chromeChildren.append(ProcInfo(pid: pid, ppid: ppid, rss: residentSize(pid),
                                                     startSec: Int64(bsd.pbi_start_tvsec),
                                                     startUsec: Int64(bsd.pbi_start_tvusec),
                                                     started: startDate(bsd), path: path, args: args))
            }
        }

        stack.totalRSS = (stack.interactiveSessions + stack.summarizers
                          + stack.headlessChrome + stack.chromeChildren)
            .reduce(0) { $0 + $1.rss }
        return stack
    }

    enum Kind: Equatable {
        case session
        case summarizer(owner: String)
        case chrome
        case chromeIgnored     // orphaned headless main on a persistent profile
        case other
    }

    /// Resolved-path pre-filter: the only executables whose argv is worth reading.
    static func isCandidatePath(_ path: String) -> Bool {
        isClaudePath(path) || path.hasSuffix(chromeMainSuffix)
    }

    static func isClaudePath(_ path: String) -> Bool {
        path.hasPrefix(claudeVersionsDir) || path == claudeLocalBin
    }

    /// The fingerprints. Keep in step with `list_stale_summarizers` and
    /// `list_stale_headless_chrome` in ~/.local/bin/claude-hygiene.
    /// `parent` looks up a parent's resolved path and argv (called only for
    /// summarizer-shaped processes, so the cost is two calls per candidate).
    static func classify(path: String, args: [String], ppid: pid_t,
                         parent: (pid_t) -> (path: String, args: [String])?) -> Kind {
        if isClaudeBinary(path: path, args: args) {
            if isSummarizer(args) {
                // Shape alone is not ownership: `--output-format stream-json` is
                // a public CLI mode. Only the claude-mem worker's own children are ours.
                if let owner = summarizerOwner(ppid: ppid, parent: parent) {
                    return .summarizer(owner: owner)
                }
                return .other
            }
            if isInteractive(args) { return .session }
            return .other                      // e.g. `claude -p` one-shots: not ours to touch
        }
        switch headlessChrome(path: path, args: args, ppid: ppid) {
        case .throwawayProfile:  return .chrome
        case .persistentProfile: return .chromeIgnored
        case .none:              return .other
        }
    }

    /// The resolved executable decides (`~/.local/share/claude/versions/…` or
    /// `~/.local/bin/claude`); argv[0] named `claude` only corroborates, but it
    /// is required: Claude Code is a multicall binary that re-execs itself as
    /// `ugrep` and friends, and those share the resolved path without being sessions.
    static func isClaudeBinary(path: String, args: [String]) -> Bool {
        guard isClaudePath(path), let a0 = args.first else { return false }
        return a0 == "claude" || a0.hasSuffix("/claude")
    }

    /// The options of an invocation: argv after argv[0], stopping at the first
    /// bare `--` (everything after it is operands, never options).
    static func options(_ args: [String]) -> ArraySlice<String> {
        let rest = args.dropFirst()
        if let dash = rest.firstIndex(of: "--") { return rest[rest.startIndex..<dash] }
        return rest
    }

    /// `--flag value` or `--flag=value`, among the options.
    static func hasOption(_ args: [String], _ flag: String, _ value: String) -> Bool {
        let opts = options(args)
        if opts.contains(flag + "=" + value) { return true }
        var i = opts.startIndex
        while i < opts.endIndex {
            if opts[i] == flag {
                let next = opts.index(after: i)
                if next < opts.endIndex, opts[next] == value { return true }
            }
            i = opts.index(after: i)
        }
        return false
    }

    static func isPrintMode(_ args: [String]) -> Bool {
        let opts = options(args)
        return opts.contains("-p") || opts.contains("--print")
    }

    /// The claude-mem summarizer's exact shape: a bidirectional stream-json
    /// channel that is not a `-p` one-shot. Shape only; see `summarizerOwner`.
    static func isSummarizer(_ args: [String]) -> Bool {
        hasOption(args, "--output-format", "stream-json")
            && hasOption(args, "--input-format", "stream-json")
            && !isPrintMode(args)
    }

    static func isInteractive(_ args: [String]) -> Bool {
        !isSummarizer(args) && !isPrintMode(args)
    }

    /// The claude-mem worker: `bun …/plugin/scripts/worker-service.cjs --daemon`.
    /// Both halves are required: the script in argv and bun as the executable.
    static func isWorker(path: String, args: [String]) -> Bool {
        path.hasSuffix("/bun") && args.contains { $0.contains("plugin/scripts/worker-service.cjs") }
    }

    /// Who vouches for a summarizer-shaped process: only the worker as its
    /// current parent. A ppid-1 leftover is the worker's own reaper's job
    /// (it kills any `claude.*output-format` orphan every 5 minutes).
    static func summarizerOwner(ppid: pid_t, parent: (pid_t) -> (path: String, args: [String])?) -> String? {
        guard ppid > 1, let p = parent(ppid), isWorker(path: p.path, args: p.args) else { return nil }
        return "claude-mem worker"
    }

    enum ChromeMatch { case none, throwawayProfile, persistentProfile }

    /// Orphaned headless Chrome. `ppid == 1` alone does not prove abandonment
    /// (a deliberately nohup'd daemon looks the same), so the profile directory
    /// is the discriminator: automation uses a throwaway one under /tmp or
    /// /var/folders; a persistent profile means someone wants it kept.
    static func headlessChrome(path: String, args: [String], ppid: pid_t) -> ChromeMatch {
        guard ppid == 1, path.hasSuffix(chromeMainSuffix),
              options(args).contains(where: { $0.hasPrefix("--headless") })
        else { return .none }
        guard let dir = userDataDir(args), dir.hasPrefix("/") else { return .persistentProfile }
        let std = URL(fileURLWithPath: dir).standardized.path
        let throwaway = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        return throwaway.contains(where: { std.hasPrefix($0) }) ? .throwawayProfile : .persistentProfile
    }

    static func userDataDir(_ args: [String]) -> String? {
        let opts = options(args)
        var i = opts.startIndex
        while i < opts.endIndex {
            let a = opts[i]
            if a.hasPrefix("--user-data-dir=") { return String(a.dropFirst("--user-data-dir=".count)) }
            if a == "--user-data-dir" {
                let next = opts.index(after: i)
                if next < opts.endIndex { return opts[next] }
            }
            i = opts.index(after: i)
        }
        return nil
    }

    /// A real Chrome helper, as opposed to something else that happens to be
    /// a child of the main process.
    static func isChromeHelperPath(_ path: String) -> Bool {
        path.contains("Google Chrome Helper") || path.contains("Google Chrome Framework.framework")
    }

    // MARK: libproc / sysctl wrappers

    private static func probe(_ pid: pid_t, uid: uid_t,
                              pathBuf: inout [CChar]) -> (proc_bsdinfo, String)? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size,
              bsd.pbi_uid == uid, bsd.pbi_status != SZOMB else { return nil }
        guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { return nil }
        return (bsd, String(cString: pathBuf))
    }

    private static func parentInfo(_ pid: pid_t, pathBuf: inout [CChar],
                                   argBuf: inout [UInt8]) -> (path: String, args: [String])? {
        guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { return nil }
        let path = String(cString: pathBuf)
        guard let args = arguments(pid, into: &argBuf) else { return nil }
        return (path, args)
    }

    private static func startDate(_ bsd: proc_bsdinfo) -> Date {
        Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1e6)
    }

    private static func residentSize(_ pid: pid_t) -> UInt64 {
        var ru = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &ru) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return r == 0 ? ru.ri_resident_size : 0
    }

    private static func arguments(_ pid: pid_t, into buf: inout [UInt8]) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buf.count
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return buf.withUnsafeBytes { parseProcArgs($0, size: size) }
    }

    /// KERN_PROCARGS2 layout: Int32 argc, exec path NUL, padding NULs, then
    /// argc NUL-terminated argv strings (environment follows; ignored). This is
    /// a kill gate, so it fails closed: any malformed payload is nil, which
    /// classifies the process as `.other`. Exactly argc strings are taken, so a
    /// genuine empty argument survives; only the NUL run right after the exec
    /// path is skipped; every argument must be NUL-terminated inside the
    /// payload and be valid UTF-8.
    static func parseProcArgs(_ raw: UnsafeRawBufferPointer, size: Int) -> [String]? {
        guard size > 4, size <= raw.count else { return nil }
        let argc = Int(raw.loadUnaligned(as: Int32.self))
        guard argc > 0, argc <= maxArgc, argc <= size - 4 else { return nil }
        var i = 4
        while i < size && raw[i] != 0 { i += 1 }          // exec path
        guard i < size else { return nil }                 // exec path not terminated
        while i < size && raw[i] == 0 { i += 1 }          // padding after it
        var args: [String] = []
        args.reserveCapacity(argc)
        while args.count < argc {
            let start = i
            while i < size && raw[i] != 0 { i += 1 }
            guard i < size else { return nil }             // argument not terminated in payload
            guard let s = String(bytes: UnsafeRawBufferPointer(rebasing: raw[start..<i]), encoding: .utf8)
            else { return nil }                            // not UTF-8
            args.append(s)
            i += 1
        }
        return args
    }

    // MARK: Identity, re-checked before every signal

    enum Identity: Equatable { case same(ppid: pid_t), gone, changed, unknown }

    /// Re-reads the pid right before a kill. `gone` is ESRCH or a zombie
    /// (dead, its parent just has not collected it); `changed` means the pid
    /// now belongs to something else (owner or start time differ); `unknown`
    /// is any other failure and is never treated as gone or signalled.
    static func identity(of p: ProcInfo) -> Identity {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let got = proc_pidinfo(p.pid, PROC_PIDTBSDINFO, 0, &bsd, size)
        if got != size { return errno == ESRCH ? .gone : .unknown }
        if bsd.pbi_status == SZOMB { return .gone }
        guard bsd.pbi_uid == getuid(),
              Int64(bsd.pbi_start_tvsec) == p.startSec,
              Int64(bsd.pbi_start_tvusec) == p.startUsec
        else { return .changed }
        return .same(ppid: pid_t(bsd.pbi_ppid))
    }

    /// argv as it is right now (fresh buffer; used only at kill time).
    static func currentArguments(_ pid: pid_t) -> [String]? {
        var buf = [UInt8](repeating: 0, count: Int(sysctlInt32("kern.argmax") ?? 262_144))
        return arguments(pid, into: &buf)
    }

    static func currentPath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: pathCapacity)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    static func currentInfo(_ pid: pid_t) -> (path: String, args: [String])? {
        guard let path = currentPath(pid), let args = currentArguments(pid) else { return nil }
        return (path, args)
    }

    enum Role { case summarizer, chromeMain, chromeChild(of: ProcInfo) }

    enum Verdict { case kill, gone, skip }

    /// The full gate before any signal: same identity, not us or our parent or
    /// the worker, and the exact fingerprint still holds on the CURRENT path
    /// and argv. For a Chrome helper the parent is re-fingerprinted too.
    static func verify(_ p: ProcInfo, as role: Role) -> Verdict {
        if p.pid == getpid() || p.pid == getppid() || p.pid <= 1 { return .skip }
        let ppid: pid_t
        switch identity(of: p) {
        case .gone:          return .gone
        case .changed:       return .skip
        case .unknown:       return .skip
        case .same(let now): ppid = now
        }
        guard let (path, args) = currentInfo(p.pid) else { return .skip }
        if isWorker(path: path, args: args) || args.contains(where: { $0.contains("worker-service.cjs") }) {
            return .skip
        }

        switch role {
        case .summarizer:
            guard isClaudeBinary(path: path, args: args), isSummarizer(args),
                  summarizerOwner(ppid: ppid, parent: { currentInfo($0) }) != nil
            else { return .skip }
        case .chromeMain:
            guard headlessChrome(path: path, args: args, ppid: ppid) == .throwawayProfile else { return .skip }
        case .chromeChild(let main):
            // A helper is ours only while its parent is still the verified main
            // and it is a real Chrome helper itself.
            guard ppid == main.pid, isChromeHelperPath(path),
                  verify(main, as: .chromeMain) == .kill
            else { return .skip }
        }
        return .kill
    }
}

// MARK: - Tunables

enum HealthPrefs {
    static let autoReapKey = "health.autoReap"
    static let summarizerMaxAgeKey = "health.summarizerMaxAgeMin"
    static let chromeMaxAgeKey = "health.chromeMaxAgeMin"
    static let emergencyAgeKey = "health.emergencySummarizerAgeMin"
    static let pollSecondsKey = "health.pollSeconds"
    static let burstMaxKey = "health.summarizerBurstMax"
    static let lastReapKey = "health.lastReapJSON"

    private static let registered: Void = {
        UserDefaults.standard.register(defaults: [
            autoReapKey: true,
            summarizerMaxAgeKey: 120,
            emergencyAgeKey: 10,
            chromeMaxAgeKey: 60,
            pollSecondsKey: 30,
            burstMaxKey: 10,
        ])
    }()
    private static var defaults: UserDefaults { _ = registered; return .standard }

    static var autoReap: Bool {
        get { defaults.bool(forKey: autoReapKey) }
        set { defaults.set(newValue, forKey: autoReapKey) }
    }
    static var summarizerMaxAge: TimeInterval {
        Double(max(1, defaults.integer(forKey: summarizerMaxAgeKey))) * 60
    }
    static var chromeMaxAge: TimeInterval {
        Double(max(1, defaults.integer(forKey: chromeMaxAgeKey))) * 60
    }
    /// Used instead of `summarizerMaxAge` while the machine is in an emergency
    /// (see `HealthScorer.isEmergency`): a lost memory summary is nothing next
    /// to a hard reboot.
    static var emergencySummarizerAge: TimeInterval {
        Double(max(1, defaults.integer(forKey: emergencyAgeKey))) * 60
    }
    /// Burst rule (2026-11-09): more summarizers than this at once and the
    /// extras are reaped whatever their age. After a reboot the worker started
    /// 25 in one minute (about 12 GB) and none was old enough for the age rule.
    /// 0 turns the rule off.
    static var summarizerBurstMax: Int { max(0, defaults.integer(forKey: burstMaxKey)) }

    static var pollSeconds: TimeInterval {
        Double(max(10, defaults.integer(forKey: pollSecondsKey)))
    }
    static var lastReap: ReapResult? {
        get {
            guard let data = defaults.string(forKey: lastReapKey)?.data(using: .utf8) else { return nil }
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            return try? d.decode(ReapResult.self, from: data)
        }
        set {
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
            if let r = newValue, let data = try? e.encode(r), let s = String(data: data, encoding: .utf8) {
                defaults.set(s, forKey: lastReapKey)
            } else {
                defaults.removeObject(forKey: lastReapKey)
            }
        }
    }
}

// MARK: - Scoring

enum HealthLevel: Int, Comparable, Encodable {
    case ok = 0, warn = 1, critical = 2
    static func < (a: HealthLevel, b: HealthLevel) -> Bool { a.rawValue < b.rawValue }
    var name: String {
        switch self { case .ok: return "ok"; case .warn: return "warn"; case .critical: return "critical" }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(name)
    }
}

enum HealthMetric: String, Encodable { case memory, load, claude, disk }

struct HealthReason: Encodable {
    let metric: HealthMetric
    let level: HealthLevel
    let text: String
}

struct HealthHistoryEntry: Encodable { let level: HealthLevel; let at: Date }

struct HealthAssessment: Encodable {
    let level: HealthLevel          // after hysteresis: what the UI shows
    let rawLevel: HealthLevel       // this sample on its own
    let emergency: Bool             // this sample alone, or a kernel critical event
    let reasons: [String]           // plain English, worst first
    let details: [HealthReason]
    let history: [HealthHistoryEntry]   // recent raw levels, newest last
    let sample: HealthSample

    func level(for metric: HealthMetric) -> HealthLevel {
        details.filter { $0.metric == metric }.map(\.level).max() ?? .ok
    }
}

enum HealthScorer {
    static let memWarnPct = 35
    static let memCriticalPct = 15
    static let loadWarnPerCore = 2.0
    static let loadCriticalPerCore = 4.0
    static let staleWarn = 5
    static let staleCritical = 20
    static let stackWarnBytes: UInt64 = 4 << 30
    static let swapCriticalBytes: UInt64 = 6 << 30
    // 2026-11-07: the disk sat at 99% (8.5 GB free) with swap at 12 GB and
    // nothing flagged it. Below ~20 GB swap cannot grow and the Mac thrashes.
    static let diskWarnBytes: UInt64 = 50 << 30
    static let diskCriticalBytes: UInt64 = 20 << 30
    static let historyLength = 6
    static let promotionAge: TimeInterval = 20    // the confirming sample must be this old

    /// Recent raw levels and the last effective one. Touch only from the health queue.
    private(set) static var history: [HealthHistoryEntry] = []
    private(set) static var lastEffective: HealthLevel = .ok

    static func evaluate(_ s: HealthSample) -> (HealthLevel, [HealthReason]) {
        var out: [HealthReason] = []
        func add(_ m: HealthMetric, _ l: HealthLevel, _ t: String) { out.append(HealthReason(metric: m, level: l, text: t)) }

        // A missing reading is a warning about the widget, never a verdict on the Mac.
        if let pct = s.memFreePct {
            if pct < memCriticalPct {
                add(.memory, .critical, "memory \(pct)% free")
            } else if pct < memWarnPct {
                add(.memory, .warn, "memory \(pct)% free")
            }
            // Free pages alone mean little on macOS (the file cache keeps them
            // near zero by design), so heavy swap only counts once the kernel
            // itself reports pressure.
            if let swap = s.swap, swap.usedBytes > swapCriticalBytes, pct < memWarnPct {
                add(.memory, .critical, "swap \(Style.bytes(swap.usedBytes)) at \(pct)% free")
            }
        } else {
            add(.memory, .warn, "memory metric unavailable")
        }

        if let perCore = s.loadPerCore {
            if perCore > loadCriticalPerCore {
                add(.load, .critical, String(format: "load %.1f per core", perCore))
            } else if perCore > loadWarnPerCore {
                add(.load, .warn, String(format: "load %.1f per core", perCore))
            }
        } else {
            add(.load, .warn, "load metric unavailable")
        }

        // An unreadable disk says nothing either way, so it stays silent.
        if let d = s.disk {
            if d.freeBytes < diskCriticalBytes {
                add(.disk, .critical, "disk \(Style.bytes(d.freeBytes)) free")
            } else if d.freeBytes < diskWarnBytes {
                add(.disk, .warn, "disk \(Style.bytes(d.freeBytes)) free")
            }
        }

        // The leak's signature is accumulation: a healthy worker holds about one
        // summarizer per live session, so a pile of them is a leak whatever
        // their age. Below that, age is the tell.
        let all = s.claude.summarizers
        if all.count >= staleCritical {
            let bytes = all.reduce(0) { $0 + $1.rss }
            add(.claude, .critical, "\(all.count) summarizers piling up (\(Style.bytes(bytes)))")
        } else {
            let maxAge = HealthPrefs.summarizerMaxAge
            let stale = all.filter { $0.age > maxAge }
            if stale.count >= staleWarn {
                let bytes = stale.reduce(0) { $0 + $1.rss }
                add(.claude, .warn, "\(stale.count) leaked summarizers (\(Style.bytes(bytes)))")
            }
        }
        if s.claude.totalRSS > stackWarnBytes {
            add(.claude, .warn, "Claude stack \(Style.bytes(s.claude.totalRSS)) resident")
        }
        let chromeAge = HealthPrefs.chromeMaxAge
        let chrome = s.claude.headlessChrome.filter { $0.age > chromeAge }
        if !chrome.isEmpty {
            add(.claude, .warn, chrome.count == 1 ? "1 orphaned headless Chrome"
                                                  : "\(chrome.count) orphaned headless Chrome")
        }

        // Worst first, stable within a level.
        let sorted = out.enumerated().sorted {
            ($1.element.level, $0.offset) < ($0.element.level, $1.offset)
        }.map(\.element)
        return (sorted.first?.level ?? .ok, sorted)
    }

    /// True when this single sample, on its own, says the machine is in trouble:
    /// the kernel reports critical memory, the load is critical, or summarizers
    /// have piled up. No hysteresis: an emergency reap must not wait a poll.
    /// A metric that could not be read never contributes (`evaluate` emits no
    /// critical reason from it), and a kernel `.critical` pressure event is an
    /// emergency whatever the polled percentage says. A full disk colours the
    /// menu bar but is no emergency: killing summarizers frees no disk space.
    static func isEmergency(_ s: HealthSample, kernelCritical: Bool = false) -> Bool {
        if kernelCritical { return true }
        let (_, reasons) = evaluate(s)
        return reasons.contains { $0.level == .critical && $0.metric != .disk }
    }

    /// A level is promoted only when the previous sample was already at that
    /// level or worse AND is at least `promotionAge` old, so neither one spike
    /// nor two back-to-back queued samples can colour the menu bar; demotion
    /// is immediate.
    static func assess(_ s: HealthSample, kernelCritical: Bool = false) -> HealthAssessment {
        let (raw, details) = evaluate(s)
        let now = s.sampledAt
        let previous = history.last
        let effective: HealthLevel
        if let prev = previous, now.timeIntervalSince(prev.at) >= promotionAge {
            effective = min(raw, prev.level)
        } else {
            effective = min(raw, lastEffective)
        }
        history.append(HealthHistoryEntry(level: raw, at: now))
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
        lastEffective = effective
        return HealthAssessment(level: effective, rawLevel: raw,
                                emergency: isEmergency(s, kernelCritical: kernelCritical),
                                reasons: details.map(\.text), details: details,
                                history: history, sample: s)
    }
}

// MARK: - Intervention

struct ReapResult: Codable {
    var summarizersKilled = 0      // confirmed gone after escalation
    var chromeKilled = 0           // Chrome mains confirmed gone
    var signalled = 0              // processes that received at least one signal
    var survived = 0               // signalled, still present (or unverifiable) at confirmation
    var skipped = 0                // targets whose identity or fingerprint no longer held at signal time
    var bytesResident: UInt64 = 0  // RSS the confirmed-gone processes had (what they held, not a promise of what came back)
    var at = Date()

    var killedAnything: Bool { summarizersKilled + chromeKilled > 0 }
    var terminated: Int { summarizersKilled + chromeKilled }

    /// "37 summarizers" or "37 summarizers + 1 Chrome tree"
    var what: String {
        var parts: [String] = []
        if summarizersKilled > 0 {
            parts.append("\(summarizersKilled) summarizer\(summarizersKilled == 1 ? "" : "s")")
        }
        if chromeKilled > 0 {
            parts.append("\(chromeKilled) Chrome tree\(chromeKilled == 1 ? "" : "s")")
        }
        return parts.joined(separator: " + ")
    }

    /// "37 summarizers terminated · 2.1 GB was resident"
    var summary: String { "\(what) terminated \u{00B7} \(Style.bytes(bytesResident)) was resident" }
}

enum HealthAction {

    static let queue = DispatchQueue(label: "com.claudeusage.health", qos: .utility)
    static let grace: TimeInterval = 2          // SIGTERM → SIGKILL
    static let settle: TimeInterval = 0.3       // SIGKILL → confirmation

    struct Targets {
        var summarizers: [ProcInfo] = []
        var chrome: [ProcInfo] = []
        var chromeChildren: [ProcInfo] = []
        var isEmpty: Bool { summarizers.isEmpty && chrome.isEmpty }
        var count: Int { summarizers.count + chrome.count }
        var all: [ProcInfo] { summarizers + chrome }
    }

    /// What `reap` would kill: only fingerprinted processes past their age
    /// limit. Interactive sessions never appear here by construction.
    /// `summarizerAge` overrides the age limit; only Free Up Memory passes it
    /// (0 while memory is low: the click is the consent, see Relief.swift).
    static func targets(in s: HealthSample, emergency: Bool = false,
                        summarizerAge: TimeInterval? = nil) -> Targets {
        var t = Targets()
        let sAge = summarizerAge ?? (emergency ? HealthPrefs.emergencySummarizerAge : HealthPrefs.summarizerMaxAge)
        let cAge = HealthPrefs.chromeMaxAge
        t.summarizers = s.claude.summarizers.filter { $0.age > sAge }
        // Burst rule: keep the newest `burstMax` (most likely still tied to a
        // live session), reap every older one beyond that, whatever its age.
        let burstMax = HealthPrefs.summarizerBurstMax
        if burstMax > 0, s.claude.summarizers.count > burstMax {
            let chosen = Set(t.summarizers.map(\.pid))
            let extras = s.claude.summarizers.sorted { $0.started > $1.started }.dropFirst(burstMax)
            t.summarizers += extras.filter { !chosen.contains($0.pid) }
        }
        t.chrome = s.claude.headlessChrome.filter { $0.age > cAge }
        let mains = Set(t.chrome.map(\.pid))
        t.chromeChildren = s.claude.chromeChildren.filter { mains.contains($0.ppid) }
        return t
    }

    private struct Termed { let proc: ProcInfo; let role: HealthSensor.Role }

    /// SIGTERM, a two-second grace, SIGKILL for whatever is left, then a
    /// confirmation pass; the waits are `asyncAfter` steps on `queue` so the
    /// queue is never blocked, and `completion` runs on `queue` at the end.
    /// Every signal, including the escalation, is gated by `HealthSensor.verify`
    /// on the process as it is at that moment: same identity, current path and
    /// argv still match the exact fingerprint, never us, our parent, or the
    /// worker. Counts are outcomes: only a process confirmed gone is "killed".
    static func reap(sample: HealthSample, emergency: Bool = false, summarizerAge: TimeInterval? = nil,
                     on queue: DispatchQueue, completion: @escaping (ReapResult) -> Void) {
        var result = ReapResult()
        let t = targets(in: sample, emergency: emergency, summarizerAge: summarizerAge)
        guard !t.isEmpty else { return completion(result) }

        var termed: [Termed] = []

        func signal(_ p: ProcInfo, _ sig: Int32, as role: HealthSensor.Role) -> Bool {
            switch HealthSensor.verify(p, as: role) {
            case .kill:  return kill(p.pid, sig) == 0
            case .gone:  return false
            case .skip:  result.skipped += 1; return false
            }
        }

        for p in t.summarizers where signal(p, SIGTERM, as: .summarizer) {
            termed.append(Termed(proc: p, role: .summarizer))
        }
        for main in t.chrome {
            // The main must pass before its children are touched; then real
            // helpers first, then the main, which `signal` re-verifies once more.
            let verdict = HealthSensor.verify(main, as: .chromeMain)
            if verdict == .skip { result.skipped += 1 }
            guard verdict == .kill else { continue }
            for child in t.chromeChildren where child.ppid == main.pid
                && signal(child, SIGTERM, as: .chromeChild(of: main)) {
                termed.append(Termed(proc: child, role: .chromeChild(of: main)))
            }
            if signal(main, SIGTERM, as: .chromeMain) {
                termed.append(Termed(proc: main, role: .chromeMain))
            }
        }
        result.signalled = termed.count
        guard !termed.isEmpty else { return completion(result) }

        queue.asyncAfter(deadline: .now() + grace) {
            for x in termed where presence(of: x.proc) == .present {
                _ = signal(x.proc, SIGKILL, as: x.role)      // re-verified again
            }
            queue.asyncAfter(deadline: .now() + settle) {
                var goneSummarizers: [ProcInfo] = []
                var goneChrome: [ProcInfo] = []
                for x in termed {
                    guard presence(of: x.proc) == .gone else { result.survived += 1; continue }
                    result.bytesResident += x.proc.rss
                    switch x.role {
                    case .summarizer:  result.summarizersKilled += 1; goneSummarizers.append(x.proc)
                    case .chromeMain:  result.chromeKilled += 1; goneChrome.append(x.proc)
                    case .chromeChild: break
                    }
                }
                if !goneSummarizers.isEmpty {
                    let mb = goneSummarizers.reduce(0) { $0 + $1.rss }
                    log("killed \(goneSummarizers.count) stale claude-mem summarizer(s) (\(self.mb(mb)) MB) (pids \(goneSummarizers.map(\.identityString).joined(separator: ", ")))")
                }
                if !goneChrome.isEmpty {
                    let mb = goneChrome.reduce(0) { $0 + $1.rss }
                    log("killed \(goneChrome.count) stale orphaned headless Chrome tree(s) (\(self.mb(mb)) MB) (pids \(goneChrome.map(\.identityString).joined(separator: ", ")))")
                }
                completion(result)
            }
        }
    }

    enum Presence { case gone, present, unknown }

    /// Is the sampled process still there? ESRCH, a zombie, or a recycled pid
    /// all mean the one we signalled is gone; an unreadable pid is never
    /// assumed gone.
    static func presence(of p: ProcInfo) -> Presence {
        errno = 0
        if kill(p.pid, 0) != 0 { return errno == ESRCH ? .gone : .unknown }
        switch HealthSensor.identity(of: p) {
        case .gone, .changed: return .gone
        case .same:           return .present
        case .unknown:        return .unknown
        }
    }

    private static func mb(_ bytes: UInt64) -> String { String(format: "%.0f", Double(bytes) / 1_048_576) }

    // MARK: Audit trail, shared with the bash tool

    static let logPath = (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/.claude-mem/hygiene.log"
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    /// `[YYYY-MM-DD HH:MM:SS] widget: <line>`, appended with O_APPEND so it
    /// interleaves safely with the bash tool. Never throws; a line that cannot
    /// be written is dropped.
    static func log(_ line: String) {
        let text = "[\(stamp.string(from: Date()))] widget: \(line)\n"
        let dir = (logPath as NSString).deletingLastPathComponent
        mkdir(dir, 0o755)                                   // EEXIST is fine
        let fd = open(logPath, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        let total = bytes.count
        var offset = 0
        while offset < total {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, total - offset) }
            if n > 0 { offset += n; continue }
            if n < 0 && errno == EINTR { continue }
            return                                          // partial line dropped; nothing more to do
        }
    }
}

// MARK: - Notifications

/// UNUserNotificationCenter needs a real bundle; an ad-hoc signed one is fine,
/// but a bare binary (the debug flags) would trap inside it, and the centre
/// can refuse requests outright. Every path here degrades to the legacy
/// NSUserNotification (reached dynamically, so nothing deprecated is compiled)
/// or to silence. It never crashes.
enum HealthNotifier {

    private static var hasBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        static let shared = Presenter()
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                    withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
            handler([.banner, .list])      // show even while our menu is open
        }
    }

    static func requestAuthorization() {
        guard hasBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = Presenter.shared
        center.requestAuthorization(options: [.alert]) { _, _ in }    // denial is fine
    }

    /// `outcome` is for the debug flag only: what path the notification took.
    static func post(title: String, body: String, outcome: ((String) -> Void)? = nil) {
        guard hasBundle else {
            legacyPost(title: title, body: body)
            outcome?("no app bundle: legacy NSUserNotification")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error = error {
                legacyPost(title: title, body: body)
                outcome?("UNUserNotificationCenter refused (\(error.localizedDescription)): legacy NSUserNotification")
            } else {
                outcome?("UNUserNotificationCenter accepted")
            }
        }
    }

    private static func legacyPost(title: String, body: String) {
        guard let noteClass = NSClassFromString("NSUserNotification") as? NSObject.Type,
              let centerClass = NSClassFromString("NSUserNotificationCenter") as? NSObject.Type
        else { return }
        let note = noteClass.init()
        note.setValue(title, forKey: "title")
        note.setValue(body, forKey: "informativeText")
        let sel = NSSelectorFromString("defaultUserNotificationCenter")
        guard centerClass.responds(to: sel),
              let center = centerClass.perform(sel)?.takeUnretainedValue() as? NSObject
        else { return }
        _ = center.perform(NSSelectorFromString("deliverNotification:"), with: note)
    }
}

// MARK: - Monitor: timer, memory-pressure source, reap policy

/// What the panel and menu need, published on the main thread after every run.
struct HealthPanelState {
    var assessment: HealthAssessment?
    var suspected: [ProcInfo] = []        // current targets (summarizers + Chrome mains)
    var autoReap = true
    var sessionReap: ReapResult?          // the last reap that ran in THIS process
    var lastCheck: Date?
}

final class HealthMonitor {

    /// Called on the main thread after every sample.
    var onUpdate: ((HealthPanelState) -> Void)?

    private(set) var state = HealthPanelState()   // main-thread copy

    private var timer: DispatchSourceTimer?
    private var pressure: DispatchSourceMemoryPressure?
    private let queue = HealthAction.queue
    private var started = false

    // Queue-confined scheduling state: at most one run in flight and one pending.
    private struct Request { var manual: Bool; var kernelCritical: Bool; var kernelEvent: String? }
    private var inFlight = false
    private var pending: Request?
    private var lastPressureNotice = Date.distantPast
    private var lastPressureRun = Date.distantPast
    private var sessionReap: ReapResult?

    func start() {
        guard !started else { return }
        started = true
        HealthNotifier.requestAuthorization()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: HealthPrefs.pollSeconds, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.request(Request(manual: false, kernelCritical: false, kernelEvent: nil)) }
        t.resume()
        timer = t

        // The kernel tells us first when memory gets tight: sample and reap at once.
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self = self, let src = src else { return }
            let mask = src.data
            let critical = mask.contains(.critical)
            // The source can flap on the warn boundary; one warning run per 10 s
            // is plenty. A critical event always goes through (it still coalesces).
            if !critical && Date().timeIntervalSince(self.lastPressureRun) < 10 { return }
            self.lastPressureRun = Date()
            self.request(Request(manual: false, kernelCritical: critical,
                                 kernelEvent: critical ? "critical" : "warning"))
        }
        src.resume()
        pressure = src
    }

    func stop() {
        guard started else { return }
        started = false
        timer?.cancel(); timer = nil
        pressure?.cancel(); pressure = nil
    }

    /// Sample now. `manual` reaps even when auto-reap is off. Requests coalesce:
    /// while a run is in flight, at most one more is queued, and a manual
    /// request stays manual.
    func poll(manual: Bool = false) {
        queue.async { [weak self] in
            self?.request(Request(manual: manual, kernelCritical: false, kernelEvent: nil))
        }
    }

    private func request(_ r: Request) {        // on queue
        if inFlight {
            var p = pending ?? Request(manual: false, kernelCritical: false, kernelEvent: nil)
            p.manual = p.manual || r.manual
            p.kernelCritical = p.kernelCritical || r.kernelCritical
            p.kernelEvent = r.kernelEvent ?? p.kernelEvent
            pending = p
            return
        }
        begin(r)
    }

    private func begin(_ r: Request) {          // on queue
        inFlight = true
        let sample = HealthSensor.sample(kernelPressure: r.kernelEvent)
        let emergency = HealthScorer.isEmergency(sample, kernelCritical: r.kernelCritical)
        let targets = HealthAction.targets(in: sample, emergency: emergency)
        if !targets.isEmpty && (r.manual || HealthPrefs.autoReap) {
            HealthAction.reap(sample: sample, emergency: emergency, on: queue) { [weak self] result in
                self?.finish(r, sample: sample, reap: result)
            }
        } else {
            finish(r, sample: sample, reap: nil)
        }
    }

    private func finish(_ r: Request, sample first: HealthSample, reap: ReapResult?) {   // on queue
        var sample = first
        if let result = reap {
            sessionReap = result
            if result.killedAnything {
                HealthPrefs.lastReap = result
                HealthNotifier.post(title: "Headroom reaped leaks", body: result.summary)
                sample = HealthSensor.sample(kernelPressure: r.kernelEvent)   // show the post-reap state
            }
        }

        let assessment = HealthScorer.assess(sample, kernelCritical: r.kernelCritical)
        let suspected = HealthAction.targets(in: sample, emergency: assessment.emergency).all

        if assessment.level == .critical, !(reap?.killedAnything ?? false),
           Date().timeIntervalSince(lastPressureNotice) > 15 * 60 {
            lastPressureNotice = Date()
            let sessions = sample.claude.interactiveSessions.count
            var body = assessment.reasons.prefix(2).joined(separator: ", ")
            body += ", \(sessions) Claude session\(sessions == 1 ? "" : "s") open"
            if let oldest = sample.claude.oldestSession, oldest.age > 86_400 {
                body += ", oldest \(Style.duration(oldest.age))"
            }
            HealthNotifier.post(title: "Mac under pressure", body: body)
        }

        let published = HealthPanelState(assessment: assessment, suspected: suspected,
                                         autoReap: HealthPrefs.autoReap,
                                         sessionReap: sessionReap, lastCheck: sample.sampledAt)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.state = published
            self.onUpdate?(published)
        }

        inFlight = false
        if let next = pending {
            pending = nil
            begin(next)
        }
    }
}

// MARK: - Formatting shared with the panel

extension Style {
    /// "2.1 GB" or "512 MB"
    static func bytes(_ b: UInt64) -> String {
        b >= 1 << 30 ? String(format: "%.1f GB", Double(b) / 1_073_741_824)
                     : String(format: "%.0f MB", Double(b) / 1_048_576)
    }

    /// Always in GB with one decimal, for "swap 4.5 of 9.2 GB".
    static func gb(_ b: UInt64) -> String { String(format: "%.1f", Double(b) / 1_073_741_824) }

    /// "3d 1h", "5h 12m", "45m"
    static func duration(_ secs: TimeInterval) -> String {
        let s = max(0, Int(secs))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// "today 09:33", "Thu 09:33", or "12 Sep" once it is a week old.
    static func dayClock(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "today " + clock(date) }
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate(date.timeIntervalSinceNow > -6 * 86400 ? "EEE jmm" : "d MMM")
        return f.string(from: date)
    }
}

// MARK: - Debug output (used by --health-json / --reap-dry-run / --argv-selftest)

enum HealthDebug {
    static func json(_ assessment: HealthAssessment) -> String {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(assessment), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    static func row(_ p: ProcInfo) -> String {
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
        var s = "  pid " + pad(String(p.pid), 7) + " " + pad(Style.bytes(p.rss), 8)
            + "  age " + pad(Style.duration(p.age), 9) + " " + p.args.prefix(3).joined(separator: " ")
        if let owner = p.owner, let ownerPid = p.ownerPid {
            s += "  [owner: \(owner), pid \(ownerPid)]"
        }
        return s
    }

    static func dryRun(_ sample: HealthSample) -> String {
        let emergency = HealthScorer.isEmergency(sample)
        let t = HealthAction.targets(in: sample, emergency: emergency)
        var lines: [String] = []
        lines.append("metrics: memory \(sample.validity.memory ? "\(sample.memFreePct ?? -1)% free (\(sample.memSource))" : "UNAVAILABLE")"
                     + " · load \(sample.validity.load ? String(format: "%.1f per core", sample.loadPerCore ?? 0) : "UNAVAILABLE")"
                     + " · emergency \(emergency)")
        let age = emergency ? HealthPrefs.emergencySummarizerAge : HealthPrefs.summarizerMaxAge
        lines.append("summarizers older than \(Int(age / 60)) min\(emergency ? " (EMERGENCY threshold)" : ""): \(t.summarizers.count) of \(sample.claude.summarizers.count) running")
        t.summarizers.forEach { lines.append(row($0)) }
        let live = sample.claude.summarizers.filter { s in !t.summarizers.contains { $0.pid == s.pid } }
        if !live.isEmpty {
            lines.append("  live (under the age limit):")
            live.forEach { lines.append("  " + row($0)) }
        }
        lines.append("orphaned headless Chrome older than \(Int(HealthPrefs.chromeMaxAge / 60)) min: \(t.chrome.count) of \(sample.claude.headlessChrome.count) found"
                     + (sample.claude.headlessChromeIgnored > 0 ? " (\(sample.claude.headlessChromeIgnored) on a persistent profile, ignored)" : ""))
        t.chrome.forEach { lines.append(row($0)) }
        t.chromeChildren.forEach {
            lines.append("    child" + row($0).dropFirst(5)
                         + (HealthSensor.isChromeHelperPath($0.path) ? "" : "  [not a Chrome helper: would be skipped]"))
        }
        lines.append("interactive sessions (never killed): \(sample.claude.interactiveSessions.count)")
        sample.claude.interactiveSessions.forEach { lines.append(row($0)) }
        let bytes = (t.summarizers + t.chrome + t.chromeChildren).reduce(0) { $0 + $1.rss }
        lines.append(t.isEmpty ? "would kill: nothing"
                               : "would kill: \(t.summarizers.count) summarizer(s), \(t.chrome.count) Chrome tree(s), \(Style.bytes(bytes)) resident")
        return lines.joined(separator: "\n")
    }

    /// Fixtures for the KERN_PROCARGS2 parser and the option scanner. Returns
    /// the number of failures; prints one line per case.
    static func argvSelfTest() -> Int {
        func payload(argc: Int32, exec: String, pad: Int, parts: [[UInt8]], env: String = "ENV=1\0") -> [UInt8] {
            var b: [UInt8] = withUnsafeBytes(of: argc.littleEndian) { Array($0) }
            b += Array(exec.utf8) + [0] + [UInt8](repeating: 0, count: pad)
            for p in parts { b += p }
            b += Array(env.utf8)
            return b
        }
        func parse(_ b: [UInt8], size: Int? = nil) -> [String]? {
            b.withUnsafeBytes { HealthSensor.parseProcArgs($0, size: size ?? b.count) }
        }
        var cases: [(String, Bool)] = []
        func check(_ name: String, _ got: [String]?, _ want: [String]?) { cases.append((name, got == want)) }

        check("normal: argc 2, padded exec path",
              parse(payload(argc: 2, exec: "/usr/local/bin/x", pad: 3,
                            parts: [Array("/usr/local/bin/x\0".utf8), Array("--flag\0".utf8)])),
              ["/usr/local/bin/x", "--flag"])
        check("empty argument after argv[0] is kept",
              parse(payload(argc: 3, exec: "/x", pad: 1, parts: [Array("a\0".utf8), [0], Array("b\0".utf8)])),
              ["a", "", "b"])
        check("truncated payload (size cuts the last argument)",
              parse(payload(argc: 2, exec: "/x", pad: 1, parts: [Array("a\0".utf8), Array("bcd\0".utf8)], env: ""),
                    size: 4 + 3 + 2 + 2),
              nil)
        check("missing terminator on the only argument",
              parse(withUnsafeBytes(of: Int32(1).littleEndian) { Array($0) } + Array("/x\0".utf8) + Array("abc".utf8)),
              nil)
        check("argc larger than the payload",
              parse(withUnsafeBytes(of: Int32(100_000).littleEndian) { Array($0) } + Array("/x\0a\0".utf8)),
              nil)
        check("argc says 5, payload has 2",
              parse(payload(argc: 5, exec: "/x", pad: 1, parts: [Array("a\0".utf8), Array("b\0".utf8)], env: "")),
              nil)
        check("argc 0", parse(payload(argc: 0, exec: "/x", pad: 1, parts: [Array("a\0".utf8)])), nil)
        check("argc negative", parse(payload(argc: -1, exec: "/x", pad: 1, parts: [Array("a\0".utf8)])), nil)
        check("payload of 4 bytes", parse([2, 0, 0, 0]), nil)
        check("exec path never terminated", parse([1, 0, 0, 0] + Array("/usr/bin/x".utf8)), nil)
        check("invalid UTF-8 argument",
              parse(payload(argc: 1, exec: "/x", pad: 1, parts: [[0xFF, 0xFE, 0] as [UInt8]])), nil)
        check("environment after argv is ignored",
              parse(payload(argc: 1, exec: "/x", pad: 2, parts: [Array("a\0".utf8)], env: "PATH=/b\0X=\0")),
              ["a"])
        check("argc exactly 4096 is the ceiling",
              parse(payload(argc: 4097, exec: "/x", pad: 1, parts: [[UInt8]](repeating: [0], count: 4097), env: "")),
              nil)

        // Option scanner: `--` ends the options.
        let sJ = ["claude", "--output-format", "stream-json", "--input-format=stream-json"]
        cases.append(("summarizer shape (both spellings)", HealthSensor.isSummarizer(sJ)))
        cases.append(("options after `--` are ignored",
                      !HealthSensor.isSummarizer(["claude", "--", "--output-format", "stream-json", "--input-format", "stream-json"])))
        cases.append(("-p after `--` does not make print mode",
                      HealthSensor.isInteractive(["claude", "--", "-p"])))
        cases.append(("-p before `--` is print mode", HealthSensor.isPrintMode(["claude", "-p", "--", "x"])))
        cases.append(("user-data-dir= spelling", HealthSensor.userDataDir(["c", "--user-data-dir=/tmp/x"]) == "/tmp/x"))
        cases.append(("user-data-dir separate value", HealthSensor.userDataDir(["c", "--user-data-dir", "/tmp/y"]) == "/tmp/y"))
        cases.append(("user-data-dir after `--` ignored", HealthSensor.userDataDir(["c", "--", "--user-data-dir=/tmp/x"]) == nil))
        let chrome = "/Applications" + HealthSensor.chromeMainSuffix
        cases.append(("chrome: /tmp/../tmp/x standardises to throwaway",
                      HealthSensor.headlessChrome(path: chrome, args: ["c", "--headless=new", "--user-data-dir=/tmp/../tmp/x"], ppid: 1) == .throwawayProfile))
        cases.append(("chrome: relative user-data-dir is persistent",
                      HealthSensor.headlessChrome(path: chrome, args: ["c", "--headless=new", "--user-data-dir=tmp/x"], ppid: 1) == .persistentProfile))
        cases.append(("chrome: /Users profile is persistent",
                      HealthSensor.headlessChrome(path: chrome, args: ["c", "--headless", "--user-data-dir=/Users/x/p"], ppid: 1) == .persistentProfile))
        cases.append(("chrome: helper path is not a main",
                      HealthSensor.headlessChrome(path: chrome + " Helper", args: ["c", "--headless"], ppid: 1) == .none))
        cases.append(("chrome: ppid 2 is not orphaned",
                      HealthSensor.headlessChrome(path: chrome, args: ["c", "--headless", "--user-data-dir=/tmp/x"], ppid: 2) == .none))
        cases.append(("worker: bun + script", HealthSensor.isWorker(path: "/u/.bun/bin/bun", args: ["bun", "/u/plugin/scripts/worker-service.cjs"])))
        cases.append(("worker: perl + script is not the worker", !HealthSensor.isWorker(path: "/usr/bin/perl", args: ["perl", "/u/plugin/scripts/worker-service.cjs"])))
        cases.append(("claude binary: versions dir + argv0 claude",
                      HealthSensor.isClaudeBinary(path: HealthSensor.claudeVersionsDir + "2.1.277", args: ["/u/.local/bin/claude"])))
        cases.append(("claude binary: versions dir + argv0 ugrep is not",
                      !HealthSensor.isClaudeBinary(path: HealthSensor.claudeVersionsDir + "2.1.277", args: ["ugrep", "-G"])))
        cases.append(("claude binary: other path + argv0 claude is not",
                      !HealthSensor.isClaudeBinary(path: "/usr/local/bin/claude", args: ["claude"])))

        // Burst rule: 25 summarizers 1-25 min old (the 2026-11-09 boot burst).
        do {
            let now = Date()
            func summ(_ i: Int) -> ProcInfo {
                let start = now.addingTimeInterval(-Double(i) * 60)
                return ProcInfo(pid: pid_t(50_000 + i), ppid: 5702, rss: 400 << 20,
                                startSec: Int64(start.timeIntervalSince1970), startUsec: 0, started: start,
                                path: "/x/claude", args: ["claude"], ownerPid: 5702, owner: "claude-mem worker")
            }
            var stack = ClaudeStack()
            stack.summarizers = (1...25).map(summ)
            let sample = HealthSample(memFreePct: 60, memSource: "test", vm: nil, swap: nil, load: nil, ncpu: 14,
                                      kernelPressure: nil, sampledAt: now, claude: stack, sampleMillis: 0,
                                      validity: Validity(memory: true, vm: false, swap: false, load: false))
            let max = HealthPrefs.summarizerBurstMax
            let t = HealthAction.targets(in: sample)
            let reaped = Set(t.summarizers.map(\.pid))
            let wantReaped = Set((max + 1...25).map { pid_t(50_000 + $0) })   // the oldest beyond the newest `max`
            cases.append(("burst rule: 25 young summarizers, newest \(max) kept, \(25 - max) reaped",
                          max > 0 && reaped == wantReaped))
            stack.summarizers = (1...max).map(summ)
            let quiet = HealthSample(memFreePct: 60, memSource: "test", vm: nil, swap: nil, load: nil, ncpu: 14,
                                     kernelPressure: nil, sampledAt: now, claude: stack, sampleMillis: 0,
                                     validity: Validity(memory: true, vm: false, swap: false, load: false))
            cases.append(("burst rule: \(max) young summarizers, none reaped", HealthAction.targets(in: quiet).summarizers.isEmpty))
        }

        var failures = 0
        for (name, ok) in cases {
            print((ok ? "PASS  " : "FAIL  ") + name)
            if !ok { failures += 1 }
        }
        print("\(cases.count - failures)/\(cases.count) passed")
        return failures
    }
}
