import AppKit

// Settings ▸ Keys (R-72): every command with its keys, found by name, alias or key. Click a key (or ＋) and press the
// new one; a clash shows at once, worded as Reload Config words it. keymap.json stays the source: only the commands
// you changed are in it, and a hand edit shows here the next time the tab opens.

extension AppDelegate {
    /// keymap.json after giving `id` the keys `keys`: its entry, or none when they're its defaults.
    static func keymap(_ file: [String: [String]], setting id: String, to keys: [Shortcut], defaults: [Shortcut]) -> [String: [String]] {
        var f = file
        f[id] = keys == defaults ? nil : keys.map(\.spec)
        return f
    }

    /// What's wrong with `id` having `keys` that wasn't with `old` — `keymapProblems`, without keymap.json's prefix.
    func newKeyProblems(_ id: String, _ keys: [Shortcut], old: [Shortcut], defaults: [Shortcut]) -> [String] {
        let fixed = Self.fixedKeys(NSApp.mainMenu ?? makeMenu())
        let was = Set(Self.keymapProblems(id, old, was: defaults, fixed: fixed))
        return Self.keymapProblems(id, keys, was: defaults, fixed: fixed).filter { !was.contains($0) }
            .map { $0.replacingOccurrences(of: "keymap.json: \(id): ", with: "") }
    }

    /// Writes keymap.json and applies it as Reload Config does: menus, key bar, F1, search.
    func writeKeymap(_ file: [String: [String]]) {
        Config.save("keymap.json", file, in: Self.keymapDir)
        Config.flush()
        applyConfig(reportProblems: false)
    }
}

@MainActor
final class KeysPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private unowned let app: AppDelegate
    private let defaults: [String: [Shortcut]]
    private var file: [String: [String]] = [:]
    private var all: [Command] = []
    private var owners: [Shortcut: Command] = [:]
    private(set) var shown: [Command] = []
    private(set) var recording: (id: String, replacing: Shortcut?)?
    private var monitor: Any?
    private var waiting: (() -> Void)?   // Use Here
    let field = NSSearchField()
    let table = NSTableView()
    let message = NSTextField(wrappingLabelWithString: "")
    private let use = NSButton(title: "Use Here", target: nil, action: nil)
    private let dismiss = NSButton(title: "Cancel", target: nil, action: nil)
    private var bar: NSView!

    init(app: AppDelegate) {
        self.app = app
        defaults = Dictionary(app.makeCommands().map { ($0.id, $0.keys) }, uniquingKeysWith: { a, _ in a })
        super.init(frame: NSRect(origin: .zero, size: SettingsWindow.size))
        field.placeholderString = "Find a command by name or key, like cmd+d"
        field.delegate = self
        let edit = NSButton(title: "Edit keymap.json…", target: self, action: #selector(editFile))
        let reset = NSButton(title: "Reset All…", target: self, action: #selector(resetAllClicked))
        let top = NSStackView(views: [field, edit, reset])
        top.spacing = 8
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for (id, title, width) in [("title", "Command", 205.0), ("menu", "Menu", 125), ("keys", "Keys", 260)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        for b in [use, dismiss] { b.target = self }
        use.action = #selector(useHere)
        dismiss.action = #selector(clearMessage)
        let sign = NSImageView(image: Symbol.warn.image("Attention", color: Palette.warn, size: 13))
        message.font = .systemFont(ofSize: 12)
        let line = NSStackView(views: [sign, message, dismiss, use])
        line.spacing = 8
        message.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar = TintBox(line, fill: Palette.warn.withAlphaComponent(0.14), inset: NSSize(width: 10, height: 6))
        bar.isHidden = true

        let stack = NSStackView(views: [top, scroll, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Reads keymap.json again (a hand edit shows), and stops a recording.
    func reload() {
        stop()
        do { file = try AppDelegate.readKeymap() } catch { file = [:]; say("keymap.json: \(error.localizedDescription)") }
        let bound = AppDelegate.bind(app.makeCommands(), file)
        let visible = bound.commands.filter { !$0.hidden }
        all = AppDelegate.menuOrder(visible) + visible.filter { $0.menu == nil }
        owners = bound.keymap
        filter()
    }

    private func filter() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        shown = q.isEmpty ? all : all.filter { c in
            ([c.title, c.aliases, c.topMenu ?? "Keyboard"] + c.keys.flatMap { [$0.display, $0.spec] }).contains { $0.localizedCaseInsensitiveContains(q) }
        }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    // MARK: - Recording

    /// Click on a key (`replacing` it) or on ＋: the next key pressed is the command's. ⎋ cancels, ⌫ removes the key.
    func record(_ id: String, replacing: Shortcut?) {
        stop()
        clearMessage()
        recording = (id, replacing)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            self.pressed(Shortcut(event: e))
            return nil   // the menu never sees it
        }
        reloadRow(id)
    }

    func stop() {
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
        if let id = recording?.id { recording = nil; reloadRow(id) }
    }

    /// A key pressed while recording (the monitor's; tests call it).
    func pressed(_ k: Shortcut) {
        guard let (id, replacing) = recording, let c = all.first(where: { $0.id == id }) else { return stop() }
        let defaultKeys = defaults[id] ?? []
        if k.flags.isEmpty, k.name == "esc" { return stop() }
        if k.flags.isEmpty, k.name == "backspace" {   // ⌫: the key goes
            stop()
            guard let replacing else { return }
            return assign(c, c.keys.filter { $0 != replacing }, defaults: defaultKeys)
        }
        guard !k.name.isEmpty else { return NSSound.beep() }   // a key keymap.json has no name for
        stop()
        if k == replacing || c.keys.contains(k) { return }
        let keys = replacing.map { r in c.keys.map { $0 == r ? k : $0 } } ?? c.keys + [k]
        guard let other = owners[k], other.id != id else { return assign(c, keys, defaults: defaultKeys) }
        guard app.newKeyProblems(id, keys, old: c.keys, defaults: defaultKeys).isEmpty else { return assign(c, keys, defaults: defaultKeys) }   // it says why
        say("\(k.display) is \(other.title)\(other.topMenu.map { " (\($0))" } ?? "").", ask: { [unowned self] in
            // Its keymap.json entry loses the key; a default of its own gives way to this entry (`bind`).
            var f = file
            if let theirs = f[other.id] {
                f = AppDelegate.keymap(f, setting: other.id, to: theirs.compactMap { Shortcut($0) }.filter { $0 != k }, defaults: defaults[other.id] ?? [])
            }
            assign(c, keys, defaults: defaultKeys, in: f)
        })
    }

    /// Gives `c` its new keys unless that adds a problem Reload Config would report; then says it and changes nothing.
    private func assign(_ c: Command, _ keys: [Shortcut], defaults d: [Shortcut], in base: [String: [String]]? = nil) {
        let problems = app.newKeyProblems(c.id, keys, old: c.keys, defaults: d)
        guard problems.isEmpty else { return say(problems.joined(separator: "; ")) }
        app.writeKeymap(AppDelegate.keymap(base ?? file, setting: c.id, to: keys, defaults: d))
        reload()
    }

    @objc private func editFile() { app.run("app.keymap") }

    /// One command back to its own keys.
    func reset(_ id: String) {
        guard file[id] != nil else { return }
        file[id] = nil
        app.writeKeymap(file)
        reload()
    }

    @objc private func resetAllClicked() { Task { await resetAll() } }

    /// Every entry goes, after a question whose ↩ is Cancel (it can't be undone).
    func resetAll() async {
        guard !file.isEmpty else { return say("Every command has Kermo's keys already.") }
        var c = Confirm("Reset all shortcuts?", action: "Reset All")
        c.irreversible = true
        c.note = "keymap.json loses its \(file.count) \(file.count == 1 ? "entry" : "entries"): every command gets Kermo's keys back."
        guard await app.confirm(c, on: window) == 0 else { return }
        app.writeKeymap([:])
        reload()
    }

    // MARK: - The line under the table

    private func say(_ text: String, ask: (() -> Void)? = nil) {
        message.stringValue = text
        waiting = ask
        use.isHidden = ask == nil
        dismiss.title = ask == nil ? "OK" : "Cancel"
        bar.isHidden = false
    }

    var said: String? { bar.isHidden ? nil : message.stringValue }

    @objc func useHere() {
        let run = waiting
        clearMessage()
        run?()
    }

    @objc func clearMessage() {
        waiting = nil
        bar?.isHidden = true
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    private func reloadRow(_ id: String) {
        guard let r = shown.firstIndex(where: { $0.id == id }) else { return }
        table.reloadData(forRowIndexes: [r], columnIndexes: IndexSet(0..<table.numberOfColumns))
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let c = shown[row]
        switch column?.identifier.rawValue {
        case "title": return centered(label(c.title))
        case "menu": return centered(label(c.menu?.replacingOccurrences(of: "/", with: " ▸ ") ?? "Keyboard", secondary: true))
        default: return centered(keys(c))
        }
    }

    /// A cell's content on the row's middle line.
    private func centered(_ v: NSView) -> NSView {
        let cell = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), v.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            v.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func label(_ s: String, secondary: Bool = false) -> NSView {
        let t = NSTextField(labelWithString: s)
        t.lineBreakMode = .byTruncatingTail
        if secondary { (t.textColor, t.font) = (.secondaryLabelColor, .systemFont(ofSize: 11.5)) }
        return t
    }

    private func keys(_ c: Command) -> NSView {
        var views: [NSView] = []
        let rec = recording?.id == c.id ? recording : nil
        for k in c.keys {
            if let rec, rec.replacing == k { views.append(typing()); continue }
            let b = NSButton(title: "", target: self, action: #selector(keyClicked(_:)))
            b.isBordered = false
            b.attributedTitle = KeyCap.text(k.display, font: .systemFont(ofSize: 12))
            b.identifier = .init(c.id + "\t" + k.spec)
            b.setAccessibilityLabel("\(k.display), \(c.title): click and press another key, ⌫ removes it")
            views.append(b)
        }
        if let rec, rec.replacing == nil { views.append(typing()) } else {
            let add = NSButton(image: Symbol.plus.image("Add a shortcut to \(c.title)"), target: self, action: #selector(addClicked(_:)))
            add.isBordered = false
            add.identifier = .init(c.id)
            add.contentTintColor = .tertiaryLabelColor
            views.append(add)
        }
        if file[c.id] != nil {
            let r = NSButton(image: Symbol.undo.image("Reset \(c.title) to Kermo's keys"), target: self, action: #selector(resetClicked(_:)))
            r.isBordered = false
            r.identifier = .init(c.id)
            r.toolTip = "Back to Kermo's keys: \((defaults[c.id] ?? []).map(\.display).joined(separator: " ").nonEmpty ?? "none")"
            views.append(r)
        }
        let h = NSStackView(views: views)
        h.spacing = 4
        return h
    }

    private func typing() -> NSView {
        let t = NSTextField(labelWithString: "Type a shortcut… ⎋")
        t.textColor = Palette.accent
        t.font = .systemFont(ofSize: 11.5)
        return t
    }

    @objc private func keyClicked(_ b: NSButton) {
        let parts = (b.identifier?.rawValue ?? "").components(separatedBy: "\t")
        guard parts.count == 2 else { return }
        record(parts[0], replacing: Shortcut(parts[1]))
    }

    @objc private func addClicked(_ b: NSButton) { b.identifier.map { record($0.rawValue, replacing: nil) } }
    @objc private func resetClicked(_ b: NSButton) { b.identifier.map { reset($0.rawValue) } }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
