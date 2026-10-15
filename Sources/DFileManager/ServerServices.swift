import AppKit
import DFMCore

// Services… and Containers… (README "Services and containers"): what a server runs, in a Picker; keys on a row act on it.
extension AppDelegate {
    /// The server of the active panel or SSH tab — root if the panel is — else a Picker of servers to choose from.
    /// `what`: "Forward a port of", "Services of".
    func onServer(_ what: String, _ then: @escaping @MainActor (SFTPTarget) -> Void) {
        if let here = terminal.isShown ? terminal.current?.target : active.remote?.target { return then(here) }
        let items = serverChoices().map { c in
            Picker.Item(title: c.saved?.pickerTitle ?? c.title, subtitle: c.saved.map { ServerRow.address($0.target) } ?? "~/.ssh/config") { then(c.target) }
        }
        Picker.show(over: window, placeholder: "\(what) which server? — or type user@host", items: items, freeText: { q in
            guard case let .sftp(t, _)? = ServerAddress.parse(q) else { return [] }
            return [Picker.Item(title: "\(what) “\(q)”", detail: "↩") { then(t) }]
        }, freeTextLast: true)   // "web db" picks the server, not a host named so
    }

    /// A look at `t`'s server: a locked server asks first, then the login, if one is due — before anything shows: its
    /// dialogs take the focus, which closes a Picker. The Picker then says it's looking at `what` — ⎋ there stops the
    /// look — and gives way to `show`, or closes with why not (`say`). `command`: what asks for the password.
    func look<T: Sendable>(at t: SFTPTarget, _ what: String, for command: String, say: @escaping @MainActor (String, Bool) -> Void,
                           _ read: @escaping @Sendable (SFTPTarget, String, [String: String], CancelFlag) throws -> T,
                           show: @escaping @MainActor (T, SavedServer, SFTPTarget) -> Void) {
        let s = savedServer(at: t) ?? SavedServer(target: t)
        let t = s.target.asRoot(t.sudo)   // a saved server's: its key and connection time, whatever was typed
        Task {
            if let locked = ServerLock.server(for: s.target), await !ServerLock.authorize(locked, "look at the \(what) of") {
                return say("🔒 \(s.title) stays locked", false)
            }
            let env = SSHAskpass.env.merging(["DFM_ASKPASS_WHY": "For “\(command)” on \(s.title)"]) { $1 }
            let login = await Blocking.run { Result { try SFTP.startMaster(t, env: env) } }
            if case .failure(let e) = login {
                if !(e is CancellationError) { say(e.localizedDescription, true) }
                return
            }
            noteLook(t)   // the next look rides it, though no panel shows the server
            let cancel = CancelFlag()   // set by ⎋ there — and by its giving way, when the look is over anyway
            Picker.show(over: window, placeholder: "Looking at \(s.title)'s \(what)…", items: [], onDismiss: { cancel.cancel() })
            let title = s.title
            let result = await Blocking.run { Result { try read(t, title, env, cancel) } }
            guard !cancel.isCancelled else { return }
            switch result {
            case .failure(let e):
                Picker.dismiss()
                say(e.localizedDescription, true)
            case .success(let found): show(found, s, t)
            }
        }
    }

    /// The panel that says what runs on `t`'s server: one showing it, else the active one.
    private func panel(for t: SFTPTarget) -> PanelViewController { panels.first { $0.remote?.target.asUser == t.asUser } ?? active }

    /// A row whose name Kermo won't put into a command: its keys say so.
    private func notInCommands(_ name: String) -> @MainActor () -> Void {
        { [unowned self] in active.flash("“\(name)” has characters Kermo won't put into a command: nothing runs on it", error: true) }
    }

    /// The description, cut to fit next to the name.
    private static func detail(_ s: String) -> String { s.count > 40 ? s.prefix(39) + "…" : s }

    // MARK: Services

    /// Services… (⌘⇧P, a server's menu): on the server of the active panel or SSH tab, else picked (S1).
    func showServices() { onServer("Services of") { [unowned self] in showServices(on: $0) } }

    func showServices(on t: SFTPTarget) {
        look(at: t, "services", for: "Services", say: { [unowned self] in active.flash($0, error: $1) },
             { t, title, env, cancel in try Services.read(on: t.asUser, server: title, env: env, cancel: cancel) }) { [unowned self] units, s, t in
            guard !units.isEmpty else {
                Picker.dismiss()
                return active.flash("\(s.title): systemd lists no services there")
            }
            Picker.show(over: window, placeholder: (s.prod ? SavedServer.mark : "") + "\(s.title)'s services — ↩ status · ⌘L log · ⌘E edit unit · ⌘R restart",
                        items: units.map { serviceItem($0, on: t, of: s) },
                        rank: { item, q in Fuzzy.score(q, item.title + " " + item.subtitle + " " + item.detail) })
        }
    }

    /// "nginx" · "active · running" · its description (S2). ↩ its status, ⌘L its log as it goes, ⌘E its unit file,
    /// ⌘R a restart (S3) — status and log as the user, the restart as root; one with a name Kermo won't put into a
    /// command does nothing and says why.
    func serviceItem(_ u: ServiceUnit, on t: SFTPTarget, of s: SavedServer) -> Picker.Item {
        let state = u.active == u.sub ? u.active : "\(u.active) · \(u.sub)"
        guard u.safe else {
            let no = notInCommands(u.unit)
            return Picker.Item(title: u.name, subtitle: state, detail: Self.detail(u.description), edit: no,
                               keys: [Shortcut("cmd+l")!: no, Shortcut("cmd+r")!: no], run: no)
        }
        let log: @MainActor () -> Void = { Shell.run(Services.log(u), on: t.asUser, in: "/", follow: true, title: "\(s.title): \(u.name) log") }
        let restart: @MainActor () -> Void = { [unowned self] in
            let panel = panel(for: t)
            Task {
                await runThere(Services.restart(u), on: t.asRoot(), action: "restart", busy: "Restarting \(u.name) on \(s.title)…",
                               done: "Restarted \(u.name) on \(s.title)", ask: ("Restart \(u.name) on \(s.title)?", "Restart"), in: panel)
            }
        }
        return Picker.Item(title: u.name, subtitle: state, detail: Self.detail(u.description), edit: { [unowned self] in editUnit(u, on: t) },
                           keys: [Shortcut("cmd+l")!: log, Shortcut("cmd+r")!: restart]) {
            Shell.run(Services.status(u), on: t.asUser, in: "/", title: "\(s.title): \(u.name) status")
        }
    }

    /// ⌘E on a service: its unit file in the editor — as the panel is, root's or the user's — with what any server file
    /// gets there (history, a check and daemon-reload for /etc/systemd/system).
    func editUnit(_ u: ServiceUnit, on t: SFTPTarget) {
        let panel = panel(for: t), env = SSHAskpass.env
        Task {
            let r = await panel.busy("Looking for \(u.name)'s unit file…") { flag in try Services.unitFile(u, on: t.asUser, env: env, cancel: flag) }
            switch r {
            case .success(let path?): remoteOpen(.edit, t, path, in: panel)
            case .success(nil): panel.flash("\(u.name) has no unit file there: systemd made it up", error: true)
            case .failure(let e): if !(e is CancellationError) { showError(e) }
            }
        }
    }

    // MARK: Containers

    /// Containers… (⌘⇧P, a server's menu): on the server of the active panel or SSH tab, else picked (S1).
    func showContainers() { onServer("Containers of") { [unowned self] in showContainers(on: $0) } }

    func showContainers(on t: SFTPTarget) {
        look(at: t, "containers", for: "Containers", say: { [unowned self] in active.flash($0, error: $1) },
             { t, title, env, cancel in try Containers.read(on: t.asUser, server: title, env: env, cancel: cancel) }) { [unowned self] found, s, t in
            guard !found.containers.isEmpty else {
                Picker.dismiss()
                return active.flash("\(s.title): \(found.tool) has no containers there")
            }
            Picker.show(over: window, placeholder: (s.prod ? SavedServer.mark : "") + "\(s.title)'s containers — ↩ log · ⌘R restart · ⌘C copy name",
                        items: found.containers.map { containerItem($0, tool: found.tool, on: t, of: s) },
                        rank: { item, q in Fuzzy.score(q, item.title + " " + item.subtitle + " " + item.detail) })
        }
    }

    /// "web" · "running · Up 3 hours" · its image (S5). ↩ its log as it goes, ⌘R a restart — as the user, whose
    /// docker or podman it is — ⌘C its name.
    func containerItem(_ c: ContainerInfo, tool: String, on t: SFTPTarget, of s: SavedServer, pasteboard: NSPasteboard = .general) -> Picker.Item {
        let copy: @MainActor () -> Void = { [unowned self] in
            pasteboard.clearContents()
            pasteboard.setString(c.name, forType: .string)
            active.flash("Copied “\(c.name)”")
        }
        let state = c.status.isEmpty ? c.state : "\(c.state) · \(c.status)"
        guard c.safe else {
            let no = notInCommands(c.name)
            return Picker.Item(title: c.name, subtitle: state, detail: Self.detail(c.image), keys: [Shortcut("cmd+r")!: no, Shortcut("cmd+c")!: copy], run: no)
        }
        let restart: @MainActor () -> Void = { [unowned self] in
            let panel = panel(for: t)
            Task {
                await runThere(Containers.restart(c, tool: tool), on: t.asUser, action: "restart", busy: "Restarting \(c.name) on \(s.title)…",
                               done: "Restarted \(c.name) on \(s.title)", ask: ("Restart \(c.name) on \(s.title)?", "Restart"), in: panel)
            }
        }
        return Picker.Item(title: c.name, subtitle: state, detail: Self.detail(c.image), keys: [Shortcut("cmd+r")!: restart, Shortcut("cmd+c")!: copy]) {
            Shell.run(Containers.logs(c, tool: tool), on: t.asUser, in: "/", follow: true, title: "\(s.title): \(c.name) log")
        }
    }
}
