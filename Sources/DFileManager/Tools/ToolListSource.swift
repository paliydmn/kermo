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

    /// `columns` (§6.2), else the row's title, its state and its detail.
    var columns: [ListColumn] {
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

    /// A read: the rows, how many there were, the line above them, the vars a command found.
    struct Read: Sendable {
        var rows: [ToolRow]
        var total: Int
        var header: String?
        var vars: [String: String]?
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

        /// The vars' commands first if they're due, the list, then (`header`) its header line (up to 200 characters)
        /// and what it warns about: rows past `limit`, a server clock off by over a minute, a version outside `tested`.
        /// ponytail: three round trips; one (§3.2 rule 9) would save two.
        func read(_ env: [String: String], _ cancel: CancelFlag, header: Bool = true) throws -> Read {
            let p = tool.preset, title = p.title
            guard let list = p.list else { throw JobErrorMessage("\(title) has no list") }
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
            let r = try ToolRunner.exec(list.run, of: tool, scope, on: target, timeout: list.run.timeout ?? 30, env: env, cancel: cancel).ran
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
            var read = Read(rows: records.rows.map { list.view.row($0, scope, now: now) }, total: records.total, vars: vars), notes: [String] = []
            guard header else { return read }
            func first(_ run: ToolRun) -> String? {
                guard let r = try? ToolRunner.exec(run, of: tool, scope, on: target, timeout: run.timeout ?? 10, env: env, cancel: cancel).ran,
                      r.stopped == nil, run.succeeded(r.status) else { return nil }
                return r.text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(200)) }
            }
            if let h = list.view.header ?? p.header, let line = first(h) { notes.append(line) }
            if records.total > records.rows.count { notes.append("shown \(records.rows.count) of \(records.total)") }
            if let skew = r.skew, abs(skew) > 60 { notes.append("⚠ the server's clock is \(Int(abs(skew) / 60)) min \(skew > 0 ? "ahead" : "behind")") }
            if let v = p.version, let out = first(ToolRun(command: .one(v.command))), let found = v.found(in: out), v.tested(found) == false {
                notes.append("⚠ \(p.tool ?? title) \(found) is outside what this tool was tested with (\(v.tested ?? ""))")
            }
            read.header = notes.isEmpty ? nil : notes.joined(separator: " · ")
            return read
        }
    }

    func lister() -> Lister {
        Lister(tool: tool, scope: app.tools.scope(preset, on: server, target), target: target, server: server.title,
               facts: app.tools.answer(target)?.answer.facts, findVars: app.tools.found[key] == nil)
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
        app.tools.counts[key] = r.total
        _ = app.tools.answer(target)   // connected now: what the server has, if not asked yet
        let scope = app.tools.scope(preset, on: server, target)
        let c = ListContent(rows: r.rows.map(item), header: r.header, empty: preset.list?.view.empty.map { ToolTemplate.text($0, scope) } ?? "Nothing here")
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
        let actions: @MainActor () -> [ListAction] = { [unowned self] in listActions(row) }
        let enter = actions().first { $0.key == Shortcut("return") }
        var it = Picker.Item(title: row.title, subtitle: running ?? row.subtitle, detail: row.detail, verb: enter?.title ?? "Actions") { [unowned self] in
            if let enter { app.perform(enter.title, actions) } else { NSSound.beep() }
        }
        it.id = id
        it.keepsOpen = enter == nil
        it.state = row.state.flatMap(Self.mark)
        it.busy = running != nil || row.state == .busy
        it.subtitleColor = running == nil && row.state == .bad ? Palette.fail : nil
        it.badges = running == nil && row.state == .bad ? [StateMark.failed.image("failed", size: 9)] : []   // a shape, not only red
        it.cells = Dictionary(row.cells.map { ($0.field, $0.text) }) { a, _ in a }
        it.listActions = actions
        it.menu = { [unowned self] in
            let menu = app.serviceMenu(actions)
            menu.addItem(.separator())
            menu.addItem(MenuAction.item("Refresh") { Picker.current?.reread() })
            return menu
        }
        return it
    }

    /// The row's actions, then the tool's — those this server has: of same-key variants the first whose `requires`
    /// passed; one that passed nowhere grey, saying why, without its key (§10.4) — then Copy and the tool's file.
    func listActions(_ row: ToolRow) -> [ListAction] {
        let known = app.tools.answers[ServerRow.key(target)]?.answer, id = rowID(row.key)
        func actions(_ all: [ToolAction]?, onRow: Bool, group: Int) -> [ListAction] {
            let all = (all ?? []).filter(ToolRunner.runs)
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
        let text = [row.title, row.subtitle, row.detail].filter { !$0.isEmpty }.joined(separator: " · "), path = tool.path
        return actions(preset.actions, onRow: true, group: 0) + actions(preset.toolActions, onRow: false, group: 1) + [
            ListAction(title: "Copy", key: nil, group: 2, closes: false, why: nil) { [unowned self] _ in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                app.active.flash("Copied “\(text)”")
                return nil
            },
            ListAction(title: "Show \((path as NSString).lastPathComponent)", key: nil, group: 2, closes: true, why: nil) { _ in
                Viewer.show(URL(fileURLWithPath: path))
                return nil
            },
        ]
    }

    /// One action as a list has it: its key (none where it can't run here), why it can't now, what its question says;
    /// a window's closes a Picker first. `multi`: it runs on marked rows, else only the cursor's (Q15).
    private func action(_ a: ToolAction, row: ToolRow, onRow: Bool, id: String, group: Int, keyed: Bool) -> ListAction {
        let mac = (a.run.where ?? preset.where) == .mac, sudo = (a.run.sudo ?? preset.sudo ?? false) && !mac
        let scope = app.tools.scope(preset, on: server, target, rows: onRow ? [row.record] : [])
        let why = keyed ? app.tools.why(a, of: tool, row: row, onRow: onRow, id: id, on: server, target)
            : app.tools.why(a, of: tool, row: row, onRow: onRow, id: id, on: server, target) ?? "\(a.spec.title ?? a.spec.id) doesn't run here"
        let asks: ListAction.Asks = a.spec.readonly == true ? .never : a.spec.dangerous == true || a.spec.confirm == true ? .always : .prod
        return ListAction(title: a.spec.title ?? a.spec.id, key: keyed ? a.spec.key.flatMap(Shortcut.init) : nil, group: group, closes: a.spec.output == .window,
                          why: why, command: try? ToolPayload.of(a.run, in: preset, scope: scope, scripts: tool.scripts).willRun,
                          runsOn: mac ? nil : target.asRoot(sudo), asks: asks, dangerous: a.spec.dangerous == true,
                          note: a.spec.message.map { ToolTemplate.text($0, scope) }, multi: a.spec.multi == true) { [unowned self] asked in
            app.tools.perform(a, of: tool, row: row, onRow: onRow, id: id, from: self, on: server, target, asked: asked)
        }
    }
}
