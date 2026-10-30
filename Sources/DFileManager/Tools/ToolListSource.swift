import AppKit
import DFMCore

/// A tool's list on a server (protocol §6.2) — in a Picker (Tools ▸) and in a panel (its place's row, ⌘↩) alike: the
/// rows, the line above them, the row's keys and menu, its actions' questions and how they went. (Not `ToolList`: that's
/// the preset's `list`.)
@MainActor
final class ToolListSource: ListSource {
    unowned let app: AppDelegate
    let tool: LoadedTool
    let server: SavedServer
    /// As its user: a tool says itself when it runs as root.
    let target: SFTPTarget
    private(set) var content: ListContent?

    init(_ app: AppDelegate, _ tool: LoadedTool, _ server: SavedServer, _ target: SFTPTarget) {
        (self.app, self.tool, self.server, self.target) = (app, tool, server, target.asUser)
    }

    var preset: ToolPreset { tool.preset }
    var title: String { preset.title }
    private var key: String { ServerRow.key(target) + " " + preset.id }
    /// A tool's action with no row is said about the list (as its one-command run is: `AppDelegate.openTool`).
    var listID: String? { ServerRow.key(target) + " tool:\(preset.id)" }

    /// `columns` (§6.2), else the row's title, its state and its detail; a launcher's: the action, what it runs, its key.
    var columns: [ListColumn] {
        if preset.list == nil {
            return [ListColumn(title: "Action", field: .title, width: 170), ListColumn(title: "Runs", field: .subtitle, width: 330), ListColumn(title: "Key", field: .detail, width: 60)]
        }
        guard let cs = preset.list?.view.columns else {
            return [ListColumn(title: "Name", field: .title, width: 170), ListColumn(title: "State", field: .subtitle, width: 170, state: true),
                    ListColumn(title: "Detail", field: .detail, width: 160)]
        }
        return cs.map { c in
            let (field, format) = c.field
            var (title, width) = (field.prefix(1).uppercased() + field.dropFirst(), 120.0)
            if case .object(_, let t, let w) = c { (title, width) = (t ?? title, w ?? width) }
            return ListColumn(title: title, field: .cell(field), width: CGFloat(width), state: format == "state")
        }
    }

    // MARK: Reading it

    /// A read: the rows, how many there were, the line above them, the vars a command found, what the version says
    /// (nil: not asked; nil inside: nothing to warn about).
    struct Read: Sendable {
        var rows: [ToolRow]
        var total: Int
        var header: String?
        var vars: [String: String]?
        var version: String??
        /// The row `key` names now, as read (`verify`).
        func current(_ key: String) -> ToolRecord? { rows.first { $0.key == key }?.record }
    }

    /// A list's read that gave no rows to show: why, and what the server said (Show Output).
    struct Failed: LocalizedError, ShowsOutput {
        let message: String
        let output: String
        var errorDescription: String? { message }
    }

    /// What reads the list, off the main thread: the tool, the names its templates have there.
    struct Lister: Sendable {
        let tool: LoadedTool
        let scope: ToolTemplate.Scope
        let target: SFTPTarget
        let server: String
        let facts: ToolFacts?
        let findVars: Bool
        /// The program's version is known already this session: not asked again.
        let versionKnown: Bool

        /// The vars' commands first if they're due, the list, then (`header`) its header line (up to 200 characters)
        /// and what it warns about: rows past `limit`, a server clock off by over a minute, a version outside `tested`
        /// (asked once a session). The list, the header and the version go in one round trip (§3.2 rule 9) where they
        /// can share one (`ToolPayload.parts`); a launcher reads only its header.
        func read(_ env: [String: String], _ cancel: CancelFlag, header: Bool = true) throws -> Read {
            let p = tool.preset, title = p.title
            var scope = scope, vars: [String: String]?
            if findVars, !p.varCommands.isEmpty {
                var found: [String: String] = [:]
                for (name, run) in p.varCommands {
                    let r = try ToolRunner.exec(run, of: tool, scope, on: target, timeout: run.timeout ?? 10, env: env, cancel: cancel).ran
                    if run.succeeded(r.status), let first = r.text.split(whereSeparator: \.isNewline).first { found[name] = String(first) }
                }
                vars = found
                scope.levels[scope.levels.count - 2] = p.varValues(saved: [:], found: found)
            }
            // The header and the version (once a session) say something above the rows.
            let extra = header ? [p.list?.view.header ?? p.header, versionKnown ? nil : p.version.map { ToolRun(command: .one($0.command)) }] : []
            var said = extra.map { _ in String?.none }
            func first(_ text: String) -> String? { text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(200)) } }
            func one(_ run: ToolRun) -> String? {
                guard let r = try? ToolRunner.exec(run, of: tool, scope, on: target, timeout: run.timeout ?? 10, env: env, cancel: cancel).ran,
                      r.stopped == nil, run.succeeded(r.status) else { return nil }
                return first(r.text)
            }
            guard let list = p.list else {   // a launcher: its actions are its rows
                for (i, run) in extra.enumerated() { said[i] = run.flatMap(one) }
                return note(Read(rows: [], total: 0, vars: vars), said: said, total: 0, skew: nil)
            }
            var r: ToolExec.Ran
            let together = [list.run] + extra.compactMap { $0 }
            if together.count > 1, let plain = try? ToolPayload.parts(together, in: p, scope: scope, scripts: tool.scripts, sudoProgram: ToolRunner.sudoProgram),
               let wrapped = try? ToolPayload.parts(together, in: p, scope: scope, scripts: tool.scripts, password: true, sudoProgram: ToolRunner.sudoProgram) {
                // One round trip (§3.2 rule 9): the list, then what goes above it.
                r = try ToolExec.run({ $0 ? wrapped : plain }, on: target, timeout: (list.run.timeout ?? 30) + 10 * Double(together.count - 1),
                                     cancel: cancel, env: env, command: ToolRunner.command)
                let parts = ToolPayload.parts(r.out, nonce: r.password == nil ? plain.nonce : wrapped.nonce)
                if let mine = parts.first { (r.out, r.status) = (mine.out, mine.status) }
                var k = 1
                for (i, run) in extra.enumerated() where run != nil {
                    if parts.indices.contains(k), run!.succeeded(parts[k].status) { said[i] = first(String(decoding: parts[k].out, as: UTF8.self)) }
                    k += 1
                }
            } else {
                r = try ToolRunner.exec(list.run, of: tool, scope, on: target, timeout: list.run.timeout ?? 30, env: env, cancel: cancel).ran
                for (i, run) in extra.enumerated() where r.stopped == nil && list.run.succeeded(r.status) { said[i] = run.flatMap(one) }
            }
            if let stopped = r.stopped { throw JobErrorMessage("\(title) on \(server): \(stopped)") }
            let output = [r.errors, r.text].filter { !$0.isEmpty }.joined(separator: "\n")
            guard list.run.succeeded(r.status) else {
                throw Failed(message: ToolExec.notHere(r, server: server, facts: facts)
                             ?? "\(title) on \(server): " + (r.errors.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(r.status)"), output: output)
            }
            let records = list.parse.records(r.out)
            guard records.matched else {
                throw Failed(message: "\(title) on \(server): the output didn't match — " + (records.unmatched.first { !$0.isEmpty } ?? ""), output: output)
            }
            let now = Date().addingTimeInterval(r.skew ?? 0)   // `ago` by the server's clock
            let read = Read(rows: records.rows.map { list.view.row($0, scope, now: now) }, total: records.total, vars: vars)
            return header ? note(read, said: said, total: records.rows.count, skew: r.skew) : read
        }

        /// The line above the rows: the header's first line, "shown N of M", a clock off by over a minute; and what the
        /// version says.
        private func note(_ read: Read, said: [String?], total shown: Int, skew: TimeInterval?) -> Read {
            var read = read, notes = [said.first ?? nil].compactMap { $0 }
            if read.total > shown { notes.append("shown \(shown) of \(read.total)") }
            if let skew, abs(skew) > 60 { notes.append("⚠ the server's clock is \(Int(abs(skew) / 60)) min \(skew > 0 ? "ahead" : "behind")") }
            if let v = tool.preset.version, !versionKnown, said.count > 1 {
                let found = said[1].flatMap(v.found)
                read.version = .some(found.flatMap { v.tested($0) == false ? "⚠ \(tool.preset.tool ?? tool.preset.title) \($0) is outside what this tool was tested with (\(v.tested ?? ""))" : nil })
            }
            read.header = notes.isEmpty ? nil : notes.joined(separator: " · ")
            return read
        }
    }

    func lister() -> Lister { Self.lister(app, tool, server, target) }

    /// What reads `tool`'s list on `target` now: an action's `verify` needs it whether its list still shows or not.
    static func lister(_ app: AppDelegate, _ tool: LoadedTool, _ server: SavedServer, _ target: SFTPTarget) -> Lister {
        let key = ServerRow.key(target.asUser) + " " + tool.preset.id
        return Lister(tool: tool, scope: app.tools.scope(tool.preset, on: server, target), target: target.asUser, server: server.title,
                      facts: app.tools.answer(target)?.answer.facts, findVars: app.tools.found[key] == nil, versionKnown: app.tools.versions[key] != nil)
    }

    /// As any look: a locked server asks first, then the login if one is due — to the server as it was reached (its
    /// place's) — then the list's runs. Its connection is kept for its ControlPersist (`noteLook`).
    func read(_ cancel: CancelFlag) async throws -> ListContent {
        if await !ServerLock.authorize(target, "look at the \(title.lowercased()) of") { throw AppDelegate.Locked(message: "\(server.title) stays locked") }
        let t = target, env = SSHAskpass.env.merging(["DFM_ASKPASS_WHY": "For “\(title)” on \(server.title)"]) { $1 }
        try await Blocking.run { try SFTP.startMaster(t, env: env) }
        app.noteLook(t)
        if cancel.isCancelled { throw CancellationError() }
        let lister = lister()
        return show(try await Blocking.run { try lister.read(env, cancel) })
    }

    /// A read's rows as items, the line above them, what an empty list says; the place counts them.
    func show(_ r: Read) -> ListContent {
        if let v = r.vars { app.tools.found[key] = v }
        if let v = r.version { app.tools.versions[key] = .some(v) }
        app.tools.counts[key] = r.total
        _ = app.tools.answer(target)   // connected now: what the server has, if not asked yet
        let scope = app.tools.scope(preset, on: server, target)
        let header = [r.header, app.tools.versions[key] ?? nil].compactMap { $0 }.joined(separator: " · ")
        let primary = preset.primary.flatMap { id in preset.toolActions?.first { $0.spec.id == id } }.map { $0.spec.title ?? $0.spec.id }
        let c = ListContent(rows: preset.list == nil ? launcherRows() : r.rows.map(item), header: header.isEmpty ? nil : header, empty: preset.list?.view.empty.map { ToolTemplate.text($0, scope) } ?? "Nothing here",
                            primary: primary.flatMap { title in listActions(nil).first { $0.title == title } },
                            actions: { [weak self] in self?.listActions(nil) ?? [] })
        content = c
        return c
    }

    // MARK: A row

    func rowID(_ key: String) -> String { ServerRow.key(target) + " tool:\(preset.id) " + key }

    /// ok ●, warn ○, bad ◆, off a grey dot (§6.2); busy is a spinner.
    static func mark(_ s: ToolRowState) -> StateMark? {
        switch s { case .ok: .on; case .warn: .attention; case .bad: .failed; case .off: .off; case .busy: nil }
    }

    /// A row as the Picker and the panel show it: its title, its state (or the action running on it, with a spinner),
    /// its detail; ↩ and the other keys as its actions have them, ⌃↩ its menu.
    func item(_ row: ToolRow) -> Picker.Item {
        let id = rowID(row.key), running = app.serviceRuns[id].flatMap { $0.isEmpty ? nil : $0 }
        // A Picker closes before an action that opens a window of its own runs (↩: Status in Full) — and this list may go
        // with it: what runs then holds the app, the tool and the server, never the list.
        let actions: @MainActor () -> [ListAction] = { [weak self] in self?.listActions(row) ?? [] }
        let enter = actions().first { $0.key == Shortcut("return") }, app = app
        var it = Picker.Item(title: row.title, subtitle: running ?? row.subtitle, detail: row.detail, verb: enter?.title ?? "Actions") { [weak self] in
            guard let enter else { return NSSound.beep() }
            let now = self?.listActions(row) ?? [enter]
            app.perform(enter.title, { now })
        }
        it.id = id
        it.keepsOpen = enter.map { !$0.closes } ?? true
        it.state = row.state.flatMap(Self.mark)
        it.busy = running != nil || row.state == .busy
        it.subtitleColor = running == nil && row.state == .bad ? Palette.fail : nil
        it.badges = running == nil && row.state == .bad ? [StateMark.failed.image("failed", size: 9)] : []   // a shape, not only red
        it.cells = Dictionary(row.cells.map { ($0.field, $0.text) }) { a, _ in a }
        it.listActions = actions
        it.menu = {
            let menu = app.serviceMenu(actions)
            menu.addItem(.separator())
            menu.addItem(MenuAction.item("Refresh") { Picker.current?.reread() })
            return menu
        }
        return it
    }

    /// A launcher's rows (§1.3): its actions, each one's ↩ running it — the others keep their keys; one that can't run
    /// here says why.
    private func launcherRows() -> [Picker.Item] {
        listActions(nil).filter { $0.group == 1 }.map { a in
            let actions: @MainActor () -> [ListAction] = { [weak self] in
                (self?.listActions(nil) ?? [a]).map { b in
                    var b = b
                    if b.group == 1 { b.key = b.title == a.title ? Shortcut("return") : b.key == Shortcut("return") ? nil : b.key }
                    return b
                }
            }
            let app = app
            var it = Picker.Item(title: a.title, subtitle: a.why ?? a.command ?? "", detail: a.key.flatMap { $0 == Shortcut("return") ? nil : $0.display } ?? "", verb: a.title) {
                app.perform(a.title, actions)
            }
            it.id = rowID(a.title)
            it.keepsOpen = !a.closes
            it.listActions = actions
            it.menu = { app.serviceMenu(actions) }
            return it
        }
    }

    /// The row's actions, then the tool's — those this server has: of same-key variants the first whose `requires`
    /// passed; one that passed nowhere grey, saying why, without its key (§10.4) — then Copy and the tool's file. No
    /// row: the tool's alone, and its file (the list's own, where no row is under the cursor).
    func listActions(_ row: ToolRow?) -> [ListAction] {
        let known = app.tools.answers[ServerRow.key(target)]?.answer, id = row.map { rowID($0.key) } ?? listID!
        func actions(_ all: [ToolAction]?, onRow: Bool, group: Int) -> [ListAction] {
            let all = (all ?? []).filter { ToolRunner.runs($0, of: preset) }
            let shown = known.map { $0.visible(all, of: preset) } ?? all.filter { $0.spec.requires == nil }
            var seen = Set<String>(), out: [ListAction] = []
            for a in all {
                let title = a.spec.title ?? a.spec.id
                guard !seen.contains(title), shown.contains(a) || !all.contains(where: { ($0.spec.title ?? $0.spec.id) == title && shown.contains($0) }) else { continue }
                seen.insert(title)
                out.append(action(a, row: row, onRow: onRow, id: id, group: group, keyed: shown.contains(a)))
            }
            return out
        }
        let path = tool.path
        let copy = row.map { row in
            let text = [row.title, row.subtitle, row.detail].filter { !$0.isEmpty }.joined(separator: " · ")
            return ListAction(title: "Copy", key: nil, group: 2, closes: false, why: nil) { [app] _ in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                app.active.flash("Copied “\(text)”")
                return nil
            }
        }
        return (row == nil ? [] : actions(preset.actions, onRow: true, group: 0)) + actions(preset.toolActions, onRow: false, group: 1) + [copy].compactMap { $0 } + [
            ListAction(title: "Show \((path as NSString).lastPathComponent)", key: nil, group: 2, closes: true, why: nil) { _ in
                Viewer.show(URL(fileURLWithPath: path))
                return nil
            },
        ]
    }

    /// One action as a list has it: its key (none where it can't run here), why it can't now, what its question says;
    /// a window's closes a Picker first. `multi`: it runs on marked rows, else only the cursor's (Q15).
    private func action(_ a: ToolAction, row: ToolRow?, onRow: Bool, id: String, group: Int, keyed: Bool) -> ListAction {
        let mac = (a.run.where ?? preset.where) == .mac, sudo = (a.run.sudo ?? preset.sudo ?? false) && !mac
        let scope = app.tools.scope(preset, on: server, target, rows: onRow ? row.map { [$0.record] } ?? [] : [])
        let why = keyed ? app.tools.why(a, of: tool, row: row, onRow: onRow, id: id, on: server, target)
            : app.tools.why(a, of: tool, row: row, onRow: onRow, id: id, on: server, target) ?? "\(a.spec.title ?? a.spec.id) doesn't run here"
        let asks: ListAction.Asks = a.spec.readonly == true ? .never : a.spec.dangerous == true || a.spec.confirm == true ? .always : .prod
        let own = a.spec.edit != nil || [.window, .follow, .terminal].contains(a.spec.output)   // a window, a tab or the editor of its own
        var it = ListAction(title: a.spec.title ?? a.spec.id, key: keyed ? a.spec.key.flatMap(Shortcut.init) : nil, group: group, closes: own,
                            why: why, command: a.spec.inputs == nil ? try? ToolPayload.of(a.run, in: preset, scope: scope, scripts: tool.scripts).willRun : nil,
                            runsOn: mac ? nil : target.asRoot(sudo), asks: asks, dangerous: a.spec.dangerous == true,
                            note: a.spec.message.map { ToolTemplate.text($0, scope) }, multi: a.spec.multi == true) { [weak self, app, tool, server, target] asked in
            app.tools.perform(a, of: tool, row: row, onRow: onRow, id: id, from: self, on: server, target, asked: asked)
        }
        // A log that asks nothing follows next door in a panel (⌘L's Quick View), the row under the cursor's — not where
        // sudo wants a password: that's asked off the main thread, so it opens a window of its own.
        if a.spec.output == .follow, a.spec.readonly == true, a.spec.inputs == nil, why == nil, !(sudo && ToolExec.wantsPassword(target)),
           let payload = try? ToolRunner.payloads(a.run, of: tool, scope).0 {
            let t = mac ? SFTPTarget.local() : target, cri = a.spec.strip == "cri", title = a.spec.title ?? a.spec.id
            it.followWindow = { OutputWindow.follow(payload, password: nil, on: t, title: "\(title) — " + (mac ? "this Mac" : SavedServer.name(for: t)), cri: cri, embedded: true) }
        }
        return it
    }
}
