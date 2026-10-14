import AppKit
import DFMCore

// Run on Servers… (README "Commands"): one command on several servers at once, in one output window.
extension AppDelegate {
    /// The sheet (U8): saved servers and ~/.ssh/config hosts, as Connect… lists them, with the last choice and command.
    func runOnServers() {
        let choices = serverChoices().map { RunOnServersSheet.Choice(title: $0.title, target: $0.target, saved: $0.saved) }
        guard !choices.isEmpty else { return active.flash("No servers to run on: save one (New Server…) or add hosts to ~/.ssh/config") }
        RunOnServersSheet.show(on: window, choices: choices, ticked: Set(defaults.stringArray(forKey: "runOnServers") ?? []),
                               command: defaults.string(forKey: "runOnServersCommand") ?? "") { [unowned self] command, chosen in
            defaults.set(chosen.map { ServerRow.key($0.target) }, forKey: "runOnServers")
            defaults.set(command, forKey: "runOnServersCommand")
            Task { await runOnServers(command, chosen) }
        }
    }

    /// U11: a command that removes, moves or stops things (`Shell.isDangerous`) on production servers asks once, naming
    /// them all, ↩ answering Cancel; other commands don't ask, as F2 there doesn't. Locked servers ask for Touch ID one
    /// after another before anything runs — one refused is skipped, the rest run. Each production server's run is a
    /// line in the production log, with its exit status.
    func runOnServers(_ command: String, _ chosen: [RunOnServersSheet.Choice]) async {
        if let q = Self.runQuestion(command, on: chosen.map(\.target)), await choose(q.message, info: q.info, ["Run", "Cancel"], default: 1) != 0 { return }
        let (run, skipped) = await Self.unlocked(chosen)
        guard !run.isEmpty else { return active.flash("🔒 Nothing ran: the servers stayed locked") }
        let env = SSHAskpass.env.merging(["DFM_ASKPASS_WHY": "For “Run on Servers”"]) { $1 }
        Self.start(command, on: run, of: chosen.count, skipped: skipped, env: env)
    }

    /// The question before a dangerous command on production servers, naming them all; nil: none to ask.
    static func runQuestion(_ command: String, on targets: [SFTPTarget]) -> (message: String, info: String)? {
        let prod = SavedServer.prodNote(targets)
        guard !prod.isEmpty, Shell.isDangerous(command) else { return nil }
        return ("Run “\(command)” on \(targets.count) server\(targets.count == 1 ? "" : "s")?", targets.count == 1 ? String(prod.dropLast()) : prod + "It runs on all \(targets.count) at once.")
    }

    /// Touch ID for each locked one, one after another, before anything runs: one refused is skipped.
    static func unlocked(_ chosen: [RunOnServersSheet.Choice]) async -> (run: [RunOnServersSheet.Choice], skipped: [String]) {
        var run: [RunOnServersSheet.Choice] = [], skipped: [String] = []
        for c in chosen {
            if ServerLock.needsUnlock(c.target), let s = ServerLock.server(for: c.target), await !ServerLock.authorize(s, "run a command on") {
                skipped.append(c.title)
            } else {
                run.append(c)
            }
        }
        return (run, skipped)
    }

    /// The output window; each production server's run a line in the production log as soon as it's over (one done
    /// isn't lost to quitting while another still runs). The servers' connections stay for ControlPersist, as ssh's
    /// own do: the next run needs no login.
    static func start(_ command: String, on run: [RunOnServersSheet.Choice], of count: Int, skipped: [String], env: [String: String]) {
        Shell.run(command, on: run.map { MultiRun.Server(name: $0.title, target: $0.target) }, skipped: skipped, env: env,
                  title: "Run on \(count) server\(count == 1 ? "" : "s"): \(command)") { i, o in
            let t = run[i].target   // as F2's: ran as the user (ssh)
            switch o {
            case .exit(let s): AuditLog.write(t, "command", paths: [], command: command, exit: s)
            case .notRun(let why): AuditLog.write(t, "command", paths: [], command: command, exit: 255, error: why)
            case .stopped: AuditLog.write(t, "command", paths: [], command: command, exit: nil, error: "stopped")
            case .skipped: break
            }
        }
    }
}

/// Run on Servers…' sheet: the command (focused), a filter, the servers with check boxes — production in its color,
/// locked with 🔒 — and "Run on N Servers", the default button, off with no server or no command. What runs is what's
/// ticked and shown: the filter hides the rest. ⌘A in the filter ticks all shown, ⇧⌘A unticks them.
@MainActor
final class RunOnServersSheet: NSWindowController, NSTextFieldDelegate, NSSearchFieldDelegate {
    struct Choice {
        let title: String
        let target: SFTPTarget
        let saved: SavedServer?
    }

    let choices: [Choice]
    let command = NSTextField(string: "")
    let filter = NSSearchField()
    private(set) var boxes: [NSButton] = []
    let runButton = NSButton(title: "", target: nil, action: nil)
    private let onRun: (String, [Choice]) -> Void
    private var keys: Any?
    private(set) static var current: RunOnServersSheet?

    static func show(on parent: NSWindow, choices: [Choice], ticked: Set<String>, command: String, onRun: @escaping (String, [Choice]) -> Void) {
        let s = RunOnServersSheet(choices: choices, ticked: ticked, command: command, onRun: onRun)
        current = s
        parent.beginSheet(s.window!)
        s.window!.makeFirstResponder(s.command)   // a sheet doesn't take its initialFirstResponder
    }

    private init(choices: [Choice], ticked: Set<String>, command text: String, onRun: @escaping (String, [Choice]) -> Void) {
        self.choices = choices
        self.onRun = onRun
        super.init(window: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .resizable],
                                    backing: .buffered, defer: false))
        command.stringValue = text
        command.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        command.placeholderString = "uptime · df -h / · systemctl is-active nginx"
        command.delegate = self
        filter.placeholderString = "Filter by name or host — ⌘A ticks all shown, ⇧⌘A none"
        filter.delegate = self
        let note = NSTextField(wrappingLabelWithString: "Runs in each server's login shell, as F2 does: no terminal, so sudo only with -n.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        for c in choices {
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(update))
            let name = NSMutableAttributedString(string: (c.saved?.locked == true ? "🔒 " : "") + c.title,
                                                 attributes: [.foregroundColor: c.saved?.prod == true ? SavedServer.color : NSColor.labelColor])
            let host = c.saved.map { ServerRow.address($0.target) } ?? "~/.ssh/config"
            if host != c.title {
                name.append(NSAttributedString(string: "   " + host, attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                                                                                  .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]))
            }
            b.attributedTitle = name
            b.state = ticked.contains(ServerRow.key(c.target)) ? .on : .off
            boxes.append(b)
            list.addArrangedSubview(b)
        }
        let page = Flipped()
        page.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.documentView = page
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        page.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet))
        cancel.keyEquivalent = "\u{1b}"
        runButton.target = self
        runButton.action = #selector(run)
        runButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, runButton])

        let root = NSView()
        let label = NSTextField(labelWithString: "Command:")
        for v in [label, command, note, filter, scroll, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            command.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            command.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            command.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            note.topAnchor.constraint(equalTo: command.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: command.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            filter.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 14),
            filter.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            filter.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            page.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            page.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.topAnchor.constraint(equalTo: page.topAnchor, constant: 6),
            list.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 8),
            list.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -8),
            list.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -6),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        window!.title = "Run on Servers"
        window!.contentView = root
        window!.autorecalculatesKeyViewLoop = true   // Tab: command, filter, the boxes (with keyboard navigation on), the buttons
        update()
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let ticked = MainActor.assumeIsolated { () -> Bool in
                let key = Shortcut(event: e), all = key == Shortcut("cmd+a")
                guard let self, e.window === self.window, all || key == Shortcut("cmd+shift+a"),
                      (self.window?.firstResponder as? NSTextView)?.delegate === self.filter else { return false }
                self.tickShown(all)
                return true
            }
            return ticked ? nil : e
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// What runs: ticked and shown.
    var chosen: [Choice] { zip(choices, boxes).filter { $1.state == .on && !$1.isHidden }.map(\.0) }

    /// The filter's words in the name or the address.
    func filtered(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        for (c, b) in zip(choices, boxes) {
            b.isHidden = !q.isEmpty && !(c.title + " " + c.target.host).lowercased().contains(q)
        }
        update()
    }

    /// The boxes shown: all ticked, or (`false`) none.
    func tickShown(_ on: Bool = true) {
        boxes.filter { !$0.isHidden }.forEach { $0.state = on ? .on : .off }
        update()
    }

    @objc func update() {
        let n = chosen.count
        runButton.title = "Run on \(n) Server\(n == 1 ? "" : "s")"
        runButton.isEnabled = n > 0 && !command.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === filter { filtered(filter.stringValue) } else { update() }
    }

    @objc func run() {
        let (text, picked) = (command.stringValue.trimmingCharacters(in: .whitespaces), chosen)
        guard !picked.isEmpty, !text.isEmpty else { return }
        close()
        onRun(text, picked)
    }

    @objc private func cancelSheet() { close() }

    override func close() {
        keys.map(NSEvent.removeMonitor)
        keys = nil
        if let w = window, let parent = w.sheetParent { parent.endSheet(w) }
        Self.current = nil
    }
}

/// A scroll view's page that starts at the top.
private final class Flipped: NSView {
    override var isFlipped: Bool { true }
}
