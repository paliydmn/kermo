import AppKit
import DFMCore

// Tools in the main window (Tools PR 2): the tools Kermo knows, what each server has of them, and the one path an
// action takes to a server — the lock, the question, the run, the line that says how it went, the list read again
// (protocol §7.2–7.3). A tool's list is a `ToolListSource`; Tools ▸ and a place's rows are in ToolsMenu.swift.

@MainActor
final class ToolRunner {
    unowned let app: AppDelegate
    private(set) var library = ToolLibrary()
    /// Your own tools you said to use (`tools/trust.json`); built-ins always.
    /// ponytail: nothing asks yet — the trust sheet comes with Tools PR 2b, until then only built-ins run.
    var trust = ToolTrust()
    /// What each server (`ServerRow.key`) said this session, and when: its facts, the tools and actions it has.
    /// ponytail: this session's only; Tools PR 2b keeps them in tools/known.json, for a menu without a connection.
    private(set) var answers: [String: (answer: ToolBatch.Answer, at: Date)] = [:]
    private var asking: Set<String> = []
    /// What vars' commands found, per server and tool ("<server> <tool>").
    /// ponytail: once a session, not once a connection — Reload Config looks again.
    var found: [String: [String: String]] = [:]
    /// How many rows a tool's list had when last read ("<server> <tool>").
    var counts: [String: Int] = [:]
    /// A change running on a server's tool ("<server> <tool>"): its title. One at a time there; reads run alongside (§2).
    var changing: [String: String] = [:]

    /// Tests: how a payload starts (in a session of its own), sudo's stand-in, your folder, a connection that answers.
    nonisolated(unsafe) static var command: @Sendable (ToolPayload) -> String = { $0.command }
    nonisolated(unsafe) static var sudoProgram = "sudo"
    nonisolated(unsafe) static var hasMaster: @Sendable (SFTPTarget) -> Bool = { ToolBatch.live($0) }
    static var own: URL? = URL(fileURLWithPath: Config.path("tools"))

    init(_ app: AppDelegate) { self.app = app }

    /// Reads the tools again (at launch, Reload Config); what couldn't be loaded, as Reload Config says it.
    func reload() -> [String] {
        library = ToolLibrary.load(own: Self.own, hasSymbol: { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })
        (answers, found) = ([:], [:])   // a changed tool's requires: asked again
        return library.problems
    }

    /// The tools this version shows: trusted, with nothing to ask before use (vars' `ask`: Tools PR 4), a list read by a
    /// command or a script, or a command of their own.
    var tools: [LoadedTool] {
        library.trusted(trust).filter { t in
            let p = t.preset
            return p.varsToAsk(saved: [:]).isEmpty && (p.list.map { $0.run.command != nil || $0.run.script != nil } ?? p.commandAction.map(Self.runs) ?? false)
        }
    }

    /// What this version runs of an action: a command or a script whose output is a line, a window or nothing; no form.
    /// ponytail: Tools PR 2b brings inputs, follow, terminal and edit — this filter goes then.
    static func runs(_ a: ToolAction) -> Bool {
        (a.run.command != nil || a.run.script != nil) && a.spec.inputs == nil && a.spec.long != true && a.spec.list == nil
            && [nil, .line, .window, .silent].contains(a.spec.output) && a.spec.edit == nil && a.spec.open == nil && a.spec.goto == nil && a.spec.accepts == nil
    }

    // MARK: What a server has

    /// What `t`'s server has, as last asked; nil: not yet. The first look asks — off the main thread, in one batch with
    /// the facts, over a connection that's up: never a login for it (§10.5).
    func answer(_ t: SFTPTarget) -> (answer: ToolBatch.Answer, at: Date)? {
        let key = ServerRow.key(t.asUser)
        if answers[key] == nil, AppDelegate.connected(t.asUser) { ask(t.asUser) }
        return answers[key]
    }

    private func ask(_ t: SFTPTarget) {
        let key = ServerRow.key(t), tools = tools
        guard !tools.isEmpty, asking.insert(key).inserted else { return }
        let s = app.savedServer(at: t) ?? SavedServer(target: t)
        let scopes = Dictionary(tools.map { ($0.preset.id, scope($0.preset, on: s, t)) }) { a, _ in a }
        let scripts = Dictionary(tools.map { ($0.preset.id, $0.scripts) }) { a, _ in a }
        let items = ToolBatch.items(tools.map(\.preset)), command = Self.command, live = Self.hasMaster
        Task {
            let a = await Blocking.run { ToolBatch.ask(t, items, scope: { scopes[$0] ?? .init() }, scripts: { scripts[$0] ?? [:] }, hasMaster: live, command: command) }
            asking.remove(key)
            guard let a else { return }
            answers[key] = (a, Date())
            app.toolsKnown(on: t)
        }
    }

    /// The names a tool's templates have on a server (§5.3) besides the row's: its vars, then Kermo's own.
    func scope(_ p: ToolPreset, on s: SavedServer, _ t: SFTPTarget, rows: [ToolRecord] = []) -> ToolTemplate.Scope {
        let key = ServerRow.key(t.asUser)
        var kermo: [String: ToolValue] = ["server": .string(s.title), "host": .string(s.host), "user": .string(s.user ?? "")]
        if let f = answers[key]?.answer.facts { kermo.merge(f.names) { $1 } }
        return .init(rows: rows, vars: p.varValues(saved: [:], found: found[key + " " + p.id] ?? [:]), kermo: kermo)
    }

    /// `run` of `tool` with `scope`'s names, once (§2): its payload, as root if the tool says, on `t` or this Mac.
    nonisolated static func exec(_ run: ToolRun, of tool: LoadedTool, _ scope: ToolTemplate.Scope, on t: SFTPTarget, timeout: Double,
                                 env: [String: String], cancel: CancelFlag) throws -> (ran: ToolExec.Ran, payload: ToolPayload) {
        let mac = (run.where ?? tool.preset.where) == .mac, sudo = sudoProgram
        let plain = try ToolPayload.of(run, in: tool.preset, scope: scope, scripts: tool.scripts, sudoProgram: sudo).payload
        let wrapped = plain.sudo == .noPassword
            ? try ToolPayload.of(run, in: tool.preset, scope: scope, scripts: tool.scripts, password: true, sudoProgram: sudo).payload : plain
        let ran = try ToolExec.run({ $0 ? wrapped : plain }, on: mac ? .local() : t, timeout: timeout, cancel: cancel, env: env, command: command)
        return (ran, ran.password == nil ? plain : wrapped)
    }

    // MARK: An action

    /// Why `a` can't run now, or nil: its `requires` didn't pass on this server, a change of the row or of the tool
    /// runs, a value won't go into a command (§3.2 rule 5; `where: mac` with a server's data, S3), a field is empty.
    func why(_ a: ToolAction, of tool: LoadedTool, row: ToolRow?, onRow: Bool, id: String, on s: SavedServer, _ t: SFTPTarget) -> String? {
        let p = tool.preset, title = a.spec.title ?? a.spec.id
        if let r = a.spec.requires {
            guard let known = answers[ServerRow.key(t.asUser)]?.answer else { return "\(title): not checked on \(s.title) yet" }
            if !known.has(a, of: p) {
                let program = (r.command?.all.first).flatMap { $0.firstMatch(of: /command -v ([^\s;|&]+)/)?.output.1 }.map { "needs \($0)" } ?? "its check didn't pass"
                return "\(title) \(program); \(s.title) is \(known.facts.said)"
            }
        }
        if a.spec.readonly != true {
            let name = row?.title ?? p.title
            if let busy = app.serviceRuns[id] { return busy.isEmpty ? "\(name): one change at a time — another is being asked" : "\(name): \(busy.dropLast()) runs on it — wait for it" }
            if let other = changing[ServerRow.key(t.asUser) + " " + p.id] { return "\(p.title) on \(s.title) is busy: \(other.replacingOccurrences(of: "…", with: ""))" }
        }
        let scope = scope(p, on: s, t, rows: onRow ? row.map { [$0.record] } ?? [] : [])
        if let why = Self.refusal(a.run, of: p, scope) { return "\(title): \(why) — nothing runs" }
        do { _ = try ToolPayload.of(a.run, in: p, scope: scope, scripts: tool.scripts) } catch { return "\(title): \(error) — nothing runs" }
        return nil
    }

    /// Why a value can't go into `run`'s command, or nil: it begins with `-`, holds a line break or a control character
    /// (§3.2 rule 5). On this Mac (`where: mac`) a value is a server's data: only `[A-Za-z0-9._:/@%+=,-]`, and `open`
    /// takes only a web address.
    static func refusal(_ run: ToolRun, of p: ToolPreset, _ scope: ToolTemplate.Scope) -> String? {
        let mac = (run.where ?? p.where) == .mac
        for text in (run.command?.all ?? []) + Array((p.env ?? [:]).values) + Array((run.env ?? [:]).values) {
            for ph in ToolTemplate.placeholders(in: text) {
                let v = scope.value(ph.name)?.text ?? ""
                if let why = ToolTemplate.refusal(v) { return "{\(ph.name)}: \(why)" }
                guard mac else { continue }
                if !v.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._:/@%+=,-".unicodeScalars.contains($0)) }) {
                    return "{\(ph.name)}: “\(v)” has characters this Mac won't put into a command"
                }
                if (run.command?.all.first ?? "").hasPrefix("open"), !(v.hasPrefix("http://") || v.hasPrefix("https://")) {
                    return "{\(ph.name)}: open takes only http:// and https:// addresses"
                }
            }
        }
        return nil
    }

    /// `a` of `tool` on `t`'s server, started on `row` of a list (`source`) — acting on it if `onRow`, else a tool's
    /// action — or from Tools ▸: §7.2's order — the lock (not on this Mac), the question (§7.3; `asked`: asked for
    /// several rows already), the run, how it went, the list read again unless it's `readonly`. `id`: the row that
    /// says it runs; a second press there waits. What to wait for: its run.
    @discardableResult
    func perform(_ a: ToolAction, of tool: LoadedTool, row: ToolRow?, onRow: Bool, id: String, from source: ToolListSource?, on s: SavedServer,
                 _ t: SFTPTarget, asked: Bool = false) -> Task<Void, Never>? {
        let p = tool.preset, title = a.spec.title ?? a.spec.id, verb = title.replacingOccurrences(of: "…", with: "")
        if let why = why(a, of: tool, row: row, onRow: onRow, id: id, on: s, t) {
            app.active.flash(why, error: true)
            return nil
        }
        let scope = scope(p, on: s, t, rows: onRow ? row.map { [$0.record] } ?? [] : [])
        guard let made = try? ToolPayload.of(a.run, in: p, scope: scope, scripts: tool.scripts) else { return nil }
        let mac = (a.run.where ?? p.where) == .mac, readonly = a.spec.readonly == true, sudo = (a.run.sudo ?? p.sudo ?? false) && !mac
        let place = mac ? "this Mac" : s.title, key = ServerRow.key(t.asUser) + " " + p.id
        let asks = !asked && (a.spec.dangerous == true || a.spec.confirm == true || !readonly && SavedServer.isProd(t))
        let message = a.spec.message.map { ToolTemplate.text($0, scope) }
        let question: @MainActor (NSWindow?) async -> Bool = { [unowned self] window in
            if !mac, await !ServerLock.authorize(t, "run “\(verb)” on") { return false }
            guard asks else { return true }
            return await ask(a, verb: verb, row: onRow ? row?.title : nil, on: t, mac: mac, sudo: sudo, willRun: made.willRun,
                             payload: made.payload, message: message, window: window)
        }
        let timeout = a.run.timeout ?? 30
        if !readonly { changing[key] = title }

        if a.spec.output == .window {   // a window of its own: the run, then its output there
            return Task {
                defer { if !readonly { changing[key] = nil } }
                let panel = app.active
                guard await question(nil) else { return panel.flash("\(verb): cancelled — nothing ran") }
                let env = SSHAskpass.env
                let r = await panel.busy("\(verb) on \(place)…") { flag in try Self.exec(a.run, of: tool, scope, on: t, timeout: timeout, env: env, cancel: flag) }
                _ = ran(r, a, of: p, on: t, shown: made.payload.shown)
                switch r {
                case .success(let (ran, _)):
                    OutputWindow.show(ran.text, errors: ran.stopped ?? ran.errors, title: "\(verb) — \(place)", place: place,
                                      status: ran.status, ok: ran.stopped == nil && a.run.succeeded(ran.status))
                case .failure(is CancellationError): break
                case .failure(is ToolExec.NoPassword): panel.flash("\(verb): no sudo password — nothing ran")
                case .failure(let e): app.showError(e)
                }
            }
        }

        // The result line under the list, the list read again (§7.2), in the loop Services… changes go through.
        let verify = onRow && row != nil && (a.spec.verify ?? (a.spec.dangerous == true)), lister = source?.lister()
        let refresh = !readonly && a.spec.refresh != false
        app.serviceRuns[id] = ""
        return Task {
            defer { if !readonly { changing[key] = nil } }
            await app.changeRow(id: id, shown: made.willRun, on: t, busy: verb + "…", name: onRow ? row?.title ?? p.title : p.title, server: place,
                run: { window, panel, running in
                    guard await question(window) else { return .notRun("cancelled") }
                    running()
                    let env = SSHAskpass.env, rowKey = row?.key, record = row?.record
                    let r = await panel.busy("\(verb) on \(place)…") { flag in
                        if verify, let lister, let rowKey {   // the row as it was asked about, field for field, or nothing runs
                            guard try lister.read(env, flag, header: false).current(rowKey) == record else { throw Changed() }
                        }
                        return try Self.exec(a.run, of: tool, scope, on: t, timeout: timeout, env: env, cancel: flag)
                    }
                    return self.ran(r, a, of: p, on: t, shown: made.payload.shown)
                },
                read: refresh ? lister.map { l in { env, flag in try l.read(env, flag) } } : nil,
                show: { list, read in
                    guard let source else { return }
                    if let read { list.reload(source.show(read), having: id) } else if let row { list.update(source.item(row)) }
                },
                say: { how, _, error, time in self.line(how, a, scope, place: place, at: time, readError: error, facts: self.answers[ServerRow.key(t.asUser)]?.answer.facts) })
        }
    }

    /// The row changed between the question and the run (`verify`).
    struct Changed: Error {}

    /// A run as the change loop takes it, and in the production log: the tool, the action, the payload with its
    /// secrets and the password as •••, the exit.
    private func ran(_ r: Result<(ran: ToolExec.Ran, payload: ToolPayload), Error>, _ a: ToolAction, of p: ToolPreset, on t: SFTPTarget, shown: String) -> AppDelegate.RanThere {
        let what = "tool \(p.id) \(a.spec.id)"
        switch r {
        case .success(let (ran, payload)):
            let ok = ran.stopped == nil && a.run.succeeded(ran.status)
            AuditLog.write(t, what, paths: [], command: payload.mask(payload.shown, password: ran.password), exit: ran.stopped == nil ? ran.status : nil,
                           error: ok ? nil : ran.stopped ?? ran.errors.split(whereSeparator: \.isNewline).first.map(String.init))
            if let stopped = ran.stopped { return .ran(.failure(JobErrorMessage(stopped))) }
            if ok { return .ran(.success(.passed(""))) }
            if ran.status == 127 { answers[ServerRow.key(t.asUser)] = nil }   // its requires again on the next look
            return .ran(.success(.failed(status: ran.status, output: [ran.errors, ran.text].filter { !$0.isEmpty }.joined(separator: "\n"))))
        case .failure(is ToolExec.NoPassword): return .notRun("no sudo password")
        case .failure(is Changed): return .notRun("the list changed")
        case .failure(let e):
            AuditLog.write(t, what, paths: [], command: shown, exit: nil, error: e is CancellationError ? "cancelled, may have run" : e.localizedDescription)
            return .ran(.failure(e))
        }
    }

    /// How an action went, for the line under its list: its `done` (§6.1) or the first line it said — 127 and 126 in
    /// words; nothing for a `silent` one that went well.
    func line(_ how: Services.Ran, _ a: ToolAction, _ scope: ToolTemplate.Scope, place: String, at time: String, readError: String?,
              facts: ToolFacts?) -> (outcome: Services.Outcome, line: String) {
        let verb = (a.spec.title ?? a.spec.id).replacingOccurrences(of: "…", with: "")
        switch how {
        case .passed:
            if a.spec.output == .silent, readError == nil { return (.ok, "") }
            let done = a.spec.done.map { ToolTemplate.text($0, scope) } ?? "\(verb): done"
            return readError.map { (.warning, "\(done) on \(place) at \(time) — the list wasn't read again: \($0)") } ?? (.ok, "\(done) on \(place) at \(time)")
        case .failed(let exit, let output):
            var r = ToolExec.Ran()
            (r.status, r.errors) = (exit, output)
            if let words = ToolExec.notHere(r, server: place, facts: facts) { return (.failed, words) }
            return (.failed, "\(verb) failed on \(place) at \(time): " + (output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(exit)"))
        case .couldNotRun(let why): return (.failed, "\(verb) didn't run on \(place) at \(time): \(why)")
        case .unknown: return (.warning, "\(verb): stopped waiting on \(place) at \(time) — it may have run")
        case .notRun(let why): return (.notRun, "\(verb): " + (why == "cancelled" ? "cancelled — nothing ran" : "\(why); nothing ran"))
        }
    }

    /// The question (§7.3): what runs with its values, how and where, the production strip, the action's `message`;
    /// "Show Exactly What Runs" shows the payload, then asks again. True: run it.
    func ask(_ a: ToolAction, verb: String, row: String?, on t: SFTPTarget, mac: Bool, sudo: Bool, willRun: String, payload: ToolPayload,
             message: String?, window: NSWindow?) async -> Bool {
        let place = mac ? "this Mac" : SavedServer.name(for: t.asUser)
        var c = Confirm("\(verb) on \(place)?", on: mac ? nil : t.asRoot(sudo), action: verb)
        if let row { c.items = [Confirm.Item(name: row)] }
        (c.runs, c.command, c.note) = (mac ? "Runs on this Mac." : AppDelegate.runs(on: t.asRoot(sudo)), willRun, message)
        c.others = ["Show Exactly What Runs"]
        c.irreversible = a.spec.dangerous == true
        while true {
            switch await app.confirm(c, on: window) {
            case 0: return true
            case 1: await exactly(payload.shown, on: place, window: window)
            default: return false
            }
        }
    }

    /// The payload as it's sent, its secrets as •••: mono, scrolling past 8 lines.
    private func exactly(_ shown: String, on place: String, window: NSWindow?) async {
        let title = "Exactly what runs on \(place)"
        if let answer = AppDelegate.answering { AppDelegate.answeredInfo = shown; _ = answer(title, ["OK"], nil); return }
        let alert = AppDelegate.alert(title, info: "", ["OK"])
        alert.accessoryView = Confirm.stack([Confirm.label("This goes to sh -s as its input. Each value is a variable set before the command, never part of it.",
                                                           color: .secondaryLabelColor, size: 11), Confirm.commandBox(shown)])
        _ = await AppDelegate.sheet(alert, on: window ?? app.window)
    }
}
