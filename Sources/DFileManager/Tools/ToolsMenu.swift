import AppKit
import DFMCore

// Where Tools show (Tools PR 2): Tools ▸ in a server's menus — its sidebar row's, a server folder's, Server in the menu
// bar — and a row for each tool in the server's place, so the search finds them too ("Firewall — web-01"). What a
// server has is asked once its connection is up (`ToolRunner.answer`), never logging in for a menu.
extension AppDelegate {
    /// Tools ▸ for `t`'s server: its tools as last known — "Firewall (ufw)", its symbol, a submenu per `group` — grey
    /// with "As of 14:02" while it isn't connected (a saved server's last answer, `tools/known.json`). Not known yet:
    /// "Connect to see tools"; known, none there: no item. Then your own tools not in use yet, each asking first.
    func toolsItem(for t: SFTPTarget) -> NSMenuItem? {
        let untrusted = tools.untrusted
        guard !tools.tools.isEmpty || !untrusted.isEmpty else { return nil }
        let menu = NSMenu(title: "Tools")
        menu.autoenablesItems = false
        let item = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        item.submenu = menu
        let up = Self.connected(t.asUser), s = savedServer(at: t) ?? SavedServer(target: t.asUser)
        var here: [LoadedTool] = []
        if let known = tools.answer(t) {
            here = tools.tools.filter { known.answer.has($0.preset) }
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
        }
        guard !here.isEmpty || !menu.items.isEmpty || !untrusted.isEmpty else { return nil }
        var groups: [String: NSMenu] = [:]
        for tool in here {
            let p = tool.preset
            let it = MenuAction.item(p.tool.map { "\(p.title) (\($0))" } ?? p.title) { [unowned self] in openTool(tool, on: s, t) }
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

    /// A tool on `t`'s server: its list in the search, on the server's place as Services… is; a one-command tool runs. A
    /// tool of yours not in use yet asks first (§12), and the server is asked again what it has.
    func openTool(_ tool: LoadedTool, on s: SavedServer, _ t: SFTPTarget) {
        guard tools.trust.trusts(tool) else {
            Task {
                guard await tools.trustAsk(tool, window: nil) else { return }
                tools.askAgain(t)
                openTool(tool, on: s, t)
            }
            return
        }
        if tool.preset.list != nil { return showInSearch(ToolListSource(self, tool, s, t)) }
        if let a = tool.preset.commandAction {
            tools.perform(a, of: tool, row: nil, onRow: false, id: ServerRow.key(t.asUser) + " tool:\(tool.preset.id)", from: nil, on: s, t.asUser)
        }
    }

    /// A place's tools: a row for each its server has, as last asked; its state the rows its list had when last read
    /// ("—" till then, or while it isn't connected). ↩ shows the list in that panel; a one-command tool runs.
    func placeTools(_ p: PlaceSource) -> [Picker.Item] {
        guard let known = tools.answer(p.target) else { return [] }
        let up = Self.connected(p.target)
        return tools.tools.filter { known.answer.has($0.preset) }.map { tool in
            guard tool.preset.list != nil else {
                return placeRow(tool.preset.title, p, about: tool.preset.about ?? "", open: { [unowned self] _ in openTool(tool, on: p.server, p.target) })
            }
            let n = up ? tools.counts[ServerRow.key(p.target) + " " + tool.preset.id] : nil
            return placeRow(tool.preset.title, p, state: n.map { $0 == 1 ? "1 row" : "\($0) rows" } ?? "—", about: tool.preset.about ?? "",
                            into: { [unowned self] in ToolListSource(self, tool, p.server, p.target) })
        }
    }

    /// What `t`'s server has is known now: its place in a panel shows its tools.
    func toolsKnown(on t: SFTPTarget) {
        for p in panels {
            guard let l = p.list, let s = l.source as? PlaceSource, ServerRow.key(s.target) == ServerRow.key(t), let c = s.content else { continue }
            l.set(c)
        }
    }
}
