import AppKit
import DFMCore

// Services… and Containers… (README "Services and containers"): what a server runs, in a Picker; keys on a row act on it.
extension AppDelegate {
    /// The server of the active panel or SSH tab — root if the panel is — else a Picker of servers to choose from.
    /// `what`: "Forward a port of", "Services of".
    func onServer(_ what: String, _ then: @escaping @MainActor (SFTPTarget) -> Void) {
        if let here = terminalActive ? terminal.current?.target : active.remote?.target ?? active.list?.source.target { return then(here) }
        let items = serverChoices().map { c in
            Picker.Item(title: c.title, subtitle: c.saved.map { ServerRow.address($0.target) } ?? "~/.ssh/config", badges: (c.saved?.chips ?? []).map(\.image),
                        verb: "Choose") { then(c.target) }
        }
        let scope = what.hasSuffix(" of") ? String(what.dropLast(3)) : what   // "Services of" → "Services ›"
        Picker.show(over: window, placeholder: "Server or user@host", scope: (scope, []), items: items, freeText: { q in
            guard case let .sftp(t, _)? = ServerAddress.parse(q) else { return [] }
            return [Picker.Item(title: "\(what) “\(q)”", verb: "Choose") { then(t) }]
        }, freeTextLast: true)   // "web db" picks the server, not a host named so
    }

    /// A locked server stayed locked: said plainly, not as a failure.
    struct Locked: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// What a look does first: a locked server asks, then the login, if one is due — the saved server's (its key and
    /// connection time, whatever was typed). Its connection is kept for its ControlPersist (`noteLook`).
    func lookLogin(at t: SFTPTarget, _ what: String, for command: String) async -> Result<(SavedServer, SFTPTarget, [String: String]), Error> {
        let s = savedServer(at: t) ?? SavedServer(target: t)
        let t = s.target.asRoot(t.sudo)
        if await !ServerLock.authorize(s.target, "look at the \(what) of") { return .failure(Locked(message: "\(s.title) stays locked")) }
        let env = SSHAskpass.env.merging(["DFM_ASKPASS_WHY": "For “\(command)” on \(s.title)"]) { $1 }
        let login = await Blocking.run { Result { try SFTP.startMaster(t, env: env) } }
        if case .failure(let e) = login { return .failure(e) }
        noteLook(t)   // the next look rides it, though no panel shows the server
        return .success((s, t, env))
    }

    /// A list's read in a panel (`ListSource.read`): a look as a Picker's, then `read` off the main thread.
    func lookRead<T: Sendable>(at t: SFTPTarget, _ what: String, for command: String, cancel: CancelFlag,
                               _ read: @escaping @Sendable (SFTPTarget, String, [String: String], CancelFlag) throws -> T) async throws -> T {
        let (s, t, env) = try await lookLogin(at: t, what, for: command).get()
        if cancel.isCancelled { throw CancellationError() }
        let title = s.title
        return try await Blocking.run { try read(t, title, env, cancel) }
    }

    /// The panel that says what runs on `t`'s server: one showing it — its files or a list of it — else the active one.
    private func panel(for t: SFTPTarget) -> PanelViewController {
        panels.first { $0.remote?.target.asUser == t.asUser } ?? panels.first { $0.list?.source.target.asUser == t.asUser } ?? active
    }

    /// A row whose name Kermo won't put into a command: its keys say so.
    private func notInCommands(_ name: String) -> @MainActor () -> Void {
        { [unowned self] in active.flash("“\(name)” has characters Kermo won't put into a command: nothing runs on it", error: true) }
    }

    /// The description, cut to fit next to the name.
    private static func detail(_ s: String) -> String { s.count > 40 ? s.prefix(39) + "…" : s }

    // MARK: Services

    /// Services… (⌘⇧P, a server's menu): on the server of the active panel or SSH tab, else picked (S1).
    func showServices() { onServer("Services of") { [unowned self] in showServices(on: $0) } }

    func showServices(on t: SFTPTarget) { showInSearch(ServiceList(self, savedServer(at: t) ?? SavedServer(target: t), t)) }

    /// A list of what a server runs in the search, on the server's overview — ⌫ goes there, ⇥ into a row's actions:
    /// read as it opens (a locked server asks first, then the login, "Looking at services…", ⎋ stops it), it stays open
    /// while its rows change, and opens again where it was left (what was typed and highlighted) — after a look at a
    /// status or a log, say. ⌘↩: the same rows in the other panel.
    func showInSearch(_ source: ListSource) {
        let key = source.title.lowercased() + " " + ServerRow.key(source.target.asUser), kept = servicesKept[key]
        let s = savedServer(at: source.target) ?? SavedServer(target: source.target.asUser)
        let p = palette()
        p.go(into: PlaceSource(self, s, source.target.asUser), select: "place " + source.title)
        p.go(into: source, query: kept?.query ?? "", select: kept?.id) { [unowned self] q, id in servicesKept[key] = (q, id) }
    }

    /// The units' rows, the line about them, what's said when there are none: a Picker's and a panel's.
    func serviceContent(_ units: [ServiceUnit], on t: SFTPTarget, of s: SavedServer) -> ListContent {
        let failed = units.filter(\.failed).count
        noteCount("services", on: t, units.count, problems: failed)
        return ListContent(rows: units.map { serviceItem($0, on: t, of: s) },
                           header: "\(units.count) unit\(units.count == 1 ? "" : "s")" + (failed > 0 ? " · \(failed) failed" : ""),
                           empty: "systemd lists no services there")
    }

    /// One service of one server: what a row, its run and its result are found by.
    static func serviceID(_ u: ServiceUnit, on t: SFTPTarget) -> String { ServerRow.key(t.asUser) + " " + u.unit }

    /// What a service's keys and its menu do, in a Picker and in a panel (`ListAction`).
    typealias ServiceAction = ListAction

    /// Looks — status, its log as it goes, its unit file, its state again, its name copied — then what changes it,
    /// as root: start, stop (asked first), restart, reload; at boot; a failed state reset. While one change runs the
    /// others wait; what doesn't apply (a reload without ExecReload, enable on an enabled or static unit, a reset of
    /// one not failed) says why. One with a name Kermo won't put into a command only has its name copied.
    func serviceActions(_ u: ServiceUnit, on t: SFTPTarget, of s: SavedServer, pasteboard: NSPasteboard = .general) -> [ServiceAction] {
        let no = u.safe ? nil : "“\(u.unit)” has characters Kermo won't put into a command: nothing runs on it"
        let busy = serviceRuns[Self.serviceID(u, on: t)].map(Self.waitFor(u.name))
        // As root, the command shown in a question for several. Stop asks everywhere and is on F8 in a panel — not red:
        // a Start undoes it.
        func changing(_ c: Services.Change, _ title: String? = nil, key: Shortcut? = nil, group: Int, why: String? = nil) -> ServiceAction {
            ServiceAction(title: title ?? c.title, key: key, group: group, closes: false, why: no ?? busy ?? why, listKey: c == .stop ? Shortcut("f8") : nil,
                          command: c.command(u), runsOn: t.asRoot(), asks: c == .stop ? .always : .prod,
                          note: c == .stop ? "They stay stopped until they're started again, or the server starts where enabled at boot. Services that need them may stop with them." : nil) { [unowned self] asked in
                change(c, u, on: t, of: s, asked: asked)
            }
        }
        let file = u.unitFile ?? ""
        let fixed = ["static": "static (its unit has no [Install] section)", "masked": "masked", "generated": "made by a generator",
                     "transient": "transient"][file].map { "\(u.name) is \($0): nothing to change at boot" }
        return [
            ServiceAction(title: "Status", key: Shortcut("return"), group: 0, closes: true, why: no) { _ in
                Shell.run(Services.status(u), on: t.asUser, in: "/", title: "\(u.name) status")   // where: the subtitle
                return nil
            },
            ServiceAction(title: "Live Logs", key: Shortcut("cmd+l"), group: 0, closes: true, why: no,
                          follow: (Services.log(u), t.asUser)) { _ in   // in a panel: next door
                Shell.run(Services.log(u), on: t.asUser, in: "/", follow: true, title: "\(u.name) log")
                return nil
            },
            ServiceAction(title: "Edit Unit File…", key: Shortcut("cmd+e"), group: 0, closes: true, why: no) { [unowned self] _ in editUnit(u, on: t); return nil },
            ServiceAction(title: "Refresh Status", key: nil, group: 0, closes: false, why: no) { [unowned self] _ in refresh(u, on: t, of: s) },
            ServiceAction(title: "Copy Service Name", key: Shortcut("cmd+c"), group: 0, closes: false, why: nil) { [unowned self] _ in
                pasteboard.clearContents()
                pasteboard.setString(u.unit, forType: .string)
                active.flash("Copied “\(u.unit)”")
                return nil
            },
            changing(.start, group: 1, why: u.active == "active" ? "\(u.name) is \(u.sub == "running" ? "running" : "active") already" : nil),
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
    func perform(_ title: String, _ actions: () -> [ServiceAction]) {
        guard let a = actions().first(where: { $0.title == title }) else { return }
        if let why = a.why { return active.flash(why, error: true) }
        guard a.closes, Picker.current != nil else { _ = a.run(false); return }
        Picker.dismiss()
        DispatchQueue.main.async { _ = a.run(false) }   // after focus is back on the main window
    }

    /// The menu of a service's row (a Tools row's too), a line between looks and changes; what can't run now is
    /// greyed, saying why; red what can't be undone.
    func serviceMenu(_ actions: @escaping () -> [ServiceAction]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var group: Int?
        for a in actions() {
            if let group, group != a.group { menu.addItem(.separator()) }
            group = a.group
            let item = MenuAction.item(a.title) { [unowned self] in perform(a.title, actions) }
            // Not ↩: in an open menu it would run Status, not the highlighted item.
            if let key = a.key, !key.flags.isEmpty { (item.keyEquivalent, item.keyEquivalentModifierMask) = (key.menuKey, key.flags) }
            if a.dangerous { item.attributedTitle = NSAttributedString(string: a.title, attributes: [.foregroundColor: Palette.fail]) }
            item.isEnabled = a.why == nil
            item.toolTip = a.why
            menu.addItem(item)
        }
        return menu
    }

    /// "nginx" · "active · running" (failed in red, whatever the highlight) · its description (S2); "Restarting…"
    /// and a spinner while that runs. ↩ ⌘L ⌘E ⌘C ⌘R and its menu (⌃↩) as `serviceActions` has them, named so on the
    /// action bar; a change and a copy keep the list open.
    func serviceItem(_ u: ServiceUnit, on t: SFTPTarget, of s: SavedServer, pasteboard: NSPasteboard = .general) -> Picker.Item {
        let running = serviceRuns[Self.serviceID(u, on: t)].flatMap { $0.isEmpty ? nil : $0 }   // "": being asked, not running yet
        let actions: @MainActor () -> [ServiceAction] = { [unowned self] in serviceActions(u, on: t, of: s, pasteboard: pasteboard) }
        func act(_ title: String) -> @MainActor () -> Void { { [unowned self] in perform(title, actions) } }
        let all = actions().compactMap { a in a.key.flatMap { $0 == Shortcut("return") ? nil : ($0, a) } }
        let first = { (a: ServiceAction) in a.title == "Live Logs" || a.group > 0 }   // the bar's: the log and the changes, then ⌘E ⌘C
        let keyed = all.filter { first($0.1) } + all.filter { !first($0.1) }
        var item = Picker.Item(title: u.name, subtitle: running ?? (u.active == u.sub ? u.active : "\(u.active) · \(u.sub)"),
                               detail: Self.detail(u.description),
                               actions: keyed.map { key, a in .init(key: key, label: a.title.replacingOccurrences(of: "…", with: ""), keepsOpen: !a.closes, run: act(a.title)) },
                               verb: "Status", run: act("Status"))
        item.id = Self.serviceID(u, on: t)
        item.subtitleColor = running == nil && u.failed ? Palette.fail : nil
        item.badges = running == nil && u.failed ? [StateMark.failed.image("failed", size: 9)] : []   // a shape, not only red
        item.busy = running != nil
        item.menu = { [unowned self] in serviceMenu(actions) }
        item.cells = ["boot": u.unitFile ?? "", "description": u.description]   // a panel's Boot and whole Description
        item.state = u.failed ? .failed : u.active == "active" ? .on : ["activating", "deactivating", "reloading"].contains(u.active) ? .attention : .off
        item.listActions = actions
        return item
    }

    /// `c` of `u` as root, the list staying open (`changeRow`). Stop asks first, everywhere, saying what it means.
    /// `asked`: a question for several rows was asked already — none here. What to wait for: its run.
    @discardableResult
    func change(_ c: Services.Change, _ u: ServiceUnit, on t: SFTPTarget, of s: SavedServer, asked: Bool = false) -> Task<Void, Never> {
        let root = t.asRoot(), user = t.asUser, read = Self.unitState
        let what = switch c {
        case .enable: "Enable \(u.name) at boot"
        case .disable: "Disable \(u.name) at boot"
        case .resetFailed: "Reset the failed state of \(u.name)"
        default: "\(c.title) \(u.name)"
        }
        var stop: Confirm?
        if c == .stop, !asked {   // ↩ = Cancel everywhere: it says what stopping means
            var q = Confirm("Stop \(u.name) on \(s.title)?", on: root, action: "Stop")
            (q.runs, q.command, q.returnCancels) = (Self.runs(on: root), c.command(u), true)
            q.note = "It stays stopped until it's started again" + (u.unitFile?.hasPrefix("enabled") == true ? " or the server starts: it's enabled at boot." : ".")
                + " Services that need it may stop with it."
            stop = q
        }
        serviceRuns[Self.serviceID(u, on: t)] = ""   // being asked: no other change of it meanwhile, though its row doesn't say it runs yet
        return Task {
            await changeRow(id: Self.serviceID(u, on: t), command: c.command(u), on: root, action: c.rawValue, busy: c.busy, name: u.name, server: s.title,
                            ask: asked ? nil : (what + " on \(s.title)?", c.title), first: stop,
                            read: { env, flag in try read(u, user, c.waits, env, flag) },
                            row: { state in self.serviceItem(state.map(u.applying) ?? u, on: t, of: s) },
                            say: { how, state, error, time in Services.outcome(c, of: u.name, on: s.title, at: time, ran: how, state: state, stateError: error) })
        }
    }

    /// Refresh Status: its state read again, as the user, into its row and the line under the list; nothing runs on it.
    private func refresh(_ u: ServiceUnit, on t: SFTPTarget, of s: SavedServer) -> Task<Void, Never> {
        let id = Self.serviceID(u, on: t), panel = panel(for: t), read = Self.unitState, user = t.asUser, env = SSHAskpass.env
        return Task {
            let r = await panel.busy("Looking at \(u.name) on \(s.title)…") { flag in try read(u, user, false, env, flag) }
            let time = Self.clock.string(from: Date())
            for shown in rowLists(id) {   // none: closed — the next look reads it anyway
                switch r {
                case .success(let state):
                    shown.update(serviceItem(u.applying(state), on: t, of: s))
                    shown.said(Self.result((.notRun, "\(u.name) on \(s.title) at \(time) — \(state.said)" + (state.unitFile.map { ", \($0) at boot" } ?? "")), mark: .refresh),
                               about: id, failed: false, output: nil)
                case .failure(is CancellationError): break
                case .failure(let e):
                    shown.said(Self.result((.failed, "\(u.name): its state couldn't be read on \(s.title) at \(time): \(e.localizedDescription)")), about: id, failed: true, output: nil)
                }
            }
        }
    }

    /// A service's or a container's change in the loop of one (`changeRow`): the lock, `first`'s question or else the
    /// production one (`ask`, nil: asked for several already), the sudo password, the run (`ranThere`); then its state
    /// read again, as the user (`read`), into its row (`row`, nil: as it was).
    private func changeRow<S: Sendable>(id: String, command: String, on target: SFTPTarget, action: String, busy: String, name: String, server: String,
                                        ask: (message: String, button: String)?, first: Confirm? = nil,
                                        read: @escaping @Sendable ([String: String], CancelFlag) throws -> S,
                                        row: @escaping @MainActor (S?) -> Picker.Item,
                                        say: @escaping @MainActor (Services.Ran, S?, String?, String) -> (outcome: Services.Outcome, line: String)) async {
        await changeRow(id: id, shown: { command }, on: target, busy: busy, name: name, server: server, run: { [unowned self] window, panel, running in
            if let first, await confirm(first, on: window) != 0 { return .notRun("cancelled") }
            return await ranThere(command, on: target, action: action, busy: busy.dropLast() + " \(name) on \(server)…",
                                  ask: first == nil ? ask : nil, askOn: window, in: panel, running: running)
        }, read: read, show: { $0.update(row($1)) }, say: say)
    }

    /// A change of one row — a service, a container, a Tools action — the list staying open; `serviceRuns[id]` is ""
    /// already (being asked), so a second press waits. `run` asks (over the list: `window`) and runs it; once it's
    /// asked (`running`) the row says it runs (`busy`) and its other changes wait. Then what it changed is read again
    /// (`read`; nil: nothing to read) into each list showing the row (`show`, nil: as it was), and the line under the
    /// list says how it went (`say`) until the next one, a failure's output a click away. The list is a Picker's or a
    /// panel's (`rowLists`), both if both show it. One closed meanwhile: the status line says it, or a failure's alert,
    /// as `runThere`'s. `shown`: the command, as those name it (once it ran: a form may have filled it in).
    func changeRow<S: Sendable>(id: String, shown: @escaping @MainActor () -> String, on target: SFTPTarget, busy: String, name: String, server: String,
                                run: @escaping @MainActor (_ window: NSWindow?, PanelViewController, _ running: @escaping @MainActor () -> Void) async -> RanThere,
                                read: (@Sendable ([String: String], CancelFlag) throws -> S)?,
                                show: @escaping @MainActor (any RowList, S?) -> Void,
                                say: @escaping @MainActor (Services.Ran, S?, String?, String) -> (outcome: Services.Outcome, line: String)) async {
        let panel = panel(for: target), list = rowLists(id).first
        let go: () async -> (RanThere, Result<S, Error>?) = { [unowned self] in
            let ran = await run(list?.sheetWindow, panel) { [unowned self] in
                serviceRuns[id] = busy
                rowLists(id).forEach { show($0, nil) }
            }
            if case .notRun = ran { return (ran, nil) }
            guard let read else { return (ran, nil) }
            let env = SSHAskpass.env
            return (ran, await panel.busy("Looking at \(name) on \(server)…") { flag in try read(env, flag) })
        }
        let (ran, read) = if let list { await list.holding(go) } else { await go() }
        let (how, output) = Self.how(ran), command = shown()
        var state: S?, stateError: String?
        switch read {
        case .success(let now)?: state = now
        case .failure(let e)?: stateError = e is CancellationError ? "stopped" : e.localizedDescription
        case nil: break
        }
        serviceRuns[id] = nil
        let said = say(how, state, stateError, Self.clock.string(from: Date()))
        let lists = rowLists(id)
        if said.line.isEmpty { return lists.forEach { show($0, state) } }   // nothing to say (a `silent` Tools action that went well)
        guard !lists.isEmpty else {   // closed (or another list): as runThere says it
            if case .passed = how { return panel.flash(said.line, error: said.outcome != .ok) }
            if case .notRun = how { return }
            _ = await sayRan(ran, command, on: target, done: said.line, in: panel)
            return
        }
        let full = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for list in lists {
            show(list, state)
            var output: (@MainActor () -> Void)?
            if !full.isEmpty {
                output = { [unowned self, weak list] in
                    guard let list else { return }
                    Task { await list.holding { _ = await choose("“\(command)” on \(server)", info: String(full.suffix(4000)), ["OK"], on: list.sheetWindow) } }
                }
            }
            list.said(Self.result(said), about: id, failed: said.outcome == .failed || said.outcome == .warning, output: output)
        }
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

    /// The line after its mark: done, done but look, failed — or `mark` (Refresh Status's).
    private static func result(_ said: (outcome: Services.Outcome, line: String), mark: Symbol? = nil) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12)
        let marks: [Services.Outcome: (Symbol, NSColor, String)] = [.ok: (.check, Palette.ok, "done"), .warning: (.warn, Palette.warn, "look"),
                                                                    .failed: (.failed, Palette.fail, "failed")]
        let text = NSMutableAttributedString()
        if let (symbol, color, word) = marks[said.outcome] ?? mark.map({ ($0, Palette.secondary, "") }) {
            text.append(symbol.text(color, font: font, label: word))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: said.line, attributes: [.foregroundColor: NSColor.labelColor, .font: font]))
        return text
    }

    /// Whether `t`'s server has a connection up now (its ssh master): Quick View and a place's counts ride it, never
    /// log in. Tests: a stand-in.
    nonisolated(unsafe) static var connected: @MainActor (SFTPTarget) -> Bool = { t in SFTP.masterTargets.contains { ServerRow.key($0) == ServerRow.key(t) } }

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

    func showContainers(on t: SFTPTarget) { showInSearch(ContainerList(self, savedServer(at: t) ?? SavedServer(target: t), t)) }

    /// The containers' rows, the line about them, what's said when there are none: a Picker's and a panel's.
    func containerContent(_ found: (tool: String, containers: [ContainerInfo]), on t: SFTPTarget, of s: SavedServer) -> ListContent {
        let n = found.containers.count, running = found.containers.filter { $0.state == "running" }.count
        noteCount("containers", on: t, n, problems: n - running)
        return ListContent(rows: found.containers.map { containerItem($0, tool: found.tool, on: t, of: s) },
                           header: "\(n) container\(n == 1 ? "" : "s") · \(running) running", empty: "\(found.tool) has no containers there")
    }

    /// "web" · "running · Up 3 hours" · its image (S5). ↩ its log as it goes; ⌘R a restart — as the user, whose
    /// docker or podman it is — with the list staying open, as a service's (`changeRow`); ⌘C its name. In a panel: a
    /// failed (exited with an error, dead) one first, then one stopped or starting, as needing a look.
    func containerItem(_ c: ContainerInfo, tool: String, on t: SFTPTarget, of s: SavedServer, pasteboard: NSPasteboard = .general) -> Picker.Item {
        let id = ServerRow.key(t.asUser) + " container " + c.name, running = serviceRuns[id].flatMap { $0.isEmpty ? nil : $0 }
        let copy: @MainActor () -> Void = { [unowned self] in
            pasteboard.clearContents()
            pasteboard.setString(c.name, forType: .string)
            active.flash("Copied “\(c.name)”")
        }
        let logs: @MainActor () -> Void = { Shell.run(Containers.logs(c, tool: tool), on: t.asUser, in: "/", follow: true, title: "\(c.name) log") }
        let user = t.asUser, read = Self.containerState
        let restart: @MainActor (Bool) -> Task<Void, Never>? = { [unowned self] asked in
            if let busy = serviceRuns[id] { active.flash(Self.waitFor(c.name)(busy), error: true); return nil }
            serviceRuns[id] = ""   // as a service's
            return Task {
                await changeRow(id: id, command: Containers.restart(c, tool: tool), on: user, action: "restart", busy: "Restarting…", name: c.name,
                                server: s.title, ask: asked ? nil : ("Restart \(c.name) on \(s.title)?", "Restart"),
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
        let state = running ?? (c.status.isEmpty ? c.state : "\(c.state) · \(c.status)")
        var item: Picker.Item
        if !c.safe {
            let no = notInCommands(c.name)
            item = Picker.Item(title: c.name, subtitle: state, detail: Self.detail(c.image),
                               actions: [.init(key: Shortcut("cmd+c")!, label: "Copy Name", keepsOpen: true, run: copy), .init(key: Shortcut("cmd+r")!, label: "", run: no)],
                               verb: "Live Logs", run: no)
        } else {
            item = Picker.Item(title: c.name, subtitle: state, detail: Self.detail(c.image),
                               actions: [.init(key: Shortcut("cmd+r")!, label: "Restart", keepsOpen: true, run: { _ = restart(false) }),
                                         .init(key: Shortcut("cmd+c")!, label: "Copy Name", keepsOpen: true, run: copy)], verb: "Live Logs", run: logs)
        }
        item.id = id
        item.busy = running != nil
        item.cells = ["image": c.image]
        let exit = c.status.hasPrefix("Exited (") ? Int(c.status.dropFirst(8).prefix { $0 != ")" }) : nil
        item.state = c.state == "running" ? .on : c.state == "dead" || (exit ?? 0) != 0 ? .failed : .attention
        item.listActions = { [unowned self] in
            let no = c.safe ? nil : "“\(c.name)” has characters Kermo won't put into a command: nothing runs on it"
            return [ListAction(title: "Live Logs", key: Shortcut("return"), group: 0, closes: true, why: no,
                               follow: (Containers.logs(c, tool: tool), t.asUser)) { _ in logs(); return nil },
                    ListAction(title: "Copy Name", key: Shortcut("cmd+c"), group: 0, closes: false, why: nil) { _ in copy(); return nil },
                    ListAction(title: "Restart", key: Shortcut("cmd+r"), group: 1, closes: false, why: no ?? serviceRuns[id].map(Self.waitFor(c.name)),
                               command: Containers.restart(c, tool: tool), runsOn: user, asks: .prod) { restart($0) }]
        }
        return item
    }
}

/// A server's services as a list in a panel (`ListSource`): the rows Services… shows, read again as it reads them.
@MainActor
final class ServiceList: ListSource {
    unowned let app: AppDelegate
    let server: SavedServer
    let target: SFTPTarget
    let title = "Services"
    let columns = [ListColumn(title: "Unit", field: .title, width: 170), ListColumn(title: "State", field: .subtitle, width: 130, state: true),
                   ListColumn(title: "Boot", field: .cell("boot"), width: 70), ListColumn(title: "Description", field: .cell("description"), width: 160)]
    private(set) var content: ListContent?
    private var units: [ServiceUnit] = []

    init(_ app: AppDelegate, _ server: SavedServer, _ target: SFTPTarget, units: [ServiceUnit]? = nil) {
        (self.app, self.server, self.target) = (app, server, target)
        if let units { (self.units, content) = (units, app.serviceContent(units, on: target, of: server)) }
    }

    func read(_ cancel: CancelFlag) async throws -> ListContent {
        units = try await app.lookRead(at: target, "services", for: "Services", cancel: cancel) { t, title, env, cancel in
            try Services.read(on: t.asUser, server: title, env: env, cancel: cancel)
        }
        content = app.serviceContent(units, on: target, of: server)
        return content!
    }

    /// Its `systemctl status`, as the user, over the connection the list holds — none up: it says so, logs in for nothing.
    func peek(_ row: Picker.Item) -> ListPeek? {
        guard let u = units.first(where: { AppDelegate.serviceID($0, on: target) == row.id }) else { return nil }
        guard AppDelegate.connected(target.asUser) else { return .rows([("Status", "Not connected — Refresh reads the list again")]) }
        let t = target.asUser, command = Services.status(u), env = SSHAskpass.env
        return .text { flag in
            var out = Data()
            let (_, errors) = try SSHCommand.run(t, command, env: env, cancel: flag) { out += $0 }   // exit 3: inactive — it's said
            return String(decoding: out, as: UTF8.self) + errors
        }
    }
}

/// A server's containers as a list in a panel: Containers…'s rows.
@MainActor
final class ContainerList: ListSource {
    unowned let app: AppDelegate
    let server: SavedServer
    let target: SFTPTarget
    let title = "Containers"
    let columns = [ListColumn(title: "Name", field: .title, width: 170), ListColumn(title: "State", field: .subtitle, width: 170, state: true),
                   ListColumn(title: "Image", field: .cell("image"), width: 160)]
    private(set) var content: ListContent?

    init(_ app: AppDelegate, _ server: SavedServer, _ target: SFTPTarget, found: (tool: String, containers: [ContainerInfo])? = nil) {
        (self.app, self.server, self.target) = (app, server, target)
        content = found.map { app.containerContent($0, on: target, of: server) }
    }

    func read(_ cancel: CancelFlag) async throws -> ListContent {
        let found = try await app.lookRead(at: target, "containers", for: "Containers", cancel: cancel) { t, title, env, cancel in
            try Containers.read(on: t.asUser, server: title, env: env, cancel: cancel)
        }
        content = app.containerContent(found, on: target, of: server)
        return content!
    }

    /// Its state and image, as the list read them; its log is ↩.
    func peek(_ row: Picker.Item) -> ListPeek? {
        .rows([("Name", row.title), ("State", row.subtitle), ("Image", row.cells["image"] ?? row.detail), ("Log", "↩ Live Logs")])
    }
}

// The server as a place (review 1, Р7): its files, what it runs, its ports and tunnels, its file history — rows that ↩
// goes into, in a panel. Opening it asks the server nothing; what it counts is what its lists last read.
extension AppDelegate {
    /// What a place lists, provider by provider, in this order: its folders, what it runs and its ports and tunnels,
    /// its file history. Tools add theirs as one more provider (tests: one of theirs).
    static var placeProviders: [@MainActor (AppDelegate, PlaceSource) -> [Picker.Item]] = [
        { $0.placeFolders($1) }, { $0.placeLists($1) }, { $0.placeTools($1) }, { $0.placeHistory($1) },
    ]

    /// Server ▸ Overview: the active panel's server's place (or its SSH tab's), else picked.
    func showOverview() { onServer("Overview of") { [unowned self] in showPlace($0, in: active) } }

    /// `t`'s place in `panel`, the cursor on `select` (a row's title: the list ⌫ came back from). Nothing is sent;
    /// a row that goes to the server asks for Touch ID first on a locked one, as any look.
    func showPlace(_ t: SFTPTarget, in panel: PanelViewController, select: String? = nil) {
        if terminal != nil { showPanels() }   // not at launch: a restored place comes before the terminal
        let s = savedServer(at: t) ?? SavedServer(target: t.asUser)
        let last = (defaults.dictionary(forKey: "placeLastList")?[ServerRow.key(t.asUser)] as? String)   // the list opened there last
        panel.showList(PlaceSource(self, s, t.asUser), select: (select ?? last).map { "place " + $0 })
    }

    /// How many a list of `t`'s counted when it was last read, and how many of them are in trouble (failed, exited).
    func noteCount(_ what: String, on t: SFTPTarget, _ n: Int, problems: Int = 0) { listCounts[ServerRow.key(t.asUser) + " " + what] = (n, problems) }

    /// A place's row: ↩ goes in (in this panel), its menu has Open in Other Panel too. `into`: a list it is — the panel
    /// shows it, the palette's ⇥ goes into it; else `open` says what it opens.
    func placeRow(_ title: String, _ p: PlaceSource, state: String = "", about: String, mark: StateMark? = nil,
                  into: (@MainActor () -> ListSource)? = nil, open: (@MainActor (PanelViewController) -> Void)? = nil) -> Picker.Item {
        let open = open ?? { $0.showList(into!()) }
        var it = Picker.Item(title: title, subtitle: state, detail: about) { [unowned self] in open(active) }
        it.id = "place " + title
        it.state = mark
        it.into = into
        it.listActions = { [unowned self] in   // they take the palette away: what they open is in a panel
            [ListAction(title: "Open", key: Shortcut("return"), group: 0, closes: true, why: nil) { _ in open(self.active); return nil },
             ListAction(title: "Open in Other Panel", key: Shortcut("cmd+return"), group: 0, closes: true, why: nil) { _ in
                 let o = self.other
                 open(o)
                 self.window.makeFirstResponder(o.table)
                 return nil
             }]
        }
        return it
    }

    /// Files (its start folder), Home, `/`: its files in that panel — a locked server asks first, as connecting does.
    func placeFolders(_ p: PlaceSource) -> [Picker.Item] {
        let s = p.server, row = ServerRow(target: p.target, saved: savedServer(at: p.target), title: s.title)
        func files(_ dir: String?) -> @MainActor (PanelViewController) -> Void {
            { [unowned self] panel in
                remember(row.address)
                openSFTP(row.target, dir: dir, title: row.title, panel: panel)   // nil: the login folder
            }
        }
        return (s.startDir.map { [placeRow("Files", p, about: "\($0) — start folder", open: files($0))] } ?? [])
            + [placeRow("Home", p, about: "the login folder", open: files(nil)), placeRow("/", p, about: "the root folder", open: files("/"))]
    }

    /// Services, Containers, Ports — each a list, read as it opens — and Tunnels, this Mac's. Their counts: as its lists
    /// last read them, while a connection is up; else "—" till the row is opened.
    func placeLists(_ p: PlaceSource) -> [Picker.Item] {
        let s = p.server, t = p.target, up = Self.connected(t)
        func count(_ what: String) -> (n: Int, problems: Int)? { up ? listCounts[ServerRow.key(t) + " " + what] : nil }
        let units = count("services"), boxes = count("containers"), ports = count("ports")
        let on = tunnels.listening(s).map(\.title) + tunnels.temporaries(server: ServerRow.key(s.target)).filter { $0.error == nil }.map(\.tunnel.title)
        return [
            placeRow("Services", p, state: units.map { $0.problems > 0 ? "\($0.problems) failed" : "" } ?? "—",
                     about: units.map { "\($0.n) unit\($0.n == 1 ? "" : "s")" } ?? "what systemd runs", mark: units.flatMap { $0.problems > 0 ? .failed : nil },
                     into: { [unowned self] in ServiceList(self, s, t) }),
            placeRow("Containers", p, state: boxes.map { $0.problems > 0 ? "\($0.problems) not running" : "" } ?? "—",
                     about: boxes.map { "\($0.n) container\($0.n == 1 ? "" : "s")" } ?? "docker or podman", mark: boxes.flatMap { $0.problems > 0 ? .attention : nil },
                     into: { [unowned self] in ContainerList(self, s, t) }),
            placeRow("Ports", p, state: ports == nil ? "—" : "", about: ports.map { "\($0.n) listening" } ?? "what it listens on",
                     into: { [unowned self] in PortList(self, s) }),
            placeRow("Tunnels", p, state: on.isEmpty ? "none on" : "\(on.count) on", about: on.isEmpty ? "to its ports, from this Mac" : on.joined(separator: ", "),
                     mark: on.isEmpty ? nil : .on, into: { [unowned self] in TunnelList(self, s) }),
        ]
    }

    /// File History: the versions of its files kept on this Mac, in that panel.
    func placeHistory(_ p: PlaceSource) -> [Picker.Item] {
        [placeRow("File History", p, about: "versions of its files kept on this Mac", open: { [unowned self] panel in
            window.makeFirstResponder(panel.table)
            showFileHistory(p.target)
        })]
    }
}

/// A server's place in a panel (`AppDelegate.showPlace`): its rows from `placeProviders`, read again on Refresh —
/// from what's known here, never from the server.
@MainActor
final class PlaceSource: ListSource {
    unowned let app: AppDelegate
    let server: SavedServer
    let title = "Overview"
    let keepsOrder = true
    let columns = [ListColumn(title: "Name", field: .title, width: 140), ListColumn(title: "State", field: .subtitle, width: 120, state: true),
                   ListColumn(title: "About", field: .detail, width: 200)]
    /// The server as it was reached (its alias, its key), as its user: what its rows connect to.
    let target: SFTPTarget
    var content: ListContent? { ListContent(rows: AppDelegate.placeProviders.flatMap { $0(app, self) }) }

    init(_ app: AppDelegate, _ server: SavedServer, _ target: SFTPTarget) { (self.app, self.server, self.target) = (app, server, target) }

    func read(_ cancel: CancelFlag) async throws -> ListContent { content! }
}
