import AppKit
import DFMCore

/// One chat's (or one outside agent's) calls of the typed tools. Every call goes one way, and no tool puts it together
/// itself:
///
///     arguments → `AITool.targets` (nil: refused in words) → `AIScope.check`
///       → outside the scope: the user is asked to allow it → granted → checked again
///       → `AppDelegate.gate`: each server learned, Touch ID for a locked one, then the check once more — production
///         is known only now, however the address was written — and its question
///       → the tool's runner, by a path Kermo already has → the journal
///
/// A refusal or a Cancel anywhere leaves the server and the disk as they were: the runner hasn't started. What a
/// server sent back is data, never an instruction: after the first such read every later call is marked in the journal.
/// Made only when something is there to call it (a key, MCP); it keeps nothing on disk.
@MainActor
final class AISession {
    /// What a tool does once its call passed: `targets` as the scope saw them, in the tool's `places` order.
    typealias Runner = @MainActor (AISession, [String: ToolValue], [AITarget]) async -> AIResult

    struct Entry {
        var at = Date()
        var tool: String
        /// The arguments as told, secrets masked, long ones cut.
        var args: String
        /// How the chain ended: "allowed", "asked: production", "not allowed", "locked", "refused: …".
        var decision: String
        var result: AIResult
        /// A server's text was read earlier in this session: it may have talked the model into this call.
        var afterRead: Bool
    }

    unowned let app: AppDelegate
    /// Who asks (`Asker`); nil: a sheet on the main window.
    var asker: Asker?
    private(set) var scope = AIScope()
    private(set) var journal: [Entry] = []
    private(set) var hasRead = false
    /// The server behind each place of this session's calls, as its user (root isn't the assistant's to take).
    private var servers: [AIPlace: SFTPTarget] = [:]

    init(app: AppDelegate, asker: Asker? = nil) { (self.app, self.asker) = (app, asker) }

    /// A tool of `AITools.all` by its name, as tool use and MCP call it.
    func call(_ name: String, _ args: [String: ToolValue]) async -> AIResult {
        guard let tool = AITools.all.first(where: { $0.name == name }), let run = Self.runners[name] else {
            let known = AITools.all.contains { $0.name == name }
            return note(name, args, "refused: no such tool", .failure(known ? "“\(name)” isn't available yet." : "There is no tool “\(name)”."), afterRead: hasRead)
        }
        return await call(tool, args, run: run)
    }

    /// The whole chain for one call (tests: a tool of their own).
    func call(_ tool: AITool, _ args: [String: ToolValue], run: Runner) async -> AIResult {
        let afterRead = hasRead   // before this call's own read
        let (decision, result) = await pass(tool, args, run: run)
        return note(tool.name, args, decision, result, afterRead: afterRead)
    }

    private func note(_ tool: String, _ args: [String: ToolValue], _ decision: String, _ result: AIResult, afterRead: Bool) -> AIResult {
        var kept = result   // what it came to, not all it read
        kept.text = String(result.text.prefix(2000))
        journal.append(Entry(tool: tool, args: AISecrets.mask(Self.told(args, cut: 200).joined(separator: ", ")).text, decision: decision, result: kept,
                             afterRead: afterRead))
        return result
    }

    private func pass(_ tool: AITool, _ args: [String: ToolValue], run: Runner) async -> (String, AIResult) {
        // Each server named, found and learned before it becomes a place: its key is where ssh says the address goes.
        var named: [String: SFTPTarget?] = [:]
        for arg in Set(tool.places.map(\.server)) {
            guard case .string(let name)? = args[arg] else { continue }   // missing or mistyped: `targets` refuses it
            guard let t = await server(named: name) else { return ("refused: unknown server", .failure(Self.unknown(name))) }
            named[name] = t
        }
        guard let targets = tool.targets(args, resolve: { name in named[name].map { self.place($0) } }) else {
            return ("refused: malformed", .failure("The call doesn't fit “\(tool.name)”: every argument as its schema says, each path absolute — no “..”, and no “~” on a server."))
        }
        let call = AICall(tool, targets), prod = { (p: AIPlace) in self.servers[p].map(SavedServer.isProd) ?? false }
        var decision = scope.check(call, prod: prod)
        if case .outside(let needs) = decision {
            guard await allow(needs, why: nil) else { return ("not allowed", .failure("The user didn't allow it. Nothing was done.")) }
            decision = scope.check(call, prod: prod)
        }
        if let no = Self.refusal(decision) { return no }

        let ends = targets.compactMap { servers[$0.place] }.reduce(into: [SFTPTarget]()) { if !$0.contains($1) { $0.append($1) } }
        let passed = await app.gate(ends, to: "let the assistant use “\(tool.name)” on", question: {
            decision = self.scope.check(call, prod: prod)   // production is known by now
            guard case .ask(let why) = decision, why != .unclear else { return nil }
            return self.question(tool, args, why, on: ends)
        }, asker: asker)
        switch passed {
        case .locked(let t): return ("locked", .failure("\(Self.label(t)) stays locked: the user didn't unlock it. Nothing was done."))
        case .cancelled: return (Self.said(decision) + ", cancelled", .failure("The user said no. Nothing was done."))
        case .pass: break
        }
        if let no = Self.refusal(decision) { return no }   // what the question's closure couldn't say: it only asks or passes
        // A place whose server isn't known would be read as this Mac by a runner.
        guard targets.allSatisfy({ $0.place == .mac || servers[$0.place] != nil }) else { return Self.refusal(.ask(.unclear))! }
        // Stopped while Touch ID or the question was up, answered after.
        guard !Task.isCancelled else { return ("stopped", .failure("Stopped. Nothing was done.")) }
        let result = await run(self, args, targets)
        // A server's text, its error's too; and a terminal's, whoever is logged in there.
        if targets.contains(where: { $0.place != .mac }) || tool.name == "terminal_output" { hasRead = true }
        return (Self.said(decision) + (decision == .allowed ? "" : ", allowed"), result)
    }

    private static func said(_ d: AIScope.Decision) -> String { if case .ask(let why) = d { "asked: \(why)" } else { "allowed" } }
    private static func unknown(_ name: String) -> String {
        "Kermo knows no single server “\(name)”. Use a name `focus` gave, or \"mac\" for this Mac."
    }

    /// What never reaches a server: a call still outside the scope, and one that doesn't fit its tool.
    private static func refusal(_ d: AIScope.Decision) -> (String, AIResult)? {
        switch d {
        case .outside: ("refused: outside the scope", .failure("This is outside what the user allowed this chat. Nothing was done."))
        case .ask(.unclear): ("refused: unclear", .failure("The call doesn't fit its tool, so it wasn't run. Nothing was done."))
        case .allowed, .ask: nil
        }
    }

    // MARK: Servers and places

    /// "mac" (nil inside) is this Mac, always. Else the one server that goes by `name`: saved under it, or in front
    /// of the user as `focus` named it — learned, so one server written two ways is one. Two different servers under
    /// a name are nobody's (a saved "web-01" and an ssh alias web-01 in a panel). Always as the server's user.
    private func server(named name: String) async -> SFTPTarget?? {
        if name == "mac" { return .some(nil) }
        let c = app.aiContext
        let shown = [c.active.server, c.other.server, c.active.parked?.server, c.other.parked?.server, c.editor?.server, c.terminal?.server]
        let all = ServerLock.servers().filter { $0.title == name }.map(\.target.asUser) + shown.compactMap { $0?.asUser }.filter { Self.label($0) == name }
        await ServerLock.learn(all)
        let one = all.reduce(into: [SFTPTarget]()) { found, t in if !found.contains(where: { ServerLock.same($0, t) }) { found.append(t) } }
        // `.none` spelled out: a bare nil here would read as "this Mac".
        guard one.count == 1 else { return .none }
        return .some(one[0])
    }

    /// What `focus` calls a server, and takes back: its saved name, else its address — with the port when it isn't
    /// ssh's own (two tunnels on localhost), and never "mac".
    static func label(_ t: SFTPTarget) -> String {
        let name = SavedServer.name(for: t.asUser)
        guard name == t.asUser.shown || name == "mac" else { return name }
        return t.asUser.shown + (t.port.map { $0 == 22 ? "" : ":\($0)" } ?? "")
    }

    /// The scope's key for `t`: where `ssh -G` says it goes, once learned; else the address as written, a key of its
    /// own that matches no other spelling's grant.
    func place(_ t: SFTPTarget?) -> AIPlace {
        guard let t = t?.asUser else { return .mac }
        let p = AIPlace.server(ServerLock.identity(t) ?? "as written: \(t.shown)#\(t.port ?? 22)")
        servers[p] = ServerLock.locking(t)   // a locked server's connection lingers as briefly under any name
        return p
    }

    private func name(_ p: AIPlace) -> String { servers[p].map(Self.label) ?? "this Mac" }

    // MARK: Asking

    private func ask(_ c: Confirm) async -> Bool {
        if let asker { await asker(c, nil) == 0 } else { await app.confirm(c) == 0 }
    }

    /// "Allow for This Task": what the scope lacks, line by line; granted only as a whole.
    private func allow(_ needs: [AIScope.Need], why: String?) async -> Bool {
        var c = Confirm("Allow the assistant this, until the chat ends?", action: "Allow for This Task")
        c.on(needs.compactMap { servers[$0.place] })
        c.items = needs.map { n in
            let what = switch n.level {
            case .view: "read"
            case .work: [n.folder.map { "write into \($0)" }, n.commands ? "run commands" : nil].compactMap { $0 }.joined(separator: ", ")
            case .all: "everything"
            }
            return Confirm.Item(name: "\(name(n.place)): \(what)")
        }
        let limit = needs.contains { $0.commands || $0.level == .all } ? "A command can write over files without asking first." : nil
        c.note = [why, limit, "Deleting, writing over a file and any change on a production server still ask each time."].compactMap { $0 }.joined(separator: " ")
        c.returnCancels = true
        guard await ask(c) else { return false }
        needs.forEach { scope.grant($0) }
        return true
    }

    /// The question a call in scope still gets: production, a removal, writing over what is there.
    private func question(_ tool: AITool, _ args: [String: ToolValue], _ why: AIScope.Reason, on ends: [SFTPTarget]) -> Confirm {
        let what = switch why {
        case .production: "change a production server"
        case .removes: "delete"
        case .overwrites: "write over what is there"
        case .unclear: "do this"
        }
        var c = Confirm("Let the assistant \(what)?", action: "Allow Once")
        c.on(ends)
        c.runs = tool.name
        c.command = Self.told(args, cut: 400).joined(separator: "\n")
        c.irreversible = why != .production
        c.returnCancels = true
        return c
    }

    /// The arguments as a person reads them, each value `cut` at most.
    private static func told(_ args: [String: ToolValue], cut: Int) -> [String] {
        args.sorted { $0.key < $1.key }.map { k, v in
            if case .string(let s) = v { "\(k): \(s.prefix(cut))" } else if case .bool(let b) = v { "\(k): \(b)" } else { "\(k): ?" }
        }
    }

    // MARK: Runners

    /// What a text handed to the model may be at most; a longer one is cut and says so.
    static let textLimit = 256 << 10
    static let namesLimit = 1000

    private struct NotAFile: LocalizedError { var errorDescription: String? { "it isn't a file" } }

    /// Work off the main thread that stops when the call's task is cancelled.
    private static func work<T: Sendable>(_ body: @escaping @Sendable (CancelFlag) throws -> T) async -> Result<T, Error> {
        let flag = CancelFlag()
        return await withTaskCancellationHandler { await Blocking.run { Result { try body(flag) } } } onCancel: { flag.cancel() }
    }

    /// Text for the model: secrets masked (and counted), cut at `limit` characters from the `end` that matters less.
    static func handOver(_ text: String, limit: Int = textLimit, keepEnd: Bool = false, cut: Bool = false) -> AIResult {
        let (whole, hidden) = AISecrets.mask(text)   // before the cut: a cut inside a secret would leave its tail bare
        let part = keepEnd ? String(whole.suffix(limit)) : String(whole.prefix(limit))
        var notes: [String] = []
        if cut || part.count < whole.count { notes.append(keepEnd ? "Only the end is here." : "Only the beginning is here.") }
        if hidden > 0 { notes.append("\(hidden) secret\(hidden == 1 ? "" : "s") hidden as •••.") }
        return AIResult(notes.isEmpty ? part : part + "\n\n[" + notes.joined(separator: " ") + "]")
    }

    static let runners: [String: Runner] = [
        "focus": { s, _, _ in s.focus() },
        "request_scope": { s, args, _ in await s.requestScope(args) },
        "list_folder": { s, _, targets in
            let t = s.servers[targets[0].place], path = targets[0].path ?? "/", env = SSHAskpass.env
            let found = await work { flag in try t.map { try SFTP.list($0, path, env: env, cancel: flag) } ?? DirLister.list(path) }
            switch found {
            case .failure(let e): return .failure("Couldn't list \(path): \(e.localizedDescription)")
            case .success(let items):
                let day = ISO8601DateFormatter()
                // A name with a tab or a new line in it would forge rows: left out, as a server's listing leaves them.
                let items = items.filter { !$0.name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } }
                let lines = items.sorted { $0.name < $1.name }.prefix(namesLimit).map { i in
                    "\(i.name)\(i.kind == .dir ? "/" : i.kind == .link ? "@" : "")\t\(i.kind == .dir ? "" : String(i.size))\t\(day.string(from: Date(timeIntervalSince1970: i.mtime)))"
                }
                let more = items.count > namesLimit ? "\n[\(items.count - namesLimit) more names not shown.]" : ""
                return AIResult(items.isEmpty ? "The folder is empty." : "name\tbytes\tchanged\n" + lines.joined(separator: "\n") + more)
            }
        },
        "read_file": { s, _, targets in
            let t = s.servers[targets[0].place], path = targets[0].path ?? "/", env = SSHAskpass.env, limit = textLimit
            // A file only: a FIFO or a device read as one would hang, or take what was another reader's — and some of
            // those say they are files (/proc/kmsg).
            guard !AICommand.consumes(path) else { return .failure("\(path) isn't a file to read: a device or a kernel pipe.") }
            let read = await work { flag -> Data in
                if let t {
                    return try SFTP.session(t, env: env, cancel: flag, on: nil) { c in
                        guard try c.stat(path).kind == .file else { throw NotAFile() }
                        return try c.read(path, max: limit + 1)
                    }
                }
                let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)   // never waits for a FIFO's writer
                guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var st = stat()
                guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw NotAFile() }   // what was opened, not what the name says now
                return try h.read(upToCount: limit + 1) ?? Data()
            }
            switch read {
            case .failure(let e): return .failure("Couldn't read \(path): \(e.localizedDescription)")
            case .success(let data):
                // A cut may fall inside a character: up to three bytes back find its start.
                let cut = data.count > limit, text = (0...(cut ? 3 : 0)).lazy.compactMap { String(data: data.prefix(min(data.count, limit) - $0), encoding: .utf8) }.first
                guard let text else { return .failure("\(path) isn't text (UTF-8).") }
                return handOver(text, cut: cut)
            }
        },
        "terminal_output": { s, _, targets in
            let t = s.servers[targets[0].place], tabs = s.app.terminal?.tabs ?? []
            let mine = { (tab: EmbeddedTerminal.Tab) in t.map { t in tab.target.map { ServerLock.same($0.asUser, t) } ?? false } ?? (tab.target == nil) }
            guard let tab = s.app.terminal?.current.flatMap({ mine($0) ? $0 : nil }) ?? tabs.last(where: mine) else {
                return .failure("No terminal tab of \(s.name(targets[0].place)) is open.")
            }
            guard let out = tab.view.output(), !out.isEmpty else { return .failure("Nothing to read there: no command printed anything, or a full-screen program is running.") }
            return handOver(out, limit: 16_000, keepEnd: true)
        },
    ]

    /// What the user has in front of them. A folder's names and a selection are the place's content: told only where
    /// the chat may read (any grant there), else just where the panel stands.
    private func focus() -> AIResult {
        var server = false
        let text = Self.focus(app.aiContext, name: Self.label) { t in
            guard t?.sudo != true, self.scope.grants[self.place(t)] != nil else { return false }   // a root panel's isn't the user's grant to give
            if t != nil { server = true }
            return true
        }
        if server { hasRead = true }
        return Self.handOver(text)
    }

    /// `c` in words. `name`: what a server goes by (the model names it back so); `may`: the chat may read there.
    static func focus(_ c: AIContext, name: (SFTPTarget) -> String, may: (SFTPTarget?) -> Bool) -> String {
        var lines: [String] = []
        func at(_ t: SFTPTarget?) -> String { t.map { name($0.asRoot(false)) + ($0.sudo ? " (as root)" : "") } ?? "mac" }
        for (title, p) in [("Active panel", c.active), ("Other panel", c.other)] {
            if let parked = p.parked { lines.append("\(title): a tab of \(at(parked.server)) at \(parked.dir), not connected"); continue }
            lines.append("\(title): \(at(p.server)) " + (p.list.map { "list “\($0)”" } ?? p.dir))
            guard may(p.server) else { lines.append("  names: not in this chat's scope"); continue }
            if let cur = p.cursor { lines.append("  cursor: \(cur)") }
            if !p.targets.isEmpty, p.targets != p.cursor.map({ [$0] }) {
                lines.append("  marked (\(p.targets.count)): " + p.targets.prefix(50).joined(separator: ", ") + (p.targets.count > 50 ? ", …" : ""))
            }
        }
        if let e = c.editor {
            lines.append("Editor: \(at(e.server)) \(e.path ?? "an untitled document")" + (e.unsaved ? " (unsaved changes)" : ""))
            if let sel = e.selection {
                lines.append("  selection, lines \(sel.lines.lowerBound)–\(sel.lines.upperBound)" + (may(e.server) ? ":\n" + String(sel.text.prefix(4000)) : ": not in this chat's scope"))
            }
        }
        if let t = c.terminal {
            lines.append("Terminal: a tab opened as \(at(t.server)) — who is logged in there now isn't known")
            if may(t.server) {
                if let cmd = t.command { lines.append("  last command line: \(cmd.prefix(400))") }
                if let sel = t.selection { lines.append("  selection:\n" + String(sel.prefix(4000))) }
            } else if t.command != nil || t.selection != nil { lines.append("  its text: not in this chat's scope") }
        }
        return lines.joined(separator: "\n")
    }

    /// The model's own request to widen the scope: the same question a call outside it gets, with its `why`.
    private func requestScope(_ args: [String: ToolValue]) async -> AIResult {
        func text(_ k: String) -> String? { if case .string(let s)? = args[k] { s } else { nil } }
        guard let name = text("server"), let level = ["view": AIScope.Level.view, "work": .work, "all": .all][text("level") ?? ""], let why = text("why") else {
            return .failure("request_scope needs server, level and why.")
        }
        guard let t = await server(named: name) else { return .failure(Self.unknown(name)) }
        var folder: String?
        if let f = text("folder") {
            guard level == .work, let n = AITarget.normal(f, home: t == nil ? NSHomeDirectory() : nil) else {
                return .failure("A folder goes with level “work”, as an absolute path — no “..”, and no “~” on a server.")
            }
            folder = n
        }
        let need = AIScope.Need(place: place(t), level: level, folder: folder, commands: level == .work && args["commands"] == .bool(true))
        guard level != .work || need.folder != nil || need.commands else { return .failure("Level “work” needs a folder to write into, commands, or both.") }
        guard await allow([need], why: "The assistant says: " + AISecrets.mask(String(why.prefix(300))).text) else { return .failure("The user didn't allow it.") }
        return AIResult("Allowed until the chat ends.")
    }
}
