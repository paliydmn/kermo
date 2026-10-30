import AppKit
import DFMCore

/// A tool's page in the Tools window (Tools PR 4), from a library row: who made it, its version and the hash trust goes
/// by; what it runs, grouped as "Use the tool…?" shows it; your saved servers — found there or not, used or hidden,
/// its values set or not (Set Up…). Use on Servers…, Show File, and Edit for yours, Customize for a built-in.
@MainActor
final class ToolsTool: NSView {
    unowned let app: AppDelegate
    private(set) var tool: LoadedTool
    /// ‹ back to the library it came from, named so.
    let back: @MainActor () -> Void
    let from: String
    let stack = NSStackView()
    private var kept: [AnyObject] = []

    init(_ app: AppDelegate, _ tool: LoadedTool, from: String, back: @escaping @MainActor () -> Void) {
        (self.app, self.tool, self.from, self.back) = (app, tool, from, back)
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 14, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let flipped = Flipped()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = flipped
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                                     stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor), stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: flipped.topAnchor), stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor)])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private final class Flipped: NSView { override var isFlipped: Bool { true } }

    /// Drawn again from the library as it is now (a save, a trust, Use on Servers…) — a customized built-in as yours
    /// now; a tool gone from it: back.
    func refresh() {
        guard let now = app.tools.library.tools.first(where: { $0.preset.id == tool.preset.id }) else { return back() }
        tool = now
        let p = tool.preset
        kept = []
        let backButton = button("‹ " + from) { [unowned self] in back() }
        backButton.bezelStyle = .accessoryBarAction
        let icon = NSImageView(image: Symbol.preset(p.icon))
        icon.symbolConfiguration = .init(pointSize: 26, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let name = ToolsPage.text(p.tool.map { "\(p.title) (\($0))" } ?? p.title, size: 18, bold: true)
        let use = button("Use on Servers…") { [unowned self] in Task { await app.tools.useOnServers(tool, window: window); refresh() } }
        let file = button("Show File") { [unowned self] in Viewer.show(URL(fileURLWithPath: tool.path)) }
        let edit = tool.builtIn ? button("Customize") { [unowned self] in ToolEditor.customize(app, tool) } : button("Edit") { [unowned self] in ToolEditor.edit(app, URL(fileURLWithPath: tool.path)) }
        edit.toolTip = tool.builtIn ? "A copy of its file in ~/.config/dfilemanager/tools, under the same id: yours takes its place once saved" : nil
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [icon, name, spacer, use, file, edit])
        (top.spacing, top.distribution) = (8, .fill)
        var views: [NSView] = [backButton, top]
        if let about = p.about { views.append(ToolsPage.text(about, color: .secondaryLabelColor)) }
        views.append(ToolsPage.text(facts.joined(separator: " · "), color: .secondaryLabelColor, size: 11))
        if !tool.warnings.isEmpty {
            views.append(Self.heading("Warnings"))
            views += tool.warnings.map { ToolsPage.text("⚠ " + $0.description, size: 11) }
        }
        views.append(Self.heading("What it runs"))
        for g in tool.runs.groups {
            views.append(ToolsPage.text(g.title, color: .secondaryLabelColor, size: 11, bold: true))
            views += (g.lines.isEmpty ? [ToolRuns.Line(what: "nothing", how: "")] : g.lines).map(line)
        }
        views.append(Self.heading("Servers"))
        views.append(servers())
        views.append(ToolsPage.text(p.requires.map { _ in "Found by its requires, in one batch over connections Kermo already has — never a login for it." }
                                    ?? "It has no requires: it shows on every server.", color: .secondaryLabelColor, size: 11))
        stack.setViews(views, in: .top)
        for v in views where v !== backButton { v.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -36).isActive = true }
        top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
    }

    /// Built in or yours, by whom, its version, and the hash its trust goes by.
    var facts: [String] {
        let p = tool.preset, hash = String(tool.hash.prefix(12))
        let trust = tool.builtIn ? "trusted as part of Kermo" : app.tools.trust.trusts(tool) ? "in use — sha256 \(hash)"
            : app.tools.trust.hashes[p.id] == nil ? "not in use yet — sha256 \(hash)" : "changed since you said to use it — sha256 \(hash)"
        return [tool.builtIn ? "built into Kermo" : "yours, not reviewed by anyone", p.author.map { "by \($0)" }, p.catalogVersion.map { "version \($0)" },
                p.sudo == true ? "needs root (sudo)" : nil, trust].compactMap { $0 }
    }

    /// A line of what it runs: mono, root and this Mac said after it, a dangerous one red.
    private func line(_ l: ToolRuns.Line) -> NSView {
        let t = NSTextField(wrappingLabelWithString: l.how.isEmpty ? "  " + l.what : l.text.trimmingCharacters(in: .whitespaces))
        t.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        t.textColor = l.dangerous ? Palette.fail : .labelColor
        t.isSelectable = true
        return t
    }

    /// Each saved server: whether the program is there, whether the tool is used there, its values set or Set Up….
    private func servers() -> NSView {
        let p = tool.preset, s = app.tools.settings, trusted = app.tools.trust.trusts(tool)
        guard !app.savedServers.isEmpty else { return ToolsPage.text("No saved servers yet: it shows wherever it's found.", color: .secondaryLabelColor) }
        let rows: [[NSView]] = app.savedServers.map { srv in
            let name = NSTextField(labelWithString: srv.title)
            name.textColor = srv.prod ? Palette.prod : .labelColor
            let used = !trusted ? "not in use yet" : s.uses(p.id, on: srv.id.uuidString) ? "used" : s.only[p.id] != nil ? "not on its list" : "hidden here"
            var cells: [NSView] = [name, Self.small(app.tools.state(tool, on: srv)), Self.small(used)]
            if trusted, s.uses(p.id, on: srv.id.uuidString), !p.varsToAsk(saved: [:]).isEmpty {
                cells.append(app.tools.toSetUp(tool, on: srv.target).isEmpty ? Self.small("settings set")
                             : button("Set Up…") { [unowned self] in Task { _ = await app.tools.setUp(tool, on: srv.target, window: window); refresh() } })
            }
            return cells
        }
        let g = NSGridView(views: rows.map { $0 + Array(repeating: NSGridCell.emptyContentView, count: 4 - $0.count) })
        (g.rowSpacing, g.columnSpacing) = (6, 16)
        g.rowAlignment = .firstBaseline
        return g
    }

    private func button(_ title: String, action: @escaping @MainActor () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        kept.append(MenuAction.attach(to: b, action))
        return b
    }

    private static func heading(_ s: String) -> NSTextField { ToolsPage.text(s.uppercased(), color: .secondaryLabelColor, size: 11, bold: true) }

    private static func small(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11.5)
        l.textColor = .secondaryLabelColor
        return l
    }
}

/// New Tool… (Tools PR 4): a name, its file's name from it, and what to start from — a list, buttons, one command.
/// The editor opens with it; nothing is written before you save.
@MainActor
final class ToolsNew: NSView, NSTextFieldDelegate {
    unowned let app: AppDelegate
    let name = NSTextField(string: "My Tool")
    let file = NSTextField(labelWithString: "")
    private(set) var starters: [NSButton] = []
    private var kept: [AnyObject] = []

    init(_ app: AppDelegate) {
        self.app = app
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        name.placeholderString = "Its name, as menus show it"
        name.delegate = self
        name.setAccessibilityLabel("Name")
        file.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        var views: [NSView] = [ToolsPage.text("New Tool", size: 18, bold: true),
                               ToolsPage.text("A JSON file in ~/.config/dfilemanager/tools — the format of the built-in ones. docs/tools.md has every field.",
                                              color: .secondaryLabelColor),
                               NSStackView(views: [NSTextField(labelWithString: "Name:"), name]), file,
                               ToolsPage.text("Start from", color: .secondaryLabelColor, size: 11, bold: true)]
        for kind in ToolNew.Kind.allCases {
            let b = NSButton(title: kind.title, target: nil, action: nil)
            b.controlSize = .large
            b.widthAnchor.constraint(equalToConstant: 180).isActive = true
            kept.append(MenuAction.attach(to: b) { [unowned self] in start(kind) })
            starters.append(b)
            let about = ToolsPage.text(kind.about, color: .secondaryLabelColor)
            let row = NSStackView(views: [b, about])
            row.spacing = 12
            views.append(row)
        }
        name.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor)])
        named()
    }

    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ obj: Notification) { named() }

    /// The file the name makes, or why there's none: no letter or digit, a file already there, a built-in's id.
    var problem: String? {
        guard let id = ToolNew.id(from: name.stringValue) else { return "A name needs a letter or a digit." }
        if app.tools.library.tools.contains(where: { $0.builtIn && $0.preset.id == id }) { return "\(id) is a built-in tool's: its page's Customize makes it yours." }
        if let dir = ToolRunner.own, FileManager.default.fileExists(atPath: dir.appendingPathComponent(id + ".json").path) { return "\(id).json is there already: My Tools has it, or Show File." }
        return nil
    }

    private func named() {
        let why = problem
        file.stringValue = why ?? "~/.config/dfilemanager/tools/\(ToolNew.id(from: name.stringValue) ?? "").json"
        file.textColor = why == nil ? .secondaryLabelColor : Palette.fail
        starters.forEach { $0.isEnabled = why == nil }
    }

    func start(_ kind: ToolNew.Kind) {
        guard problem == nil, let id = ToolNew.id(from: name.stringValue) else { return named() }
        ToolEditor.new(app, kind, id: id, title: name.stringValue.trimmingCharacters(in: .whitespaces))
    }
}
