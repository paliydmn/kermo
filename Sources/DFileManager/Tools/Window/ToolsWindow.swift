import AppKit
import DFMCore

/// The Tools window (Tools PR 4, monitor §9): a sidebar of your servers — each a page of its tools (`ToolsPage`) — and
/// the library: the tools built into Kermo and yours, each with its page (`ToolsTool`), and New Tool…. A server's page
/// can be a window of its own (Open in New Window), several at once. WATCHED comes with watching (PR 5).
/// ponytail: nothing reopens after a restart (D-159).
@MainActor
final class ToolsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// The Tools window; and servers' pages in windows of their own.
    private(set) static var main: ToolsWindow?
    private(set) static var alone: [ToolsWindow] = []
    /// The pages on screen: they say how their buttons' runs went (`AppDelegate.rowLists`).
    static var pages: [ToolsPage] { ([main].compactMap { $0 } + alone).compactMap(\.page) }

    enum Row: Equatable {
        case header(String)
        case server(SavedServer, SFTPTarget)
        case library(mine: Bool)
        case newTool
    }

    unowned let app: AppDelegate
    let window: NSWindow
    let sidebar = NSTableView()
    private(set) var rows: [Row] = []
    private(set) var page: ToolsPage?
    private(set) var library: ToolsLibrary?
    /// A library row's page, over its library.
    private(set) var tool: ToolsTool?
    private(set) var starter: ToolsNew?
    private let content = NSView()
    /// A server's page alone: no sidebar.
    private let isAlone: Bool
    /// Servers as a Tools ▸ (or ⌃⌘T) opened them here — an alias, `.local()` — their pages go there; one not saved is
    /// listed while the window is.
    private var given: [SFTPTarget] = []

    /// Window ▸ Tools (⌃⌘T), Tools ▸ ▸ Open in Tools Window: the window, on `t`'s server if given.
    static func show(_ app: AppDelegate, server t: SFTPTarget? = nil) {
        let w = main ?? ToolsWindow(app, alone: nil)
        main = w
        if let t {
            w.given.removeAll { ServerRow.key($0) == ServerRow.key(t) }
            w.given.append(t.asUser)
        }
        w.reload()
        if let t, let i = w.rows.firstIndex(where: { if case .server(_, let x) = $0 { ServerRow.key(x) == ServerRow.key(t.asUser) } else { false } }) {
            w.sidebar.selectRowIndexes([i], byExtendingSelection: false)
        } else if w.sidebar.selectedRow < 0, let i = w.rows.firstIndex(where: { if case .header = $0 { false } else { true } }) {
            w.sidebar.selectRowIndexes([i], byExtendingSelection: false)
        }
        w.window.makeKeyAndOrderFront(nil)
    }

    /// A server's page as a window of its own; one already open comes to the front.
    static func showAlone(_ app: AppDelegate, _ s: SavedServer, _ t: SFTPTarget) {
        if let w = alone.first(where: { $0.page.map { ServerRow.key($0.target) == ServerRow.key(t.asUser) } == true }) { return w.window.makeKeyAndOrderFront(nil) }
        let w = ToolsWindow(app, alone: (s, t))
        alone.append(w)
        w.window.makeKeyAndOrderFront(nil)
    }

    /// What servers have, or what you set, changed: every window shows it again.
    static func refresh() {
        main?.reload()
        main?.page?.refresh()
        main?.library?.refresh()
        main?.tool?.refresh()
        alone.forEach { $0.page?.refresh() }
    }

    private init(_ app: AppDelegate, alone: (SavedServer, SFTPTarget)?) {
        (self.app, isAlone) = (app, alone != nil)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: alone == nil ? 900 : 700, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)
        super.init()
        window.delegate = self
        if let (s, t) = alone {
            window.title = "\(s.title) — Tools"
            let p = ToolsPage(app, s, t)
            page = p
            window.contentView = p
        } else {
            window.title = "Tools"
            let col = NSTableColumn(identifier: .init("row"))
            sidebar.addTableColumn(col)
            sidebar.headerView = nil
            sidebar.style = .sourceList
            sidebar.dataSource = self
            sidebar.delegate = self
            sidebar.setAccessibilityLabel("Servers and library")
            let scroll = NSScrollView()
            scroll.documentView = sidebar
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            let side = NSVisualEffectView()
            side.material = .sidebar
            side.blendingMode = .behindWindow
            for (v, inside) in [(scroll, side as NSView)] {
                v.translatesAutoresizingMaskIntoConstraints = false
                inside.addSubview(v)
                NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: inside.leadingAnchor), v.trailingAnchor.constraint(equalTo: inside.trailingAnchor),
                                             v.topAnchor.constraint(equalTo: inside.topAnchor), v.bottomAnchor.constraint(equalTo: inside.bottomAnchor)])
            }
            let root = NSStackView(views: [side, content])
            (root.spacing, root.distribution) = (0, .fill)
            content.setContentHuggingPriority(.init(1), for: .horizontal)
            side.widthAnchor.constraint(equalToConstant: 230).isActive = true
            window.contentView = root
            reload()
        }
        window.center()
    }

    // MARK: The sidebar

    /// SERVERS — saved ones, then others connected or opened here — and LIBRARY.
    func reload() {
        guard !isAlone else { return }
        let keys = Set(app.savedServers.map { ServerRow.key($0.target) })
        func given(_ t: SFTPTarget) -> SFTPTarget? { self.given.first { ServerRow.key($0) == ServerRow.key(t) } }
        var extra: [SFTPTarget] = []
        for t in self.given + app.serverList.sessions.map(\.target.asUser) where AppDelegate.connected(t) || given(t) != nil {
            if !keys.contains(ServerRow.key(t)), !extra.contains(where: { ServerRow.key($0) == ServerRow.key(t) }) { extra.append(t) }
        }
        let was = sidebar.selectedRow >= 0 && sidebar.selectedRow < rows.count ? rows[sidebar.selectedRow] : nil
        rows = [.header("SERVERS")] + app.savedServers.map { .server($0, given($0.target) ?? $0.target) } + extra.map { .server(SavedServer(target: $0), $0) }
            + [.header("LIBRARY"), .library(mine: false), .library(mine: true), .newTool]
        sidebar.reloadData()
        if let was, let i = rows.firstIndex(where: { same($0, was) }) { sidebar.selectRowIndexes([i], byExtendingSelection: false) }
    }

    /// The same row: a server by its address (a not-saved one's id is new each time).
    private func same(_ a: Row, _ b: Row) -> Bool {
        if case .server(_, let x) = a, case .server(_, let y) = b { return ServerRow.key(x) == ServerRow.key(y) }
        return a == b
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .header = rows[row] { true } else { false } }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !self.tableView(tableView, isGroupRow: row) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let views: [NSView]
        switch rows[row] {
        case .header(let t): return NSTextField(labelWithString: t)
        case .server(let s, let t):
            let name = NSTextField(labelWithString: s.title)
            name.textColor = s.prod ? Palette.prod : .labelColor
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.init(499), for: .horizontal)   // over the count, which goes first
            let n = AppDelegate.connected(t) ? app.tools.here(t).map { "\($0.tools.count) tool\($0.tools.count == 1 ? "" : "s")" } ?? "…" : "not connected"
            views = [NSImageView(image: Symbol.server.image(nil)), name]
                + Chip.of(t).map { c in let v = NSImageView(image: c.image); v.setAccessibilityLabel(c.spoken); return v }
                + [Self.spacer(), Self.small(n)]
        case .library(let mine):
            let count = mine ? app.tools.library.tools.filter { !$0.builtIn && ToolRunner.shows($0) }.count : ToolsLibrary.tools(app, mine: false).count
            views = [NSImageView(image: (mine ? Symbol.folder : Symbol.archive).image(nil)), NSTextField(labelWithString: mine ? "My Tools" : "Built into Kermo"),
                     Self.spacer(), Self.small("\(count)")]
        case .newTool:
            views = [NSImageView(image: Symbol.plus.image(nil)), NSTextField(labelWithString: "New Tool…"), Self.spacer()]
        }
        let stack = NSStackView(views: views)
        (stack.spacing, stack.distribution) = (5, .fill)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 4)
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = sidebar.selectedRow
        guard rows.indices.contains(r) else { return }
        switch rows[r] {
        case .header: return
        case .server(let s, let t):
            if let p = page, ServerRow.key(p.target) == ServerRow.key(t) { return }
            let p = ToolsPage(app, s, t)
            p.openAlone = { [unowned self] in ToolsWindow.showAlone(app, s, t) }
            (page, library, tool, starter) = (p, nil, nil, nil)
            place(p)
        case .library(let mine):
            if library?.mine == mine { return }
            let l = ToolsLibrary(app, mine: mine)
            l.open = { [unowned self] in open($0) }
            (page, library, tool, starter) = (nil, l, nil, nil)
            place(l)
        case .newTool:
            if starter != nil { return }
            let n = ToolsNew(app)
            (page, library, tool, starter) = (nil, nil, nil, n)
            place(n)
        }
    }

    /// A library row's page, over the library; ‹ goes back to it.
    func open(_ t: LoadedTool) {
        guard let l = library else { return }
        let page = ToolsTool(app, t, from: l.mine ? "My Tools" : "Built into Kermo") { [unowned self, unowned l] in
            tool = nil
            l.refresh()
            place(l)
        }
        tool = page
        place(page)
    }

    private func place(_ view: NSView) {
        content.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: content.leadingAnchor), view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     view.topAnchor.constraint(equalTo: content.topAnchor), view.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
    }

    private static func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        return v
    }

    private static func small(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        return l
    }

    // MARK: The window

    /// Connections come and go while it's behind: drawn again as it comes to the front.
    func windowDidBecomeKey(_ notification: Notification) {
        reload()
        page?.refresh()
        library?.refresh()
        tool?.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        if Self.main === self { Self.main = nil }
        Self.alone.removeAll { $0 === self }
    }
}

/// The library: the tools built into Kermo, or yours from ~/.config/dfilemanager/tools — each with where it's used, Use
/// on Servers… and Show File; ↩ or a double-click opens its page (`open`). Yours that don't load are listed under the
/// table, each opening in the editor with its problems.
@MainActor
final class ToolsLibrary: NSView, NSTableViewDataSource, NSTableViewDelegate {
    unowned let app: AppDelegate
    let mine: Bool
    let table = NSTableView()
    private(set) var tools: [LoadedTool] = []
    /// A tool's page.
    var open: ((LoadedTool) -> Void)?
    private var kept: [AnyObject] = []
    /// Yours that don't load: the file and why.
    let broken = NSStackView()

    /// Built-ins this version runs; or yours, in use or not yet.
    static func tools(_ app: AppDelegate, mine: Bool) -> [LoadedTool] {
        app.tools.library.tools.filter { $0.builtIn != mine && ToolRunner.shows($0) }
    }

    init(_ app: AppDelegate, mine: Bool) {
        (self.app, self.mine) = (app, mine)
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        for (id, title, width) in [("tool", "Tool", 200.0), ("about", "About", 260), ("where", "Used", 200)] {
            let c = NSTableColumn(identifier: .init(id))
            (c.title, c.width) = (title, width)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel(mine ? "My Tools" : "Built into Kermo")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let heading = ToolsPage.text(mine ? "My Tools" : "Built into Kermo", size: 18, bold: true)
        let about = ToolsPage.text((mine ? "~/.config/dfilemanager/tools — yours, not reviewed by anyone. One new or changed asks “Use the tool…?” first."
                                         : "Part of Kermo: they need nothing on a server but the program each one is for.") + " ↩ or a double-click opens a tool's page.",
                                   color: .secondaryLabelColor)
        let use = NSButton(title: "Use on Servers…", target: self, action: #selector(useOn))
        let show = NSButton(title: "Show File", target: nil, action: nil)
        kept.append(MenuAction.attach(to: show) { [unowned self] in selected.map { Viewer.show(URL(fileURLWithPath: $0.path)) } })
        broken.orientation = .vertical
        broken.alignment = .leading
        broken.spacing = 2
        let stack = NSStackView(views: [heading, about, scroll, NSStackView(views: [use, show]), broken])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        for v in [heading, about, scroll, broken] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        tools = Self.tools(app, mine: mine)
        table.reloadData()
        guard mine, let dir = ToolRunner.own else { return }
        // "tools/x.json: line 3: …": x.json opens in the editor, its Problems saying the same.
        let files = app.tools.library.problems.compactMap { p -> (String, String)? in
            guard p.hasPrefix("tools/"), let colon = p.firstIndex(of: ":") else { return nil }
            return (String(p[p.index(p.startIndex, offsetBy: 6)..<colon]), p)
        }
        broken.setViews((files.isEmpty ? [] : [ToolsPage.text("Not loaded", color: .secondaryLabelColor, size: 11, bold: true)]) + files.map { file, why in
            let b = NSButton(title: "✕ " + why, target: nil, action: nil)
            (b.isBordered, b.contentTintColor, b.alignment) = (false, Palette.fail, .left)
            b.lineBreakMode = .byTruncatingTail
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            b.toolTip = why + "\nClick to edit it."
            kept.append(MenuAction.attach(to: b) { [unowned self] in ToolEditor.edit(app, dir.appendingPathComponent(file)) })
            return b
        }, in: .top)
    }

    private var selected: LoadedTool? { tools.indices.contains(table.selectedRow) ? tools[table.selectedRow] : nil }

    @objc private func openSelected() {
        guard let tool = selected else { return }
        open?(tool)
    }

    /// ↩: the tool's page.
    override func keyDown(with e: NSEvent) {
        if [36, 76].contains(e.keyCode), e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { openSelected() } else { super.keyDown(with: e) }
    }

    @objc private func useOn() {
        guard let tool = selected else { return NSSound.beep() }
        Task {
            await app.tools.useOnServers(tool, window: window)
            refresh()
        }
    }

    /// Where `tool` is used, as Use on Servers… set it.
    func used(_ tool: LoadedTool) -> String {
        let id = tool.preset.id, s = app.tools.settings
        if !app.tools.trust.trusts(tool) { return "not in use yet" }
        if let only = s.only[id] {
            let names = app.savedServers.filter { only.contains($0.id.uuidString) }.map(\.title)
            return names.isEmpty ? "on no server" : "only on " + names.joined(separator: ", ")
        }
        let hidden = app.savedServers.filter { !s.uses(id, on: $0.id.uuidString) }.count
        return "wherever found" + (hidden > 0 ? " · hidden on \(hidden)" : "")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tools.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = tools[row].preset
        switch tableColumn?.identifier.rawValue {
        case "tool":
            let l = NSTextField(labelWithString: p.tool.map { "\(p.title) (\($0))" } ?? p.title)
            let stack = NSStackView(views: [NSImageView(image: Symbol.preset(p.icon)), l])
            stack.spacing = 5
            return stack
        case "about": return label(p.about ?? "")
        default: return label(used(tools[row]))
        }
    }

    /// In a stack, as the Tool column's: centred in the row.
    private func label(_ s: String) -> NSView {
        let l = NSTextField(labelWithString: s)
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        l.toolTip = s
        return NSStackView(views: [l])
    }
}
