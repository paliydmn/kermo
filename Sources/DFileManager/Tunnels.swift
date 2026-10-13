import AppKit
import DFMCore

// Tunnels (README "Tunnels"): what the menus, ⌘⇧P and the tunnel sheet do with them. Their ports: `Tunnels`.
extension AppDelegate {
    /// Turn On: a locked server asks first (Touch ID, as connecting does); then its port listens, now and at launch,
    /// and `then` runs. A production server's doesn't ask: a tunnel changes nothing there by itself.
    func turnOn(_ t: Tunnel, of s: SavedServer, then: (@MainActor () -> Void)? = nil) {
        Task {
            guard await ServerLock.authorize(s, "open a tunnel to") else { return tunnels.say("🔒 \(s.title) stays locked", false) }
            if let why = tunnels.start(t, of: s) { return tunnels.say("“\(t.title)”: \(why)", true) }
            saveTunnel(t, of: s, on: true)
            tunnels.say("\(t.title): " + (t.host == "localhost" ? "\(t.address) → \(s.title):\(t.port)" : t.route(via: s.title)) + " · listening", false)
            then?()
        }
    }

    /// Turn Off: asks first only while connections are open, since they close.
    func turnOff(_ t: Tunnel, of s: SavedServer) {
        Task {
            let n = tunnels.connections(t, of: s)
            if n > 0, await !confirm("Turn off “\(t.title)”?", info: n == 1 ? "1 open connection closes." : "\(n) open connections close.", ok: "Turn Off") { return }
            turnOffNow(t, of: s)
        }
    }

    /// Its port closes, its connections too, and it stays off at launch (Turn Off, Disconnect).
    func turnOffNow(_ t: Tunnel, of s: SavedServer) {
        tunnels.stop(t, of: s)
        saveTunnel(t, of: s, on: false)
    }

    private func saveTunnel(_ t: Tunnel, of s: SavedServer, on: Bool) {
        guard let i = savedServers.firstIndex(where: { $0.id == s.id }),
              let j = savedServers[i].tunnels.firstIndex(where: { $0.localPort == t.localPort }), savedServers[i].tunnels[j].on != on else { return }
        savedServers[i].tunnels[j].on = on
        Config.save("servers.json", savedServers)
    }
}

extension AppDelegate {
    /// A tunnel's item (U3): "Postgres → 15432 · 3" with a ● — green listening, grey off, red when its last connection
    /// failed (the tooltip says why) — and what to do with it in a submenu, so a stray click never cuts a client off.
    /// Red on a production server, as the server is.
    func tunnelItem(_ t: Tunnel, of s: SavedServer) -> NSMenuItem {
        let st = tunnels.state(t, of: s), on = st?.listener != nil, n = tunnels.connections(t, of: s)
        let it = NSMenuItem(title: "\(t.title) → \(t.localPort)" + (n > 0 ? " · \(n)" : ""), action: nil, keyEquivalent: "")
        let failed = st?.error != nil
        let color: NSColor = failed ? .systemRed : on ? .systemGreen : .tertiaryLabelColor
        it.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: failed ? "failed" : on ? "listening" : "off")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular).applying(.init(paletteColors: [color])))
        it.toolTip = st?.error ?? t.route(via: s.title)
        if s.prod { it.attributedTitle = NSAttributedString(string: it.title, attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0)]) }
        let menu = NSMenu()
        [on ? MenuAction.item("Turn Off") { [unowned self] in turnOff(t, of: s) } : MenuAction.item("Turn On") { [unowned self] in turnOn(t, of: s) },
         t.link.map { url in MenuAction.item("Open in Browser") { [unowned self] in openTunnel(t, of: s, url) } },
         MenuAction.item("Copy Address") { [unowned self] in copyAddress(t) },
         .separator(),
         MenuAction.item("Edit…") { [unowned self] in editTunnel(t, of: s) },
         MenuAction.item("Delete…") { [unowned self] in deleteTunnel(t, of: s) }].compactMap { $0 }.forEach(menu.addItem)
        it.submenu = menu
        return it
    }

    /// A server's sidebar menu ▸ Tunnels.
    func tunnelsItem(for s: SavedServer) -> NSMenuItem {
        let it = NSMenuItem(title: "Tunnels", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        s.tunnels.map { tunnelItem($0, of: s) }.forEach(menu.addItem)
        if !s.tunnels.isEmpty { menu.addItem(.separator()) }
        menu.addItem(MenuAction.item("New Tunnel…") { [unowned self] in editTunnel(nil, of: s) })
        it.submenu = menu
        return it
    }

    /// Go ▸ Tunnels (U2): every saved server's tunnels under its name, built each time it opens.
    func goTunnelsItem() -> NSMenuItem {
        let it = NSMenuItem(title: "Tunnels", action: nil, keyEquivalent: "")
        it.submenu = LiveMenu(title: "Tunnels") { [unowned self] in
            var items: [NSMenuItem] = []
            for s in savedServers where !s.tunnels.isEmpty {
                let header = NSMenuItem.sectionHeader(title: s.title)
                if s.prod { header.attributedTitle = NSAttributedString(string: s.title, attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)]) }
                items += [header] + s.tunnels.map { tunnelItem($0, of: s) }
            }
            if !items.isEmpty { items.append(.separator()) }
            return items + [MenuAction.item("New Tunnel…") { [unowned self] in newTunnel() }]
        }
        return it
    }

    /// Opens its URL — turning it on first if it's off (a locked server asks), or the page would find nobody there.
    func openTunnel(_ t: Tunnel, of s: SavedServer, _ url: URL) {
        if tunnels.isListening(t, of: s) { NSWorkspace.shared.open(url) } else { turnOn(t, of: s) { NSWorkspace.shared.open(url) } }
    }

    func copyAddress(_ t: Tunnel) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t.address, forType: .string)
        tunnels.say("Copied \(t.address)", false)
    }

    /// Tunnels… (⌘⇧P): every saved server's tunnels — ↩ turns one on or off, ⌘E edits, ⌘C copies its address, ⌘O opens it
    /// in the browser, ⌘⌫ deletes — then New Tunnel on each server. `newOnly`: just those (New Tunnel… with no server
    /// at hand).
    func showTunnels(newOnly: Bool = false) {
        var items: [Picker.Item] = []
        for s in savedServers where !newOnly {
            for t in s.tunnels {
                let st = tunnels.state(t, of: s), n = tunnels.connections(t, of: s)
                var keys: [Shortcut: @MainActor () -> Void] = [Shortcut("cmd+c")!: { [unowned self] in copyAddress(t) },
                                                               Shortcut("cmd+backspace")!: { [unowned self] in deleteTunnel(t, of: s) }]
                if let url = t.link { keys[Shortcut("cmd+o")!] = { [unowned self] in openTunnel(t, of: s, url) } }
                items.append(Picker.Item(title: "\(t.title) → \(t.localPort)", subtitle: (s.prod ? "🔴 PROD · " : "") + (st?.error ?? t.route(via: s.title)),
                                         detail: st?.error != nil ? "failed" : st?.listener == nil ? "off" : n > 0 ? "listening · \(n) open" : "listening",
                                         edit: { [unowned self] in editTunnel(t, of: s) }, keys: keys) { [unowned self] in
                    if tunnels.isListening(t, of: s) { turnOff(t, of: s) } else { turnOn(t, of: s) }
                })
            }
        }
        items += savedServers.map { s in Picker.Item(title: "New Tunnel on “\(s.title)”…", subtitle: s.target.host) { [unowned self] in editTunnel(nil, of: s) } }
        guard !items.isEmpty else { return active.flash("Tunnels belong to saved servers: save one first (New Server…)") }
        Picker.show(over: window, placeholder: newOnly ? "New tunnel on which server?"
                    : "Tunnels — ↩ on / off · ⌘E edit · ⌘C copy address · ⌘O open in browser · ⌘⌫ delete", items: items)
    }

    /// New Tunnel… (⌘⇧P, Go ▸ Tunnels): on the saved server the active panel or SSH tab is on; else pick one.
    func newTunnel() {
        let here = terminal.isShown ? terminal.current?.target : active.remote?.target
        if let here, let s = savedServers.first(where: { ServerRow.key($0.target) == ServerRow.key(here) }) { return editTunnel(nil, of: s) }
        showTunnels(newOnly: true)
    }

    /// New Tunnel… and Edit… (U6); a locked server asks first, as editing it does.
    func editTunnel(_ old: Tunnel?, of s: SavedServer) {
        Task {
            guard await ServerLock.authorize(s, "change the tunnels of") else { return }
            showTunnelSheet(old, of: s, name: old?.name ?? "", forward: old?.forward ?? "", url: old?.url ?? "")
        }
    }

    /// Forward is read as typed: the way it goes, or what's wrong, under it, and Save works only while it reads. Name
    /// left empty takes the port's usual name; URL left empty, a web port's own. A local port someone else listens on is
    /// said at Save with the next free one to take ("Use 15433"): a tunnel's port never moves by itself.
    private func showTunnelSheet(_ old: Tunnel?, of server: SavedServer, name: String, forward: String, url: String,
                                 problem: String? = nil, free: Int? = nil) {
        let nameField = NSTextField(string: name), forwardField = NSTextField(string: forward), urlField = NSTextField(string: url)
        [nameField, forwardField, urlField].forEach { $0.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        forwardField.placeholderString = "5432 · 15432:5432 · 15432:db.internal:5432"
        let hint = NSTextField(wrappingLabelWithString: "")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.preferredMaxLayoutWidth = 300
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Name:"), nameField],
                                      [NSTextField(labelWithString: "Forward:"), forwardField],
                                      [NSGridCell.emptyContentView, hint],
                                      [NSTextField(labelWithString: "URL:"), urlField]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 390, height: 130)

        let alert = NSAlert()
        alert.messageText = (old.map { "Edit “\($0.title)”" } ?? "New Tunnel on “\(server.title)”").bidiVisible
        alert.informativeText = "Kermo listens on this Mac (127.0.0.1 only) and goes on from “\(server.title)”, as ssh -L does.".bidiVisible
        let save = old == nil ? ["Save & Turn On", "Save"] : ["Save"]
        (save + (free.map { ["Use \($0)"] } ?? []) + ["Cancel"]).forEach { alert.addButton(withTitle: $0) }
        if old != nil { alert.addButton(withTitle: "Delete…").hasDestructiveAction = true }
        alert.accessoryView = grid
        alert.window.initialFirstResponder = forward.isEmpty ? forwardField : nameField

        let draft = Tunnel(localPort: 0, port: 0)
        func update(said: String? = nil) {
            let read = try? draft.reading(forwardField.stringValue).get()
            for b in alert.buttons.prefix(save.count) { b.isEnabled = read != nil }
            nameField.placeholderString = read.map(\.title) ?? "the port's own: Postgres, Redis, Grafana…"
            urlField.placeholderString = read?.link?.absoluteString ?? "none — a web page's, if it is one: http://localhost:…"
            if case .failure(let p) = draft.reading(forwardField.stringValue), !forwardField.stringValue.isEmpty || said != nil {
                (hint.stringValue, hint.textColor) = (said ?? p.message, .systemRed)
            } else {
                (hint.stringValue, hint.textColor) = (said ?? read?.route(via: server.title) ?? "As ssh -L: local port, then host and port as “\(server.title)” sees them", said == nil ? .secondaryLabelColor : .systemRed)
            }
        }
        update(said: problem)
        let live = LiveField { update() }
        forwardField.delegate = live

        alert.beginSheetModal(for: window) { [unowned self] r in
            _ = live
            window.makeFirstResponder(active.table)
            let i = r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let typed = (name: nameField.stringValue.trimmingCharacters(in: .whitespaces), forward: forwardField.stringValue,
                         url: urlField.stringValue.trimmingCharacters(in: .whitespaces))
            if let old, i == save.count + (free == nil ? 1 : 2) { return deleteTunnel(old, of: server) }
            guard i < save.count + (free == nil ? 0 : 1), var t = try? draft.reading(typed.forward).get(),
                  var s = savedServers.first(where: { $0.id == server.id }) else { return }
            let turnOnNow = old == nil && i != 1
            if let free, i == save.count { t.localPort = free }
            t.name = typed.name.isEmpty ? Tunnel.knownNames[t.port] ?? "" : typed.name
            t.url = typed.url.isEmpty ? nil : typed.url
            t.on = old?.on ?? false
            let again = { (problem: String, free: Int?) in
                DispatchQueue.main.async {
                    self.showTunnelSheet(old, of: server, name: typed.name, forward: t.forward, url: typed.url, problem: problem, free: free)
                }
            }
            if let j = s.tunnels.firstIndex(where: { $0.localPort == old?.localPort }) { s.tunnels[j] = t } else { s.tunnels.append(t) }
            if let p = Tunnel.problem(s.tunnels) { return again(p, nil) }
            if t.localPort != old?.localPort, !TunnelListener.isFree(t.localPort) {
                return again("Port \(t.localPort) is in use on this Mac", TunnelListener.freePort(after: t.localPort))
            }
            Task { await saveTunnelSheet(t, replacing: old, in: s, turnOn: turnOnNow) }
        }
    }

    /// A tunnel listening that now goes another way listens anew: its open connections close, so that's asked first.
    private func saveTunnelSheet(_ t: Tunnel, replacing old: Tunnel?, in s: SavedServer, turnOn now: Bool) async {
        let listening = old.map { tunnels.isListening($0, of: s) } ?? false, n = old.map { tunnels.connections($0, of: s) } ?? 0
        if let old, listening, n > 0, (old.localPort, old.host, old.port) != (t.localPort, t.host, t.port),
           await !confirm("Change “\(old.title)”?", info: n == 1 ? "It listens anew: 1 open connection closes." : "It listens anew: \(n) open connections close.", ok: "Save") {
            return
        }
        guard let i = savedServers.firstIndex(where: { $0.id == s.id }) else { return }
        savedServers[i] = s
        Config.save("servers.json", savedServers)   // `sync`: gone, or listening anew on the same port
        if now || (listening && old?.localPort != t.localPort) { turnOn(t, of: s) }
        refreshSidebar()
    }

    func deleteTunnel(_ t: Tunnel, of s: SavedServer) {
        Task {
            guard await ServerLock.authorize(s, "change the tunnels of") else { return }
            let n = tunnels.connections(t, of: s)
            let info = !tunnels.isListening(t, of: s) ? "" : n == 0 ? "It stops listening." : "It stops listening: \(n) open connection\(n == 1 ? " closes" : "s close")."
            guard await confirm("Delete the tunnel “\(t.title)”?", info: info, ok: "Delete"),
                  let i = savedServers.firstIndex(where: { $0.id == s.id }) else { return }
            savedServers[i].tunnels.removeAll { $0.localPort == t.localPort }
            Config.save("servers.json", savedServers)
        }
    }
}

/// A menu built each time it opens (Go ▸ Tunnels: connections come and go all the time).
final class LiveMenu: NSMenu, NSMenuDelegate {
    private let build: () -> [NSMenuItem]
    init(title: String, _ build: @escaping () -> [NSMenuItem]) {
        self.build = build
        super.init(title: title)
        delegate = self
    }
    required init(coder: NSCoder) { fatalError("not from a nib") }
    func menuNeedsUpdate(_ menu: NSMenu) { items = build() }
}

/// A field's text as typed, as it changes.
final class LiveField: NSObject, NSTextFieldDelegate {
    private let changed: () -> Void
    init(_ changed: @escaping () -> Void) { self.changed = changed }
    func controlTextDidChange(_ obj: Notification) { changed() }
}
