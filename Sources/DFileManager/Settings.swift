import AppKit
import UniformTypeIdentifiers

// Settings (⌘,): one window of tabs, each tab groups of rows. A row is an option the code already reads — its
// `defaults` key at its right, written where the code reads it and applied the way the menu or Reload Config does —
// or a button that runs a command. A new tab is one entry in `settingsTabs` (Monitor is; Tools' tab will be).

struct SettingsTab {
    let title: String, symbol: Symbol
    let groups: [(title: String, rows: [SettingsRow])]
    var view: (@MainActor (AppDelegate) -> NSView)? = nil   // a tab of its own making (Keys), not rows
}

struct SettingsRow {
    enum Control {
        case toggle(Bool)                                  // the key's default
        case command(String)                               // a switch of the menu's: its ✓, and running it
        case choice([(title: String, value: Any?)], segmented: Bool)   // nil: no key, the code's default
        case field(String)                                 // placeholder; empty: no key
        case number(ClosedRange<Double>, step: Double, value: Double, unit: String)
        case buttons([(title: String, command: String)])
        case themes
        case info
    }
    let title: String
    var note = ""
    var key: String? = nil
    let control: Control
    var apply: (@MainActor (AppDelegate) -> Void)? = nil   // after the write: the path the menu or Reload Config takes
    var status: (@MainActor (AppDelegate) async -> String)? = nil   // the note, as things are now: read again each time the window shows
}

extension AppDelegate {
    var settingsTabs: [SettingsTab] { [
        SettingsTab(title: "General", symbol: .general, groups: [
            ("Lists", [
                SettingsRow(title: "Show hidden files", note: "⇧⌘. switches it anywhere", key: "showHidden", control: .command("view.hidden")),
                SettingsRow(title: "Dates", note: "The Modified column", key: "isoDates",
                            control: .choice([("Today 13:33", false), ("2026-10-27 13:33", true)], segmented: true),
                            apply: { $0.panels.forEach { $0.rollDates() } }),
            ]),
            ("Updates", [
                SettingsRow(title: "Check for updates once a day", note: "One request to GitHub a day, with nothing in it but Kermo's version",
                            key: "updateCheckOff", control: .command("app.update.auto")),
                SettingsRow(title: "“fm” command", note: "Open Kermo from the shell: fm ~/a ~/b", control: .buttons([("Install…", "app.installCLI")])),
            ]),
        ]),
        SettingsTab(title: "Appearance", symbol: .appearance, groups: [
            ("Theme", [SettingsRow(title: "Theme", key: "theme", control: .themes, apply: { $0.applyTheme() })]),
            ("Panels", [
                SettingsRow(title: "Permissions & Owner columns", note: "View ▸ Permissions & Owner", key: "showPerms", control: .command("view.perms")),
            ]),
            ("Key bar", [
                SettingsRow(title: "Show a modifier's keys after holding it for", key: "keyBarHoldDelay",
                            control: .number(0...1, step: 0.02, value: 0.12, unit: "s")),
            ]),
        ]),
        SettingsTab(title: "Keys", symbol: .keyboard, groups: [], view: { KeysPane(app: $0) }),
        SettingsTab(title: "Terminal", symbol: .terminal, groups: [
            ("Text", [
                SettingsRow(title: "Font", note: "MesloLGS NF shows Powerlevel10k and Starship icons", key: "terminalFont",
                            control: .choice([("SF Mono", nil)] + Self.monospacedFamilies.map { ($0, $0) }, segmented: false),
                            apply: { $0.terminal?.zoom(by: 0) }),
                SettingsRow(title: "Size", note: "⌘+ and ⌘− change it too", key: "terminalFontSize", control: .number(9...36, step: 1, value: 13, unit: "pt"),
                            apply: { app in app.terminal.map { $0.zoom(by: CGFloat(app.defaults.double(forKey: "terminalFontSize")) - $0.fontSize) } }),
                SettingsRow(title: "Drawer height", note: "Drag the line above the terminal; ⌃⇧O gives it the whole window",
                            key: "terminalDrawerHeight", control: .info),
            ]),
            ("Keyboard and mouse", [
                SettingsRow(title: "Option is Meta", note: "For new terminal tabs. Off: ⌥ types your layout's @ | [ ]", key: "terminalOptionIsMeta", control: .toggle(true)),
                SettingsRow(title: "Selecting text copies it", note: "It replaces what's on the clipboard, as in PuTTY; off: only ⌘C copies",
                            key: "terminalCopyOnSelect", control: .toggle(true)),
                SettingsRow(title: "Right-click pastes", note: "What's on the clipboard goes to the shell, as in PuTTY; ⇧-right-click in mc, htop and the like",
                            key: "terminalRightClickPaste", control: .toggle(true)),
            ]),
            ("Other apps", [
                SettingsRow(title: "Terminal for ⌥⌘T and ⌘↩", key: "terminalBundleID",
                            control: .choice(Self.apps(Self.terminalApps, keeping: defaults.string(forKey: "terminalBundleID"), first: ("Terminal", nil)), segmented: false)),
            ]),
        ]),
        SettingsTab(title: "Editor & Viewer", symbol: .document, groups: [
            ("Editor", [
                SettingsRow(title: "Edit files on this Mac with", note: "Server files always open in Kermo's editor", key: "editorBundleID",
                            control: .choice(Self.apps(Self.textEditors, keeping: defaults.string(forKey: "editorBundleID"), first: ("Kermo", nil)), segmented: false)),
                SettingsRow(title: "End with a newline", note: "For new editor windows; File ▸ Ensure Final Newline changes one", key: "editorFinalNewline",
                            control: .choice([("Config files", nil), ("Always", true), ("Never", false)], segmented: true)),
            ]),
            ("Viewer", [
                SettingsRow(title: "Line numbers", note: "For the next viewer; l switches them in one", key: "viewerLineNumbers", control: .toggle(false)),
            ]),
            ("Compare", [
                SettingsRow(title: "Compare files with", note: "%1 and %2 are the two files: code --diff %1 %2", key: "diffCommand", control: .field("built-in diff")),
            ]),
        ]),
        SettingsTab(title: "Servers & Safety", symbol: .safety, groups: [
            ("On production servers", [
                SettingsRow(title: "Keep a production log", note: "~/.config/dfilemanager/audit.jsonl, only yours to read; it may hold what you typed in commands",
                            key: "auditLog", control: .toggle(true)),
                SettingsRow(title: "Production log", control: .buttons([("Show", "admin.auditLog")])),
            ]),
            ("Server files", [
                SettingsRow(title: "Keep earlier versions of saved server files", note: "20 a file, 200 MB in all, out of Spotlight and Time Machine",
                            key: "serverHistory", control: .toggle(true)),
                SettingsRow(title: "Checks before saving", note: "visudo, nginx -t, sshd -t and the like, and your own (validators.json)",
                            control: .buttons([("Edit…", "validators.edit")])),
            ]),
            ("Servers", [
                SettingsRow(title: "SSH config", note: "~/.ssh/config: its hosts are in Connect to Server…", control: .buttons([("Edit SSH Config…", "ssh.config")])),
                SettingsRow(title: "sudo password", note: "Kept in memory for 5 minutes after its last use; forgotten at screen lock, sleep and Disconnect", control: .info),
            ]),
        ]),
        SettingsTab(title: "Monitor", symbol: .monitor, groups: [
            ("Notifications", [
                SettingsRow(title: "Critical alerts as notifications", control: .buttons([("Open System Settings", "monitor.notificationSettings")]),
                            status: { await $0.tools.monitor.notificationsSaid() }),
            ]),
            ("On critical alerts", [
                SettingsRow(title: "Also run this command", note: "On this Mac, in your login shell, with $KERMO_SERVER, $KERMO_LEVEL, $KERMO_MESSAGE and $KERMO_TOOL set. Only you set it: a tool never can",
                            key: "onAlert", control: .field("curl -d \"$KERMO_MESSAGE\" ntfy.sh/…")),
                SettingsRow(title: "Test", control: .buttons([("Send Test", "monitor.test")]), status: { $0.tools.monitor.tested }),
            ]),
        ]),
        SettingsTab(title: "Advanced", symbol: .advanced, groups: [
            ("Files", [
                SettingsRow(title: "keymap.json", note: "Your shortcuts", control: .buttons([("Edit…", "app.keymap")])),
                SettingsRow(title: "usermenu.json", note: "The F2 menu", control: .buttons([("Edit…", "usermenu.edit")])),
                SettingsRow(title: "validators.json", note: "Checks on save", control: .buttons([("Edit…", "validators.edit")])),
                SettingsRow(title: "filters.json", note: "Quick filter presets (⌘/)", control: .buttons([("Edit…", "view.filterPresets.edit")])),
                SettingsRow(title: "servers.json", note: "Saved servers and tunnels: New Server… and a server's Edit… write it; a hand edit waits for the next launch", control: .info),
            ]),
            ("Config folder", [
                SettingsRow(title: "~/.config/dfilemanager", note: "Owner-only. Reload Config applies a changed keymap.json, user menu or checks",
                            control: .buttons([("Open", "app.config"), ("Reload Config", "app.reload")])),
                SettingsRow(title: "For scripts", note: "Every option here is a defaults key, shown at its right: defaults write com.dmn.dfilemanager <key> … sets it too", control: .info),
            ]),
        ]),
    ] }

    /// Monospaced families installed: SF Mono is the code's default, not one of them.
    static var monospacedFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { NSFont(name: $0, size: 12)?.isFixedPitch == true && !$0.hasPrefix(".") }
    }
    static let terminalApps = ["com.googlecode.iterm2", "com.mitchellh.ghostty", "com.github.wez.wezterm", "net.kovidgoyal.kitty",
                               "org.alacritty", "dev.warp.Warp-Stable"]
    @MainActor static var textEditors: [String] {
        NSWorkspace.shared.urlsForApplications(toOpen: .plainText).compactMap { Bundle(url: $0)?.bundleIdentifier }
            .filter { $0 != Bundle.main.bundleIdentifier }
    }

    /// A menu of apps by bundle id: `first` (the code's default, no key), the ones installed, and the key's own if it's none of them.
    @MainActor static func apps(_ ids: [String], keeping current: String?, first: (String, String?)) -> [(title: String, value: Any?)] {
        let ws = NSWorkspace.shared
        func name(_ id: String) -> String? { ws.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } }
        var out: [(title: String, value: Any?)] = [(first.0, first.1)]
        var seen = Set<String>()
        for id in ids where seen.insert(id).inserted { if let n = name(id) { out.append((n, id)) } }
        if let current, !seen.contains(current) { out.append((name(current) ?? current, current)) }
        return out
    }
}

/// The window: one for the app, kept when closed, so ⌘, comes back on the tab you left.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private static var shared: SettingsWindow?
    let window: NSWindow
    let tabs: Tabs
    private unowned let app: AppDelegate
    private let defaults: UserDefaults
    private var refreshers: [() -> Void] = []   // controls re-read their keys (⇧⌘. may have changed one meanwhile)
    private var actions: [ClosureTarget] = []

    /// Something a row's note says changed meanwhile (`SettingsRow.status`).
    static func refreshShown() { shared?.refresh() }

    /// `tab`: its title, to open on it (Thresholds' Notification Settings… opens Monitor).
    static func show(_ app: AppDelegate, tab: String? = nil) {
        let s = shared ?? SettingsWindow(app: app, tabs: app.settingsTabs, defaults: app.defaults)
        shared = s
        if let i = s.tabs.tabViewItems.firstIndex(where: { $0.label == tab }) { s.tabs.selectedTabViewItemIndex = i }
        s.refresh()
        s.window.makeKeyAndOrderFront(nil)
    }

    /// `defaults`: tests' own suite; the app's is `UserDefaults.standard`, where the code reads its options.
    init(app: AppDelegate, tabs list: [SettingsTab], defaults: UserDefaults) {
        self.app = app
        self.defaults = defaults
        tabs = Tabs()
        tabs.tabStyle = .toolbar
        window = NSWindow(contentViewController: tabs)
        super.init()
        for t in list {
            let vc = NSViewController()
            vc.view = t.view?(app) ?? page(t)
            vc.title = t.title
            vc.preferredContentSize = Self.size   // the tab view keeps the window at it
            let item = NSTabViewItem(viewController: vc)
            item.image = t.symbol.image(t.title)
            tabs.addTabViewItem(item)
        }
        window.styleMask = [.titled, .closable]
        window.setContentSize(Self.size)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        window.delegate = self
        window.center()
        tabs.selected = { [unowned self] in refresh() }
    }

    final class Tabs: NSTabViewController {
        var selected: (() -> Void)?
        override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
            super.tabView(tabView, didSelect: item)
            selected?()
        }
    }

    static let size = NSSize(width: 680, height: 560)

    func windowDidBecomeKey(_ notification: Notification) { refresh() }
    func refresh() {
        refreshers.forEach { $0() }
        for item in tabs.tabViewItems { (item.viewController?.view as? KeysPane)?.reload() }   // keymap.json again: a hand edit shows
    }

    // MARK: - Building

    private func page(_ tab: SettingsTab) -> NSView {
        let groups = tab.groups.map { group($0.title, $0.rows) }
        let stack = NSStackView(views: groups)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        doc.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor), stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ] + groups.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48) })
        return scroll
    }

    private func group(_ title: String, _ rows: [SettingsRow]) -> NSView {
        let head = NSTextField(labelWithString: title)
        head.font = .systemFont(ofSize: 11.5, weight: .semibold)
        head.textColor = .secondaryLabelColor
        var views: [NSView] = []
        for r in rows {
            if !views.isEmpty { views.append(Self.line()) }
            views.append(row(r))
        }
        let list = NSStackView(views: views)
        list.orientation = .vertical
        list.spacing = 0
        views.forEach { $0.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        let box = TintBox(list, fill: .quaternarySystemFill, inset: NSSize(width: 12, height: 2))
        let g = NSStackView(views: [head, box])
        g.orientation = .vertical
        g.alignment = .leading
        g.spacing = 6
        box.widthAnchor.constraint(equalTo: g.widthAnchor).isActive = true
        g.translatesAutoresizingMaskIntoConstraints = false
        return g
    }

    private static func line() -> NSView {
        let v = Line()
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func row(_ r: SettingsRow) -> NSView {
        if case .themes = r.control { return themes(r) }
        let title = NSTextField(labelWithString: r.title)
        title.font = .systemFont(ofSize: 13)
        var left: [NSView] = [title]
        if !r.note.isEmpty || r.status != nil {
            let note = NSTextField(wrappingLabelWithString: r.note)
            note.font = .systemFont(ofSize: 11.5)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = 330
            left.append(note)
            if let status = r.status {
                refreshers.append { [unowned self, weak note] in
                    let app = app   // the window may be gone by the answer
                    Task { let said = await status(app); note?.stringValue = said }
                }
            }
        }
        let text = NSStackView(views: left)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var right: [NSView] = []
        if let key = r.key {   // always shown: decision 8 puts the key by each option, and hover would hide it from keyboard users
            let k = NSTextField(labelWithString: key)
            k.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            k.textColor = .tertiaryLabelColor
            k.toolTip = "defaults write com.dmn.dfilemanager \(key) …"
            k.setAccessibilityElement(false)   // the control says it
            right.append(k)
        }
        if let c = control(r) {
            if !(c is NSButton) || c is NSSwitch { c.setAccessibilityLabel(r.title) }   // a button says its action too (`buttons`)
            if let key = r.key { c.setAccessibilityHelp("defaults key \(key)") }
            right.append(c)
        }
        let h = NSStackView()
        h.addView(text, in: .leading)
        right.forEach { h.addView($0, in: .trailing) }   // at the right edge
        h.alignment = .centerY
        h.spacing = 10
        h.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        return h
    }

    private func control(_ r: SettingsRow) -> NSView? {
        let key = r.key ?? ""
        switch r.control {
        case .toggle(let on):
            let s = NSSwitch()
            refreshers.append { [unowned self] in s.state = defaults.object(forKey: key) as? Bool ?? on ? .on : .off }
            target(s) { [unowned self] in
                defaults.set(s.state == .on, forKey: key)
                r.apply?(app)
            }
            return s
        case .command(let id):
            let s = NSSwitch()
            refreshers.append { [unowned self] in s.state = app.commands.first { $0.id == id }?.on?(app) == true ? .on : .off }
            target(s) { [unowned self] in
                app.run(id)
                refresh()
            }
            return s
        case .choice(let options, let segmented):
            let index = { [unowned self] in
                options.firstIndex { o in
                    guard let v = o.value else { return defaults.object(forKey: key) == nil }
                    return (defaults.object(forKey: key) as? NSObject)?.isEqual(v) == true
                } ?? 0
            }
            let write = { [unowned self] (i: Int) in
                if let v = options[i].value { defaults.set(v, forKey: key) } else { defaults.removeObject(forKey: key) }
                r.apply?(app)
            }
            if segmented {
                let s = NSSegmentedControl(labels: options.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
                refreshers.append { s.selectedSegment = index() }
                target(s) { write(s.selectedSegment) }
                return s
            }
            let p = NSPopUpButton()
            p.addItems(withTitles: options.map(\.title))
            refreshers.append { p.selectItem(at: index()) }
            target(p) { write(p.indexOfSelectedItem) }
            return p
        case .field(let placeholder):
            let f = NSTextField()
            f.placeholderString = placeholder
            f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            f.widthAnchor.constraint(equalToConstant: 230).isActive = true
            (f.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
            refreshers.append { [unowned self] in f.stringValue = defaults.string(forKey: key) ?? "" }
            target(f) { [unowned self] in
                let v = f.stringValue.trimmingCharacters(in: .whitespaces)
                if v.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(v, forKey: key) }
                r.apply?(app)
            }
            return f
        case .number(let range, let step, let value, let unit):
            let label = NSTextField(labelWithString: "")
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            let s = NSStepper()
            (s.minValue, s.maxValue, s.increment, s.valueWraps) = (range.lowerBound, range.upperBound, step, false)
            let show = { label.stringValue = (step < 1 ? String(format: "%.2f", s.doubleValue) : "\(Int(s.doubleValue))") + " " + unit }
            refreshers.append { [unowned self] in
                s.doubleValue = defaults.object(forKey: key) as? Double ?? value
                show()
            }
            target(s) { [unowned self] in
                defaults.set(s.doubleValue, forKey: key)
                show()
                r.apply?(app)
            }
            let h = NSStackView(views: [label, s])
            h.spacing = 4
            h.setHuggingPriority(.required, for: .horizontal)   // at the row's right edge, not stretched
            return h
        case .buttons(let list):
            let bs = list.map { b -> NSButton in
                let button = NSButton(title: b.title, target: nil, action: nil)
                button.setAccessibilityLabel("\(b.title.replacingOccurrences(of: "…", with: "")) — \(r.title)")   // "Edit — keymap.json", not five "Edit…"
                target(button) { [unowned self] in app.run(b.command) }
                return button
            }
            if bs.count == 1 { return bs[0] }
            let h = NSStackView(views: bs)
            h.spacing = 6
            h.setHuggingPriority(.required, for: .horizontal)
            return h
        case .themes, .info:
            return nil
        }
    }

    /// Appearance's previews: a click uses the theme at once, as View ▸ Theme… does.
    private func themes(_ r: SettingsRow) -> NSView {
        let key = r.key ?? "theme"
        let swatches = Theme.all.map { ThemeSwatch(theme: $0) }
        refreshers.append { [unowned self] in
            let name = defaults.string(forKey: key) ?? Theme.all[0].name
            swatches.forEach { $0.isChosen = $0.theme.name == name }
        }
        for s in swatches {
            target(s) { [unowned self] in
                defaults.set(s.theme.name, forKey: key)
                r.apply?(app)
                refresh()
            }
        }
        let rows = stride(from: 0, to: swatches.count, by: 5).map { i -> NSStackView in
            let h = NSStackView(views: Array(swatches[i..<min(i + 5, swatches.count)]))
            h.spacing = 8
            return h
        }
        let k = NSTextField(labelWithString: key)   // as each row shows its key
        k.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        k.textColor = .tertiaryLabelColor
        let top = NSStackView()
        top.addView(k, in: .trailing)
        let v = NSStackView(views: [top] + rows)
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 8
        top.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        v.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        return v
    }

    /// The control's action as a closure, kept as long as the window.
    private func target(_ c: NSControl, _ run: @escaping @MainActor () -> Void) {
        let t = ClosureTarget(run)
        actions.append(t)
        c.target = t
        c.action = #selector(ClosureTarget.fire)
    }
}

private final class ClosureTarget: NSObject {
    private let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    @MainActor @objc func fire() { run() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A row's separator: a box's height isn't Auto Layout's (phase 5).
private final class Line: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

/// A theme's preview, drawn from its colors: background, a folder, the cursor's row, a marked file, an executable.
/// A button, so Tab reaches it and VoiceOver reads its name.
final class ThemeSwatch: NSButton {
    let theme: Theme
    var isChosen = false { didSet { needsDisplay = true; setAccessibilityValue(isChosen ? "chosen" : nil) } }

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 112, height: 78))
        title = theme.name
        isBordered = false
        setButtonType(.momentaryChange)
        widthAnchor.constraint(equalToConstant: 112).isActive = true
        heightAnchor.constraint(equalToConstant: 78).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let preview = NSRect(x: 4, y: bounds.height - 60, width: bounds.width - 8, height: 56)
        let shape = NSBezierPath(roundedRect: preview, xRadius: 5, yRadius: 5)
        (theme.background ?? .textBackgroundColor).setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.stroke()
        let font = theme.mono ? NSFont.monospacedSystemFont(ofSize: 9, weight: .regular) : .systemFont(ofSize: 9.5)
        let lines: [(String, NSColor, NSColor?, Bool)] = [
            ("▸ Sources", theme.dir, nil, false),
            ("  config.yaml", theme.cursor == nil ? .alternateSelectedControlTextColor : theme.text, theme.cursor ?? .selectedContentBackgroundColor, false),
            ("✓ notes.md", theme.marked, nil, true),
            ("  run.sh", theme.exec, nil, false),
        ]
        for (i, l) in lines.enumerated() {
            let r = NSRect(x: preview.minX, y: preview.maxY - 4 - CGFloat(i + 1) * 12, width: preview.width, height: 12)
            if let bg = l.2 { bg.setFill(); r.fill() }
            (l.0 as NSString).draw(at: NSPoint(x: r.minX + 6, y: r.minY), withAttributes: [
                .font: l.3 ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font, .foregroundColor: l.1])
        }
        let p = NSMutableParagraphStyle()
        (p.alignment, p.lineBreakMode) = (.center, .byTruncatingTail)
        NSAttributedString(string: theme.name, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: isChosen ? .semibold : .regular), .paragraphStyle: p,
            .foregroundColor: isChosen ? NSColor.labelColor : .secondaryLabelColor]).draw(in: NSRect(x: 0, y: 1, width: bounds.width, height: 14))
        if isChosen {
            Palette.accent.setStroke()
            let ring = NSBezierPath(roundedRect: preview.insetBy(dx: -2, dy: -2), xRadius: 7, yRadius: 7)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill() }
}
