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

    /// Its port closes, its connections too, and it stays off at launch (a temporary one is gone); the server's
    /// connection goes too if nothing else uses it now.
    func turnOffNow(_ t: Tunnel, of s: SavedServer) {
        let temporary = tunnels.isTemporary(t, of: s)
        tunnels.stop(t, of: s)
        if !temporary { saveTunnel(t, of: s, on: false) }
        releaseIdleServers()
    }

    func saveTunnel(_ t: Tunnel, of s: SavedServer, on: Bool) {
        guard let i = savedServers.firstIndex(where: { $0.id == s.id }),
              let j = savedServers[i].tunnels.firstIndex(where: { $0.localPort == t.localPort }), savedServers[i].tunnels[j].on != on else { return }
        savedServers[i].tunnels[j].on = on
        Config.save("servers.json", savedServers)
        refreshSidebar()   // its rows keep a copy of the server: their menus would edit the old `on`
    }
}

extension AppDelegate {
    /// A tunnel's item (U3): "Postgres → 15432 · 3" with a ● — green listening, grey off, red when its last connection
    /// failed (the tooltip says why) — and what to do with it in a submenu, so a stray click never cuts a client off.
    /// In production's color on a production server, as the server is.
    /// A temporary one (U5): "· temporary", and Turn Off, Open in Browser, Copy Address, Save (once its server is saved).
    func tunnelItem(_ t: Tunnel, of s: SavedServer) -> NSMenuItem {
        let st = tunnels.state(t, of: s), on = st?.listener != nil, n = tunnels.connections(t, of: s), temporary = st?.temporary == true
        let it = NSMenuItem(title: "\(t.title) → \(t.localPort)" + (n > 0 ? " · \(n)" : "") + (temporary ? " · temporary" : ""), action: nil, keyEquivalent: "")
        let failed = st?.error != nil
        let color: NSColor = failed ? .systemRed : on ? .systemGreen : .tertiaryLabelColor
        it.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: failed ? "failed" : on ? "listening" : "off")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular).applying(.init(paletteColors: [color])))
        it.toolTip = st?.error ?? t.route(via: s.title)
        if s.prod { it.attributedTitle = NSAttributedString(string: it.title, attributes: [.foregroundColor: SavedServer.color, .font: NSFont.menuFont(ofSize: 0)]) }
        let menu = NSMenu()
        if temporary {
            [MenuAction.item("Turn Off") { [unowned self] in turnOff(t, of: s) },
             t.link.map { url in MenuAction.item("Open in Browser") { [unowned self] in openTunnel(t, of: s, url) } },
             MenuAction.item("Copy Address") { [unowned self] in copyAddress(t) },
             savedServer(at: s.target).map { _ in MenuAction.item("Save") { [unowned self] in saveTemporary(t, of: s) } }].compactMap { $0 }.forEach(menu.addItem)
            it.submenu = menu
            return it
        }
        [on ? MenuAction.item("Turn Off") { [unowned self] in turnOff(t, of: s) } : MenuAction.item("Turn On") { [unowned self] in turnOn(t, of: s) },
         !on && failed && t.on ? MenuAction.item("Turn Off") { [unowned self] in turnOffNow(t, of: s) } : nil,   // couldn't listen: not at launch either
         t.link.map { url in MenuAction.item("Open in Browser") { [unowned self] in openTunnel(t, of: s, url) } },
         MenuAction.item("Copy Address") { [unowned self] in copyAddress(t) },
         .separator(),
         MenuAction.item("Edit…") { [unowned self] in editTunnel(t, of: s) },
         MenuAction.item("Delete…") { [unowned self] in deleteTunnel(t, of: s) }].compactMap { $0 }.forEach(menu.addItem)
        it.submenu = menu
        return it
    }

    /// A server row's menu ▸ Tunnels: a saved server's tunnels, then the temporary ones on its address (an unsaved
    /// server has those alone); New Tunnel… (saved) and Forward Port….
    func tunnelsItem(for s: SavedServer?, at target: SFTPTarget) -> NSMenuItem {
        let it = NSMenuItem(title: "Tunnels", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let items = (s.map { s in s.tunnels.map { tunnelItem($0, of: s) } } ?? [])
            + tunnels.temporaries(server: ServerRow.key(target)).map { tunnelItem($0.tunnel, of: $0.server) }
        items.forEach(menu.addItem)
        if !items.isEmpty { menu.addItem(.separator()) }
        if let s { menu.addItem(MenuAction.item("New Tunnel…") { [unowned self] in editTunnel(nil, of: s) }) }
        menu.addItem(MenuAction.item("Forward Port…") { [unowned self] in forwardPort(on: target) })
        it.submenu = menu
        return it
    }

    /// Go ▸ Tunnels (U2): every saved server's tunnels under its name — the temporary ones on its address too — then
    /// those of servers not saved; built each time it opens.
    func goTunnelsItem() -> NSMenuItem {
        let it = NSMenuItem(title: "Tunnels", action: nil, keyEquivalent: "")
        it.submenu = LiveMenu(title: "Tunnels") { [unowned self] in
            var items: [NSMenuItem] = []
            func header(_ title: String, prod: Bool) -> NSMenuItem {
                let h = NSMenuItem.sectionHeader(title: title)
                if prod { h.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: SavedServer.color, .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)]) }
                return h
            }
            var temporaries = tunnels.temporaries()
            for s in savedServers {
                let key = ServerRow.key(s.target), mine = temporaries.filter { ServerRow.key($0.server.target) == key }
                temporaries.removeAll { ServerRow.key($0.server.target) == key }
                guard !s.tunnels.isEmpty || !mine.isEmpty else { continue }
                items += [header(s.title, prod: s.prod)] + s.tunnels.map { tunnelItem($0, of: s) } + mine.map { tunnelItem($0.tunnel, of: $0.server) }
            }
            for key in temporaries.map({ ServerRow.key($0.server.target) }).reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } }) {
                let mine = temporaries.filter { ServerRow.key($0.server.target) == key }
                items += [header(mine[0].server.title, prod: false)] + mine.map { tunnelItem($0.tunnel, of: $0.server) }
            }
            if !items.isEmpty { items.append(.separator()) }
            return items + [MenuAction.item("New Tunnel…") { [unowned self] in newTunnel() },
                            MenuAction.item("Forward Port…") { [unowned self] in forwardPort() }]
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
        for st in newOnly ? [] : tunnels.temporaries() {   // ↩ turns one off: it goes
            let (t, s) = (st.tunnel, st.server), n = tunnels.connections(t, of: s)
            var keys: [Shortcut: @MainActor () -> Void] = [Shortcut("cmd+c")!: { [unowned self] in copyAddress(t) }]
            if let url = t.link { keys[Shortcut("cmd+o")!] = { [unowned self] in openTunnel(t, of: s, url) } }
            if savedServer(at: s.target) != nil { keys[Shortcut("cmd+s")!] = { [unowned self] in saveTemporary(t, of: s) } }
            items.append(Picker.Item(title: "\(t.title) → \(t.localPort)", subtitle: (SavedServer.isProd(s.target) ? "🟣 PROD · " : "") + (st.error ?? t.route(via: s.title)),
                                     detail: (st.error != nil ? "failed" : n > 0 ? "listening · \(n) open" : "listening") + " · temporary",
                                     keys: keys) { [unowned self] in turnOff(t, of: s) })
        }
        for s in savedServers where !newOnly {
            for t in s.tunnels {
                let st = tunnels.state(t, of: s), n = tunnels.connections(t, of: s)
                var keys: [Shortcut: @MainActor () -> Void] = [Shortcut("cmd+c")!: { [unowned self] in copyAddress(t) },
                                                               Shortcut("cmd+backspace")!: { [unowned self] in deleteTunnel(t, of: s) }]
                if let url = t.link { keys[Shortcut("cmd+o")!] = { [unowned self] in openTunnel(t, of: s, url) } }
                items.append(Picker.Item(title: "\(t.title) → \(t.localPort)", subtitle: (s.prod ? "🟣 PROD · " : "") + (st?.error ?? t.route(via: s.title)),
                                         detail: st?.error != nil ? "failed" : st?.listener == nil ? "off" : n > 0 ? "listening · \(n) open" : "listening",
                                         edit: { [unowned self] in editTunnel(t, of: s) }, keys: keys) { [unowned self] in
                    if tunnels.isListening(t, of: s) { turnOff(t, of: s) } else { turnOn(t, of: s) }
                })
            }
        }
        items += savedServers.map { s in Picker.Item(title: "New Tunnel on “\(s.title)”…", subtitle: s.target.host) { [unowned self] in editTunnel(nil, of: s) } }
        guard !items.isEmpty else { return active.flash("Tunnels belong to saved servers: save one first (New Server…), or Forward Port… for now") }
        Picker.show(over: window, placeholder: newOnly ? "New tunnel on which server?"
                    : "Tunnels — ↩ on / off · ⌘E edit · ⌘C copy address · ⌘O open in browser · ⌘S save · ⌘⌫ delete", items: items)
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
                                 problem: String? = nil, free: Int? = nil, turnOn wanted: Bool = false) {
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
        alert.informativeText = "Kermo listens on this Mac's localhost only and goes on from “\(server.title)”, as ssh -L does.".bidiVisible
        let save = old == nil ? ["Save & Turn On", "Save"] : ["Save"]
        (save + (free.map { ["Use \($0)"] } ?? []) + ["Cancel"]).forEach { alert.addButton(withTitle: $0) }
        if old != nil { alert.addButton(withTitle: "Delete…").hasDestructiveAction = true }
        if free != nil { Self.returnTakes(alert.buttons[save.count], in: alert) }   // back with a taken port: ↩ takes the free one
        alert.accessoryView = grid
        alert.window.initialFirstResponder = forward.isEmpty ? forwardField : nameField

        let draft = Tunnel(localPort: 0, port: 0)
        func update(said: String? = nil) {
            let read = try? draft.reading(forwardField.stringValue).get()
            for b in alert.buttons.prefix(save.count + (free == nil ? 0 : 1)) { b.isEnabled = read != nil }   // Use N too
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
            let use = free != nil && i == save.count   // "Use N": as the button chosen before it was taken
            let turnOnNow = old == nil && (use ? wanted : i == 0)
            if let free, use { t.localPort = free }
            t.name = typed.name.isEmpty ? Tunnel.knownNames[t.port] ?? "" : typed.name
            t.url = typed.url.isEmpty ? nil : typed.url
            t.on = s.tunnels.first { $0.localPort == old?.localPort }?.on ?? false   // as saved now: the menu's copy may be older
            let again = { (problem: String, free: Int?) in
                DispatchQueue.main.async {
                    self.showTunnelSheet(old, of: server, name: typed.name, forward: t.forward, url: typed.url, problem: problem, free: free,
                                         turnOn: turnOnNow)
                }
            }
            if let j = s.tunnels.firstIndex(where: { $0.localPort == old?.localPort }) { s.tunnels[j] = t } else { s.tunnels.append(t) }
            if let p = Tunnel.problem(s.tunnels) { return again(p, nil) }
            if t.localPort != old?.localPort, !TunnelListener.isFree(t.localPort) {
                return again("Port \(t.localPort) is in use on this Mac", TunnelListener.freePort(after: t.localPort))
            }
            saveTunnelSheet(t, replacing: old, in: s, turnOn: turnOnNow)
        }
    }

    /// ↩ answers `button`, no longer the first; ⎋ stays Cancel's.
    static func returnTakes(_ button: NSButton, in alert: NSAlert) {
        alert.buttons.filter { $0.keyEquivalent == "\r" }.forEach { $0.keyEquivalent = "" }
        button.keyEquivalent = "\r"
    }

    /// Saved; one listening that now goes another way listens anew (`sync`: on another port, here) — the connections
    /// it has open live on to where they went. One that was on but couldn't listen tries again.
    private func saveTunnelSheet(_ t: Tunnel, replacing old: Tunnel?, in s: SavedServer, turnOn now: Bool) {
        let st = old.flatMap { tunnels.state($0, of: s) }, listening = st?.listener != nil, failed = st != nil && !listening && t.on
        guard let i = savedServers.firstIndex(where: { $0.id == s.id }) else { return }
        if let old, old.localPort != t.localPort { tunnels.moving(old, of: s) }
        savedServers[i] = s
        Config.save("servers.json", savedServers)
        if now || failed || (listening && old?.localPort != t.localPort) { turnOn(t, of: s) } else { releaseIdleServers() }
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
            releaseIdleServers()
        }
    }
}

// Forward Port… (README "Tunnels"): what a server listens on, in a Picker; a port picked is forwarded by a temporary tunnel.
extension AppDelegate {
    /// The saved server at `t`'s address (user@host:port), if there is one.
    func savedServer(at t: SFTPTarget) -> SavedServer? { savedServers.first { ServerRow.key($0.target) == ServerRow.key(t) } }

    /// Saved servers, then the ~/.ssh/config hosts not saved — as Connect… lists them.
    func serverChoices() -> [(title: String, target: SFTPTarget, saved: SavedServer?)] {
        let saved = Set(savedServers.map { ServerRow.key($0.target) })
        return savedServers.map { ($0.title, $0.target, $0) }
            + SSHConfig.hosts().map { SFTPTarget(host: $0.alias) }.filter { !saved.contains(ServerRow.key($0)) }.map { ($0.host, $0, nil) }
    }

    /// Forward Port… (⌘⇧P, Go ▸ Tunnels): on the server the active panel or SSH tab is on (as its user); else pick one.
    func forwardPort() { onServer("Forward a port of") { [unowned self] in forwardPort(on: $0.asUser) } }

    /// The ports `t`'s server listens on (U1): a locked server asks first (U6), then the login (`look`).
    func forwardPort(on t: SFTPTarget) {
        look(at: t, "ports", for: "Forward Port", say: { [unowned self] in tunnels.say($0, $1) },
             { t, title, env, cancel in try ListeningPorts.read(on: t, server: title, env: env, cancel: cancel) }) { [unowned self] ports, s in
            showPorts(ports, of: s)
        }
    }

    /// One row a port (U2): ":5432 Postgres", its process and where it listens, and "→ localhost:15432" where a tunnel of
    /// the server already goes there. ↩ forwards it, ⌘O and opens it in the browser, ⌘C and copies the address, ⌘S and
    /// saves it as the server's tunnel (U4).
    func showPorts(_ ports: [ListeningPort], of s: SavedServer) {
        guard !ports.isEmpty else {
            Picker.dismiss()
            return tunnels.say("\(s.title): nothing listens on TCP", false)
        }
        Picker.show(over: window, placeholder: (s.prod ? SavedServer.mark : "") + "\(s.title)'s ports — ↩ forward · ⌘O browser · ⌘C copy · ⌘S save",
                    items: portItems(ports, of: s))
    }

    func portItems(_ ports: [ListeningPort], of s: SavedServer) -> [Picker.Item] {
        ports.map { p -> Picker.Item in
            let to = tunnelTo(p, of: s).flatMap { tunnels.isListening($0.tunnel, of: $0.server) ? $0 : nil }
            var keys: [Shortcut: @MainActor () -> Void] = [:]
            for (key, then) in [("cmd+o", PortThen.open), ("cmd+c", .copy), ("cmd+s", .save)] {
                keys[Shortcut(key)!] = { [unowned self] in forward(p, of: s, then) }
            }
            return Picker.Item(title: ":\(p.port)" + (Tunnel.knownNames[p.port].map { " " + $0 } ?? ""),
                               subtitle: ([p.process, p.reach].compactMap { $0 }).joined(separator: " · "),
                               detail: to.map { "→ \($0.tunnel.address)" + ($0.temporary ? " · temporary" : "") } ?? "", keys: keys) { [unowned self] in
                forward(p, of: s, .none)
            }
        }
    }

    enum PortThen { case none, open, copy, save }

    /// A tunnel of the server — saved or temporary — that goes to this port: to its address, or to localhost for one
    /// that listens there or everywhere.
    private func tunnelTo(_ p: ListeningPort, of s: SavedServer) -> (tunnel: Tunnel, server: SavedServer, temporary: Bool)? {
        let local = ["localhost", "127.0.0.1", "::1"]
        func goes(_ t: Tunnel) -> Bool { t.port == p.port && (t.host == p.host || local.contains(t.host) && local.contains(p.host)) }
        let saved = savedServer(at: s.target).map { s in s.tunnels.filter(goes).map { ($0, s, false) } } ?? []
        let temporary = tunnels.temporaries(server: ServerRow.key(s.target)).filter { goes($0.tunnel) }.map { ($0.tunnel, $0.server, true) }
        return (saved + temporary).first { tunnels.isListening($0.0, of: $0.1) } ?? (saved + temporary).first
    }

    /// ↩ on a port: a tunnel already going there serves (a saved one that's off turns on); else a temporary one on the
    /// same port here — the next free one when it's taken, said (U3) — which then never moves by itself.
    func forward(_ p: ListeningPort, of s: SavedServer, _ then: PortThen) {
        if let to = tunnelTo(p, of: s) {
            let (t, owner) = (to.tunnel, to.server)
            if tunnels.isListening(t, of: owner) {
                if then == .none { tunnels.say("\(t.title): \(t.address) → \(owner.title):\(t.port) · listening already", false) }
                return portThen(t, of: owner, then)
            }
            return turnOn(t, of: owner) { [unowned self] in portThen(t, of: owner, then) }
        }
        guard let local = freeLocalPort(p.port) else { return tunnels.say("No free port on this Mac near \(p.port)", true) }
        let t = Tunnel(name: Tunnel.knownNames[p.port] ?? p.process ?? "", localPort: local, host: p.host, port: p.port)
        if let why = tunnels.start(t, of: s, temporary: true) { return tunnels.say("“\(t.title)”: \(why)", true) }
        tunnels.say("\(t.title): " + (t.host == "localhost" ? "\(t.address) → \(s.title):\(t.port)" : t.route(via: s.title))
                    + (local == p.port ? "" : " (\(p.port) is taken here)") + " · listening", false)
        portThen(t, of: s, then)
    }

    private func portThen(_ t: Tunnel, of s: SavedServer, _ then: PortThen) {
        switch then {
        case .none: break
        case .open: NSWorkspace.shared.open(t.link ?? URL(string: "http://localhost:\(t.localPort)")!)   // asked for: a web page, whatever the port
        case .copy: copyAddress(t)
        case .save: saveTemporary(t, of: s)
        }
    }

    /// The server's port on this Mac too, if it's free and no saved tunnel has it (that one couldn't listen later);
    /// else the next such one.
    func freeLocalPort(_ port: Int) -> Int? {
        let saved = Set(savedServers.flatMap(\.tunnels).map(\.localPort))
        return stride(from: port, through: min(port + 100, 65535), by: 1).first { !saved.contains($0) && TunnelListener.isFree($0) }
    }

    /// Save (U4, U5): a temporary tunnel becomes its saved server's — on, so it listens at launch too — without closing
    /// its port; one on a server not saved stays temporary, and the status line says so.
    func saveTemporary(_ t: Tunnel, of temporary: SavedServer) {
        guard tunnels.isTemporary(t, of: temporary) else { return tunnels.say("“\(t.title)” is saved already", false) }
        guard let s = savedServer(at: temporary.target) else {
            return tunnels.say("Save the server first (New Server…): “\(t.title)” stays temporary", false)
        }
        Task {
            guard await ServerLock.authorize(s, "change the tunnels of"), tunnels.isTemporary(t, of: temporary),
                  let i = savedServers.firstIndex(where: { $0.id == s.id }) else { return }
            var saved = t
            saved.on = true
            if let p = Tunnel.problem(savedServers[i].tunnels + [saved]) { return tunnels.say("“\(t.title)” not saved: \(p)", true) }
            tunnels.adopt(t, of: temporary, into: savedServers[i])   // first: `sync` then finds it the server's
            savedServers[i].tunnels.append(saved)
            Config.save("servers.json", savedServers)
            refreshSidebar()
            tunnels.say("“\(t.title)” saved as a tunnel of \(s.title)", false)
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
