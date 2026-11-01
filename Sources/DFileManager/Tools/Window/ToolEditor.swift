import AppKit
import DFMCore

/// A tool's file in Kermo's editor (Tools PR 4, protocol §12–14), with a pane beside its text: **Problems** — the file
/// checked as Kermo loads it, as you type; a click goes to the line — and **Test**, which runs what the tool runs by
/// itself (never an action) on a server that's connected. Saving writes it owner-only to ~/.config/dfilemanager/tools,
/// reads the library again and asks "Use the tool…?"; a new tool then asks where it's used. New Tool… starts one from
/// `ToolNew`'s starters; Customize starts yours from a built-in, under its id.
@MainActor
final class ToolEditor: NSView, NSTextViewDelegate, NSMenuDelegate {
    unowned let app: AppDelegate
    /// ~/.config/dfilemanager/tools/<id>.json
    let url: URL
    /// A built-in's folder, whose scripts a Customize copies next to yours on its first save.
    let scriptsFrom: URL?
    /// Not on disk before its first save: that save asks where it's used too.
    private(set) var isNew: Bool
    private(set) weak var editor: Editor?
    private(set) var problems: NSTextView!
    private(set) var output: NSTextView!
    let servers = NSPopUpButton()
    let test = NSButton(title: "Test", target: nil, action: nil)
    let save = NSButton(title: "Save", target: nil, action: nil)
    /// The popup's servers, in its order.
    private(set) var places: [(SavedServer, SFTPTarget)] = []
    private var pending: Task<Void, Never>?
    /// Test said once what it runs; production asks every time.
    private var told = false
    private var kept: [AnyObject] = []

    /// Tests: where Test may run (connected servers, as their sessions name them).
    nonisolated(unsafe) static var connected: (@MainActor (AppDelegate) -> [(SavedServer, SFTPTarget)])?

    // MARK: Opening one

    /// New Tool…: `kind`'s starter as <id>.json — written by its first save.
    static func new(_ app: AppDelegate, _ kind: ToolNew.Kind, id: String, title: String) {
        guard let dir = ToolRunner.own else { return }
        open(app, dir.appendingPathComponent(id + ".json"), text: ToolNew.text(kind, id: id, title: title), isNew: true)
    }

    /// One of yours, as it is on disk — loading or not.
    static func edit(_ app: AppDelegate, _ url: URL) {
        open(app, url, text: nil, isNew: false)
    }

    /// A built-in's file as yours, under its id (§12): yours takes its place once saved — one with an error leaves the
    /// built-in in place, and Problems says why. Yours already there (not loading): that file.
    static func customize(_ app: AppDelegate, _ tool: LoadedTool) {
        guard let dir = ToolRunner.own else { return }
        let url = dir.appendingPathComponent(tool.preset.id + ".json"), from = URL(fileURLWithPath: tool.path)
        let text = FileManager.default.fileExists(atPath: url.path) ? nil : (try? String(contentsOf: from, encoding: .utf8))
        open(app, url, text: text, scriptsFrom: from.deletingLastPathComponent(), isNew: false)
    }

    private static func open(_ app: AppDelegate, _ url: URL, text: String?, scriptsFrom: URL? = nil, isNew: Bool) {
        if let w = Editor.window(for: url) { return w.makeKeyAndOrderFront(nil) }
        let dir = url.deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o700)
        let pane = ToolEditor(app, url: url, scriptsFrom: scriptsFrom, isNew: isNew)
        do {
            let e = try Editor.open(url, text: text, beside: pane) { [weak pane] _ in pane?.saved() }
            pane.attach(e)
        } catch { app.showError(error) }
    }

    init(_ app: AppDelegate, url: URL, scriptsFrom: URL?, isNew: Bool) {
        (self.app, self.url, self.scriptsFrom, self.isNew) = (app, url, scriptsFrom, isNew)
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        let problemsScroll = NSTextView.scrollableTextView(), outputScroll = NSTextView.scrollableTextView()
        problems = problemsScroll.documentView as? NSTextView
        output = outputScroll.documentView as? NSTextView
        for (t, s) in [(problems!, problemsScroll), (output!, outputScroll)] {
            (t.isEditable, t.isSelectable, t.drawsBackground) = (false, true, false)
            t.textContainerInset = NSSize(width: 2, height: 4)
            (s.drawsBackground, s.borderType, s.autohidesScrollers) = (false, .noBorder, true)
        }
        problems.delegate = self
        problems.setAccessibilityLabel("Problems")
        output.setAccessibilityLabel("Test output")
        servers.menu?.delegate = self
        servers.setAccessibilityLabel("Server to test on")
        servers.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        kept = [MenuAction.attach(to: test) { [unowned self] in runTest() },
                MenuAction.attach(to: save) { [unowned self] in Task { await editor?.save() } }]
        let testRow = NSStackView(views: [Self.heading("Test on"), servers, test])
        testRow.spacing = 6
        let note = Self.small("Runs what the tool runs by itself — its check, header, version and list — never an action, on a server already connected.")
        let foot = NSStackView(views: [Self.small("⌘S saves it; then Kermo asks whether to use it."), save])
        let stack = NSStackView(views: [Self.heading("Problems"), problemsScroll, testRow, note, outputScroll, foot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     problemsScroll.heightAnchor.constraint(equalToConstant: 150)])
        for v in [problemsScroll, testRow, note, outputScroll, foot] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true }
        outputScroll.setContentHuggingPriority(.init(1), for: .vertical)
        say([(.plain, "Pick a server and Test: what the tool makes of the real output shows here — and every line that didn't fit.")])
        menuNeedsUpdate(servers.menu!)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func attach(_ e: Editor) {
        editor = e
        e.edited = { [weak self] in self?.later() }
        recheck()
    }

    // MARK: Problems

    /// The file as Kermo would load it now: the tool if nothing is an error, and every problem (§14). Its scripts are
    /// yours next to it, or a Customize's built-in ones till they're copied.
    func check() -> (tool: LoadedTool?, problems: [ToolProblem]) {
        let text = editor?.textView.string ?? "", dir = url.deletingLastPathComponent()
        func script(_ name: String) -> URL? {
            [dir, scriptsFrom].compactMap { $0?.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
        }
        let (preset, found) = ToolSchema.validate(Data(text.utf8), file: url.lastPathComponent, hasScript: { script($0) != nil }, hasSymbol: Symbol.exists)
        guard let preset else { return (nil, found) }
        let scripts = preset.scriptNames.reduce(into: [String: String]()) { all, n in all[n] = script(n).flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
        return (LoadedTool(preset: preset, path: url.path, builtIn: false, scripts: scripts, hash: "", warnings: found), found)
    }

    /// Typing: checked once it pauses.
    private func later() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { self?.recheck() }
        }
    }

    /// Errors (it isn't loaded) apart from warnings (it loads); each with its line, a link to it.
    func recheck() {
        let (tool, found) = check()
        let s = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor = .labelColor, bold: Bool = false, line: Int? = nil) {
            var a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: bold ? .semibold : .regular), .foregroundColor: color]
            if let line { a[.link] = "line:\(line)" }
            s.append(NSAttributedString(string: (s.length == 0 ? "" : "\n") + text, attributes: a))
        }
        let errors = found.filter { $0.level == .error }, warnings = found.filter { $0.level == .warning }
        if found.isEmpty { add("✓ No problems: Kermo loads it as it is.", Palette.ok) }
        if !errors.isEmpty { add("Errors — it isn't loaded:", Palette.fail, bold: true) }
        for p in errors { add("✕ " + p.description, line: p.line) }
        if !warnings.isEmpty { add("Warnings — it loads:", bold: true) }
        for p in warnings { add("⚠ " + p.description, line: p.line) }
        problems.textStorage?.setAttributedString(s)
        test.isEnabled = tool != nil && !places.isEmpty
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let s = (link as? String) ?? (link as? URL)?.absoluteString, s.hasPrefix("line:"), let n = Int(s.dropFirst(5)) else { return false }
        go(to: n)
        return true
    }

    /// Line `n` of the text, selected, in view.
    func go(to n: Int) {
        guard let tv = editor?.textView else { return }
        let text = tv.string as NSString
        var at = 0
        for _ in 1..<max(n, 1) where at < text.length { at = NSMaxRange(text.lineRange(for: NSRange(location: at, length: 0))) }
        var r = text.lineRange(for: NSRange(location: min(at, text.length), length: 0))
        if r.length > 0, text.substring(with: r).hasSuffix("\n") { r.length -= 1 }
        tv.setSelectedRange(r)
        tv.scrollRangeToVisible(r)
        tv.window?.makeFirstResponder(tv)
    }

    // MARK: Saving

    /// Owner-only; a Customize's scripts next to it; the library read again. Loaded: "Use the tool…?" — for a new one,
    /// Use on Servers… (which asks that first). Not loaded: Problems says why, and the built-in, if any, stays.
    private func saved() {
        chmod(url.path, 0o600)
        let dir = url.deletingLastPathComponent()
        if let from = scriptsFrom, let p = check().tool?.preset {
            for name in p.scriptNames where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
                if (try? FileManager.default.copyItem(at: from.appendingPathComponent(name), to: dir.appendingPathComponent(name))) != nil {
                    chmod(dir.appendingPathComponent(name).path, 0o600)
                }
            }
        }
        Config.flush()   // trust.json and servers.json as last written: reload reads them back
        let problems = app.tools.reload()
        app.toolsKnown(on: nil)
        recheck()
        guard let tool = app.tools.library.tools.first(where: { $0.path == url.path }) else {
            let mine = problems.first { $0.hasPrefix("tools/\(url.lastPathComponent):") }
            editor?.flash("Saved. Not loaded" + (mine.map { ": " + $0.dropFirst("tools/\(url.lastPathComponent): ".count) } ?? " — see Problems"))
            return
        }
        let first = isNew
        isNew = false
        Task {
            if first { await app.tools.useOnServers(tool, window: window) } else { _ = await app.tools.trustAsk(tool, window: window) }
            editor?.flash(app.tools.trust.trusts(tool) ? "Saved. In use: Tools ▸ shows it where it's found." : "Saved. Not in use yet: Tools ▸ lists it under Not in use yet, and asks again.")
            ToolsWindow.refresh()
        }
    }

    // MARK: Test

    /// Servers connected now, as their sessions name them (an alias in life); saved ones by their title.
    private func connectedNow() -> [(SavedServer, SFTPTarget)] {
        if let c = Self.connected { return c(app) }
        var all: [(SavedServer, SFTPTarget)] = []
        for t in app.serverList.sessions.map(\.target.asUser) + app.savedServers.map(\.target)
        where AppDelegate.connected(t) && !all.contains(where: { ServerRow.key($0.1) == ServerRow.key(t) }) {
            all.append((app.savedServer(at: t) ?? SavedServer(target: t), t))
        }
        return all
    }

    /// The popup, as servers are connected now: the one picked stays picked.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let was = servers.indexOfSelectedItem >= 0 && places.indices.contains(servers.indexOfSelectedItem) ? ServerRow.key(places[servers.indexOfSelectedItem].1) : nil
        places = connectedNow()
        servers.removeAllItems()
        servers.addItems(withTitles: places.map(\.0.title))
        if places.isEmpty { servers.addItem(withTitle: "No server connected") }
        servers.isEnabled = !places.isEmpty
        if let was, let i = places.firstIndex(where: { ServerRow.key($0.1) == was }) { servers.selectItem(at: i) }
        test.isEnabled = !places.isEmpty && check().tool != nil
    }

    /// On the server picked: what the tool runs by itself, shown first (production asks every time); never a login.
    func runTest() {
        menuNeedsUpdate(servers.menu!)
        guard places.indices.contains(servers.indexOfSelectedItem) else { return say([(.fail, "No server is connected. Test never logs in: connect one first.")]) }
        let (s, t) = places[servers.indexOfSelectedItem]
        guard let tool = check().tool else { return say([(.fail, "Fix the errors first: the tool doesn't load as it is.")]) }
        Task {
            guard AppDelegate.connected(t), ToolRunner.hasMaster(t) else { return say([(.fail, "\(s.title) isn't connected now. Test never logs in: connect it first.")]) }
            let runs = tool.runs.itself
            if !told || s.prod {
                var c = Confirm("Test \(tool.preset.title) on \(s.title)?", on: t.asRoot(runs.contains(where: \.root)), action: "Test")
                c.runs = "Test runs what the tool runs by itself, as the menus would — never one of its actions:"
                c.command = runs.isEmpty ? "  nothing" : runs.map(\.text).joined(separator: "\n")
                guard await app.confirm(c, on: window) == 0 else { return }
                told = true
            }
            guard await ServerLock.authorize(t, "test a tool on") else { return say([(.fail, "\(s.title) stays locked.")]) }
            test.isEnabled = false
            say([(.plain, "Testing on \(s.title)…")])
            let scope = app.tools.scope(tool.preset, on: s, t), saved = app.tools.settings.vars(tool.preset.id, on: app.tools.serverID(t)), env = SSHAskpass.env
            let said = await Blocking.run { Self.test(tool, scope, saved: saved, on: t, env: env) }
            test.isEnabled = check().tool != nil
            say([(.plain, "On \(s.title) at \(Date().formatted(date: .omitted, time: .standard)):")] + said)
        }
    }

    enum Mark: Sendable { case ok, fail, warn, plain }

    /// What runs by itself, each part on its own: the vars' commands, `requires` in one batch as the menus ask, the
    /// header, the version, the list — its rows (the first 20), its fields, the lines that didn't fit, stderr.
    nonisolated static func test(_ tool: LoadedTool, _ scope: ToolTemplate.Scope, saved: [String: String], on t: SFTPTarget,
                                 env: [String: String]) -> [(Mark, String)] {
        let p = tool.preset, cancel = CancelFlag()
        var out: [(Mark, String)] = [], scope = scope
        func first(_ s: String) -> String { s.split(whereSeparator: \.isNewline).first.map { String($0.prefix(300)) } ?? "" }
        /// Its output, or why it gave none: stopped, failed (exit, stderr's first line), couldn't start.
        func run(_ what: String, _ r: ToolRun, _ timeout: Double, format: ToolFormat? = nil) -> ToolExec.Ran? {
            do {
                let ran = try ToolRunner.exec(r, of: tool, scope, on: t, timeout: r.timeout ?? timeout, env: env, cancel: cancel).ran
                if let stopped = ran.stopped { out.append((.fail, "\(what): \(stopped)")); return nil }
                guard r.succeeded(ran.status, format: format) else {
                    out.append((.fail, "\(what): exit \(ran.status)" + (ran.errors.isEmpty ? "" : " — " + first(ran.errors))))
                    return nil
                }
                return ran
            } catch {
                out.append((.fail, "\(what): \(error.localizedDescription)"))
                return nil
            }
        }
        if !p.varCommands.isEmpty {
            var found: [String: String] = [:]
            for (name, r) in p.varCommands {
                guard let ran = run("vars.\(name)", r, 10) else { continue }
                found[name] = first(ran.text)
                out.append((.ok, "vars.\(name): \(first(ran.text))"))
            }
            scope.levels[scope.levels.count - 2] = p.varValues(saved: saved, found: found)
        }
        let items = ToolBatch.items([p])
        if !items.isEmpty {
            let a = ToolBatch.ask(t, items, scope: { _ in scope }, scripts: { _ in tool.scripts }, hasMaster: ToolRunner.hasMaster, command: ToolRunner.command)
            for i in items {
                let title = i.action.map { id in (p.allActions.first { $0.action.spec.id == id }?.action.spec.title ?? id) + " requires" } ?? "requires"
                guard let a else { out.append((.fail, "\(title): no answer from the server")); continue }
                out.append(a.passed.contains(i.name) ? (.ok, "\(title): passed") : (.fail, "\(title): failed — " + (i.action == nil ? "the tool doesn't show here" : "that action doesn't show here")))
            }
        }
        if let h = p.header ?? p.list?.view.header, let ran = run("header", h, 10) { out.append((.ok, "header: \(first(ran.text))")) }
        if let v = p.version, let ran = run("version", ToolRun(command: .one(v.command)), 10) {
            if let found = v.found(in: ran.text) {
                let fits = v.tested(found)
                out.append((fits == false ? .warn : .ok, "version: \(found)" + (v.tested.map { fits == false ? " — outside what it was tested with (\($0))" : " (tested with \($0))" } ?? "")))
            } else {
                out.append((.warn, "version: its pattern finds nothing in “\(first(ran.text))”"))
            }
        }
        if let list = p.list {
            var ran: ToolExec.Ran?, records: ToolRecords?
            if list.run.files != nil {   // over SFTP, as the list reads them
                do { records = try ToolExec.files(list, of: p, scope, on: t, env: env, cancel: cancel) } catch { out.append((.fail, "list: \(error.localizedDescription)")) }
            } else if let r = run("list", list.run, 30, format: list.parse.format) {
                (ran, records) = (r, list.parse.records(r.out, exit: r.status))
            }
            if let records {
                let now = Date().addingTimeInterval(ran?.skew ?? 0)
                out.append((records.matched ? .ok : .fail, "list: " + records.summary))
                for r in records.rows.prefix(20) {
                    let row = list.view.row(r, scope, now: now)
                    out.append((.plain, "  " + [row.title, row.subtitle, row.detail].filter { !$0.isEmpty }.joined(separator: " · ")))
                }
                if records.rows.count > 20 { out.append((.plain, "  … and \(records.rows.count - 20) more")) }
                if let f = records.rows.first { out.append((.plain, "fields: " + f.keys.sorted().joined(separator: " "))) }
                if !records.unmatched.isEmpty {
                    out.append((.warn, "\(records.unmatched.count) \(records.unmatched.count == 1 ? "line" : "lines") didn't fit:"))
                    out += records.unmatched.prefix(10).map { (.plain, "  " + String($0.prefix(300))) }
                }
                if let errors = ran?.errors, !errors.isEmpty { out.append((.warn, "stderr: " + first(errors))) }
            }
        }
        return out.isEmpty ? [(.plain, "Nothing runs by itself: its actions run only when you choose one, and Test runs none.")] : out
    }

    private func say(_ lines: [(Mark, String)]) {
        let s = NSMutableAttributedString()
        for (i, (mark, text)) in lines.enumerated() {
            let (sign, color): (String, NSColor) = switch mark {
            case .ok: ("✓ ", Palette.ok)
            case .fail: ("✕ ", Palette.fail)
            case .warn: ("⚠ ", Palette.warn)
            case .plain: ("", .labelColor)
            }
            let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
            s.append(NSAttributedString(string: (i == 0 ? "" : "\n") + sign, attributes: [.font: font, .foregroundColor: color]))
            s.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: mark == .plain ? NSColor.labelColor : color]))
        }
        output.textStorage?.setAttributedString(s)
    }

    private static func heading(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        return l
    }

    private static func small(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }
}
