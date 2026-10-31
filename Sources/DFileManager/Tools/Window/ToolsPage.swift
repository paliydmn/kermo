import AppKit
import DFMCore

/// A server's page in the Tools window, or a window of its own (monitor §9, decision 30): its name and chips, the open
/// tab's header line, Terminal and ⋯; the tools it shows as tabs (⌘1…⌘9), ＋ for the rest of the library. A list's tab
/// opens the list in the main window — a panel or the search — never here; a launcher's buttons run its actions as
/// its rows do (the question over this window, the line under the buttons); a one-command tool is one button. A server
/// that isn't connected shows what it last had, grey, and Connect: nothing logs in to draw a page (§10.5).
@MainActor
final class ToolsPage: NSView, RowList {
    unowned let app: AppDelegate
    let server: SavedServer
    /// As its user, as Tools ▸ has it.
    let target: SFTPTarget
    /// In the Tools window, where ⋯ offers a window of its own; nil in that window.
    var openAlone: (@MainActor () -> Void)?
    /// The open tab: a tool's id.
    private(set) var tab: String?
    private(set) var shown: [LoadedTool] = []
    /// The rows (as `ToolListSource` names them) whose actions this page's buttons run: how they went is said here.
    private var ids: Set<String> = []
    private var headers: [String: String] = [:]
    private var connecting = false
    private var output: (@MainActor () -> Void)?
    private var kept: [AnyObject] = []
    /// The body's buttons' actions: replaced with it.
    private var bodyKept: [AnyObject] = []
    /// A watched tool's tab, made once and updated in place (`live`).
    private var lives: [String: ToolsLive] = [:]

    let title = NSTextField(labelWithString: "")
    let chips = NSStackView()
    let line = NSTextField(labelWithString: "")
    let tabs = NSSegmentedControl()
    let add = NSButton(title: "", target: nil, action: nil)
    let more = NSButton(title: "", target: nil, action: nil)
    let terminal = NSButton(title: "Terminal", target: nil, action: nil)
    let body = NSStackView()
    let result = NSTextField(labelWithString: "")
    let outputButton = NSButton(title: "Output…", target: nil, action: nil)

    init(_ app: AppDelegate, _ server: SavedServer, _ target: SFTPTarget) {
        (self.app, self.server, self.target) = (app, server, target.asUser)
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        line.textColor = .secondaryLabelColor
        line.lineBreakMode = .byTruncatingTail
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        terminal.image = Symbol.ssh.image("Terminal")
        terminal.imagePosition = .imageLeading
        terminal.toolTip = "An SSH tab on \(server.title) in the main window"
        more.image = Symbol.more.image("More")
        more.bezelStyle = .accessoryBarAction
        add.image = Symbol.plus.image("Use another tool here")
        add.bezelStyle = .accessoryBarAction
        add.toolTip = "Use another tool on \(server.title)"
        tabs.segmentStyle = .automatic
        tabs.trackingMode = .selectOne
        kept = [MenuAction.attach(to: terminal) { [unowned self] in
                    app.showMainWindow(nil)
                    app.openSSH(target)
                },
                MenuAction.attach(to: more) { [unowned self] in moreMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more) },
                MenuAction.attach(to: add) { [unowned self] in addMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: add.bounds.height + 4), in: add) },
                MenuAction.attach(to: tabs) { [unowned self] in select(shown.indices.contains(tabs.selectedSegment) ? shown[tabs.selectedSegment].preset.id : nil) },
                MenuAction.attach(to: outputButton) { [unowned self] in output?() }]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [title, chips, spacer, terminal, more])
        (top.spacing, top.distribution) = (8, .fill)
        chips.spacing = 4
        let tabRow = NSStackView(views: [tabs, add])
        tabRow.spacing = 6
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        result.lineBreakMode = .byTruncatingTail
        result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        outputButton.bezelStyle = .accessoryBarAction
        outputButton.isHidden = true
        let foot = NSStackView(views: [result, outputButton])
        let fill = NSView()
        fill.setContentHuggingPriority(.init(1), for: .vertical)
        let stack = NSStackView(views: [top, line, tabRow, body, fill, foot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 12, right: 18)
        stack.setCustomSpacing(4, after: top)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        for v in [top, line, body, foot] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var key: String { ServerRow.key(target) }
    private var up: Bool { AppDelegate.connected(target) }
    private var current: LoadedTool? { shown.first { $0.preset.id == tab } }
    /// The open tab's tool when it has a stream or a poll: live while this page shows it (`ToolMonitor`).
    var liveTool: LoadedTool? { current.flatMap { $0.preset.watchable ? $0 : nil } }
    private func watched(_ tool: LoadedTool) -> Bool { app.tools.monitor.tool(tool.preset.id, on: target)?.watched == true }
    private func name(_ p: ToolPreset) -> String { p.tool.map { "\(p.title) (\($0))" } ?? p.title }

    // MARK: Showing it

    /// Drawn again from what's known: the tools the server shows (`ToolRunner.here`), connected or not.
    func refresh() {
        let known = app.tools.here(target)
        shown = known?.tools ?? []
        title.stringValue = server.title
        title.textColor = server.prod ? Palette.prod : .labelColor
        chips.setViews(Chip.of(target).map { c in
            let v = NSImageView(image: c.image)
            v.setAccessibilityLabel(c.spoken)
            return v
        }, in: .leading)
        tabs.segmentCount = shown.count
        for (i, t) in shown.enumerated() {
            tabs.setLabel(t.preset.title, forSegment: i)
            tabs.setImage(Symbol.preset(t.preset.icon), forSegment: i)
            tabs.setImageScaling(.scaleProportionallyDown, forSegment: i)
            tabs.setToolTip((t.preset.about.map { $0 + " · " } ?? "") + (i < 9 ? "⌘\(i + 1)" : ""), forSegment: i)
        }
        tabs.isHidden = shown.isEmpty
        tabs.isEnabled = up || shown.contains(where: watched)
        if current == nil { tab = shown.first?.preset.id }
        tabs.selectedSegment = shown.firstIndex { $0.preset.id == tab } ?? -1
        more.isEnabled = current != nil
        showBody(known?.at)
        showHeader()
        marks()
        app.tools.monitor.reconcile()
    }

    /// Samples came, or the server's state changed: the live tab and the tabs' marks, in place.
    func live() {
        tab.flatMap { lives[$0] }?.update()
        marks()
    }

    /// A tab with an alert standing shows it instead of its icon (monitor §3.6): a triangle for a warning, an octagon
    /// for a critical one.
    private func marks() {
        for (i, t) in shown.enumerated() {
            let level = app.tools.monitor.level(t.preset.id, on: target)
            tabs.setImage(level == .critical ? Symbol.crit.image(color: Palette.fail, size: 13) : level == .warning ? Symbol.warnFill.image(color: Palette.warn, size: 13)
                          : Symbol.preset(t.preset.icon), forSegment: i)
        }
    }

    func select(_ id: String?) {
        guard id != tab else { return }
        tab = id
        (result.stringValue, outputButton.isHidden, output) = ("", true, nil)
        refresh()
    }

    /// ⌘1…⌘9: a tab.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, let c = e.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n),
              shown.indices.contains(n - 1), tabs.isEnabled else { return super.performKeyEquivalent(with: e) }
        select(shown[n - 1].preset.id)
        return true
    }

    private func showBody(_ at: Date?) {
        (ids, bodyKept) = ([], [])
        let views: [NSView]
        if let tool = current, watched(tool) || (up && liveTool != nil) {   // a watched tool's tab draws on its own, connected or not
            views = [live(tool)]
        } else if !up {
            let since = at.map { "As of \($0.formatted(date: .omitted, time: .shortened)) it had " + (shown.isEmpty ? "none of your tools." : shown.map(\.preset.title).joined(separator: ", ") + ".") }
            views = [Self.text("\(server.title) isn't connected.", size: 15, bold: true),
                     Self.text((since ?? "Kermo hasn't seen what it has yet.") + " Kermo doesn't connect to draw this page.", color: .secondaryLabelColor),
                     button(connecting ? "Connecting…" : "Connect", enabled: !connecting) { [unowned self] in connect() }]
        } else if let tool = current {
            views = page(tool)
            readHeader(tool)
        } else if app.tools.answer(target) == nil {
            views = [Self.text("Looking at what \(server.title) has…", color: .secondaryLabelColor)]
        } else {
            views = [Self.text("No tools on \(server.title).", size: 15, bold: true),
                     Self.text("＋ above uses one of the library's here; Use on Servers… in the library chooses where each one is used.", color: .secondaryLabelColor)]
        }
        body.setViews(views, in: .top)
    }

    private func live(_ tool: LoadedTool) -> ToolsLive {
        let v = lives[tool.preset.id] ?? ToolsLive(app, tool, server, target)
        lives[tool.preset.id] = v
        v.update()
        return v
    }

    /// The open tab's: a list's card, a launcher's buttons, a one-command tool's button — or its values to set first.
    private func page(_ tool: LoadedTool) -> [NSView] {
        let p = tool.preset
        let needs = app.tools.toSetUp(tool, on: target)
        if !needs.isEmpty {
            let titles = needs.map { p.vars?[$0]?.info.title ?? $0 }.joined(separator: ", ")
            return [Self.text("\(p.title) needs settings on \(server.title)", size: 15, bold: true),
                    Self.text("It asks for: \(titles). Kermo keeps the values with the server, not in the tool's file; nothing runs before they're set.", color: .secondaryLabelColor),
                    button("Set Up on \(server.title)…") { [unowned self] in Task { _ = await app.tools.setUp(tool, on: target, window: window) } }]
        }
        if p.list != nil {
            let n = app.tools.counts[key + " " + p.id].map { $0 == 1 ? "1 row on \(server.title) when last read. " : "\($0) rows on \(server.title) when last read. " } ?? ""
            let icon = NSImageView(image: Symbol.preset(p.icon))
            icon.symbolConfiguration = .init(pointSize: 30, weight: .regular)
            icon.contentTintColor = .secondaryLabelColor
            let buttons = NSStackView(views: [button("Open in Panel", primary: true) { [unowned self] in openInPanel(tool) },
                                              button("Open in Search") { [unowned self] in openInSearch(tool) }])
            return [icon, Self.text("\(p.title) is a list", size: 15, bold: true),
                    Self.text(n + "Lists open in the main window: as a panel next to your files, or in the search (⇧⌘P). The same rows, keys and questions everywhere.",
                              color: .secondaryLabelColor), buttons]
        }
        if let a = p.commandAction {
            let id = key + " tool:\(p.id)"
            ids.insert(id)
            let why = app.tools.why(a, of: tool, row: nil, onRow: false, id: id, on: server, target)
            let command = try? ToolPayload.of(a.run, in: p, scope: app.tools.scope(p, on: server, target), scripts: tool.scripts).willRun
            return [grid([launch(p.title, why: why, about: command ?? "") { [unowned self] in
                app.tools.perform(a, of: tool, row: nil, onRow: false, id: id, from: nil, on: server, target)
            }])]
        }
        let source = ToolListSource(app, tool, server, target)   // a launcher's actions, as its rows have them
        let actions = source.listActions(nil).filter { $0.group == 1 }
        return [grid(actions.map { a in
            ids.insert(source.rowID(a.title))
            return launch(a.title, why: a.why, about: a.command ?? "") { a.run(false) }
        })]
    }

    /// A launcher's button and what it runs under it (or why it can't); pressed, it waits for its run.
    private func launch(_ title: String, why: String?, about: String, run: @escaping @MainActor () -> Task<Void, Never>?) -> NSView {
        let b = NSButton(title: title, target: nil, action: nil)
        b.controlSize = .large
        b.isEnabled = why == nil
        b.toolTip = why ?? about
        bodyKept.append(MenuAction.attach(to: b) { [weak self, weak b] in
            guard let task = run() else { return }
            b?.isEnabled = false
            Task { await task.value; self?.refresh() }   // drawn again meanwhile (a sheet came and went): as it is now
        })
        let under = NSTextField(labelWithString: why ?? about)
        under.font = why == nil ? .monospacedSystemFont(ofSize: 10.5, weight: .regular) : .systemFont(ofSize: 11)
        under.textColor = .secondaryLabelColor
        under.lineBreakMode = .byTruncatingTail
        under.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cell = NSStackView(views: [b, under])
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 3
        cell.widthAnchor.constraint(equalToConstant: 200).isActive = true
        b.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
        under.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
        return cell
    }

    /// Buttons three to a row.
    private func grid(_ cells: [NSView]) -> NSView {
        let rows = stride(from: 0, to: cells.count, by: 3).map { i in (0..<3).map { i + $0 < cells.count ? cells[i + $0] : NSGridCell.emptyContentView } }
        let g = NSGridView(views: rows)
        (g.rowSpacing, g.columnSpacing) = (12, 12)
        return g
    }

    private func button(_ title: String, primary: Bool = false, enabled: Bool = true, _ run: @escaping @MainActor () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        if primary { b.keyEquivalent = "\r" }
        b.isEnabled = enabled
        bodyKept.append(MenuAction.attach(to: b, run))
        return b
    }

    static func text(_ s: String, color: NSColor = .labelColor, size: CGFloat = 12, bold: Bool = false) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s.bidiVisible)
        l.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        l.textColor = color
        return l
    }

    // MARK: The header line

    /// The open tab's `header` and what its version says, as the list's line above its rows has them: read over the
    /// connection that's up, once a page — not on a locked server (that asks Touch ID: a look, not a page's drawing).
    private func readHeader(_ tool: LoadedTool) {
        let p = tool.preset, k = key + " " + p.id
        guard headers[k] == nil, (p.list?.view.header ?? p.header) != nil || p.version != nil, !ServerLock.needsUnlock(target) else { return }
        headers[k] = ""
        let lister = ToolListSource.lister(app, tool, server, target), env = SSHAskpass.env
        Task {
            let r = await Blocking.run { try? lister.read(env, CancelFlag(), rows: false) }
            if let v = r?.vars { app.tools.found[k] = v }
            if let v = r?.version { app.tools.versions[k] = .some(v) }
            headers[k] = r?.header ?? ""
            showHeader()
        }
    }

    private func showHeader() {
        let k = key + " " + (tab ?? "")
        line.stringValue = [headers[k].flatMap { $0.isEmpty ? nil : $0 }, app.tools.versions[k] ?? nil].compactMap { $0 }.joined(separator: " · ")
        line.isHidden = line.stringValue.isEmpty || !up
    }

    // MARK: What it does

    private func openInPanel(_ tool: LoadedTool) {
        app.showMainWindow(nil)
        app.showPanels()
        app.active.showList(ToolListSource(app, tool, server, target))
        app.window.makeFirstResponder(app.active.table)
    }

    private func openInSearch(_ tool: LoadedTool) {
        app.showMainWindow(nil)
        app.showInSearch(ToolListSource(app, tool, server, target))
    }

    /// As a list's look does: a locked server asks first, then the login if one is due; then what it has is asked.
    private func connect() {
        connecting = true
        refresh()
        let t = target, env = SSHAskpass.env.merging(["DFM_ASKPASS_WHY": "For Tools on \(server.title)"]) { $1 }
        Task {
            defer { connecting = false; refresh() }
            guard await ServerLock.authorize(t, "connect to") else { return say("\(server.title) stays locked", failed: false) }
            do {
                try await Blocking.run { try SFTP.startMaster(t, env: env) }
                app.noteLook(t)
            } catch { say("\(server.title): \(error.localizedDescription)", failed: true) }
        }
    }

    /// ⋯: this page in a window of its own, where the tool is used, its file, Hide.
    func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let openAlone { menu.addItem(MenuAction.item("Open in New Window", openAlone)) }
        guard let tool = current else { return menu }
        let p = tool.preset
        if p.watchable {
            let on = watched(tool)
            let it = MenuAction.item(on ? "Stop Watching \(p.title) on \(server.title)" : "Watch \(p.title) in Background…") { [unowned self] in
                Task { await app.tools.toggleWatch(tool, on: server, target, window: window) }
            }
            it.isEnabled = app.tools.serverID(target) != nil
            it.toolTip = it.isEnabled ? nil : "\(server.title) isn't saved: only a saved server is watched"
            menu.addItem(it)
            menu.addItem(.separator())
        }
        menu.addItem(MenuAction.item("Use \(p.title) on Servers…") { [unowned self] in Task { await app.tools.useOnServers(tool, window: window) } })
        menu.addItem(MenuAction.item("Show \((tool.path as NSString).lastPathComponent)") { Viewer.show(URL(fileURLWithPath: tool.path)) })
        menu.addItem(.separator())
        let hide = MenuAction.item("Hide \(p.title) on \(server.title)") { [unowned self] in app.tools.show(tool, on: target, false) }
        hide.isEnabled = app.tools.serverID(target) != nil
        hide.toolTip = hide.isEnabled ? "＋ or Use on Servers… shows it again" : "\(server.title) isn't saved: only a saved server keeps settings"
        menu.addItem(hide)
        return menu
    }

    /// ＋: the library's tools this server doesn't show — hidden or not used here (shown again), not there (grey), yours
    /// not in use yet ("Use the tool…?" first).
    func addMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let known = app.tools.answer(target)?.answer, here = Set(shown.map(\.preset.id)), saved = app.tools.serverID(target) != nil
        for tool in app.tools.tools where !here.contains(tool.preset.id) {
            let p = tool.preset
            guard known?.has(p) == true else {
                menu.addItem(AppDelegate.note("\(name(p)) — " + (known == nil ? "not checked yet" : "not on \(server.title)")))
                continue
            }
            let it = MenuAction.item("\(name(p)) — " + (app.tools.settings.only[p.id] != nil ? "used on other servers" : "hidden here")) { [unowned self] in
                app.tools.show(tool, on: target, true)
                select(p.id)
            }
            it.image = Symbol.preset(p.icon)
            it.isEnabled = saved
            menu.addItem(it)
        }
        let untrusted = app.tools.untrusted
        if !untrusted.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(AppDelegate.note("Not in use yet"))
            for tool in untrusted {
                menu.addItem(MenuAction.item(name(tool.preset) + "…") { [unowned self] in
                    Task {
                        guard await app.tools.trustAsk(tool, window: window) else { return }
                        app.tools.askAgain(target)
                        refresh()
                    }
                })
            }
        }
        if menu.items.isEmpty { menu.addItem(AppDelegate.note("Every tool Kermo has shows here")) }
        return menu
    }

    // MARK: RowList — how a button's run went

    func has(_ id: String) -> Bool { window != nil && ids.contains(id) }
    func update(_ item: Picker.Item) {}
    func reload(_ c: ListContent, having id: String) {}
    var sheetWindow: NSWindow? { window }
    func holding<T>(_ work: () async -> T) async -> T { await work() }

    func said(_ text: NSAttributedString, about id: String, failed: Bool, output: (@MainActor () -> Void)?) {
        result.attributedStringValue = text
        result.toolTip = text.string
        (outputButton.isHidden, self.output) = (output == nil, output)
    }

    private func say(_ text: String, failed: Bool) {
        said(NSAttributedString(string: text, attributes: [.foregroundColor: failed ? Palette.fail : NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12)]),
             about: "", failed: failed, output: nil)
    }
}
