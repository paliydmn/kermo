import AppKit
import DFMCore

/// A tool's list on a server (protocol §6.2) — in a Picker (Tools ▸) and in a panel (its place's row, ⌘↩) alike: the
/// rows, the line above them, the row's keys and menu, its actions' questions and how they went. One level down
/// (§7.5), an action's rows: its own list, its run, its rows' actions. (Not `ToolList`: that's the preset's `list`.)
@MainActor
final class ToolListSource: ListSource {
    unowned let app: AppDelegate
    let tool: LoadedTool
    let server: SavedServer
    /// As its user: a tool says itself when it runs as root.
    let target: SFTPTarget
    private(set) var content: ListContent?
    /// One level down (§7.5): the action whose output it lists, the row it ran on (none: a tool's action), the list
    /// that row is in.
    struct Level {
        let action: ToolAction
        let row: ToolRow?
        let parent: ToolListSource
    }
    let level: Level?
    /// A level's form as filled in: ⌘R shows it so.
    private var values: [String: String]?

    init(_ app: AppDelegate, _ tool: LoadedTool, _ server: SavedServer, _ target: SFTPTarget, level: Level? = nil) {
        (self.app, self.tool, self.server, self.target, self.level) = (app, tool, server, target.asUser, level)
    }

    var preset: ToolPreset { tool.preset }
    /// A level's: the row it went into (`web-01 › fail2ban › sshd`), else the action.
    var title: String { level.map { $0.row?.title ?? $0.action.spec.title ?? $0.action.spec.id } ?? preset.title }
    var trail: [String] { (level?.parent.trail ?? []) + [title] }
    /// The list above, if it was one: a dashboard's table isn't (its level goes back to the server's place).
    var up: (source: ListSource, row: String?)? {
        level.flatMap { lv in lv.parent.content == nil ? nil : (lv.parent, lv.row.map { lv.parent.rowID($0.key) }) }
    }
    private var key: String { ServerRow.key(target) + " " + preset.id }
    /// What its rows and a change of it are said about: a level's own, so a row there with a key one above has too
    /// (`du -d1 /var` lists `/var`) is another row. A tool's action with no row is said about the list (as its
    /// one-command run is: `AppDelegate.openTool`).
    private var base: String { level.map { $0.parent.base + " › \($0.action.spec.id)" + ($0.row.map { " " + $0.key } ?? "") } ?? ServerRow.key(target) + " tool:\(preset.id)" }
    var listID: String? { base }

    /// What it lists: the tool's list, or an action's own with the action's run; one with no list of its own repeats
    /// the level it's on (D-155) — its rows' actions too.
    var list: ToolList? {
        guard let lv = level else { return preset.list }
        var l = lv.action.spec.list ?? lv.parent.list
        l?.run = lv.action.run
        return l
    }
    var rowActions: [ToolAction]? { level.map { $0.action.spec.list == nil ? $0.parent.rowActions : $0.action.spec.actions } ?? preset.actions }
    /// The rows above, nearest first: their fields are names here (§5.3).
    var above: [ToolRecord] { level.map { lv in (lv.row.map { [$0.record] } ?? []) + lv.parent.above } ?? [] }

    /// `columns` (§6.2), else the row's title, its state and its detail; a launcher's: the action, what it runs, its key.
    var columns: [ListColumn] {
        if list == nil {
            return [ListColumn(title: "Action", field: .title, width: 170), ListColumn(title: "Runs", field: .subtitle, width: 330), ListColumn(title: "Key", field: .detail, width: 60)]
        }
        guard let cs = list?.view.columns else {
            return [ListColumn(title: "Name", field: .title, width: 170), ListColumn(title: "State", field: .subtitle, width: 170, state: true),
                    ListColumn(title: "Detail", field: .detail, width: 160)]
        }
        return cs.map { c in ListColumn(title: c.title, field: .cell(c.field.name), width: CGFloat(c.width ?? 120), state: c.field.format == "state") }
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
        var list: ToolList?
        /// What goes above its rows (`header`).
        var heading: ToolRun?
        var scope: ToolTemplate.Scope
        /// A level's rows above, nearest first (`ToolRow.above`).
        var above: [ToolRecord] = []
        let target: SFTPTarget
        let server: String
        let facts: ToolFacts?
        /// The vars' values set on this server (`tools/servers.json`): over what their commands find.
        let saved: [String: String]
        var findVars: Bool
        /// The program's version is known already this session: not asked again.
        var versionKnown: Bool

        /// The vars' commands first if they're due, the list, then (`header`) its header line (up to 200 characters)
        /// and what it warns about: rows past `limit`, a server clock off by over a minute, a version outside `tested`
        /// (asked once a session). The list, the header and the version go in one round trip (§3.2 rule 9) where they
        /// can share one (`ToolPayload.parts`); a launcher reads only its header — and so does any tool without `rows`
        /// (its page in the Tools window: a list's rows are the main window's).
        func read(_ env: [String: String], _ cancel: CancelFlag, header: Bool = true, rows: Bool = true) throws -> Read {
            let p = tool.preset, title = p.title
            var scope = scope, vars: [String: String]?
            if findVars, !p.varCommands.isEmpty {
                var found: [String: String] = [:]
                for (name, run) in p.varCommands {
                    let r = try ToolRunner.exec(run, of: tool, scope, on: target, timeout: run.timeout ?? 10, env: env, cancel: cancel).ran
                    if run.succeeded(r.status), let first = r.text.split(whereSeparator: \.isNewline).first { found[name] = String(first) }
                }
                vars = found
                scope.levels[scope.levels.count - 2] = p.varValues(saved: saved, found: found)
            }
            // The header and the version (once a session) say something above the rows.
            let extra = header ? [heading, versionKnown ? nil : p.version.map { ToolRun(command: .one($0.command)) }] : []
            var said = extra.map { _ in String?.none }
            func first(_ text: String) -> String? { text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(200)) } }
            func one(_ run: ToolRun) -> String? {
                guard let r = try? ToolRunner.exec(run, of: tool, scope, on: target, timeout: run.timeout ?? 10, env: env, cancel: cancel).ran,
                      r.stopped == nil, run.succeeded(r.status) else { return nil }
                return first(r.text)
            }
            guard let list, rows else {   // a launcher: its actions are its rows
                for (i, run) in extra.enumerated() { said[i] = run.flatMap(one) }
                return note(Read(rows: [], total: 0, vars: vars), said: said, total: 0, skew: nil)
            }
            let records: ToolRecords, output: String, skew: TimeInterval?
            if list.run.files != nil {   // its files over SFTP; what goes above them as commands
                do { records = try ToolExec.files(list, of: p, scope, on: target, env: env, cancel: cancel) } catch let e as SFTPError where e.code != nil {
                    throw Failed(message: "\(title) on \(server): \(e.localizedDescription)", output: "")
                }
                (output, skew) = (records.unmatched.joined(separator: "\n"), nil)
                for (i, run) in extra.enumerated() { said[i] = run.flatMap(one) }
            } else {
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
                output = [r.errors, r.text].filter { !$0.isEmpty }.joined(separator: "\n")
                guard list.run.succeeded(r.status, format: list.parse.format) else {
                    throw Failed(message: ToolExec.notHere(r, server: server, facts: facts)
                                 ?? "\(title) on \(server): " + (r.errors.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(r.status)"), output: output)
                }
                (records, skew) = (list.parse.records(r.out, exit: r.status), r.skew)
            }
            guard records.matched else {
                throw Failed(message: "\(title) on \(server): the output didn't match — " + (records.unmatched.first { !$0.isEmpty } ?? ""), output: output)
            }
            let now = Date().addingTimeInterval(skew ?? 0)   // `ago` by the server's clock
            let read = Read(rows: records.rows.map { var r = list.view.row($0, scope, now: now); r.above = above; return r }, total: records.total, vars: vars)
            return header ? note(read, said: said, total: records.rows.count, skew: skew) : read
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

    /// A level's reads its action's run, with its form's values and the rows above; no vars or version again.
    func lister() -> Lister {
        var l = Self.lister(app, tool, server, target)
        guard level != nil else { return l }
        (l.list, l.heading, l.above, l.findVars, l.versionKnown) = (list, list?.view.header, above, false, true)
        l.scope = app.tools.scope(preset, on: server, target, rows: above)
        l.scope.levels[0] = (values ?? [:]).mapValues { .string($0) }
        return l
    }

    /// What reads it again after a change on one of its rows: none for a launcher, nor for a level whose own run
    /// changes something (⌘R asks first).
    var relister: Lister? { list == nil || level.map({ !ToolRunner.looks($0.action) }) == true ? nil : lister() }

    /// What reads `tool`'s list on `target` now: an action's `verify` needs it whether its list still shows or not.
    static func lister(_ app: AppDelegate, _ tool: LoadedTool, _ server: SavedServer, _ target: SFTPTarget) -> Lister {
        let key = ServerRow.key(target.asUser) + " " + tool.preset.id
        return Lister(tool: tool, list: tool.preset.list, heading: tool.preset.list?.view.header ?? tool.preset.header, scope: app.tools.scope(tool.preset, on: server, target),
                      target: target.asUser, server: server.title,
                      facts: app.tools.answer(target)?.answer.facts, saved: app.tools.settings.vars(tool.preset.id, on: app.tools.serverID(target)), findVars: app.tools.found[key] == nil, versionKnown: app.tools.versions[key] != nil)
    }

    /// As any look: a locked server asks first, then the login if one is due — to the server as it was reached (its
    /// place's) — then the list's runs. Its connection is kept for its ControlPersist (`noteLook`).
    func read(_ cancel: CancelFlag) async throws -> ListContent {
        if await !ServerLock.authorize(target, "look at the \(title.lowercased()) of") { throw AppDelegate.Locked(message: "\(server.title) stays locked") }
        var willRun: String?
        if let level { willRun = try await ready(level) }
        let t = target, env = SSHAskpass.env.merging(["DFM_ASKPASS_WHY": "For “\(title)” on \(server.title)"]) { $1 }
        try await Blocking.run { try SFTP.startMaster(t, env: env) }
        app.noteLook(t)
        if cancel.isCancelled { throw CancellationError() }
        let lister = lister()
        let read: Read
        do { read = try await Blocking.run { try lister.read(env, cancel) } } catch {
            changed(willRun, error)
            throw error
        }
        changed(willRun, nil)
        return show(read)
    }

    /// A level's action as any (§7.2), after the lock: its form, production's question — over the list it's shown in.
    /// What it runs; Cancel goes back where it came from.
    private func ready(_ lv: Level) async throws -> String {
        let verb = (lv.action.spec.title ?? lv.action.spec.id).replacingOccurrences(of: "…", with: "")
        switch await app.tools.ready(lv.action, of: tool, app.tools.scope(preset, on: server, target, rows: above), row: lv.row?.title, on: target, asked: false,
                                     window: app.rowLists(base).first?.sheetWindow, values: values) {
        case .stop("cancelled"): throw CancellationError()
        case .stop(let why): throw JobErrorMessage("\(verb): \(why) — nothing ran")
        case .go(let scope, _, let willRun, _, _):
            values = scope.levels[0].mapValues(\.text)
            return willRun
        }
    }

    /// A level's run is in the production log, as any action's is.
    private func changed(_ willRun: String?, _ error: Error?) {
        guard let lv = level, let willRun else { return }
        AuditLog.write(target, "tool \(preset.id) \(lv.action.spec.id)", paths: [], command: willRun, exit: error == nil ? 0 : nil,
                       error: error is CancellationError ? "cancelled, may have run" : error?.localizedDescription)
    }

    /// A read's rows as items, the line above them, what an empty list says; the place counts them.
    func show(_ r: Read) -> ListContent {
        if level == nil {   // the tool's: a level's read says nothing of the tool's list
            if let v = r.vars { app.tools.found[key] = v }
            if let v = r.version { app.tools.versions[key] = .some(v) }
            app.tools.counts[key] = r.total
        }
        _ = app.tools.answer(target)   // connected now: what the server has, if not asked yet
        let scope = app.tools.scope(preset, on: server, target, rows: above)
        let header = [r.header, level == nil ? app.tools.versions[key] ?? nil : nil].compactMap { $0 }.joined(separator: " · ")
        let primary = level == nil ? preset.primary.flatMap { id in preset.toolActions?.first { $0.spec.id == id } }.map { $0.spec.title ?? $0.spec.id } : nil
        let c = ListContent(rows: list == nil ? launcherRows() : r.rows.map(item), header: header.isEmpty ? nil : header, empty: list?.view.empty.map { ToolTemplate.text($0, scope) } ?? "Nothing here",
                            primary: primary.flatMap { title in listActions(nil).first { $0.title == title } },
                            actions: { [weak self] in self?.listActions(nil) ?? [] })
        content = c
        return c
    }

    // MARK: A row

    func rowID(_ key: String) -> String { base + " " + key }
    static func rowID(_ key: String, tool: String, on t: SFTPTarget) -> String { ServerRow.key(t.asUser) + " tool:\(tool) " + key }

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
        it.busy = running != nil || row.state == .busy || app.tools.jobs.running(rowID: id) != nil
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
            it.busy = app.serviceRuns[it.id]?.isEmpty == false || app.tools.jobs.running(rowID: it.id) != nil   // its action runs
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
            // A launcher's action runs on its own row: that row spins while it runs.
            func runID(_ a: ToolAction) -> String { list == nil && group == 1 ? rowID(a.spec.title ?? a.spec.id) : id }
            let all = (all ?? []).filter { a in ToolRunner.runs(a, of: preset) && (!onRow || row.map { a.offered(on: $0.record) } != false) }
            let shown = known.map { $0.visible(all, of: preset) } ?? all.filter { $0.spec.requires == nil }
            var seen = Set<String>(), out: [ListAction] = []
            for a in all {
                let title = a.spec.title ?? a.spec.id
                guard !seen.contains(title), shown.contains(a) || !all.contains(where: { ($0.spec.title ?? $0.spec.id) == title && shown.contains($0) }) else { continue }
                seen.insert(title)
                out.append(action(a, row: row, onRow: onRow, id: runID(a), group: group, keyed: shown.contains(a)))
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
        return (row == nil ? [] : actions(rowActions, onRow: true, group: 0)) + (level == nil ? actions(preset.toolActions, onRow: false, group: 1) : []) + [copy].compactMap { $0 } + [
            ListAction(title: "Show \((path as NSString).lastPathComponent)", key: nil, group: 2, closes: true, why: nil) { _ in
                Viewer.show(URL(fileURLWithPath: path))
                return nil
            },
        ]
    }

    /// One action as a list has it: its key (none where it can't run here), why it can't now, what its question says;
    /// a window's closes a Picker first. `multi`: it runs on marked rows, else only the cursor's (Q15).
    func action(_ a: ToolAction, row: ToolRow?, onRow: Bool, id: String, group: Int, keyed: Bool) -> ListAction {
        let mac = (a.run.where ?? preset.where) == .mac, sudo = (a.run.sudo ?? preset.sudo ?? false) && !mac
        let scope = app.tools.scope(preset, on: server, target, rows: onRow ? row?.records ?? [] : above)
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
