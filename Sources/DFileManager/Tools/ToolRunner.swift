import AppKit
import DFMCore

// Tools in the main window (Tools PR 2): the tools Kermo knows, what each server has of them, and the one path an
// action takes to a server — trust, the lock, the form, the question, the run, the line that says how it went, the
// list read again (protocol §7.2–7.3). A tool's list is a `ToolListSource`; Tools ▸ and a place's rows are in
// ToolsMenu.swift; the questions in ToolQuestions.swift, the form in ToolForm.swift.

@MainActor
final class ToolRunner {
    unowned let app: AppDelegate
    private(set) var library = ToolLibrary()
    /// Your own tools you said to use (`tools/trust.json`); built-ins always.
    var trust = ToolTrust()
    /// What each server (`ServerRow.key`) said this session, and when: its facts, the tools and actions it has.
    private(set) var answers: [String: (answer: ToolBatch.Answer, at: Date)] = [:]
    /// The last answers of saved servers (`SavedServer.id`), kept in `tools/known.json`: Tools ▸ shows a server's tools
    /// greyed while it isn't connected. A cache, not a setting: deleting it costs a batch on the next connection.
    private var known: [String: Known] = [:]
    struct Known: Codable { var facts: ToolFacts; var passed: [String]; var at: Date }
    private var asking: Set<String> = []
    /// What vars' commands found, per server and tool ("<server> <tool>").
    /// ponytail: once a session, not once a connection — Reload Config looks again.
    var found: [String: [String: String]] = [:]
    /// What a tool's version said, per server and tool: asked once a session (nil inside: nothing to warn about).
    var versions: [String: String?] = [:]
    /// How many rows a tool's list had when last read ("<server> <tool>").
    var counts: [String: Int] = [:]
    /// A change running on a server's tool ("<server> <tool>"): its title. One at a time there; reads run alongside (§2).
    var changing: [String: String] = [:]
    /// Production's question waved off for a while (§7.3): server, tool and the tool's hash (an updated tool asks
    /// again) → till when. In memory only.
    var quiet: [String: Date] = [:]
    /// Long jobs (§7.6): Activity's, `tools/runs.json`.
    private(set) lazy var jobs = ToolJobs(app)

    /// Tests: how a payload starts (in a session of its own), sudo's stand-in, your folder, a connection that answers.
    nonisolated(unsafe) static var command: @Sendable (ToolPayload) -> String = { $0.command }
    nonisolated(unsafe) static var sudoProgram = "sudo"
    nonisolated(unsafe) static var hasMaster: @Sendable (SFTPTarget) -> Bool = { ToolBatch.live($0) }
    static var own: URL? = URL(fileURLWithPath: Config.path("tools"))

    init(_ app: AppDelegate) {
        self.app = app
        ToolExec.waiting = { [weak app] t, waits in   // the channel budget (§2): a run that waits says so
            guard waits else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    app?.active.flash("Waiting for a free channel on \(SavedServer.name(for: t.asUser)): Tools hold \(ToolExec.channels) of its connection's sessions")
                }
            }
        }
    }

    /// Reads the tools again (at launch, Reload Config), what you trusted and what servers had; what couldn't be
    /// loaded, as Reload Config says it.
    func reload() -> [String] {
        library = ToolLibrary.load(own: Self.own, hasSymbol: Symbol.exists)
        (answers, found, versions) = ([:], [:], [:])   // a changed tool's requires: asked again
        trust = Self.own.flatMap { try? Config.load("trust.json", as: ToolTrust.self, in: $0.path) } ?? ToolTrust()
        known = Self.own.flatMap { try? Config.load("known.json", as: [String: Known].self, in: $0.path) } ?? [:]
        return library.problems
    }

    /// The tools this version shows: trusted, with nothing to ask before use (vars' `ask`: Tools PR 4), a list read by a
    /// command or a script, a command of their own, or actions with no list (a launcher) this version runs.
    var tools: [LoadedTool] { library.trusted(trust).filter(Self.shows) }
    /// Your own tools not trusted yet, or changed since: Tools ▸ offers them, asking first.
    var untrusted: [LoadedTool] { library.tools.filter { !trust.trusts($0) && Self.shows($0) } }

    static func shows(_ t: LoadedTool) -> Bool {
        let p = t.preset
        return p.varsToAsk(saved: [:]).isEmpty && (p.list.map { $0.run.command != nil || $0.run.script != nil } ?? p.commandAction.map { runs($0, of: p) }
            ?? p.toolActions?.contains { runs($0, of: p) } ?? false)
    }

    /// What this version runs of an action: a command, a script or an `edit`; a form of text, secrets and choices;
    /// output as a line, a window, a log that follows, a terminal or nothing; a long job (Activity's).
    /// ponytail: levels (PR 6), folder and file inputs (PR 7), `open`, `goto` and `accepts` (PR 5, 9) and a terminal on
    /// this Mac are left out till then.
    static func runs(_ a: ToolAction, of p: ToolPreset) -> Bool {
        (a.run.command != nil || a.run.script != nil || a.spec.edit != nil) && a.spec.list == nil && a.spec.output != .list
            && !(a.spec.inputs ?? []).contains { [.folder, .file].contains($0.info.type) }
            && a.spec.open == nil && a.spec.goto == nil && a.spec.accepts == nil
            && !(a.spec.output == .terminal && (a.run.where ?? p.where) == .mac)
    }

    // MARK: What a server has

    /// What `t`'s server has, as last asked; nil: not yet. The first look asks — off the main thread, in one batch with
    /// the facts, over a connection that's up: never a login for it (§10.5). Till then, a saved server's last answer.
    func answer(_ t: SFTPTarget) -> (answer: ToolBatch.Answer, at: Date)? {
        let key = ServerRow.key(t.asUser)
        if answers[key] == nil, AppDelegate.connected(t.asUser) { ask(t.asUser) }
        if let a = answers[key] { return a }
        return app.savedServer(at: t).flatMap { known[$0.id.uuidString] }.map { (ToolBatch.Answer(facts: $0.facts, passed: Set($0.passed)), $0.at) }
    }

    /// `t`'s server asked again on its next look (a tool just trusted, a program gone: exit 127).
    func askAgain(_ t: SFTPTarget) { answers[ServerRow.key(t.asUser)] = nil }

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
            if let id = app.savedServer(at: t)?.id.uuidString, let dir = Self.own?.path {
                known[id] = Known(facts: a.facts, passed: a.passed.sorted(), at: Date())
                Config.save("known.json", known, in: dir)
            }
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
    /// `secret`: inputs that go into the payload only (§7.4).
    nonisolated static func exec(_ run: ToolRun, of tool: LoadedTool, _ scope: ToolTemplate.Scope, secret: Set<String> = [], on t: SFTPTarget,
                                 timeout: Double, env: [String: String], cancel: CancelFlag) throws -> (ran: ToolExec.Ran, payload: ToolPayload) {
        let (plain, wrapped) = try payloads(run, of: tool, scope, secret: secret)
        let mac = (run.where ?? tool.preset.where) == .mac
        let ran = try ToolExec.run({ $0 ? wrapped : plain }, on: mac ? .local() : t, timeout: timeout, cancel: cancel, env: env, command: command)
        return (ran, ran.password == nil ? plain : wrapped)
    }

    /// `run`'s payload as `sudo -n` takes it, and with the password wrapper.
    nonisolated static func payloads(_ run: ToolRun, of tool: LoadedTool, _ scope: ToolTemplate.Scope, secret: Set<String> = []) throws -> (ToolPayload, ToolPayload) {
        let plain = try ToolPayload.of(run, in: tool.preset, scope: scope, scripts: tool.scripts, secret: secret, sudoProgram: sudoProgram).payload
        guard plain.sudo == .noPassword else { return (plain, plain) }
        return (plain, try ToolPayload.of(run, in: tool.preset, scope: scope, scripts: tool.scripts, secret: secret, password: true, sudoProgram: sudoProgram).payload)
    }

    // MARK: An action

    /// Why `a` can't run now, or nil: its `requires` didn't pass on this server, the server is read-only and it changes
    /// things, a change of the row or of the tool runs, a value won't go into a command (§3.2 rule 5; `where: mac`
    /// with a server's data, S3), a field is empty. Its form's values are the form's to check.
    func why(_ a: ToolAction, of tool: LoadedTool, row: ToolRow?, onRow: Bool, id: String, on s: SavedServer, _ t: SFTPTarget) -> String? {
        let p = tool.preset, title = a.spec.title ?? a.spec.id
        if let r = a.spec.requires {
            guard let known = answer(t)?.answer else { return "\(title): not checked on \(s.title) yet" }
            if !known.has(a, of: p) {
                let program = (r.command?.all.first).flatMap { $0.firstMatch(of: /command -v ([^\s;|&]+)/)?.output.1 }.map { "needs \($0)" } ?? "its check didn't pass"
                return "\(title) \(program); \(s.title) is \(known.facts.said)"
            }
        }
        if a.spec.readonly != true {
            if s.readOnly { return "\(s.title) is read-only: Tools run only actions that change nothing there" }
            let name = row?.title ?? p.title
            if let busy = app.serviceRuns[id] { return busy.isEmpty ? "\(name): one change at a time — another is being asked" : "\(name): \(busy.dropLast()) runs on it — wait for it" }
            if let other = changing[ServerRow.key(t.asUser) + " " + p.id] { return "\(p.title) on \(s.title) is busy: \(other.replacingOccurrences(of: "…", with: ""))" }
        }
        var scope = scope(p, on: s, t, rows: onRow ? row.map { [$0.record] } ?? [] : [])
        scope.levels[0] = Dictionary((a.spec.inputs ?? []).map { ($0.info.name, ToolValue.string("…")) }) { x, _ in x }   // the form fills them
        if let why = Self.refusal(a, of: p, scope) { return "\(title): \(why) — nothing runs" }
        if a.run.command != nil || a.run.script != nil {
            do { _ = try ToolPayload.of(a.run, in: p, scope: scope, scripts: tool.scripts) } catch { return "\(title): \(error) — nothing runs" }
        }
        return nil
    }

    /// Why a value can't go into `a`'s command (or its `edit` path), or nil: it begins with `-`, holds a line break or a
    /// control character (§3.2 rule 5) — an input's `pattern` may allow it. On this Mac (`where: mac`) a value is a
    /// server's data: only `[A-Za-z0-9._:/@%+=,-]`, and `open` takes only a web address. An input not filled in yet
    /// (the form's "…") is the form's to check.
    static func refusal(_ a: ToolAction, of p: ToolPreset, _ scope: ToolTemplate.Scope) -> String? {
        let run = a.run, mac = (run.where ?? p.where) == .mac, inputs = Dictionary((a.spec.inputs ?? []).map { ($0.info.name, $0) }) { x, _ in x }
        let texts = (run.command?.all ?? []) + [a.spec.edit].compactMap { $0 } + Array((p.env ?? [:]).values) + Array((run.env ?? [:]).values)
        for text in texts {
            for ph in ToolTemplate.placeholders(in: text) {
                let v = scope.value(ph.name)?.text ?? "", input = inputs[ph.name]
                if input != nil, v == "…" { continue }
                if let why = ToolTemplate.refusal(v, pattern: input?.info.pattern) { return "{\(ph.name)}: \(why)" }
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

    /// What the steps before a run came to (§7.2): its names with the form's values, and what runs; or why nothing does.
    enum Ready {
        case go(ToolTemplate.Scope, secret: Set<String>, willRun: String, payload: ToolPayload?)
        case stop(String)
    }

    /// The lock (not on this Mac), the form (its values, nil: Cancel), the values checked, the question (§7.3; `asked`:
    /// asked for several rows already) — over `window`. `values`: the form filled in so (Retry).
    func ready(_ a: ToolAction, of tool: LoadedTool, _ scope: ToolTemplate.Scope, row: String?, on t: SFTPTarget, asked: Bool, window: NSWindow?,
               values filled: [String: String]? = nil) async -> Ready {
        let p = tool.preset, verb = (a.spec.title ?? a.spec.id).replacingOccurrences(of: "…", with: "")
        let mac = (a.run.where ?? p.where) == .mac, sudo = (a.run.sudo ?? p.sudo ?? false) && !mac
        if !mac, await !ServerLock.authorize(t, "run “\(verb)” on") { return .stop("\(SavedServer.name(for: t.asUser)) stays locked") }
        var scope = scope
        if let inputs = a.spec.inputs, !inputs.isEmpty {
            guard let values = await form(a, of: tool, scope, on: t, window: window, values: filled) else { return .stop("cancelled") }
            scope.levels[0] = values.mapValues { .string($0) }
        }
        if let why = Self.refusal(a, of: p, scope) { return .stop(why) }
        let secret = Set((a.spec.inputs ?? []).filter { $0.info.type == .secret }.map(\.info.name))
        var willRun = a.spec.edit.map { "edit " + ToolTemplate.text($0, scope) } ?? "", payload: ToolPayload?
        if a.run.command != nil || a.run.script != nil {
            do {
                if a.spec.output == .terminal { willRun = try ToolPayload.terminal(a.run, in: p, scope: scope, scripts: tool.scripts).willRun }
                else { (payload, willRun) = try ToolPayload.of(a.run, in: p, scope: scope, scripts: tool.scripts, secret: secret) }
            } catch { return .stop("\(error)") }
        }
        let quietKey = ServerRow.key(t.asUser) + " " + p.id + " " + tool.hash
        let always = a.spec.dangerous == true || a.spec.confirm == true
        let prod = a.spec.readonly != true && payload != nil && SavedServer.isProd(t)   // `edit` asks as any file's save does
        guard !asked, always || prod && (quiet[quietKey] ?? .distantPast) < Date() else { return .go(scope, secret: secret, willRun: willRun, payload: payload) }
        let message = a.spec.message.map { ToolTemplate.text($0, scope) }
        switch await ask(a, verb: verb, row: row, on: t, mac: mac, sudo: sudo, willRun: willRun, payload: payload, message: message,
                         quietFor: always ? nil : SavedServer.name(for: t.asUser), window: window) {
        case nil: return .stop("cancelled")
        case let waved?:
            if waved { quiet[quietKey] = Date().addingTimeInterval(600) }
            return .go(scope, secret: secret, willRun: willRun, payload: payload)
        }
    }

    /// `a` of `tool` on `t`'s server, started on `row` of a list (`source`) — acting on it if `onRow`, else a tool's
    /// action — or from Tools ▸: §7.2's order — trust (asked where the tool opens), the lock, the form, the question,
    /// the run, how it went, the list read again unless it's `readonly`. `id`: the row that says it runs; a second
    /// press there waits. What to wait for: its run. `values`: its form filled in so (Retry).
    @discardableResult
    func perform(_ a: ToolAction, of tool: LoadedTool, row: ToolRow?, onRow: Bool, id: String, from source: ToolListSource?, on s: SavedServer,
                 _ t: SFTPTarget, asked: Bool = false, values: [String: String]? = nil) -> Task<Void, Never>? {
        let p = tool.preset, title = a.spec.title ?? a.spec.id, verb = title.replacingOccurrences(of: "…", with: "")
        guard trust.trusts(tool) else { app.active.flash("\(p.title) isn't in use yet: open it from Tools ▸ first", error: true); return nil }
        if let why = why(a, of: tool, row: row, onRow: onRow, id: id, on: s, t) {
            app.active.flash(why, error: true)
            return nil
        }
        if a.spec.long == true { return long(a, of: tool, row: onRow ? row : nil, id: id, from: source, on: s, t, asked: asked, values: values) }
        let rowScope = scope(p, on: s, t, rows: onRow ? row.map { [$0.record] } ?? [] : [])
        let mac = (a.run.where ?? p.where) == .mac, readonly = a.spec.readonly == true, sudo = (a.run.sudo ?? p.sudo ?? false) && !mac
        let place = mac ? "this Mac" : s.title, key = ServerRow.key(t.asUser) + " " + p.id, timeout = a.run.timeout ?? 30
        let rowTitle = onRow ? row?.title : nil
        if !readonly { changing[key] = title }

        let output = a.spec.output ?? (a.spec.edit != nil && a.run.command == nil && a.run.script == nil ? nil : .line)
        if output != .line && output != .silent {   // a window, a log, a terminal, the editor: theirs to show
            return Task {
                defer { if !readonly { changing[key] = nil } }
                let panel = app.active
                let r = await ready(a, of: tool, rowScope, row: rowTitle, on: t, asked: asked, window: nil, values: values)
                guard case let .go(scope, secret, _, payload) = r else {
                    if case .stop(let why) = r { panel.flash("\(verb): \(why) — nothing ran", error: why != "cancelled") }
                    return
                }
                switch output {
                case .follow?:
                    guard let payload else { return }
                    let password: String? = payload.sudo == .noPassword && ToolExec.wantsPassword(t) ? await Blocking.run { SFTP.sudoPassword?(t, false) } : nil
                    let p2 = password == nil ? payload : (try? Self.payloads(a.run, of: tool, scope, secret: secret).1) ?? payload
                    OutputWindow.follow(p2, password: password, on: mac ? .local() : t, title: "\(verb) — \(place)", cri: a.spec.strip == "cri")
                    AuditLog.write(t, "tool \(p.id) \(a.spec.id)", paths: [], command: p2.mask(p2.shown, password: password), exit: nil)
                case .terminal?:
                    guard let line = try? ToolPayload.terminal(a.run, in: p, scope: scope, scripts: tool.scripts).line else { return }
                    AuditLog.write(t, "tool \(p.id) \(a.spec.id)", paths: [], command: line, exit: nil)
                    app.openSSH(t.asUser, command: line)
                case .window?:
                    let env = SSHAskpass.env
                    let r = await panel.busy("\(verb) on \(place)…") { flag in try Self.exec(a.run, of: tool, scope, secret: secret, on: t, timeout: timeout, env: env, cancel: flag) }
                    _ = ran(r, a, of: p, on: t, shown: payload?.shown ?? "")
                    switch r {
                    case .success(let (ran, payload)):
                        OutputWindow.show(payload.mask(ran.text, password: ran.password), errors: ran.stopped ?? ran.errors, title: "\(verb) — \(place)",
                                          status: ran.status, ok: ran.stopped == nil && a.run.succeeded(ran.status), save: a.spec.save.map { ToolTemplate.text($0, scope) })
                    case .failure(is CancellationError): break
                    case .failure(is ToolExec.NoPassword): panel.flash("\(verb): no sudo password — nothing ran")
                    case .failure(let e): app.showError(e)
                    }
                default:   // `edit`: the file in the editor, as root if the tool is — history, checks and production as any file's
                    guard let path = a.spec.edit.map({ ToolTemplate.text($0, scope) }) else { return }
                    app.remoteOpen(.edit, t.asRoot(sudo), path, in: panel)
                }
            }
        }

        // The result line under the list, the list read again (§7.2), in the loop Services… changes go through.
        let verify = onRow && row != nil && (a.spec.verify ?? (a.spec.dangerous == true))
        let lister = p.list == nil ? nil : ToolListSource.lister(app, tool, s, t)
        let refresh = !readonly && a.spec.refresh != false
        var shown = ""
        var said = rowScope
        app.serviceRuns[id] = ""
        return Task {
            defer { if !readonly { changing[key] = nil } }
            await app.changeRow(id: id, shown: { shown }, on: t, busy: verb + "…", name: rowTitle ?? p.title, server: place,
                run: { window, panel, running in
                    let prepared = await self.ready(a, of: tool, rowScope, row: rowTitle, on: t, asked: asked, window: window, values: values)
                    guard case let .go(scope, secret, willRun, payload) = prepared, payload != nil else {
                        if case .stop(let why) = prepared { return .notRun(why) }
                        return .notRun("nothing to run")
                    }
                    (shown, said) = (willRun, scope)
                    running()
                    let env = SSHAskpass.env, rowKey = row?.key, record = row?.record
                    let r = await panel.busy("\(verb) on \(place)…") { flag in
                        if verify, let lister, let rowKey {   // the row as it was asked about, field for field, or nothing runs
                            guard try lister.read(env, flag, header: false).current(rowKey) == record else { throw Changed() }
                        }
                        return try Self.exec(a.run, of: tool, scope, secret: secret, on: t, timeout: timeout, env: env, cancel: flag)
                    }
                    if !readonly { self.changing[key] = nil }   // done: reading the list again isn't the change
                    return self.ran(r, a, of: p, on: t, shown: payload?.shown ?? "")
                },
                read: refresh ? lister.map { l in { env, flag in try l.read(env, flag) } } : nil,
                show: { list, read in
                    guard let source else { return }
                    if let read { list.reload(source.show(read), having: id) } else if let row { list.update(source.item(row)) }
                },
                say: { how, _, error, time in self.line(how, a, said, place: place, at: time, readError: error, facts: self.answer(t)?.answer.facts) })
        }
    }

    /// A long job (§7.6): asked as any run, then started on the server — the start comes back at once — and Activity's
    /// from then on: the row spins till it ends, the line under the list says it started (and later how it went). The
    /// tool isn't busy with it: one more of the same action on the same row says it runs, with Activity showing it.
    private func long(_ a: ToolAction, of tool: LoadedTool, row: ToolRow?, id: String, from source: ToolListSource?, on s: SavedServer,
                      _ t: SFTPTarget, asked: Bool, values filled: [String: String]?) -> Task<Void, Never>? {
        let p = tool.preset, title = a.spec.title ?? a.spec.id, verb = title.replacingOccurrences(of: "…", with: "")
        if let j = jobs.running(rowID: id) {
            app.active.flash("\(j.name) is already running on \(s.title) — Activity (⌥⌘J) follows it")
            app.ops?.showActivity(entry: nil)
            return nil
        }
        let rowScope = scope(p, on: s, t, rows: row.map { [$0.record] } ?? []), key = ServerRow.key(t.asUser) + " " + p.id
        let root = a.run.sudo ?? p.sudo ?? false, output = a.spec.output
        changing[key] = title
        var shown = "", said = rowScope
        app.serviceRuns[id] = ""
        return Task {
            defer { changing[key] = nil }
            await app.changeRow(id: id, shown: { shown }, on: t, busy: verb + "…", name: row?.title ?? p.title, server: s.title,
                run: { window, panel, running in
                    let prepared = await self.ready(a, of: tool, rowScope, row: row?.title, on: t, asked: asked, window: window, values: filled)
                    guard case let .go(scope, secret, willRun, _) = prepared,
                          let job = try? ToolPayload.of(a.run, in: p, scope: scope, scripts: tool.scripts, secret: secret, detached: true).payload else {
                        if case .stop(let why) = prepared { return .notRun(why) }
                        return .notRun("nothing to run")
                    }
                    (shown, said) = (willRun, scope)
                    running()
                    self.jobs.askToNotify()   // the first long job: macOS's question, at a moment you started something
                    let jobID = ToolLong.newID(), env = SSHAskpass.env, command = Self.command, sudo = Self.sudoProgram
                    let r = await panel.busy("Starting \(verb) on \(s.title)…") { flag in
                        let ran = try ToolLong.run(root: root, on: t, cancel: flag, env: env, command: command) { ToolLong.start(job, id: jobID, root: $0, sudoProgram: sudo) }
                        return (ran: ran, payload: ToolLong.start(job, id: jobID, root: root ? .noPassword : .none, sudoProgram: sudo))   // logged: no password in it
                    }
                    self.changing[key] = nil
                    let said = self.ran(r, a, of: p, on: t, shown: willRun)
                    guard case .success(let (ran, _)) = r, ran.status == 0, let pid = Int32(ran.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return said }
                    let inputs = Set((a.spec.inputs ?? []).map(\.info.name)).subtracting(secret)
                    self.jobs.add(ToolJob(id: jobID, server: self.app.savedServer(at: t)?.id.uuidString ?? "", target: t.asUser, place: s.title, tool: p.id,
                                          action: a.spec.id, title: title, row: row?.title, rowID: id, record: row?.record,
                                          values: scope.levels[0].filter { inputs.contains($0.key) }.mapValues(\.text), root: root, pid: pid, started: Date(),
                                          skew: ran.skew), payload: job, show: output == .window || output == .follow)
                    return said
                },
                read: nil as (@Sendable ([String: String], CancelFlag) throws -> Bool)?,
                show: { _, _ in self.jobs.spin(id) },
                say: { how, _, _, time in
                    if case .passed = how { return (.ok, "\(verb): started on \(s.title) at \(time) — it runs on there; Activity (⌥⌘J) follows it") }
                    return self.line(how, a, said, place: s.title, at: time, readError: nil, facts: self.answer(t)?.answer.facts)
                })
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
            if ran.status == 127 { askAgain(t) }   // its requires again on the next look
            let output = payload.mask([ran.errors, ran.text].filter { !$0.isEmpty }.joined(separator: "\n"), password: ran.password)
            return .ran(.success(.failed(status: ran.status, output: output)))
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
}
