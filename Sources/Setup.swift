import Cocoa

// ─────────────────────────────────────────────────────────────────────────────
// First-run setup (added 2026-11-09 for the DMG)
//
// Four pages: Welcome (and Move to Applications when launched from the disk
// image), Connect Claude (finds the Claude Code login in the Keychain and makes
// one test call to the usage API), Options (login, warnings, leak clearing,
// notifications), Done. Shown once on first launch; "Setup & About…" in the
// menu opens it again. Installs that predate it are marked done silently.
// ─────────────────────────────────────────────────────────────────────────────

enum Setup {
    static let doneKey = "setup.completed"
    static let author = "Martin Kawalski"
    static let repo = "github.com/CavalPinarello/claude-usage-widget"
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    static var isDone: Bool {
        get { UserDefaults.standard.bool(forKey: doneKey) }
        set { UserDefaults.standard.set(newValue, forKey: doneKey) }
    }

    /// First launch of this version of the app: show setup, unless this Mac
    /// already ran Headroom before setup existed (it has a login agent or
    /// health prefs), in which case it is marked done and stays quiet.
    static func showIfNeeded(onFinish: @escaping () -> Void) {
        if isDone { return }
        // Registered defaults would answer for any key, so read only what was saved.
        let saved = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
        if LoginItem.isEnabled || saved.keys.contains(where: { $0.hasPrefix("health.") }) {
            isDone = true
            return
        }
        open(page: 0, onFinish: onFinish)
    }

    private static var window: SetupWindow?

    static func open(page: Int = 0, onFinish: (() -> Void)? = nil) {
        if window == nil { window = SetupWindow() }
        window?.onFinish = onFinish
        window?.show(page: page)
    }

    // MARK: Install location

    /// Launched straight from the disk image, or from a quarantined copy macOS
    /// runs from a random read-only path.
    static var runningFromDiskImage: Bool {
        let p = Bundle.main.bundlePath
        return p.hasPrefix("/Volumes/") || p.contains("/AppTranslocation/")
    }

    /// Copies the app to /Applications (or ~/Applications when that is not
    /// writable), clears the quarantine flag the copy inherits (the person
    /// already chose to open it) and relaunches the copy. Returns an error
    /// message, or nil once the new copy is starting.
    static func moveToApplications() -> String? {
        let fm = FileManager.default
        let src = Bundle.main.bundlePath
        let candidates = ["/Applications", NSHomeDirectory() + "/Applications"]
        for dir in candidates {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            guard fm.isWritableFile(atPath: dir) else { continue }
            let dst = dir + "/Headroom.app"
            do {
                if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
                try fm.copyItem(atPath: src, toPath: dst)
            } catch { continue }
            _ = SpeedUp.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dst], timeout: 20)
            // The new copy must start after this one has quit: the single-
            // instance guard in main.swift would otherwise send it away.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1.5; /usr/bin/open -n \"$0\"", dst]
            do { try p.run() } catch { return "Copied to \(dir), but it could not be started. Open it from there." }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            return nil
        }
        return "Could not copy into Applications. Drag Headroom there from the disk image instead."
    }
}

// MARK: - Window

final class SetupWindow: NSWindowController, NSWindowDelegate {
    var onFinish: (() -> Void)?
    private var page = 0
    private let content = NSView()
    private let back = NSButton(title: "Back", target: nil, action: nil)
    private let next = NSButton(title: "Continue", target: nil, action: nil)
    private let dots = NSStackView()

    // Options page state, applied on Finish.
    private var wantLogin = true
    private var wantWarn = true
    private var wantReap = true

    private enum Connection { case unknown, noLogin, checking, connected(String), failed(String) }
    private var connection = Connection.unknown

    static let size = NSSize(width: 560, height: 470)

    init() {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: SetupWindow.size),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self

        let root = w.contentView!
        content.frame = NSRect(x: 0, y: 64, width: SetupWindow.size.width, height: SetupWindow.size.height - 64)
        content.autoresizingMask = [.width, .height]
        root.addSubview(content)

        let bar = NSBox(frame: NSRect(x: 0, y: 63, width: SetupWindow.size.width, height: 1))
        bar.boxType = .separator
        root.addSubview(bar)

        back.bezelStyle = .rounded; back.controlSize = .large
        back.frame = NSRect(x: SetupWindow.size.width - 24 - 120 - 10 - 90, y: 16, width: 90, height: 32)
        back.target = self; back.action = #selector(goBack)
        root.addSubview(back)

        next.bezelStyle = .rounded; next.controlSize = .large
        next.keyEquivalent = "\r"
        next.frame = NSRect(x: SetupWindow.size.width - 24 - 120, y: 16, width: 120, height: 32)
        next.target = self; next.action = #selector(goNext)
        root.addSubview(next)

        dots.orientation = .horizontal
        dots.spacing = 7
        dots.frame = NSRect(x: 24, y: 26, width: 80, height: 12)
        root.addSubview(dots)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(page p: Int) {
        page = max(0, min(3, p))
        render()
        if page == 1, case .unknown = connection { detectLogin() }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing early still counts: it should not pop up at every launch.
        Setup.isDone = true
    }

    @objc private func goBack() { page = max(0, page - 1); render() }

    @objc private func goNext() {
        if page == 2 { applyOptions() }
        if page == 3 {
            Setup.isDone = true
            window?.close()
            onFinish?()
            return
        }
        page += 1
        render()
        if page == 1, case .unknown = connection { detectLogin() }
    }

    private func applyOptions() {
        if LoginItem.isEnabled != wantLogin { LoginItem.setEnabled(wantLogin) }
        HealthPrefs.earlyWarning = wantWarn
        HealthPrefs.autoReap = wantReap
        if wantWarn { HealthNotifier.requestAuthorization() }
    }

    // MARK: Pages

    private func render() {
        content.subviews.forEach { $0.removeFromSuperview() }
        switch page {
        case 0: welcome()
        case 1: connect()
        case 2: options()
        default: done()
        }
        back.isHidden = page == 0
        next.title = page == 3 ? "Done" : page == 1 && !isConnected ? "Skip for Now" : "Continue"
        dots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for i in 0..<4 {
            let d = NSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
            d.wantsLayer = true
            d.layer?.cornerRadius = 3.5
            d.layer?.backgroundColor = (i == page ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
            d.widthAnchor.constraint(equalToConstant: 7).isActive = true
            d.heightAnchor.constraint(equalToConstant: 7).isActive = true
            dots.addArrangedSubview(d)
        }
    }

    private var isConnected: Bool { if case .connected = connection { return true }; return false }

    private var W: CGFloat { SetupWindow.size.width }
    private var H: CGFloat { content.bounds.height }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor, align: NSTextAlignment = .center,
                       y: CGFloat, height: CGFloat, x: CGFloat = 48, width: CGFloat? = nil) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.alignment = align
        f.isSelectable = false
        f.frame = NSRect(x: x, y: y, width: width ?? (W - x * 2), height: height)
        content.addSubview(f)
        return f
    }

    private func art(_ mood: Mascot.Mood, y: CGFloat, height: CGFloat) {
        let v = MascotView(mood: mood)
        v.frame = NSRect(x: (W - height * 1.5) / 2, y: y, width: height * 1.5, height: height)
        content.addSubview(v)
    }

    private func welcome() {
        art(.sluggish, y: H - 222, height: 196)
        _ = label("Meet Headroom", size: 26, weight: .bold, y: H - 262, height: 34)
        _ = label("It lives in your menu bar and keeps two numbers in sight: how much Claude you have left this week, "
                  + "and how much memory your Mac has left before it starts to crawl. When it gets tight, one click fixes it.",
                  size: 13, color: .secondaryLabelColor, y: H - 324, height: 56, x: 70)
        _ = label("Made by \(Setup.author)", size: 11.5, weight: .semibold, color: .tertiaryLabelColor, y: H - 352, height: 16)

        if Setup.runningFromDiskImage {
            let note = label("You opened Headroom from the disk image. Move it to Applications first so it can start at login.",
                             size: 12, color: .systemOrange, y: 12, height: 34, x: 70)
            note.font = .systemFont(ofSize: 12, weight: .medium)
            let move = NSButton(title: "Move to Applications", target: self, action: #selector(moveApp))
            move.bezelStyle = .rounded; move.controlSize = .large
            move.frame = NSRect(x: (W - 200) / 2, y: 52, width: 200, height: 32)
            move.bezelColor = .controlAccentColor
            content.addSubview(move)
        }
    }

    @objc private func moveApp() {
        if let err = Setup.moveToApplications() {
            let a = NSAlert(); a.messageText = "Could not move Headroom"; a.informativeText = err
            a.runModal()
        }
    }

    private func connect() {
        let icon = NSImageView(frame: NSRect(x: (W - 64) / 2, y: H - 120, width: 64, height: 64))
        icon.image = PanelView.appIcon ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: nil)
        content.addSubview(icon)
        _ = label("Connect to Claude", size: 22, weight: .bold, y: H - 160, height: 30)
        _ = label("Headroom reads the same numbers Claude Code shows under /usage, from Anthropic's usage API. "
                  + "It signs in with the Claude Code login already saved in your Keychain, so there is no API key to paste "
                  + "and no extra cost. The login is sent only to api.anthropic.com.",
                  size: 12.5, color: .secondaryLabelColor, y: H - 232, height: 66, x: 60)

        let status: (String, NSColor, String?)
        switch connection {
        case .unknown, .checking:
            status = ("Looking for your Claude Code login\u{2026}", .secondaryLabelColor, nil)
        case .noLogin:
            status = ("No Claude Code login on this Mac yet. Install Claude Code, run claude in Terminal and sign in "
                      + "with your Claude account, then press Check Again.", .systemOrange, nil)
        case .connected(let s):
            status = ("Connected. " + s, .systemGreen, nil)
        case .failed(let s):
            status = (s, .systemRed, nil)
        }
        let box = NSBox(frame: NSRect(x: 60, y: H - 316, width: W - 120, height: 66))
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 0
        box.fillColor = status.1.withAlphaComponent(0.10)
        content.addSubview(box)
        let t = label(status.0, size: 12.5, weight: .medium, color: status.1, y: 0, height: 0, x: 76)
        t.frame.size.width = W - 152
        // Centre the text in the box, however many lines it takes.
        let th = ceil(t.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: W - 152, height: 200)).height ?? 18)
        t.frame = NSRect(x: 76, y: box.frame.midY - th / 2, width: W - 152, height: th)

        var buttons: [NSButton] = []
        switch connection {
        case .noLogin:
            buttons.append(button("Copy Install Command", #selector(copyInstall)))
            buttons.append(button("Check Again", #selector(detectLoginAction)))
        case .failed:
            buttons.append(button("Try Again", #selector(testConnection)))
        case .unknown, .checking, .connected:
            break
        }
        var x = (W - CGFloat(buttons.count) * 180 + 10) / 2
        for b in buttons {
            b.frame = NSRect(x: x, y: H - 366, width: 170, height: 32)
            content.addSubview(b); x += 180
        }
    }

    private func button(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded; b.controlSize = .large
        return b
    }

    @objc private func copyInstall() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("curl -fsSL https://claude.ai/install.sh | bash", forType: .string)
    }

    @objc private func detectLoginAction() { detectLogin() }

    private func detectLogin() {
        connection = .checking; render()
        DispatchQueue.global(qos: .userInitiated).async {
            let found = UsageFetcher.hasLogin()
            DispatchQueue.main.async {
                if found { self.testConnection() } else { self.connection = .noLogin; self.render() }
            }
        }
    }

    /// One real call to the usage endpoint. The first one may make macOS ask
    /// whether `security` may read the Claude Code item: Always Allow.
    @objc private func testConnection() {
        connection = .checking; render()
        UsageFetcher.fetch { snap in
            DispatchQueue.main.async {
                if let w = snap.weekly {
                    let plan = snap.plan.isEmpty ? "" : "\(snap.plan) plan, "
                    self.connection = .connected(String(format: "%@%.0f%% of this week left.", plan, w.percentLeft))
                } else {
                    self.connection = .failed(snap.error ?? "The usage API answered, but without a weekly limit.")
                }
                self.render()
                NotificationCenter.default.post(name: Setup.connected, object: snap)
            }
        }
    }

    private func options() {
        _ = label("A few choices", size: 22, weight: .bold, y: H - 70, height: 30)
        _ = label("You can change all of these later from the menu bar.", size: 12.5,
                  color: .secondaryLabelColor, y: H - 96, height: 18)
        let rows: [(String, String, Bool, Selector)] = [
            ("Open at login", "Starts with your Mac, and restarts by itself if it ever crashes.", wantLogin, #selector(toggleLogin(_:))),
            ("Warn me before the Mac slows down", "A notification a few minutes before memory runs out, with one click to fix it.", wantWarn, #selector(toggleWarn(_:))),
            ("Clear leaked Claude helpers automatically", "Closes stuck background helpers (claude-mem summarizers, stray headless Chrome). Never your sessions or apps.", wantReap, #selector(toggleReap(_:))),
        ]
        var y = H - 160
        for (title, sub, on, sel) in rows {
            let b = NSButton(checkboxWithTitle: title, target: self, action: sel)
            b.state = on ? .on : .off
            b.font = .systemFont(ofSize: 13.5, weight: .semibold)
            b.frame = NSRect(x: 80, y: y, width: W - 160, height: 22)
            content.addSubview(b)
            _ = label(sub, size: 12, color: .secondaryLabelColor, align: .left, y: y - 36, height: 34, x: 102, width: W - 182)
            y -= 80
        }
    }

    @objc private func toggleLogin(_ b: NSButton) { wantLogin = b.state == .on }
    @objc private func toggleWarn(_ b: NSButton) { wantWarn = b.state == .on }
    @objc private func toggleReap(_ b: NSButton) { wantReap = b.state == .on }

    private func done() {
        art(.fast, y: H - 220, height: 180)
        _ = label("Clean, fast, and watching", size: 24, weight: .bold, y: H - 264, height: 32)
        _ = label("Look for the rings at the top right of your screen. The outer ring is your week of Claude, the inner one "
                  + "your 5-hour session. Click them for details, Speed Up Mac and Disk Space.",
                  size: 13, color: .secondaryLabelColor, y: H - 322, height: 54, x: 70)
        _ = label("Headroom \(Setup.version) \u{00B7} made by \(Setup.author)",
                  size: 11.5, weight: .semibold, color: .tertiaryLabelColor, y: H - 348, height: 16)
        _ = label(Setup.repo, size: 11, color: .tertiaryLabelColor, y: H - 366, height: 16)
    }
}

extension Setup {
    /// Posted after the setup page reaches the usage API, so the menu bar
    /// refreshes straight away instead of at the next 5-minute poll.
    static let connected = Notification.Name("HeadroomSetupConnected")
}

final class MascotView: NSView {
    let mood: Mascot.Mood
    init(mood: Mascot.Mood) { self.mood = mood; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func draw(_ dirtyRect: NSRect) { Mascot.draw(mood, in: bounds) }
}
