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
            showList("services", on: t, of: s, keys: "↩ status · ⌘L log · ⌘R restart · ⌃↩ menu", items: units.map { serviceItem($0, on: t, of: s) })
        }
    }

    /// A list of what a server runs, which stays open while its rows change: the highlighted row green, and it opens
    /// again where it was left (what was typed and highlighted) — after a look at a status or a log, say.
    private func showList(_ what: String, on t: SFTPTarget, of s: SavedServer, keys: String, items: [Picker.Item]) {
        let key = what + " " + ServerRow.key(t.asUser), kept = servicesKept[key]
        Picker.show(over: window, placeholder: (s.prod ? SavedServer.mark : "") + "\(s.title)'s \(what) — " + keys, items: items,
                    rank: { item, q in Fuzzy.score(q, item.title + " " + item.subtitle + " " + item.detail) },
                    query: kept?.query ?? "", select: kept?.id, highlight: .systemGreen,
                    onClose: { [unowned self] q, id in servicesKept[key] = (q, id) })
    }

    /// One service of one server: what a row, its run and its result are found by.
    static func serviceID(_ u: ServiceUnit, on t: SFTPTarget) -> String { ServerRow.key(t.asUser) + " " + u.unit }

    /// What a service's keys and its menu do — one list, so both act alike on the same row. `why`: it can't now.
    /// `group`: the menu puts a line between groups.
    struct ServiceAction {
        let title: String, key: Shortcut?, group: Int, closes: Bool, why: String?
        let run: @MainActor () -> Void
    }

    /// Looks — status, its log as it goes, its unit file, its state again, its name copied — then what changes it,
    /// as root: start, stop (asked first), restart, reload; at boot; a failed state reset. While one change runs the
    /// others wait; what doesn't apply (a reload without ExecReload, enable on an enabled or static unit, a reset of
    /// one not failed) says why. One with a name Kermo won't put into a command only has its name copied.
    func serviceActions(_ u: ServiceUnit, on t: SFTPTarget, of s: SavedServer, pasteboard: NSPasteboard = .general) -> [ServiceAction] {
        let no = u.safe ? nil : "“\(u.unit)” has characters Kermo won't put into a command: nothing runs on it"
        let busy = serviceRuns[Self.serviceID(u, on: t)].map(Self.waitFor(u.name))
        func changing(_ c: Services.Change, _ title: String? = nil, key: Shortcut? = nil, group: Int, why: String? = nil) -> ServiceAction {
            ServiceAction(title: title ?? c.title, key: key, group: group, closes: false, why: no ?? busy ?? why) { [unowned self] in change(c, u, on: t, of: s) }
        }
        let file = u.unitFile ?? ""
        let fixed = ["static": "static (its unit has no [Install] section)", "masked": "masked", "generated": "made by a generator",
                     "transient": "transient"][file].map { "\(u.name) is \($0): nothing to change at boot" }
        return [
            ServiceAction(title: "Status", key: Shortcut("return"), group: 0, closes: true, why: no) {
                Shell.run(Services.status(u), on: t.asUser, in: "/", title: "\(s.title): \(u.name) status")
            },
            ServiceAction(title: "Live Logs", key: Shortcut("cmd+l"), group: 0, closes: true, why: no) {
                Shell.run(Services.log(u), on: t.asUser, in: "/", follow: true, title: "\(s.title): \(u.name) log")
            },
            ServiceAction(title: "Edit Unit File…", key: Shortcut("cmd+e"), group: 0, closes: true, why: no) { [unowned self] in editUnit(u, on: t) },
            ServiceAction(title: "Refresh Status", key: nil, group: 0, closes: false, why: no) { [unowned self] in refresh(u, on: t, of: s) },
            ServiceAction(title: "Copy Service Name", key: Shortcut("cmd+c"), group: 0, closes: false, why: nil) { [unowned self] in
                pasteboard.clearContents()
                pasteboard.setString(u.unit, forType: .string)
                active.flash("Copied “\(u.unit)”")
            },
            changing(.start, group: 1),
            changing(.stop, "Stop…", group: 1, why: u.active == "inactive" ? "\(u.name) isn't running" : nil),
            changing(.restart, key: Shortcut("cmd+r"), group: 1),
            changing(.reload, group: 1, why: u.canReload == false ? "\(u.name) can't reload: it has no ExecReload (Restart is the other way)" : nil),
            changing(.enable, group: 2, why: fixed ?? (file.hasPrefix("enabled") ? "\(u.name) is enabled at boot already" : nil)),
            changing(.disable, group: 2, why: fixed ?? (file == "disabled" ? "\(u.name) is disabled at boot already" : nil)),
            changing(.resetFailed, group: 3, why: u.failed ? nil : "\(u.name) isn't failed"),
        ]
    }

    /// Why another change of `name` can't start: `run` runs on it, or ("") one is being asked about.
    static func waitFor(_ name: String) -> (String) -> String {
        { run in run.isEmpty ? "\(name): one change at a time — another is being asked" : "\(name) is \(run.lowercased()) wait for it" }
    }

    /// The action called `title` as it is now (a run may have started or ended since the row was made).
    private func perform(_ title: String, _ actions: () -> [ServiceAction]) {
        guard let a = actions().first(where: { $0.title == title }) else { return }
        if let why = a.why { return active.flash(why, error: true) }
        guard a.closes, Picker.current != nil else { return a.run() }
        Picker.dismiss()
        DispatchQueue.main.async { a.run() }   // after focus is back on the main window
    }

    /// The menu of a service's row, a line between looks and changes; what can't run now is greyed, saying why.
    private func serviceMenu(_ actions: @escaping () -> [ServiceAction]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var group: Int?
        for a in actions() {
            if let group, group != a.group { menu.addItem(.separator()) }
            group = a.group
            let item = MenuAction.item(a.title) { [unowned self] in perform(a.title, actions) }
            // Not ↩: in an open menu it would run Status, not the highlighted item.
            if let key = a.key, !key.flags.isEmpty { (item.keyEquivalent, item.keyEquivalentModifierMask) = (key.menuKey, key.flags) }
            item.isEnabled = a.why == nil
            item.toolTip = a.why
            menu.addItem(item)
        }
        return menu
    }

    /// "nginx" · "active · running" (failed in red, whatever the highlight) · its description (S2); "Restarting…"
    /// and a spinner while that runs. ↩ ⌘L ⌘E ⌘R ⌘C and its menu (⌃↩) as `serviceActions` has them; a change and a
    /// copy keep the list open.
    func serviceItem(_ u: ServiceUnit, on t: SFTPTarget, of s: SavedServer, pasteboard: NSPasteboard = .general) -> Picker.Item {
        let running = serviceRuns[Self.serviceID(u, on: t)].flatMap { $0.isEmpty ? nil : $0 }   // "": being asked, not running yet
        let actions = { [unowned self] in serviceActions(u, on: t, of: s, pasteboard: pasteboard) }
        func act(_ title: String) -> @MainActor () -> Void { { [unowned self] in perform(title, actions) } }
        var item = Picker.Item(title: u.name, subtitle: running ?? (u.active == u.sub ? u.active : "\(u.active) · \(u.sub)"),
                               detail: Self.detail(u.description), edit: act("Edit Unit File…"),
                               keys: [Shortcut("cmd+l")!: act("Live Logs"), Shortcut("cmd+r")!: act("Restart"), Shortcut("cmd+c")!: act("Copy Service Name")],
                               run: act("Status"))
        item.id = Self.serviceID(u, on: t)
        item.subtitleColor = running == nil && u.failed ? .systemRed : nil
        item.busy = running != nil
        item.keepsOpen = [Shortcut("cmd+r")!, Shortcut("cmd+c")!]
        item.menu = { [unowned self] in serviceMenu(actions) }
        return item
    }

    /// `c` of `u` as root, the list staying open (`changeRow`). Stop asks first, everywhere, saying what it means.
    func change(_ c: Services.Change, _ u: ServiceUnit, on t: SFTPTarget, of s: SavedServer) {
        let root = t.asRoot(), user = t.asUser, read = Self.unitState
        let what = switch c {
        case .enable: "Enable \(u.name) at boot"
        case .disable: "Disable \(u.name) at boot"
        case .resetFailed: "Reset the failed state of \(u.name)"
        default: "\(c.title) \(u.name)"
        }
        let stop = c != .stop ? nil : (message: "Stop \(u.name) on \(s.title)?", button: "Stop",
            info: (SavedServer.isProd(root) ? SavedServer.prodNote([root]) : "") + "It stays stopped until it's started again"
                + (u.unitFile?.hasPrefix("enabled") == true ? " or the server starts: it's enabled at boot." : ".")
                + " Services that need it may stop with it.")
        serviceRuns[Self.serviceID(u, on: t)] = ""   // being asked: no other change of it meanwhile, though its row doesn't say it runs yet
        Task {
            await changeRow(id: Self.serviceID(u, on: t), command: c.command(u), on: root, action: c.rawValue, busy: c.busy, name: u.name, server: s.title,
                            ask: (what + " on \(s.title)?", c.title), first: stop,
                            read: { env, flag in try read(u, user, c.waits, env, flag) },
                            row: { state in self.serviceItem(state.map(u.applying) ?? u, on: t, of: s) },
                            say: { how, state, error, time in Services.outcome(c, of: u.name, on: s.title, at: time, ran: how, state: state, stateError: error) })
        }
    }

    /// Refresh Status: its state read again, as the user, into its row and the line under the list; nothing runs on it.
    private func refresh(_ u: ServiceUnit, on t: SFTPTarget, of s: SavedServer) {
        let id = Self.serviceID(u, on: t), panel = panel(for: t), read = Self.unitState, user = t.asUser, env = SSHAskpass.env
        Task {
            let r = await panel.busy("Looking at \(u.name) on \(s.title)…") { flag in try read(u, user, false, env, flag) }
            guard let shown = Picker.current, shown.has(id) else { return }   // closed: the next look reads it anyway
            let time = Self.clock.string(from: Date())
            switch r {
            case .success(let state):
                shown.update(serviceItem(u.applying(state), on: t, of: s))
                shown.say(Self.result((.notRun, "↻ \(u.name) on \(s.title) at \(time) — \(state.said)" + (state.unitFile.map { ", \($0) at boot" } ?? ""))))
            case .failure(is CancellationError): break
            case .failure(let e): shown.say(Self.result((.failed, "✕ \(u.name): its state couldn't be read on \(s.title) at \(time): \(e.localizedDescription)")))
            }
        }
    }

    /// A change of one row — a service, a container — the list staying open; `serviceRuns[id]` is "" already (being
    /// asked), so a second press waits. Once it's asked (the lock, `first`'s
    /// question or else the production one, the sudo password: all over the list) its row says it runs and its other
    /// changes wait; then its state is read again, as the user (`read`), into its row (`row`, nil: as it was), and
    /// the line under the list says how it went (`say`) until the next one. A list closed meanwhile: the status line
    /// says it, or a failure's alert, as `runThere`'s.
    private func changeRow<S: Sendable>(id: String, command: String, on target: SFTPTarget, action: String, busy: String, name: String, server: String,
                                        ask: (message: String, button: String), first: (message: String, button: String, info: String)? = nil,
                                        read: @escaping @Sendable ([String: String], CancelFlag) throws -> S,
                                        row: @escaping @MainActor (S?) -> Picker.Item,
                                        say: @escaping @MainActor (Services.Ran, S?, String?, String) -> (outcome: Services.Outcome, line: String)) async {
        let panel = panel(for: target), list = Picker.current.flatMap { $0.has(id) ? $0 : nil }
        let go: () async -> (RanThere, Result<S, Error>?) = { [unowned self] in
            if let first, await choose(first.message, info: first.info, [first.button, "Cancel"], default: 1, on: list?.window) != 0 {   // ↩ = Cancel
                return (.notRun("cancelled"), nil)
            }
            let ran = await ranThere(command, on: target, action: action, busy: busy.dropLast() + " \(name) on \(server)…",
                                     ask: first == nil ? ask : nil, askOn: list?.window, in: panel) { [unowned self] in
                serviceRuns[id] = busy
                Picker.current.flatMap { $0.has(id) ? $0 : nil }?.update(row(nil))
            }
            if case .notRun = ran { return (ran, nil) }
            let env = SSHAskpass.env
            return (ran, await panel.busy("Looking at \(name) on \(server)…") { flag in try read(env, flag) })
        }
        let (ran, read) = if let list { await list.holding(go) } else { await go() }
        let (how, output) = Self.how(ran)
        var state: S?, stateError: String?
        switch read {
        case .success(let now)?: state = now
        case .failure(let e)?: stateError = e is CancellationError ? "stopped" : e.localizedDescription
        case nil: break
        }
        serviceRuns[id] = nil
        let said = say(how, state, stateError, Self.clock.string(from: Date()))
        guard let shown = Picker.current, shown.has(id) else {   // closed (or another list): as runThere says it
            if case .passed = how { return panel.flash(said.line.replacingOccurrences(of: "✓ ", with: ""), error: said.outcome != .ok) }
            if case .notRun = how { return }
            _ = await sayRan(ran, command, on: target, done: said.line, in: panel)
            return
        }
        shown.update(row(state))
        let full = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var show: (@MainActor () -> Void)?
        if !full.isEmpty {
            show = { [unowned self, weak shown] in
                guard let shown else { return }
                Task { await shown.holding { _ = await choose("“\(command)” on \(server)", info: String(full.suffix(4000)), ["OK"], on: shown.window) } }
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

    /// Tests: in place of the server's `systemctl show` (`wait`: a second first) and `docker inspect`.
    nonisolated(unsafe) static var unitState: @Sendable (ServiceUnit, SFTPTarget, Bool, [String: String], CancelFlag) throws -> Services.UnitState = {
        try Services.state($0, on: $1, wait: $2, env: $3, cancel: $4)
    }
    nonisolated(unsafe) static var containerState: @Sendable (ContainerInfo, String, SFTPTarget, [String: String], CancelFlag) throws -> String = {
        try Containers.state($0, tool: $1, on: $2, env: $3, cancel: $4)
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
            showList("containers", on: t, of: s, keys: "↩ log · ⌘R restart · ⌘C copy name",
                     items: found.containers.map { containerItem($0, tool: found.tool, on: t, of: s) })
        }
    }

    /// "web" · "running · Up 3 hours" · its image (S5). ↩ its log as it goes; ⌘R a restart — as the user, whose
    /// docker or podman it is — with the list staying open, as a service's (`changeRow`); ⌘C its name.
    func containerItem(_ c: ContainerInfo, tool: String, on t: SFTPTarget, of s: SavedServer, pasteboard: NSPasteboard = .general) -> Picker.Item {
        let id = ServerRow.key(t.asUser) + " container " + c.name, running = serviceRuns[id].flatMap { $0.isEmpty ? nil : $0 }
        let copy: @MainActor () -> Void = { [unowned self] in
            pasteboard.clearContents()
            pasteboard.setString(c.name, forType: .string)
            active.flash("Copied “\(c.name)”")
        }
        let state = running ?? (c.status.isEmpty ? c.state : "\(c.state) · \(c.status)")
        var item: Picker.Item
        if !c.safe {
            let no = notInCommands(c.name)
            item = Picker.Item(title: c.name, subtitle: state, detail: Self.detail(c.image), keys: [Shortcut("cmd+r")!: no, Shortcut("cmd+c")!: copy], run: no)
        } else {
            let user = t.asUser, read = Self.containerState
            let restart: @MainActor () -> Void = { [unowned self] in
                if let busy = serviceRuns[id] { return active.flash(Self.waitFor(c.name)(busy), error: true) }
                serviceRuns[id] = ""   // as a service's
                Task {
                    await changeRow(id: id, command: Containers.restart(c, tool: tool), on: user, action: "restart", busy: "Restarting…", name: c.name,
                                    server: s.title, ask: ("Restart \(c.name) on \(s.title)?", "Restart"),
                                    read: { env, flag in try read(c, tool, user, env, flag) },
                                    row: { now in
                                        var c = c
                                        if let now { (c.state, c.status) = (now, "") }
                                        return self.containerItem(c, tool: tool, on: t, of: s, pasteboard: pasteboard)
                                    },
                                    say: { how, now, error, time in
                                        Services.line("restart", "restarted", of: c.name, "the container", on: s.title, at: time, ran: how,
                                                      now: now, healthy: now.map { $0 == "running" }, stateError: error)
                                    })
                }
            }
            item = Picker.Item(title: c.name, subtitle: state, detail: Self.detail(c.image), keys: [Shortcut("cmd+r")!: restart, Shortcut("cmd+c")!: copy]) {
                Shell.run(Containers.logs(c, tool: tool), on: t.asUser, in: "/", follow: true, title: "\(s.title): \(c.name) log")
            }
        }
        item.id = id
        item.busy = running != nil
        item.keepsOpen = [Shortcut("cmd+r")!, Shortcut("cmd+c")!]
        return item
    }
}
