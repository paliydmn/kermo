import AppKit
import DFMCore

// Where Tools show (Tools PR 2): Tools ▸ in a server's menus — its sidebar row's, a server folder's, Server in the menu
// bar — and a row for each tool in the server's place, so the search finds them too ("Firewall — web-01"). What a
// server has is asked once its connection is up (`ToolRunner.answer`), never logging in for a menu.
extension AppDelegate {
    /// Tools ▸ for `t`'s server: the tools it shows as last known (`ToolRunner.here`) — "Firewall (ufw)", its symbol, a
    /// submenu per `group`; one still to set up there says so — grey with "As of 14:02" while it isn't connected (a saved
    /// server's last answer, `tools/known.json`). Not known yet: "Connect to see tools"; known, none there: no item.
    /// Then your own tools not in use yet, each asking first; last, the server's page in the Tools window.
    func toolsItem(for t: SFTPTarget) -> NSMenuItem? {
        let untrusted = tools.untrusted
        guard !tools.tools.isEmpty || !untrusted.isEmpty else { return nil }
        let menu = NSMenu(title: "Tools")
        menu.autoenablesItems = false
        let item = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        item.submenu = menu
        let up = Self.connected(t.asUser), s = savedServer(at: t) ?? SavedServer(target: t.asUser)
        var here: [LoadedTool] = []
        if let known = tools.here(t) {
            here = known.tools
            if !up, !here.isEmpty { menu.addItem(Self.note("As of \(known.at.formatted(date: .omitted, time: .shortened)) — connect to use them")) }
        } else if !tools.tools.isEmpty {
            menu.addItem(Self.note(up ? "Looking at what it has…" : "Connect to see tools"))
        }
        defer {   // yours, new or changed: "Use the tool…?" first
            if !untrusted.isEmpty {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                menu.addItem(Self.note("Not in use yet"))
                for tool in untrusted {
                    let p = tool.preset
                    menu.addItem(MenuAction.item((p.tool.map { "\(p.title) (\($0))" } ?? p.title) + "…") { [unowned self] in openTool(tool, on: s, t) })
                }
            }
            if !menu.items.isEmpty {
                menu.addItem(.separator())
                menu.addItem(MenuAction.item("Open in Tools Window") { [unowned self] in ToolsWindow.show(self, server: t) })
            }
        }
        guard !here.isEmpty || !menu.items.isEmpty || !untrusted.isEmpty else { return nil }
        var groups: [String: NSMenu] = [:]
        for tool in here {
            let p = tool.preset
            let setUp = tools.toSetUp(tool, on: t).isEmpty ? "" : " — Set Up on \(s.title)…"
            let it = MenuAction.item((p.tool.map { "\(p.title) (\($0))" } ?? p.title) + setUp) { [unowned self] in openTool(tool, on: s, t) }
            it.image = Symbol.preset(p.icon)
            it.isEnabled = up
            guard let g = p.group else { menu.addItem(it); continue }
            let sub = groups[g] ?? {
                let m = NSMenu(title: g)
                m.autoenablesItems = false
                menu.addItem(withTitle: g, action: nil, keyEquivalent: "").submenu = m
                return m
            }()
            groups[g] = sub
            sub.addItem(it)
        }
        return item
    }

    /// Server ▸ Tools in the menu bar: the active panel's server's, or its SSH tab's — built as it opens.
    func toolsMenuItem() -> NSMenuItem {
        let it = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        it.submenu = LiveMenu(title: "Tools") { [unowned self] in
            guard let t = terminalActive ? terminal.current?.target : active.remote?.target ?? active.list?.source.target else {
                return [Self.note("No server in the active panel")]
            }
            guard let sub = toolsItem(for: t)?.submenu else { return [Self.note("No tools on \(SavedServer.name(for: t.asUser))")] }
            let items = sub.items
            sub.removeAllItems()
            return items
        }
        return it
    }

    static func note(_ text: String) -> NSMenuItem {
        let it = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    /// A tool on `t`'s server: its list (a launcher's: its actions) in the search, on the server's place as Services… is;
    /// a one-command tool runs. A tool of yours not in use yet asks first (§12), and the server is asked again what it has;
    /// one with values to set there asks for them first (§9).
    func openTool(_ tool: LoadedTool, on s: SavedServer, _ t: SFTPTarget) {
        guard tools.trust.trusts(tool) else {
            Task {
                guard await tools.trustAsk(tool, window: nil) else { return }
                tools.askAgain(t)
                openTool(tool, on: s, t)
            }
            return
        }
        if !tools.toSetUp(tool, on: t).isEmpty {
            Task { if await tools.setUp(tool, on: t, window: nil) { openTool(tool, on: s, t) } }
            return
        }
        if tool.preset.list == nil, tool.preset.source != nil {   // a watched tool: its tab in the Tools window
            ToolsWindow.show(self, server: t)
            ToolsWindow.main?.page?.select(tool.preset.id)
            return
        }
        guard let a = tool.preset.commandAction else { return showInSearch(ToolListSource(self, tool, s, t)) }   // a list, a launcher's actions
        tools.perform(a, of: tool, row: nil, onRow: false, id: ServerRow.key(t.asUser) + " tool:\(tool.preset.id)", from: nil, on: s, t.asUser)
    }

    /// Watch… / Stop Watching in a saved server's menu (decision 7): the first watched kind of tool it shows — System.
    func watchItem(for s: SavedServer?, at t: SFTPTarget) -> NSMenuItem? {
        guard let s, let tool = tools.here(t)?.tools.first(where: \.preset.watchable) else { return nil }
        let on = tools.settings.watches(tool.preset.id, on: s.id.uuidString)
        return MenuAction.item(on ? "Stop Watching" : "Watch…") { [unowned self] in Task { await tools.toggleWatch(tool, on: s, t.asUser, window: nil) } }
    }

    /// A place's tools: a row for each its server shows, as last asked; its state the rows its list had when last read
    /// ("—" till then, or while it isn't connected). ↩ shows the list in that panel; a one-command tool runs; one still
    /// to set up there asks for its values first.
    func placeTools(_ p: PlaceSource) -> [Picker.Item] {
        guard let known = tools.here(p.target) else { return [] }
        let up = Self.connected(p.target)
        return known.tools.map { tool in
            if !tools.toSetUp(tool, on: p.target).isEmpty {
                return placeRow(tool.preset.title, p, state: "set up…", about: "asks for its settings on \(p.server.title) first",
                                open: { [unowned self] _ in openTool(tool, on: p.server, p.target) })
            }
            if tool.preset.commandAction != nil || tool.preset.list == nil && tool.preset.source != nil {
                return placeRow(tool.preset.title, p, about: tool.preset.about ?? "", open: { [unowned self] _ in openTool(tool, on: p.server, p.target) })
            }
            let n = up && tool.preset.list != nil ? tools.counts[ServerRow.key(p.target) + " " + tool.preset.id] : nil   // a launcher's rows are its actions
            return placeRow(tool.preset.title, p, state: n.map { $0 == 1 ? "1 row" : "\($0) rows" } ?? (tool.preset.list == nil ? "" : "—"), about: tool.preset.about ?? "",
                            into: { [unowned self] in ToolListSource(self, tool, p.server, p.target) })
        }
    }

    /// What `t`'s server has is known now (nil: what any server shows changed — a tool's settings): its place in a panel
    /// shows its tools, and the Tools window its page.
    func toolsKnown(on t: SFTPTarget?) {
        for p in panels {
            guard let l = p.list, let s = l.source as? PlaceSource, t.map({ ServerRow.key(s.target) == ServerRow.key($0) }) ?? true, let c = s.content else { continue }
            l.set(c)
        }
        ToolsWindow.refresh()
    }
}

extension AppDelegate {
    /// Server ▸ Watch Server… (the menu, the search): Watch, or Stop Watching, the active panel's server — its SSH tab's, a list's.
    func watchActiveServer() {
        guard let t = terminalActive ? terminal.current?.target : active.remote?.target ?? active.list?.source.target else {
            return active.flash("No server in the active panel", error: true)
        }
        guard let s = savedServer(at: t) else { return active.flash("\(SavedServer.name(for: t.asUser)) isn't saved: only a saved server is watched", error: true) }
        guard let tool = tools.here(t)?.tools.first(where: \.preset.watchable) else {
            return active.flash("Nothing to watch on \(s.title): " + (Self.connected(t.asUser) ? "no tool with a stream shows there" : "connect first"), error: true)
        }
        Task { await tools.toggleWatch(tool, on: s, t.asUser, window: nil) }
    }
}
