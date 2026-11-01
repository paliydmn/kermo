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
    /// Where you use each tool, hidden on which server, its vars' values there (`tools/servers.json`).
    var settings = ToolServers()
    /// What each server (`ServerRow.key`) said this session, and when: its facts, the tools and actions it has.
    private(set) var answers: [String: (answer: ToolBatch.Answer, at: Date)] = [:]
    /// The last answers of saved servers (`SavedServer.id`), kept in `tools/known.json`: Tools ▸ shows a server's tools
    /// greyed while it isn't connected. A cache, not a setting: deleting it costs a batch on the next connection.
    private var known: [String: Known] = [:]
    struct Known: Codable { var facts: ToolFacts; var passed: [String]; var asked: [String]?; var at: Date }
    private var asking: Set<String> = []
    /// Bumped as every answer goes (a reload, a tool trusted): a look under way then asked of the tools as they were.
    private var round = 0
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
    /// Watching (§8): the streams and polls of watched tools and open tabs, their series, alerts and events.
    private(set) lazy var monitor = ToolMonitor(app)

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
        (answers, found, versions, round) = ([:], [:], [:], round + 1)   // a changed tool's requires: asked again
        trust = Self.own.flatMap { try? Config.load("trust.json", as: ToolTrust.self, in: $0.path) } ?? ToolTrust()
        known = Self.own.flatMap { try? Config.load("known.json", as: [String: Known].self, in: $0.path) } ?? [:]
        let read = Self.own.map { Config.loadKeeping("servers.json", as: ToolServers.self, in: $0.path) }
        settings = read?.value ?? ToolServers()
        monitor.reconcile()   // watched servers, as the file says now (at launch: watching resumes by itself)
        ToolsWindow.refresh()
        return library.problems + [read?.problem.map { "tools/" + $0 }].compactMap { $0 }
    }

    func saveSettings() {
        if let dir = Self.own?.path { Config.save("servers.json", settings, in: dir) }
    }

    /// A saved server's id, as `tools/servers.json` and `known.json` have it; nil: not saved (no settings).
    func serverID(_ t: SFTPTarget) -> String? { app.savedServer(at: t)?.id.uuidString }

    /// The tools `t`'s server shows, as last known (nil: not known yet): those it has that you use there — Use on
    /// Servers…, Hide. One that asks for a value (`vars.ask`) only on a saved server: the value is kept with it, and
    /// `toSetUp` says what's still to set. One that checks the server's addresses (Sites) only on a saved server: they
    /// are kept with it (Edit Server), and its tab says when there are none yet — always last, not a server's first.
    /// Tools ▸, a place's rows (the search's too) and the Tools window show this.
    func here(_ t: SFTPTarget) -> (tools: [LoadedTool], at: Date)? {
        guard let a = answer(t) else { return nil }
        let saved = app.savedServer(at: t), id = saved?.id.uuidString
        let shown = tools.filter { a.answer.has($0.preset) && settings.uses($0.preset.id, on: id) && (id != nil || $0.preset.varsToAsk(saved: [:]).isEmpty)
                && ($0.preset.http == nil || saved != nil) }
        return (shown.filter { $0.preset.http == nil } + shown.filter { $0.preset.http != nil }, a.at)   // Watch… is System's, the tabs keep their ⌘ numbers
    }

    /// The values `tool` asks for that aren't set on `t`'s server yet: Set Up… before it's used there.
    func toSetUp(_ tool: LoadedTool, on t: SFTPTarget) -> [String] {
        tool.preset.varsToAsk(saved: settings.vars(tool.preset.id, on: serverID(t)))
    }

    /// The tools this version shows: trusted, a list read by a command, a script or its files, a command of their own, or actions
    /// with no list (a launcher) this version runs. Which a server shows: `here`.
    var tools: [LoadedTool] { library.trusted(trust).filter(Self.shows) }
    /// Your own tools not trusted yet, or changed since: Tools ▸ offers them, asking first.
    var untrusted: [LoadedTool] { library.tools.filter { !trust.trusts($0) && Self.shows($0) } }

    static func shows(_ t: LoadedTool) -> Bool {
        let p = t.preset
        if p.watchable { return true }   // watched, or live on its tab (PR 5)
        return p.list.map { $0.run.command != nil || $0.run.script != nil || $0.run.files != nil } ?? p.commandAction.map { runs($0, of: p) }
            ?? p.toolActions?.contains { runs($0, of: p) } ?? false
    }

    /// What this version runs of an action: a command, a script, an `edit`, an `open` (a server path in the panel) or
    /// a `goto` (a place in Kermo); a form of text, secrets and choices; output as a line, a window, a log that
    /// follows, a terminal, rows one level down or nothing; a long job (Activity's).
    /// ponytail: `accepts` (PR 9) and a terminal on this Mac are left out till then; `check` (Check Now) is the
    /// watching's own (`ToolsTable`).
    static func runs(_ a: ToolAction, of p: ToolPreset) -> Bool {
        (a.run.command != nil || a.run.script != nil || a.spec.edit != nil || a.spec.open != nil || a.spec.goto != nil)
            && a.spec.accepts == nil && a.spec.check == nil
            && !(a.spec.output == .terminal && (a.run.where ?? p.where) == .mac)
    }

    /// A look (§3.3): the preset says `readonly`, or the action goes somewhere in Kermo (`goto`) or shows a path it
    /// already has (`open` with no command) — nothing runs on the server, so no question and no "one change at a time".
    static func looks(_ a: ToolAction) -> Bool {
        a.spec.readonly == true || a.spec.goto != nil || (a.spec.open != nil && a.run.command == nil && a.run.script == nil)
    }

    /// `goto` (§7.1): where in Kermo an action or an event goes.
    enum Goto: Equatable {
        case services(unit: String?), containers(name: String?), ssh

        /// As a button says it.
        var title: String { switch self { case .services: "Services…"; case .containers: "Containers…"; case .ssh: "Terminal" } }

        init?(_ s: String) {
            let parts = s.split(separator: ":", maxSplits: 1).map(String.init), rest = parts.count > 1 ? parts[1] : nil
            switch parts.first {
            case "services": self = .services(unit: rest)
            case "containers": self = .containers(name: rest)
            case "ssh": self = .ssh
            default: return nil
            }
        }
    }

    /// There: Services… or Containers… of `t`'s server in the search, on the row named; an SSH tab. As any look, a
    /// locked server asks first (the lists do; the terminal's login does).
    func go(_ g: Goto, on t: SFTPTarget) {
        app.showMainWindow(nil)
        let s = app.savedServer(at: t) ?? SavedServer(target: t.asUser), key = ServerRow.key(t.asUser)
        switch g {
        case .services(let unit): app.showInSearch(ServiceList(app, s, t.asUser), select: unit.map { key + " " + $0 })
        case .containers(let name): app.showInSearch(ContainerList(app, s, t.asUser), select: name.map { key + " container " + $0 })
        case .ssh: app.openSSH(t.asUser)
        }
    }

    /// Tests: a server path shown in the active panel — the folder, or a file's folder with the file under the cursor.
    nonisolated(unsafe) static var reveal: @MainActor (AppDelegate, SFTPTarget, String) -> Void = { app, t, path in
        app.showMainWindow(nil)
        app.showPanels()
        let panel = app.active
        panel.loadRemote(t.asUser, dir: path, select: nil) { [weak panel] _ in
            panel?.loadRemote(t.asUser, dir: (path as NSString).deletingLastPathComponent, select: (path as NSString).lastPathComponent)
        }
    }

    // MARK: What a server has

    /// What `t`'s server has, as last asked; nil: not yet. The first look asks — off the main thread, in one batch with
    /// the facts, over a connection that's up: never a login for it (§10.5). Till then, a saved server's last answer.
    func answer(_ t: SFTPTarget) -> (answer: ToolBatch.Answer, at: Date)? {
        let key = ServerRow.key(t.asUser)
        if answers[key] == nil, AppDelegate.connected(t.asUser) { ask(t.asUser) }
        if let a = answers[key] { return a }
        return app.savedServer(at: t).flatMap { known[$0.id.uuidString] }.map { (ToolBatch.Answer(facts: $0.facts, passed: Set($0.passed), asked: $0.asked.map(Set.init)), $0.at) }
    }

    /// `t`'s server asked again on its next look (a tool just trusted, a program gone: exit 127).
    func askAgain(_ t: SFTPTarget) { answers[ServerRow.key(t.asUser)] = nil }
    /// Every server: a tool just trusted wasn't asked about anywhere.
    func askAgain() { (answers, round) = ([:], round + 1) }

    private func ask(_ t: SFTPTarget) {
        let key = ServerRow.key(t), tools = tools
        guard !tools.isEmpty, asking.insert(key).inserted else { return }
        let s = app.savedServer(at: t) ?? SavedServer(target: t)
        let scopes = Dictionary(tools.map { ($0.preset.id, scope($0.preset, on: s, t)) }) { a, _ in a }
        let scripts = Dictionary(tools.map { ($0.preset.id, $0.scripts) }) { a, _ in a }
        let items = ToolBatch.items(tools.map(\.preset)), command = Self.command, live = Self.hasMaster
        let r = round
        Task {
            let a = await Blocking.run { ToolBatch.ask(t, items, scope: { scopes[$0] ?? .init() }, scripts: { scripts[$0] ?? [:] }, hasMaster: live, command: command) }
            asking.remove(key)
            guard r == round else { return app.toolsKnown(on: t) }   // stale: the next look asks anew
            guard let a else { return }
            answers[key] = (a, Date())
            if let id = app.savedServer(at: t)?.id.uuidString, let dir = Self.own?.path {
                known[id] = Known(facts: a.facts, passed: a.passed.sorted(), asked: a.asked?.sorted(), at: Date())
                Config.save("known.json", known, in: dir)
            }
            app.toolsKnown(on: t)
        }
    }

    /// The names a tool's templates have on a server (§5.3) besides the row's: its vars, then Kermo's own.
    func scope(_ p: ToolPreset, on s: SavedServer, _ t: SFTPTarget, rows: [ToolRecord] = []) -> ToolTemplate.Scope {
        let key = ServerRow.key(t.asUser)
        var kermo: [String: ToolValue] = ["server": .string(s.title), "host": .string(s.host), "user": .string(s.user ?? "")]
        if let every = p.watch?.every { kermo["every"] = .number(every) }   // a stream's `{every}`
        if let f = answers[key]?.answer.facts { kermo.merge(f.names) { $1 } }
        return .init(rows: rows, vars: p.varValues(saved: settings.vars(p.id, on: serverID(t)), found: found[key + " " + p.id] ?? [:]), kermo: kermo)
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
        if !Self.looks(a) {
            if s.readOnly { return "\(s.title) is read-only: Tools run only actions that change nothing there" }
            let name = row?.title ?? p.title
            if let busy = app.serviceRuns[id] { return busy.isEmpty ? "\(name): one change at a time — another is being asked" : "\(name): \(busy.dropLast()) runs on it — wait for it" }
            if let other = changing[ServerRow.key(t.asUser) + " " + p.id] { return "\(p.title) on \(s.title) is busy: \(other.replacingOccurrences(of: "…", with: ""))" }
        }
        var scope = scope(p, on: s, t, rows: onRow ? row?.records ?? [] : [])
        scope.levels[0] = Dictionary((a.spec.inputs ?? []).map { ($0.info.name, ToolValue.string("…")) }) { x, _ in x }   // the form fills them
        if let why = Self.refusal(a, of: p, scope) { return "\(title): \(why) — nothing runs" }
        if a.run.command != nil || a.run.script != nil {
            do { _ = try ToolPayload.of(a.run, in: p, scope: scope, scripts: tool.scripts) } catch { return "\(title): \(error) — nothing runs" }
        }
        return nil
    }

    /// Why a value can't go into `a`'s command (or its `edit` path), or nil: it begins with `-`, holds a line break or a
    /// control character (§3.2 rule 5) — an input's `pattern` may allow it. On this Mac (`where: mac`) a value is a
    /// server's data: only `[A-Za-z0-9._:/@%+=,-]` — a web address standing as one word (`"$K_x"`, not inside the
    /// author's quotes, where a nested shell would read it) its query and fragment too (`?&#~`) — and `open` takes only
    /// a web address. An input not filled in yet
    /// (the form's "…") is the form's to check.
    static func refusal(_ a: ToolAction, of p: ToolPreset, _ scope: ToolTemplate.Scope) -> String? {
        let run = a.run, mac = (run.where ?? p.where) == .mac, inputs = Dictionary((a.spec.inputs ?? []).map { ($0.info.name, $0) }) { x, _ in x }
        let texts = (run.command?.all ?? []) + [a.spec.edit, a.spec.open].compactMap { $0 } + Array((p.env ?? [:]).values) + Array((run.env ?? [:]).values)
        for text in texts {
            let quote = ToolTemplate.quotes(in: text)
            for ph in ToolTemplate.placeholders(in: text) {
                let v = scope.value(ph.name)?.text ?? "", input = inputs[ph.name]
                if input != nil, v == "…" { continue }
                if ph.name == "stdout", text == a.spec.open { continue }   // the command's output: checked once it's there
                if let why = ToolTemplate.refusal(v, pattern: input?.info.pattern) { return "{\(ph.name)}: \(why)" }
                guard mac else { continue }
                let safe = "._:/@%+=,-" + (quote(ph.range.lowerBound) == .bare && ToolHTTPCheck.valid(v) ? "?&#~" : "")
                if !v.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || safe.unicodeScalars.contains($0)) }) {
                    return "{\(ph.name)}: “\(v)” has characters this Mac won't put into a command"
                }
                if (run.command?.all.first ?? "").hasPrefix("open"), !(v.hasPrefix("http://") || v.hasPrefix("https://")) {
                    return "{\(ph.name)}: open takes only http:// and https:// addresses"
                }
            }
        }
        return nil
    }

    /// What the steps before a run came to (§7.2): its names with the form's values, what runs, what's uploaded first;
    /// or why nothing does.
    enum Ready {
        case go(ToolTemplate.Scope, secret: Set<String>, willRun: String, payload: ToolPayload?, uploads: [Upload])
        case stop(String)
    }

    /// A `folder` or `file` input (§7.4): the choice on this Mac, and where it goes on the server — its value there.
    struct Upload {
        let input: String, local: String, remote: String, folder: Bool
        /// A git repository `pack` archives as committed, and how many changes in it aren't (they stay here).
        var repository = false, uncommitted = 0
        /// As the question says it: what of it goes.
        var said: String {
            guard folder else { return "Uploads \(local) first." }
            guard repository else { return "Uploads \(local) first, without .git, node_modules and .DS_Store." }
            let n = uncommitted == 1 ? "1 change" : "\(uncommitted) changes"
            return "Uploads \(local) as committed (git archive HEAD)." + (uncommitted == 0 ? "" : " ⚠ \(n) not committed stay here.")
        }
    }

    /// The lock (not on this Mac), the form (its values, nil: Cancel), the values checked, the question (§7.3; `asked`:
    /// asked for several rows already) — over `window`. `values`: the form filled in so (Retry), else the folders and
    /// files last chosen there (`remember`). `job`: a long job's id — what runs is its start then (`ToolLong.start`),
    /// as Show Exactly What Runs shows it, and a folder or a file its upload's path.
    func ready(_ a: ToolAction, of tool: LoadedTool, _ scope: ToolTemplate.Scope, row: String?, on t: SFTPTarget, asked: Bool, window: NSWindow?,
               values filled: [String: String]? = nil, job: String? = nil) async -> Ready {
        let p = tool.preset, verb = (a.spec.title ?? a.spec.id).replacingOccurrences(of: "…", with: "")
        let mac = (a.run.where ?? p.where) == .mac, sudo = (a.run.sudo ?? p.sudo ?? false) && !mac
        if !mac, await !ServerLock.authorize(t, "run “\(verb)” on") { return .stop("\(SavedServer.name(for: t.asUser)) stays locked") }
        var scope = scope, uploads: [Upload] = []
        if let inputs = a.spec.inputs, !inputs.isEmpty {
            let kept = settings.remembered(p.id, on: serverID(t), row: row)
            guard let values = await form(a, of: tool, scope, on: t, window: window, values: filled ?? (kept.isEmpty ? nil : kept), job: job) else { return .stop("cancelled") }
            scope.levels[0] = values.mapValues { .string($0) }
            let chosen = values.filter { name, _ in inputs.contains { $0.info.name == name && $0.info.remember == true } }
            if let id = serverID(t), !chosen.isEmpty {
                settings.remember(p.id, on: id, row: row, chosen)
                saveSettings()
            }
            // Where each goes: under the home folder, by its path from `/` — a command may `cd` (§3.2 rule 10).
            var home: String?
            for i in inputs where i.uploads {
                guard let job, let typed = values[i.info.name], !typed.isEmpty else { continue }   // an optional one left empty drops out
                if home == nil {
                    let env = SSHAskpass.env
                    do { home = try await Blocking.run { try SFTP.home(t.asUser, env: env) } } catch {
                        return .stop("the home folder on \(SavedServer.name(for: t.asUser)), where uploads go, can't be read: \(error.localizedDescription)")
                    }
                }
                let local = (typed as NSString).expandingTildeInPath, folder = i.info.type == .folder
                var u = Upload(input: i.info.name, local: local, remote: home! + "/" + ToolLong.upload(job, i, local: local), folder: folder)
                if folder {
                    (u.repository, u.uncommitted) = await Blocking.run {
                        ArchiveIndex.isRepository(local) ? (true, GitStatus.load(local)?.changes.count ?? 0) : (false, 0)
                    }
                }
                uploads.append(u)
                scope.levels[0][i.info.name] = .string(u.remote)
            }
        }
        if let why = Self.refusal(a, of: p, scope) { return .stop(why) }
        let secret = Set((a.spec.inputs ?? []).filter { $0.info.type == .secret }.map(\.info.name))
        var willRun = a.spec.edit.map { "edit " + ToolTemplate.text($0, scope) } ?? "", payload: ToolPayload?
        if a.run.command != nil || a.run.script != nil {
            do {
                if a.spec.output == .terminal { willRun = try ToolPayload.terminal(a.run, in: p, scope: scope, scripts: tool.scripts).willRun }
                else { (payload, willRun) = try ToolPayload.of(a.run, in: p, scope: scope, scripts: tool.scripts, secret: secret) }
                if let job {
                    let detached = try ToolPayload.of(a.run, in: p, scope: scope, scripts: tool.scripts, secret: secret, detached: true).payload
                    payload = ToolLong.start(detached, id: job, root: sudo ? .noPassword : .none, sudoProgram: Self.sudoProgram)
                }
            } catch { return .stop("\(error)") }
        }
        let quietKey = ServerRow.key(t.asUser) + " " + p.id + " " + tool.hash
        let always = a.spec.dangerous == true || a.spec.confirm == true
        let prod = a.spec.readonly != true && payload != nil && SavedServer.isProd(t)   // `edit` asks as any file's save does
        guard !asked, always || prod && (quiet[quietKey] ?? .distantPast) < Date() else { return .go(scope, secret: secret, willRun: willRun, payload: payload, uploads: uploads) }
        let notes = ([a.spec.message.map { ToolTemplate.text($0, scope) }] + uploads.map(\.said)).compactMap { $0 }
        let message = notes.isEmpty ? nil : notes.joined(separator: "\n\n")
        switch await ask(a, verb: verb, row: row, on: t, mac: mac, sudo: sudo, willRun: willRun, payload: payload, message: message,
                         quietFor: always ? nil : SavedServer.name(for: t.asUser), window: window) {
        case nil: return .stop("cancelled")
        case let waved?:
            if waved { quiet[quietKey] = Date().addingTimeInterval(600) }
            return .go(scope, secret: secret, willRun: willRun, payload: payload, uploads: uploads)
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
        if a.spec.output == .list {   // one level down (§7.5): its read is its run — the lock, the form, the question
            show(ToolListSource(app, tool, s, t, level: .init(action: a, row: onRow ? row : nil, parent: source ?? ToolListSource(app, tool, s, t))), from: id)
            return nil
        }
        let rowScope = scope(p, on: s, t, rows: onRow ? row?.records ?? [] : [])
        let mac = (a.run.where ?? p.where) == .mac, readonly = Self.looks(a), sudo = (a.run.sudo ?? p.sudo ?? false) && !mac
        let place = mac ? "this Mac" : s.title, key = ServerRow.key(t.asUser) + " " + p.id, timeout = a.run.timeout ?? 30
        let rowTitle = onRow ? row?.title : nil
        if !readonly { changing[key] = title }

        if a.spec.goto != nil || a.spec.open != nil {   // a place in Kermo, a server path in the panel: no list read again
            return Task {
                defer { if !readonly { changing[key] = nil } }
                await openOrGo(a, of: tool, rowScope, row: rowTitle, id: id, on: t, asked: asked, values: values, timeout: timeout, place: place)
            }
        }

        let output = a.spec.output ?? (a.spec.edit != nil && a.run.command == nil && a.run.script == nil ? nil : .line)
        if output != .line && output != .silent {   // a window, a log, a terminal, the editor: theirs to show
            let lists = app.rowLists(id)   // a Tools window's button: its question over that window, what stopped it on its page
            return Task {
                defer { if !readonly { changing[key] = nil } }
                let panel = app.active
                let r = await ready(a, of: tool, rowScope, row: rowTitle, on: t, asked: asked, window: lists.first?.sheetWindow, values: values)
                guard case let .go(scope, secret, _, payload, _) = r else {
                    if case .stop(let why) = r { say("\(verb): \(why) — nothing ran", to: lists, about: id, failed: why != "cancelled") }
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
                    case .failure(is ToolExec.NoPassword): say("\(verb): no sudo password — nothing ran", to: lists, about: id, failed: false)
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
        let lister = source.map(\.relister) ?? (p.list == nil ? nil : ToolListSource.lister(app, tool, s, t))
        if verify, lister == nil, source?.level != nil {   // reading this level again would run its change: nothing to check the row by
            say("\(title): \(rowTitle ?? p.title) can't be checked again here — reading this list changes something; nothing ran", to: app.rowLists(id), about: id, failed: true)
            if !readonly { changing[key] = nil }
            return nil
        }
        let refresh = !readonly && a.spec.refresh != false
        var shown = ""
        var said = rowScope
        app.serviceRuns[id] = ""
        return Task {
            defer { if !readonly { changing[key] = nil } }
            await app.changeRow(id: id, shown: { shown }, on: t, busy: verb + "…", name: rowTitle ?? p.title, server: place,
                run: { window, panel, running in
                    let prepared = await self.ready(a, of: tool, rowScope, row: rowTitle, on: t, asked: asked, window: window, values: values)
                    guard case let .go(scope, secret, willRun, payload, _) = prepared, payload != nil else {
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

    /// A level where its action was pressed (§7.5): a Picker goes into it, a panel shows it in place of its list; from
    /// a dashboard's table — the Tools window — or Tools ▸, a Picker of its own over that window, the level its first.
    private func show(_ level: ToolListSource, from id: String) {
        let list = app.rowLists(id).first
        if let p = list as? Picker { return p.go(into: level) }
        if let l = list as? ListPanel, let panel = app.panels.first(where: { $0.list === l }) { return panel.showList(level) }
        Picker.show(over: (list as? ToolsPage)?.window ?? app.window, level,
                    scope: ("\(SavedServer.name(for: level.target)) › " + level.trail.joined(separator: " › "), Chip.of(level.target))) { [app] s, q, id, rows in
            app.showMainWindow(nil)   // ⌘↩: that level in the main window's other panel, the keys there
            app.openInOther(s, query: q, select: id, rows: rows)
        }
    }

    /// `goto`: there, after the lock. `open`: the server path — the command's first output line as `{stdout}`, else the
    /// template over the row — in the active panel, after the lock and the question as any run's. What went wrong
    /// is said under the list or page that has the row (a Tools window's table), else where the panel is.
    private func openOrGo(_ a: ToolAction, of tool: LoadedTool, _ scope: ToolTemplate.Scope, row: String?, id: String, on t: SFTPTarget, asked: Bool,
                          values: [String: String]?, timeout: Double, place: String) async {
        let p = tool.preset, verb = (a.spec.title ?? a.spec.id).replacingOccurrences(of: "…", with: ""), panel = app.active
        let lists = app.rowLists(id)
        func tell(_ text: String, failed: Bool) { say(text, to: lists, about: id, failed: failed) }
        let r = await ready(a, of: tool, scope, row: row, on: t, asked: asked, window: lists.first?.sheetWindow, values: values)
        let facts = answer(t)?.answer.facts, when = Date().formatted(date: .omitted, time: .shortened)
        guard case .go(let scope, let secret, _, let payload, _) = r else {
            if case .stop(let why) = r { tell(line(.notRun(why), a, scope, place: place, at: when, readError: nil, facts: facts).line, failed: why != "cancelled") }
            return
        }
        if let g = a.spec.goto {
            guard let there = Goto(ToolTemplate.text(g, scope)) else { return tell("\(verb): Kermo has no place “\(g)”", failed: true) }
            return go(there, on: t)
        }
        var names = scope
        if let payload {   // the path is what the command prints
            let env = SSHAskpass.env
            let r = await panel.busy("\(verb) on \(place)…") { flag in try Self.exec(a.run, of: tool, scope, secret: secret, on: t, timeout: timeout, env: env, cancel: flag) }
            let (how, _) = AppDelegate.how(ran(r, a, of: p, on: t, shown: payload.shown))
            guard case .passed = how else {
                if case .unknown = how { return }
                return tell(line(how, a, scope, place: place, at: when, readError: nil, facts: facts).line, failed: true)
            }
            if case .success(let (ran, _)) = r { names.levels[0]["stdout"] = .string(ran.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "") }
        }
        let path = ToolTemplate.text(a.spec.open ?? "", names)
        guard path.hasPrefix("/"), ToolTemplate.refusal(path) == nil else { return tell("\(verb): “\(path)” isn't a path on \(place)", failed: true) }
        tell("\(verb): \(path) in the panel", failed: false)
        Self.reveal(app, t, path)
    }

    /// What stopped a run, or how it went, said where it was pressed — each list or page with its row — else in the
    /// active panel.
    private func say(_ text: String, to lists: [any RowList], about id: String, failed: Bool) {
        guard !lists.isEmpty else { return app.active.flash(text, error: failed) }
        let said = NSAttributedString(string: text, attributes: [.foregroundColor: failed ? Palette.fail : NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12)])
        lists.forEach { $0.said(said, about: id, failed: failed, output: nil) }
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
        let rowScope = scope(p, on: s, t, rows: row?.records ?? []), key = ServerRow.key(t.asUser) + " " + p.id
        let root = a.run.sudo ?? p.sudo ?? false, output = a.spec.output, jobID = ToolLong.newID()
        changing[key] = title
        var shown = "", said = rowScope, held = true   // held: this one's mark, till it goes ahead (another may hold one then)
        app.serviceRuns[id] = ""
        return Task {
            defer { if held { changing[key] = nil } }
            await app.changeRow(id: id, shown: { shown }, on: t, busy: verb + "…", name: row?.title ?? p.title, server: s.title,
                run: { window, panel, running in
                    let prepared = await self.ready(a, of: tool, rowScope, row: row?.title, on: t, asked: asked, window: window, values: filled, job: jobID)
                    guard case let .go(scope, secret, willRun, _, uploads) = prepared,
                          let job = try? ToolPayload.of(a.run, in: p, scope: scope, scripts: tool.scripts, secret: secret, detached: true).payload else {
                        if case .stop(let why) = prepared { return .notRun(why) }
                        return .notRun("nothing to run")
                    }
                    (shown, said) = (willRun, scope)
                    running()
                    (self.changing[key], held) = (nil, false)   // asked: an upload doesn't keep the tool's other changes waiting
                    if let why = await self.upload(uploads, to: t, place: s.title) { return .notRun(why) }
                    self.jobs.askToNotify()   // the first long job: macOS's question, at a moment you started something
                    let env = SSHAskpass.env, command = Self.command, sudo = Self.sudoProgram
                    let r = await panel.busy("Starting \(verb) on \(s.title)…") { flag in
                        let ran = try ToolLong.run(root: root, on: t, cancel: flag, env: env, command: command) { ToolLong.start(job, id: jobID, root: $0, sudoProgram: sudo) }
                        return (ran: ran, payload: ToolLong.start(job, id: jobID, root: root ? .noPassword : .none, sudoProgram: sudo))   // logged: no password in it
                    }
                    let said = self.ran(r, a, of: p, on: t, shown: willRun)
                    guard case .success(let (ran, _)) = r, ran.status == 0, let pid = Int32(ran.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return said }
                    let inputs = Set((a.spec.inputs ?? []).map(\.info.name)).subtracting(secret)
                    self.jobs.add(ToolJob(id: jobID, server: self.app.savedServer(at: t)?.id.uuidString ?? "", target: t.asUser, place: s.title, tool: p.id,
                                          action: a.spec.id, title: title, row: row?.title, rowID: id, record: row?.record,
                                          values: scope.levels[0].filter { inputs.contains($0.key) }.mapValues(\.text)
                                            .merging(uploads.map { ($0.input, $0.local) }) { $1 }, root: root, pid: pid, started: Date(),
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

    /// `folder` and `file` inputs onto the server before their job starts (§7.2 step 5), through the copy queue —
    /// Activity shows each — a folder packed on this Mac first (`ArchiveIndex.pack`). A copy keeps a file's own time:
    /// a file's is set to now, so a week's sweep (`ToolLong.start`) never takes one older than that. Why not, or nil.
    /// ponytail: packing and the folder's making aren't cancellable (⎋ waits for them); the copy is, in Activity.
    private func upload(_ uploads: [Upload], to t: SFTPTarget, place: String) async -> String? {
        guard let first = uploads.first else { return nil }
        let env = SSHAskpass.env, target = t.asUser, folder = (first.remote as NSString).deletingLastPathComponent
        do { try await Blocking.run { try SFTP.session(target, env: env, cancel: nil, on: nil) { try $0.makeDirectories(folder, mode: 0o700) } } } catch {
            return "nothing was uploaded: \(error.localizedDescription)"
        }
        for u in uploads {
            let name = (u.local as NSString).lastPathComponent
            let packed = u.folder ? (NSTemporaryDirectory() as NSString).appendingPathComponent("kermo-" + (u.remote as NSString).lastPathComponent) : nil
            defer { if let packed { try? FileManager.default.removeItem(atPath: packed) } }
            if let packed {
                do { try await Blocking.run { try ArchiveIndex.pack(u.local, to: packed) } } catch { return "\(name) wasn't uploaded: \(error.localizedDescription)" }
            }
            let job = FileJob(copyPairs: [(packed ?? u.local, u.remote)], from: .local, to: .sftp(target), sshEnv: env)
            if let ops = app.ops {
                await withCheckedContinuation { done in ops.enqueue(job, title: "Upload \(name) to \(place)") { _ in done.resume() } }
            } else {
                await Blocking.run { job.run() }
            }
            let p = job.progress
            guard p.state == .done, p.failed.isEmpty else {
                return p.errors.first.map { "\(name) wasn't uploaded: \($0)" } ?? (job.isCancelled ? "cancelled" : "\(name) wasn't uploaded")
            }
            if !u.folder {
                let now = Date().timeIntervalSince1970
                do { try await Blocking.run { try SFTP.session(target, env: env, cancel: nil, on: nil) { try $0.setAttrs(u.remote, mtime: now, mode: nil) } } } catch {
                    return "\(name) was uploaded, but its time couldn't be set (a week's sweep might take it): \(error.localizedDescription)"
                }
            }
        }
        return nil
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
