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
            if await !ServerLock.authorize(s.target, "look at the \(what) of") {
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
            let key = ServerRow.key(t.asUser), kept = servicesKept[key]
            Picker.show(over: window, placeholder: (s.prod ? SavedServer.mark : "") + "\(s.title)'s services — ↩ status · ⌘L log · ⌘E edit unit · ⌘R restart · ⌃↩ more",
                        items: units.map { serviceItem($0, on: t, of: s) },
                        rank: { item, q in Fuzzy.score(q, item.title + " " + item.subtitle + " " + item.detail) },
                        query: kept?.query ?? "", select: kept?.id, highlight: .systemGreen,
                        onClose: { [unowned self] q, id in servicesKept[key] = (q, id) })   // back to it after a look at status or log
        }
    }

    /// One service of one server: what a row, its run and its result are found by.
    static func serviceID(_ u: ServiceUnit, on t: SFTPTarget) -> String { ServerRow.key(t.asUser) + " " + u.unit }

    /// What a service's keys and its menu do — one list, so both act alike on the same row. `why`: it can't now.
    struct ServiceAction {
        let title: String, key: Shortcut?, closes: Bool, why: String?
        let run: @MainActor () -> Void
    }

    /// Status, its log as it goes and its unit file, then what changes it — as root, a start and a restart waiting
    /// while one runs on it. One with a name Kermo won't put into a command does nothing and says why.
    func serviceActions(_ u: ServiceUnit, on t: SFTPTarget, of s: SavedServer) -> [ServiceAction] {
        let no = u.safe ? nil : "“\(u.unit)” has characters Kermo won't put into a command: nothing runs on it"
        let busy = serviceRuns[Self.serviceID(u, on: t)].map { "\(u.name) is \($0.lowercased()) wait for it" }
        return [
            ServiceAction(title: "Status", key: Shortcut("return"), closes: true, why: no) {
                Shell.run(Services.status(u), on: t.asUser, in: "/", title: "\(s.title): \(u.name) status")
            },
            ServiceAction(title: "Live Logs", key: Shortcut("cmd+l"), closes: true, why: no) {
                Shell.run(Services.log(u), on: t.asUser, in: "/", follow: true, title: "\(s.title): \(u.name) log")
            },
            ServiceAction(title: "Edit Unit File…", key: Shortcut("cmd+e"), closes: true, why: no) { [unowned self] in editUnit(u, on: t) },
            ServiceAction(title: "Start", key: nil, closes: false, why: no ?? busy) { [unowned self] in change(.start, u, on: t, of: s) },
            ServiceAction(title: "Restart", key: Shortcut("cmd+r"), closes: false, why: no ?? busy) { [unowned self] in change(.restart, u, on: t, of: s) },
        ]
    }

    /// The action called `title` as it is now (a run may have started or ended since the row was made).
    private func perform(_ title: String, _ u: ServiceUnit, on t: SFTPTarget, of s: SavedServer) {
        guard let a = serviceActions(u, on: t, of: s).first(where: { $0.title == title }) else { return }
        if let why = a.why { return active.flash(why, error: true) }
        guard a.closes, Picker.current != nil else { return a.run() }
        Picker.dismiss()
        DispatchQueue.main.async { a.run() }   // after focus is back on the main window
    }

    /// The menu of a service's row: looks, then changes, each with its key; what can't run now is greyed, saying why.
    private func serviceMenu(_ u: ServiceUnit, on t: SFTPTarget, of s: SavedServer) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for a in serviceActions(u, on: t, of: s) {
            if a.title == "Start" { menu.addItem(.separator()) }
            let item = MenuAction.item(a.title) { [unowned self] in perform(a.title, u, on: t, of: s) }
            // Not ↩: in an open menu it would run Status, not the highlighted item.
            if let key = a.key, !key.flags.isEmpty { (item.keyEquivalent, item.keyEquivalentModifierMask) = (key.menuKey, key.flags) }
            item.isEnabled = a.why == nil
            item.toolTip = a.why
            menu.addItem(item)
        }
        return menu
    }

    /// "nginx" · "active · running" (failed in red, whatever the highlight) · its description (S2); "Restarting…"
    /// and a spinner while that runs. ↩ ⌘L ⌘E ⌘R and its menu (⌃↩) as `serviceActions` has them; a start or a restart
    /// keeps the list open.
    func serviceItem(_ u: ServiceUnit, on t: SFTPTarget, of s: SavedServer) -> Picker.Item {
        let running = serviceRuns[Self.serviceID(u, on: t)]
        func act(_ title: String) -> @MainActor () -> Void { { [unowned self] in perform(title, u, on: t, of: s) } }
        var item = Picker.Item(title: u.name, subtitle: running ?? (u.active == u.sub ? u.active : "\(u.active) · \(u.sub)"),
                               detail: Self.detail(u.description), edit: act("Edit Unit File…"),
                               keys: [Shortcut("cmd+l")!: act("Live Logs"), Shortcut("cmd+r")!: act("Restart")], run: act("Status"))
        item.id = Self.serviceID(u, on: t)
        item.subtitleColor = running == nil && u.failed ? .systemRed : nil
        item.busy = running != nil
        item.keepsOpen = [Shortcut("cmd+r")!]
        item.menu = { [unowned self] in serviceMenu(u, on: t, of: s) }
        return item
    }

    /// A start or a restart of `u` as root, the list staying open: its row says it runs, the lock, the production
    /// question and the sudo password ask over the list, then its state is read again — as the user — and the line
    /// under the list says how it went until the next one. A list closed meanwhile: the status line says it, or a
    /// failure's alert, as `runThere`'s.
    func change(_ c: Services.Change, _ u: ServiceUnit, on t: SFTPTarget, of s: SavedServer) {
        let id = Self.serviceID(u, on: t), panel = panel(for: t), list = Picker.current.flatMap { $0.has(id) ? $0 : nil }
        serviceRuns[id] = c.busy
        list?.update(serviceItem(u, on: t, of: s))
        Task { await changed(c, u, on: t, of: s, from: list, in: panel) }
    }

    private func changed(_ c: Services.Change, _ u: ServiceUnit, on t: SFTPTarget, of s: SavedServer, from list: Picker?,
                         in panel: PanelViewController) async {
        let id = Self.serviceID(u, on: t), command = c == .start ? Services.start(u) : Services.restart(u)
        let busy = String(c.busy.dropLast()) + " \(u.name) on \(s.title)…"
        let go: () async -> (RanThere, Result<Services.UnitState, Error>?) = { [unowned self] in
            let ran = await ranThere(command, on: t.asRoot(), action: c.rawValue, busy: busy,
                                     ask: ("\(c.title) \(u.name) on \(s.title)?", c.title), askOn: list?.window, in: panel)
            if case .notRun = ran { return (ran, nil) }
            let env = SSHAskpass.env, read = Self.unitState, user = t.asUser
            return (ran, await panel.busy("Looking at \(u.name) on \(s.title)…") { flag in try read(u, user, env, flag) })
        }
        let (ran, read) = if let list { await list.holding(go) } else { await go() }
        let (how, output) = Self.how(ran)
        var state: Services.UnitState?, stateError: String?
        switch read {
        case .success(let now)?: state = now
        case .failure(let e)?: stateError = e is CancellationError ? "stopped" : e.localizedDescription
        case nil: break
        }
        serviceRuns[id] = nil
        var now = u
        if let state { (now.active, now.sub) = (state.active, state.sub) }
        let said = Services.outcome(c, of: u.name, on: s.title, at: Self.clock.string(from: Date()), ran: how, state: state, stateError: stateError)
        guard let shown = Picker.current, shown.has(id) else {   // closed (or another list): as runThere says it
            if case .passed = how { return panel.flash(said.line.replacingOccurrences(of: "✓ ", with: ""), error: said.outcome != .ok) }
            if case .notRun = how { return }
            _ = await sayRan(ran, command, on: t.asRoot(), done: said.line, in: panel)
            return
        }
        shown.update(serviceItem(now, on: t, of: s))
        let full = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var show: (@MainActor () -> Void)?
        if !full.isEmpty {
            show = { [unowned self, weak shown] in
                guard let shown else { return }
                Task { await shown.holding { _ = await choose("“\(command)” on \(s.title)", info: String(full.suffix(4000)), ["OK"], on: shown.window) } }
            }
        }
        shown.say(Self.result(said), output: show)
    }

    /// `ranThere`'s outcome as `Services.outcome` takes it, and a failure's output.
    private static func how(_ ran: RanThere) -> (Services.Ran, String) {
        switch ran {
        case .notRun(let why): (.notRun(why), "")
        case .ran(.success(.passed)): (.passed, "")
        case .ran(.success(.failed(let status, let out))): (.failed(exit: status, output: out), out)
        case .ran(.success(.noProgram(let why))): (.couldNotRun(why), "")
        case .ran(.success(let other)): (.couldNotRun("\(other)"), "")   // a root target: never needsRoot
        case .ran(.failure(is CancellationError)): (.unknown("⎋"), "")
        case .ran(.failure(let e)): (.couldNotRun(e.localizedDescription), "")
        }
    }

    /// The line, its mark (✓ ⚠ ✕) in green, orange or red.
    private static func result(_ said: (outcome: Services.Outcome, line: String)) -> NSAttributedString {
        let text = NSMutableAttributedString(string: said.line, attributes: [.foregroundColor: NSColor.labelColor])
        let mark: [Services.Outcome: NSColor] = [.ok: .systemGreen, .warning: .systemOrange, .failed: .systemRed]
        if let color = mark[said.outcome] { text.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: 1)) }
        return text
    }

    /// Tests: in place of the server's `systemctl show`.
    nonisolated(unsafe) static var unitState: @Sendable (ServiceUnit, SFTPTarget, [String: String], CancelFlag) throws -> Services.UnitState = {
        try Services.state($0, on: $1, env: $2, cancel: $3)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

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
