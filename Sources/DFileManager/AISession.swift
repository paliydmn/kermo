import AppKit
import DFMCore
import os

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
    /// What a tool that writes does first, once the place is unlocked and before the user is asked: looks at what is
    /// there. `no`: it can't be done, in words. `go`: whether something would be written over — that decides the
    /// question — and the runner, holding what was seen: a change after the look is a refusal, not a silent overwrite.
    /// `asks`: the question, when the scope asks one, in the words of what was seen (a Tools action's command).
    typealias Look = @MainActor (AISession, [String: ToolValue], [AITarget]) async -> Looked
    enum Looked { case no(AIResult), go(overwrites: Bool, Runner, asks: Confirm? = nil) }

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
        /// It may change something (`AIScope.changes`): after a read, the chat's step for it says ⚠.
        var changes: Bool
    }

    unowned let app: AppDelegate
    /// Who asks (`Asker`); nil: a sheet on the main window.
    var asker: Asker?
    /// Ask and Edit: nothing that changes goes — whatever an Agent turn of the same chat was allowed — and the most
    /// the user is ever asked to allow is reading. Refused in words, unasked.
    var readOnly = false
    /// Settings › AI's "Never Send": nothing on a production server is read for the model — read at each check, so a
    /// chat or an agent already going keeps to a change, a question on screen when it changed too.
    var noProduction: Bool { AISettings.neverProd(app.defaults) }
    /// Where `propose_edit`'s diff is shown (the chat's card); nil — an outside agent's session: it says in words
    /// whether the change fits.
    var proposes: (@MainActor (AIEdit.Proposal, SFTPTarget?, String) -> Void)?
    /// Where `plan`'s steps are shown (the chat's card); nil — an outside agent's session, which isn't offered it.
    var plans: (@MainActor ([(text: String, state: String)]) -> Void)?
    /// Told whenever what is allowed changes: the chat's scope row.
    var scopeChanged: (@MainActor () -> Void)?
    private(set) var scope = AIScope() { didSet { scopeChanged?() } }
    private(set) var journal: [Entry] = []
    /// The commands that ran and ended well (exit 0), whole and masked, in order: Save as Tool's (task 23 PR 9) — a
    /// chat's session only (`plans`), an outside agent's keeps none.
    private(set) var commands: [(server: SFTPTarget, command: String, folder: String?)] = []
    /// Text from a server or a terminal went to the model: its reads — and, set by the chat, what the user attached
    /// from one, or a chat opened again that holds such text (`AISavedChat.heard`).
    var hasRead = false
    /// Something read on a production server went to the model (Never Send turned on later ends such a chat).
    private(set) var readProduction = false
    /// The server behind each place of this session's calls, as its user (root isn't the assistant's to take).
    private var servers: [AIPlace: SFTPTarget] = [:]
    private var busy = false, waiting: [CheckedContinuation<Void, Never>] = []

    init(app: AppDelegate, asker: Asker? = nil) { (self.app, self.asker) = (app, asker) }

    /// A tool of `AITools.all` by its name, as tool use and MCP call it.
    func call(_ name: String, _ args: [String: ToolValue]) async -> AIResult {
        guard let tool = AITools.all.first(where: { $0.name == name }), Self.runners[name] != nil || Self.looks[name] != nil else {
            return note(name, args, "refused: no such tool", .failure("There is no tool “\(name)”."), afterRead: hasRead)
        }
        return await call(tool, args, look: Self.looks[name], run: Self.runners[name])
    }

    /// The whole chain for one call (tests: a tool of their own). One at a time: a client may call side by side,
    /// and a second `copy` could put a link where the first has looked and not yet written.
    func call(_ tool: AITool, _ args: [String: ToolValue], look: Look? = nil, run: Runner? = nil) async -> AIResult {
        if busy { await withCheckedContinuation { waiting.append($0) } } else { busy = true }
        defer { if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() } }   // handed on: still busy
        // Stopped while it waited its turn: it asks nothing.
        guard !Task.isCancelled else { return note(tool.name, args, "stopped", .failure("Stopped. Nothing was done."), afterRead: hasRead) }
        let afterRead = hasRead   // before this call's own read
        var changes = false
        let (decision, result) = await pass(tool, args, afterRead: afterRead, changes: &changes, look: look, run: run)
        return note(tool.name, args, decision, result, afterRead: afterRead, changes: changes)
    }

    private func note(_ tool: String, _ args: [String: ToolValue], _ decision: String, _ result: AIResult, afterRead: Bool, changes: Bool = false) -> AIResult {
        var kept = result   // what it came to, not all it read
        kept.text = String(result.text.prefix(2000))
        journal.append(Entry(tool: tool, args: AISecrets.mask(Self.told(args, cut: 200).joined(separator: ", ")).text, decision: decision, result: kept,
                             afterRead: afterRead, changes: changes))
        return result
    }

    /// A question after text from a server or a terminal was read in this session (the journal's ⚠): it says so first.
    private static func warned(_ c: Confirm, _ afterRead: Bool) -> Confirm {
        guard afterRead else { return c }
        var c = c
        c.title = "⚠ " + c.title
        c.note = ["It comes after the assistant read text from a server or a terminal, and such text can try to steer it: check this is what you asked for.",
                  c.note].compactMap { $0 }.joined(separator: " ")
        return c
    }

    /// `changes`: set once the targets are known — the call may change something.
    private func pass(_ tool: AITool, _ args: [String: ToolValue], afterRead: Bool, changes: inout Bool, look: Look?, run: Runner?) async -> (String, AIResult) {
        // Never Send turned on after production text went to the model: it can't be taken back, so nothing more goes
        // on — any call, as the chat goes no further (an outside agent's session; the chat stops before its turn).
        if noProduction, readProduction {
            return ("refused: production read before Never Send", .failure("This session read on a production server before Settings › AI said Never Send, and the model still holds that text: nothing more is done here. Tell the user to restart the agent (or start a New Chat)."))
        }
        // Each server named, found and learned before it becomes a place: its key is where ssh says the address goes.
        var named: [String: SFTPTarget?] = [:]
        for arg in Set(tool.places.map(\.server)) {
            guard case .string(let name)? = args[arg] else { continue }   // missing or mistyped: `targets` refuses it
            guard let t = await server(named: name) else { return ("refused: unknown server", .failure(Self.unknown(name))) }
            named[name] = t
        }
        guard var targets = tool.targets(args, resolve: { name in named[name].map { self.place($0) } }) else {
            return ("refused: malformed", .failure("The call doesn't fit “\(tool.name)”: every argument as its schema says, each path absolute — no “..”, and no “~” on a server."))
        }
        // A Tools action is what its tool says it is, known before the scope reads it — one that isn't there or isn't
        // the assistant's is refused before anyone is asked; its look checks it still is.
        if tool.name == "tool_action", case .string(let id)? = args["tool"], case .string(let action)? = args["action"] {
            switch app.tools.accessForAI(id, action) {
            case .failure(let no): return ("refused: not the assistant's", no.result)
            case .success(let access): targets = targets.compactMap { AITarget($0.place, $0.path, access) }
            }
        }
        changes = targets.contains(where: AIScope.changes)
        // Commands, Tools and Server Info are for servers: said before the user is asked to allow one here.
        guard !targets.contains(where: { t in t.place == .mac && { switch t.access { case .run, .tool: true; default: ["tools", "server_info"].contains(tool.name) } }() }) else {
            return ("refused: no commands on this Mac", .failure("Commands, Tools and server_info run on servers only, not on this Mac. Nothing was done."))
        }
        // Kermo's own copies on this Mac — a server's file, an archive's — aren't this Mac's files to the assistant.
        guard !targets.contains(where: { $0.place == .mac && $0.path.map(TempCopies.within) == true }) else {
            return ("refused: Kermo's copy", .failure("That is inside Kermo's own temporary copies (of server files, archives…), not the assistant's to use. Read the file where it is — on its server. Nothing was done."))
        }
        // Before the scope: what an Agent turn was allowed doesn't carry into Ask.
        if readOnly, targets.contains(where: AIScope.changes) {
            return ("refused: Ask", .failure("In Ask the assistant only reads: this would change something. Nothing was done — give the user the commands instead."))
        }
        var call = AICall(tool, targets), run = run, asks: Confirm?
        let prod = { (p: AIPlace) in self.servers[p].map(SavedServer.isProd) ?? false }
        let neverProd = { self.noProduction && targets.contains { prod($0.place) } }
        if neverProd() { return Self.refusedProduction }
        var decision = scope.check(call, prod: prod)
        if case .outside(let needs) = decision {
            guard await allow(needs, afterRead: afterRead) else { return ("not allowed", .failure("The user didn't allow it. Nothing was done.")) }
            guard !Task.isCancelled else { return ("stopped", .failure("Stopped. Nothing was done.")) }   // before Touch ID is asked for nobody
            decision = scope.check(call, prod: prod)
        }
        if let no = Self.refusal(decision) { return no }

        let ends = targets.compactMap { servers[$0.place] }.reduce(into: [SFTPTarget]()) { if !$0.contains($1) { $0.append($1) } }
        let to = "let the assistant use “\(tool.name)” on"
        // A server's text, its error's too; and a terminal's, whoever is logged in there.
        let read = { if targets.contains(where: { $0.place != .mac }) || tool.name == "terminal_output" { self.hasRead = true } }
        if let look {
            // Looking is the server's too: unlocked first, as for anything sent there. Then the question knows.
            if case .locked(let t) = await app.gate(ends, to: to) { return ("locked", .failure("\(Self.label(t)) stays locked: the user didn't unlock it. Nothing was done.")) }
            guard !Task.isCancelled, targets.allSatisfy({ $0.place == .mac || servers[$0.place] != nil }) else { return ("stopped", .failure("Stopped. Nothing was done.")) }
            let looked = await look(self, args, targets)
            read()
            switch looked {
            case .no(let why): return ("refused: can't be done", why)
            case .go(let overwrites, let found, let question): (call.overwrites, run, asks) = (overwrites, found, question)
            }
        }
        guard !Task.isCancelled else { return ("stopped", .failure("Stopped. Nothing was done.")) }   // no Touch ID for nobody
        let passed = await app.gate(ends, to: to, question: {
            decision = self.scope.check(call, prod: prod)   // production is known by now
            guard case .ask(let why) = decision, why != .unclear else { return nil }
            // Which way it goes, by the places the targets resolved to (not the model's words); a path has no control
            // character (`AITarget.normal`).
            let between = why == .betweenMachines ? targets.first { !AIScope.changes($0) }.flatMap { from in targets.first(where: AIScope.changes).map { to in
                (what: String(((from.path ?? "") as NSString).lastPathComponent.prefix(60)).bidiVisible, from: self.name(from.place), to: self.name(to.place))
            } } : nil
            return Self.warned(asks ?? Self.question(tool, args, why, on: ends, over: look != nil && call.overwrites, between: between), afterRead)
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
        guard let run else { return Self.refusal(.ask(.unclear))! }
        if neverProd() { return Self.refusedProduction }   // an alias known as production only now
        var result = await run(self, args, targets)
        read()
        // Production, said where the model reads what it did there.
        let note = AIChat.productionNote(ends.filter(SavedServer.isProd).map(Self.label))
        if !note.isEmpty { (result.text, readProduction) = (note + "\n\n" + result.text, true) }
        return (Self.said(decision) + (decision == .allowed ? "" : ", allowed"), result)
    }

    private static let refusedProduction = ("refused: production", AIResult.failure("Settings › AI: nothing on a production server goes to the AI. Nothing was read."))

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
        // What is shown first: of one server written two ways, the connection that is there already.
        let all = shown.compactMap { $0?.asUser }.filter { Self.label($0) == name } + ServerLock.servers().filter { $0.title == name }.map(\.target.asUser)
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

    struct Granted {
        var place: AIPlace, name: String, words: String, short: String, level: AIScope.Level, prod: Bool
    }
    /// What the user allowed so far, place by place, in words — for whoever shows it and takes it back.
    var granted: [Granted] {
        scope.grants.map { p, g in
            Granted(place: p, name: name(p), words: "\(name(p)): " + Self.words(g.level, g.folders, g.commands), short: "\(name(p)) \(["View", "Work", "All"][g.level.rawValue])",
                    level: g.level, prod: servers[p].map(SavedServer.isProd) ?? false)
        }.sorted { $0.words < $1.words }
    }
    /// The user takes back what they allowed `place` (nil: everywhere): the next call there asks again. A call
    /// that passed already goes on.
    func takeAway(_ place: AIPlace? = nil) { (place.map { [$0] } ?? Array(scope.grants.keys)).forEach { scope.revoke($0) } }

    /// The user sets a place's level themselves (the scope row): `AIScope.set`. Whatever it is, Ask and Edit
    /// change nothing (`readOnly`) — the row offers them View only. All on this Mac goes through the question, as
    /// View there does: what it reaches is said there.
    func set(_ place: AIPlace, _ level: AIScope.Level) async {
        guard scope.grants[place] != nil else { return }
        if place == .mac, level == .all { _ = await allow([AIScope.Need(place: .mac, level: .all)]) } else { scope.set(place, level) }
    }

    /// The user gives `t` (nil: this Mac) View up front (the scope row's +): learned first, so it is the place a
    /// call there gets — one server written two ways is one. This Mac and a production server go through the
    /// question all the same — what it says there (~/.ssh, the provider) is the consent; under Never Send production
    /// isn't given.
    func give(_ t: SFTPTarget?) async {
        if let t { await ServerLock.learn([t.asUser]) }
        let p = place(t), prod = t.map(SavedServer.isProd) ?? false
        guard scope.grants[p] == nil, !(prod && noProduction) else { return }
        if t == nil || prod { _ = await allow([AIScope.Need(place: p, level: .view)]) } else { scope.grant(p, .view) }
    }

    private static func words(_ level: AIScope.Level, _ folders: [String], _ commands: Bool) -> String {
        switch level {
        case .view: "read"
        case .work: ((folders.isEmpty ? [] : ["write into " + folders.joined(separator: ", ")]) + (commands ? ["run commands"] : [])).joined(separator: ", ")
        case .all: "everything"
        }
    }

    /// Words as one line of a card: masked first (a cut inside a secret would leave its head bare) — the model's;
    /// Kermo's own (`mask: false`) are said as they are —, no line break, control character or run of spaces to
    /// draw a line of its own, `max` characters at most.
    static func oneLine(_ s: String, max: Int = .max, mask: Bool = true) -> String {
        let flat = String(String.UnicodeScalarView((mask ? AISecrets.mask(s).text : s).unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    /// The journal as text, the newest call last.
    var journalText: String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        return journal.map { e in
            "\(time.string(from: e.at)) \(e.afterRead ? "⚠ " : "")\(e.tool)(\(e.args)) — \(e.decision)\n    "
                + (e.result.isError ? "✗ " : "") + e.result.text.prefix(300).replacingOccurrences(of: "\n", with: "\n    ")
        }.joined(separator: "\n")
    }

    // MARK: Asking

    private func ask(_ c: Confirm) async -> Bool {
        if let asker { await asker(c, nil) == 0 } else { await app.confirm(c) == 0 }
    }

    /// "Allow for This Task": what the scope lacks, a line each in Kermo's words, whole (the wrapped box, never cut
    /// in the middle); the model's `whys` on a line of their own, quoted. Granted only as a whole.
    /// `afterRead`: the model asks, after a server's text (not the user's own click in the scope row).
    private func allow(_ needs: [AIScope.Need], whys: [String] = [], afterRead: Bool = false) async -> Bool {
        let reads = needs.allSatisfy { $0.level == .view }
        var c = reads ? Confirm("Let the assistant read there until the chat ends?", action: "Allow in This Chat")
            : Confirm("Allow the assistant this, until the chat ends?", action: "Allow for This Task")
        c.on(needs.compactMap { servers[$0.place] })
        c.command = needs.map { n in Self.oneLine("\(name(n.place)): " + Self.words(n.level, n.folder.map { [$0] } ?? [], n.commands), mask: false) }.joined(separator: "\n")
        let said = whys.filter { !$0.isEmpty }.map { "“" + Self.oneLine($0, max: 80) + "”" }
        if !said.isEmpty { c.runs = "The assistant says it's for: " + said.joined(separator: ", ") }
        let limit = needs.contains { $0.place != .mac && ($0.commands || $0.level == .all) } ? "A command can write over files without asking first." : nil
        // A folder that holds the home folder — however it's reached — or one of its own that runs or logs in.
        let homes = [NSHomeDirectory(), "/System/Volumes/Data" + NSHomeDirectory()], own = homes.flatMap { [$0 + "/Library", $0 + "/.ssh"] }
        let wide = needs.contains { n in
            n.place == .mac && (n.level == .all || n.folder.map { f in homes.contains { AIScope.holds(f, $0) } || own.contains { AIScope.holds($0, f) } } == true)
        }
        let mac = wide ? "On this Mac that reaches your own files — ~/Library/LaunchAgents and ~/.ssh too."
            : needs.contains { $0.place == .mac && $0.level == .view } ? "On this Mac reading is any file you can read, ~/.ssh too." : nil
        let after = reads ? nil : "Deleting, writing over a file, a copy from one machine to another and any change on a production server still ask each time."
        c.note = [mac, limit, "What it reads goes to your AI provider, secrets it recognises as •••.", after].compactMap { $0 }.joined(separator: " ")
        c.returnCancels = true
        guard await ask(Self.warned(c, afterRead)) else { return false }
        needs.forEach { scope.grant($0) }
        return true
    }

    /// The question a call in scope still gets: production, a removal, a copy between machines (`between`: what, from
    /// where, to where), writing over what is there.
    static func question(_ tool: AITool, _ args: [String: ToolValue], _ why: AIScope.Reason, on ends: [SFTPTarget], over: Bool = false,
                         between: (what: String, from: String, to: String)? = nil) -> Confirm {
        let what = switch why {
        case .production: "change a production server"
        case .removes: "delete"
        case .betweenMachines: between.map { "copy “\($0.what)” from \($0.from) to \($0.to)" } ?? "copy from one machine to another"
        case .overwrites: "write over what is there"
        case .unclear, .always: "do this"
        }
        var c = Confirm("Let the assistant \(what)?", action: "Allow Once")
        c.on(ends)
        c.runs = tool.name
        let commands = Set(tool.places.compactMap { if case .run(let arg) = $0.access { arg } else { nil } })
        c.command = told(args, cut: 400, whole: commands).joined(separator: "\n")   // what runs, whole: the box scrolls
        // The reason told is production or the copy's way; writing over is said too.
        let mild = why == .production || why == .betweenMachines
        if over, mild { c.note = "It writes over the file that is there." }
        c.irreversible = !mild || over
        c.returnCancels = true
        return c
    }

    /// The arguments as a person reads them, each value `cut` at most and what's left said — `whole` ones never.
    private static func told(_ args: [String: ToolValue], cut: Int, whole: Set<String> = []) -> [String] {
        func shown(_ k: String, _ s: String) -> String { whole.contains(k) || s.count <= cut ? s : "\(s.prefix(cut))… \(s.count - cut) more characters" }
        return args.sorted { $0.key < $1.key }.map { k, v in
            switch v {
            case .string(let s): "\(k): \(shown(k, s))"
            case .bool(let b): "\(k): \(b)"
            case .array(let items):   // propose_edit's edits: old → new each
                "\(k): " + shown(k, items.map { item -> String in
                    guard case .object(let o) = item, case .string(let a)? = o["old_text"], case .string(let b)? = o["new_text"] else { return "?" }
                    return "\(a) → \(b)"
                }.joined(separator: "; "))
            default: "\(k): ?"
            }
        }
    }

    // MARK: Runners

    /// What a text handed to the model may be at most; a longer one is cut and says so.
    static let textLimit = 256 << 10
    static let namesLimit = 1000

    private struct NotAFile: LocalizedError { var errorDescription: String? { "it isn't a file" } }

    /// Work off the main thread that stops when the call's task is cancelled.
    static func work<T: Sendable>(_ body: @escaping @Sendable (CancelFlag) throws -> T) async -> Result<T, Error> {
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

    /// How long a command may take; then Kermo stops waiting for it (tests: less).
    static var commandSeconds: TimeInterval = 30

    struct Ran: Sendable {
        /// nil: not known — Kermo let go of it, `late` (past `commandSeconds`) or having printed past `textLimit`.
        var status: Int32?
        var out: Data, err: String
        var late = false
    }

    /// `command` on `t` as its user, with no terminal and nothing to read. The login shell gets one line that bash,
    /// zsh and fish read alike; `sh` reads the command, in `dir` or not at all. A pager would wait for a key nobody
    /// presses. Fails with `CancellationError` (Stop) or with what kept it from starting.
    static func run(_ t: SFTPTarget, _ command: String, in dir: String? = nil) async -> Result<Ran, Error> {
        let line = (dir.map { "cd -- \(ShellContext.quote($0)) && " } ?? "") + "exec env PAGER=cat SYSTEMD_PAGER= sh -c " + ShellContext.quote(command)
        let env = SSHAskpass.env, seconds = commandSeconds, limit = textLimit
        return await work { flag in
            let late = CancelFlag(), full = CancelFlag()
            nonisolated(unsafe) var out = Data(), err = Data()   // each its own thread's until `run` is over
            try SFTP.startMaster(t, env: env, cancel: flag)   // logging in isn't the command's time
            Timeouts.queue.asyncAfter(deadline: .now() + seconds) { late.cancel(); flag.cancel() }
            let stop: @Sendable (Int) -> Void = { n in if n > limit { full.cancel(); flag.cancel() } }
            do {
                let (status, errors) = try SSHCommand.run(t, line, env: env, cancel: flag, onErrors: { err += $0; stop(err.count) }) { out += $0; stop(out.count) }
                return Ran(status: status, out: out, err: errors)
            } catch is CancellationError where late.isCancelled || full.isCancelled {
                // Only the ssh here is stopped: what it started there ends when it next writes, or never.
                return Ran(status: nil, out: out, err: String(decoding: err, as: UTF8.self), late: late.isCancelled)
            }
        }
    }

    /// What a command came to: how it ended first, then what it printed.
    static func told(_ r: Ran) -> AIResult {
        let how = r.status.map { "exit \($0)" } ?? (r.late ? "No end after \(Int(commandSeconds)) s" : "It printed more than Kermo takes")
            + ": Kermo stopped waiting. The command may still be running on the server."
        var result = handOver([how, String(decoding: r.out, as: UTF8.self), r.err.isEmpty ? "" : "[stderr]\n" + r.err].filter { !$0.isEmpty }.joined(separator: "\n"))
        result.isError = r.status != 0
        return result
    }

    // MARK: Writing

    /// `write_file`, `copy` and `tool_action` look before the user is asked (`Look`).
    static let looks: [String: Look] = [
        "tool_action": { s, args, targets in
            guard let t = s.servers[targets[0].place] else { return .no(.failure("Tools actions run on servers only.")) }
            return await s.app.tools.lookForAI(args, on: t, seen: targets[0].access)
        },
        "write_file": { s, args, targets in
            let path = targets[0].path ?? "/", t = s.servers[targets[0].place]
            guard case .string(let text)? = args["text"] else { return .no(.failure("write_file needs text.")) }
            if let no = await s.openInEditor(path, on: t) { return .no(no) }
            let a: SFTPClient.Attrs?
            switch await landing(path, on: t) {
            case .failure(let no): return .no(.failure(no.text))
            case .success(let there): a = there
            }
            // A link isn't written through: the file it names is the one to ask about, by its own path.
            guard a.map({ $0.kind == .file && $0.size <= Editor.sizeLimit }) ?? true else { return .no(.failure("\(path) is there and isn't a text file to write over. Nothing was written.")) }
            if let t {
                return .go(overwrites: a != nil) { s, _, _ in
                    if let no = await s.openInEditor(path, on: t) { return no }
                    return await s.write(text, to: path, on: t, over: a ?? .nothing)
                }
            }
            // What was seen: the file as it is now (the write goes over nothing else), or nothing there.
            let seen = await Blocking.run { (Editor.Stamp(path), a == nil ? nil : (try? Data(contentsOf: URL(fileURLWithPath: path))).map(Editor.sha)) }
            return .go(overwrites: a != nil) { s, _, _ in
                if let no = await s.openInEditor(path, on: nil) { return no }
                let name = (path as NSString).lastPathComponent
                let written = await Blocking.run {
                    Editor.write(Data(text.utf8), to: path, name: name, unlessChangedFrom: seen, hook: { _ in }, writing: { try $0.write(contentsOf: $1) }, willRename: { _ in })
                }
                return switch written {
                case .written(_, _, let note): AIResult("Wrote \(path)." + (note.map { " " + $0 + "." } ?? ""))
                case .changed: .failure("\(path) changed, or appeared, after Kermo looked. Nothing was written.")
                case .failed(let why, _): .failure("Not written: \(why)")
                }
            }
        },
        "copy": { s, _, targets in
            let from = targets[0], to = targets[1]
            guard let source = from.path, source != "/", let dir = to.path else { return .no(.failure("copy needs what to copy and a folder to copy into.")) }
            // A device read as a file never ends (a server's copy refuses what isn't a file or a folder itself).
            guard from.place != .mac || !(source.lowercased() + "/").hasPrefix("/dev/") else { return .no(.failure("\(source) is a device, not a file to copy.")) }
            let name = (source as NSString).lastPathComponent, landing = (dir as NSString).appendingPathComponent(name), t = s.servers[to.place]
            guard from.place != to.place || landing != source else { return .no(.failure("\(source) is in \(dir) already.")) }
            if let no = await s.openInEditor(landing, on: t) { return .no(no) }
            let taken: Bool
            switch await AISession.landing(landing, on: t) {
            case .failure(let no): return .no(.failure(no.text))
            case .success(let there):
                // ponytail: no merging into a folder that is there — its links would lead the copy out of the folder
                // the user allowed; the user's own F5 merges.
                guard there.map({ $0.kind == .file }) ?? true else { return .no(.failure("“\(name)” is in \(dir) already and isn't a file: copying over a folder or a link isn't the assistant's to do.")) }
                taken = there != nil
            }
            return .go(overwrites: taken) { s, _, _ in
                if let no = await s.openInEditor(landing, on: t) { return no }
                return await s.copy(source, from: s.servers[from.place].map { .sftp($0) } ?? .local, into: dir, on: t.map { .sftp($0) } ?? .local, over: taken ? landing : nil)
            }
        },
    ]

    /// A file open in the editor (`Editor.isOpen`) is written only through it — never under the user's unsaved
    /// text: in the chat the model's change is `propose_edit`'s card, saved by the user's ⌘S; an outside agent, which
    /// has no card, leaves it to the user. Asked at the look and again just before the write: it may have been opened
    /// while the question was up.
    private func openInEditor(_ path: String, on t: SFTPTarget?) async -> AIResult? {
        guard await Editor.isOpen(path, on: t) else { return nil }
        return .failure(proposes != nil ? "\(path) is open in the editor: propose the change with propose_edit — the user saves it there. Nothing was written."
            : "\(path) is open in Kermo's editor: tell the user the change to make there, or to close the file first — don't write it another way. Nothing was written.")
    }

    /// What has the name `path` now (a link is a link, not its file; nil: nothing), on `t` or this Mac — once its
    /// folder is the one the words say. The scope read the words: a link on the way (one `copy` put there, or a
    /// release's `current`) would lead the write out of the folder the user allowed, so it is refused, and told
    /// where the folder really is.
    private static func landing(_ path: String, on t: SFTPTarget?) async -> Result<SFTPClient.Attrs?, NotText> {
        let dir = (path as NSString).deletingLastPathComponent, env = SSHAskpass.env
        let looked = await work { flag -> (String, SFTPClient.Attrs?) in
            if let t { return try SFTP.session(t, env: env, cancel: flag, on: nil) { c in (try c.realpath(dir), try c.lstat(path)) } }
            guard let real = realpath(dir, nil) else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            defer { free(real) }
            var st = stat()
            guard lstat(path, &st) == 0 else { return (String(cString: real), nil) }
            let kind: FileItem.Kind = switch st.st_mode & S_IFMT { case S_IFREG: .file; case S_IFDIR: .dir; case S_IFLNK: .link; default: .other }
            var there = SFTPClient.Attrs.nothing
            (there.kind, there.size, there.mtime) = (kind, Int64(st.st_size), Double(st.st_mtimespec.tv_sec))
            return (String(cString: real), there)
        }
        switch looked {
        case .failure(let e): return .failure(NotText(text: "Couldn't look at \(path): \(e.localizedDescription)"))
        case .success(let (real, _)) where real != dir: return .failure(NotText(text: "\(dir) is reached through a link: it is \(real). Name it by that path. Nothing was written."))
        case .success(let (_, there)): return .success(there)
        }
    }

    /// A server file's new text by the way every save there goes (`upload`): the version it replaces into the file
    /// history, a config's check, one save of a file at a time — and nothing written if the file isn't `seen` any more.
    private func write(_ text: String, to path: String, on t: SFTPTarget, over seen: SFTPClient.Attrs) async -> AIResult {
        let tmp = NSTemporaryDirectory() + "dfm-ai-" + UUID().uuidString
        guard mkdir(tmp, 0o700) == 0 else { return .failure("Not written: no place on this Mac for the text on its way.") }
        defer { TempCopies.remove(tmp) }
        let local = URL(fileURLWithPath: tmp).appendingPathComponent((path as NSString).lastPathComponent)
        guard FileManager.default.createFile(atPath: local.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            return .failure("Not written: no place on this Mac for the text on its way.")
        }
        let state = AppDelegate.RemoteEdit(baseline: seen)
        state.prodConfirmed = true   // the session's question was that one
        var said: [String] = []
        let ok = await app.upload(local, to: path, on: t, state) { said.append($0) }
        let more = AISecrets.mask(said.joined(separator: "\n")).text
        return ok ? AIResult(["Wrote \(path).", more].filter { !$0.isEmpty }.joined(separator: " ")) : .failure(more.isEmpty ? "Not written." : more)
    }

    /// One item copied as F5 copies (a job in Activity; between two servers through this Mac), with nobody at its
    /// questions: only `over` — the file the user was asked about — is written over; any other name that
    /// is taken stays as it is and is told, an error skips its file and is told.
    private func copy(_ source: String, from: Endpoint, into dir: String, on side: Endpoint, over: String?) async -> AIResult {
        let job = FileJob(.copy, sources: [source], from: from, to: side, destDir: dir, sshEnv: SSHAskpass.env)
        let kept = OSAllocatedUnfairLock<[String]>(initialState: [])
        job.resolveConflict = { c in
            if c.dst == over, !c.replacesFolder, !c.bothDirs { return (.overwrite, false) }
            kept.withLock { $0.append(c.dst) }
            return (.skip, false)
        }
        job.resolveError = { _, _ in (.skip, true) }
        app.aiJobs.add(job)
        let name = (source as NSString).lastPathComponent
        await withTaskCancellationHandler {
            await withCheckedContinuation { done in app.ops.enqueue(job, title: "Copy \(name) → \(DirSync.place(side, dir))", asking: false) { _ in done.resume() } }
        } onCancel: { Task { @MainActor in app.ops.cancel(job) } }   // the queue's own: one still waiting its turn ends now too
        let p = job.progress, left = kept.withLock { $0 }
        var lines = ["\(p.doneFiles) of \(p.totalFiles) file\(p.totalFiles == 1 ? "" : "s") copied into \(dir)."]
        if p.state == .cancelled { lines.insert("Stopped before the end; a file cut short was removed.", at: 0) }
        if !left.isEmpty { lines.append("Already there and left as they were (\(left.count)): " + left.prefix(20).joined(separator: ", ")) }
        if !p.failed.isEmpty { lines.append("Not copied (\(p.failed.count)): " + p.failed.prefix(20).map { "\($0.path): \($0.message)" }.joined(separator: "; ")) }
        var result = Self.handOver(lines.joined(separator: "\n"))
        result.isError = p.state != .done || !left.isEmpty || !p.failed.isEmpty
        return result
    }

    /// A text file's content, `textLimit` of it at most (`cut`: there is more). A file only: a FIFO or a device read
    /// as one would hang, or take what was another reader's — and some of those say they are files (/proc/kmsg).
    static func text(_ t: SFTPTarget?, _ path: String) async -> Result<(text: String, cut: Bool), NotText> {
        guard !AICommand.consumes(path) else { return .failure(NotText(text: "\(path) isn't a file to read: a device or a kernel pipe.")) }
        let env = SSHAskpass.env, limit = textLimit
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
        case .failure(let e): return .failure(NotText(text: "Couldn't read \(path): \(e.localizedDescription)"))
        case .success(let data):
            // A cut may fall inside a character: up to three bytes back find its start.
            let cut = data.count > limit, text = (0...(cut ? 3 : 0)).lazy.compactMap { String(data: data.prefix(min(data.count, limit) - $0), encoding: .utf8) }.first
            guard let text else { return .failure(NotText(text: "\(path) isn't text (UTF-8).")) }
            return .success((text, cut))
        }
    }
    struct NotText: Error { var text: String }

    /// A folder's names, sizes and dates, `namesLimit` of them at most.
    static func listing(_ t: SFTPTarget?, _ path: String) async -> AIResult {
        let env = SSHAskpass.env
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
    }

    static let runners: [String: Runner] = [
        "focus": { s, _, _ in
            _ = await s.app.terminal?.current?.learnedOrigin()   // where an `ssh` in the tab goes, before it's told
            return s.focus()
        },
        "request_scope": { s, args, _ in await s.requestScope(args) },
        "tools": { s, args, targets in
            guard let t = s.servers[targets[0].place] else { return .failure("Tools are a server's; this Mac has none here.") }
            let id: String? = if case .string(let id)? = args["tool"] { id } else { nil }
            return await s.app.tools.toolsText(on: t, tool: id)
        },
        "plan": { s, args, _ in
            guard case .array(let items)? = args["steps"], (1...30).contains(items.count) else { return .failure("plan needs 1 to 30 steps.") }
            let steps = items.compactMap { v -> (text: String, state: String)? in   // their shape `targets` checked
                guard case .object(let o) = v, case .string(let text)? = o["text"], case .string(let state)? = o["state"] else { return nil }
                return (oneLine(text, max: 120), state)
            }
            guard steps.allSatisfy({ ["todo", "doing", "done", "skipped"].contains($0.state) }) else { return .failure("A step's state is todo, doing, done or skipped.") }
            guard let show = s.plans else { return .failure("There is no chat here to show a plan in.") }
            show(steps)
            return AIResult("Shown.")
        },
        "list_folder": { s, _, targets in   // names masked as the folder's chip has them
            let r = await listing(s.servers[targets[0].place], targets[0].path ?? "/")
            return r.isError ? r : handOver(r.text)
        },
        "read_file": { s, _, targets in
            switch await text(s.servers[targets[0].place], targets[0].path ?? "/") {
            case .failure(let no): return .failure(no.text)
            case .success(let (text, cut)): return handOver(text, cut: cut)
            }
        },
        "propose_edit": { s, args, targets in
            let path = targets[0].path ?? "/", t = s.servers[targets[0].place]
            guard case .array(let list)? = args["edits"] else { return .failure("propose_edit needs edits.") }
            let edits = list.compactMap { v -> (old: String, new: String)? in   // their shape `targets` checked
                guard case .object(let o) = v, case .string(let old)? = o["old_text"], case .string(let new)? = o["new_text"] else { return nil }
                return (old, new)
            }
            // The text as the editor has it: the file's tab (its user's), unsaved changes and all, else the file as it is now.
            let doc = EditCard.tab(t, path).flatMap { $0.cover == nil ? $0 : nil }
            let base: String, read: Bool
            if let doc {
                guard doc.storage.length <= textLimit else { return .failure("\(path) is too long to edit this way.") }
                (base, read) = (doc.storage.string, false)
            } else {
                switch await text(t, path) {
                case .failure(let no): return .failure(no.text)
                case .success(let (text, cut)):
                    guard !cut else { return .failure("\(path) is too long to edit this way.") }
                    (base, read) = (text, true)
                }
            }
            // As the editor would read it; the edits, the hidden values and a diff of up to 256 KB: off the main thread.
            let made = await Blocking.run(.userInitiated) { AIEdit.propose(edits, to: read ? AIEdit.editorText(base) : base, in: path) }
            guard !Task.isCancelled else { return .failure("Stopped. Nothing was shown.") }
            let p: AIEdit.Proposal
            switch made {
            case .failure(let no): return .failure(no.words + (doc?.isEdited == true ? " (\(path) is open in the editor with unsaved changes: the change goes on its text there.)" : ""))
            case .success(let made): p = made
            }
            // Nothing of the diff in the words: its lines are paired on the text as it is, hidden values too.
            guard let show = s.proposes else { return AIResult("The change fits \(path). Nothing is saved.") }
            show(p, t, path)
            return AIResult("Shown to the user as a diff of \(path). They keep or drop each change and apply it to the editor (or open it in Compare); nothing is saved until they press ⌘S there.")
        },
        "open_in_editor": { s, _, targets in
            let path = targets[0].path ?? "/", env = SSHAskpass.env
            guard let t = s.servers[targets[0].place] else {
                var st = stat()
                guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= Editor.sizeLimit else { return .failure("\(path) isn't a file the editor opens.") }
                Editor.open(URL(fileURLWithPath: path))
                return AIResult("Opened \(path) in the editor.")
            }
            // Looked at first: a file that can't be opened is said here, not in a sheet nobody asked for.
            let there = await work { flag in try SFTP.session(t, env: env, cancel: flag, on: nil) { try $0.stat(path) } }
            guard case .success(let a) = there, a.kind == .file, a.size <= Editor.sizeLimit else {
                if case .failure(let e) = there { return .failure("Couldn't open \(path): \(e.localizedDescription)") }
                return .failure("\(path) isn't a file the editor opens.")
            }
            s.app.remoteOpen(.edit, t, path, in: s.app.panels.first { $0.remote?.target.asUser == t } ?? s.app.active)
            return AIResult("Opening \(path) in the editor.")
        },
        "terminal_output": { s, _, targets in
            let t = s.servers[targets[0].place], tabs = s.app.terminal?.tabs ?? []
            let mine = { (tab: EmbeddedTerminal.Tab) in t.map { t in tab.target.map { ServerLock.same($0.asUser, t) } ?? false } ?? (tab.target == nil) }
            guard let tab = s.app.terminal?.current.flatMap({ mine($0) ? $0 : nil }) ?? tabs.last(where: mine) else {
                return .failure("No terminal tab of \(s.name(targets[0].place)) is open.")
            }
            // A local tab where `ssh prod` runs or ran that command, a tab whose title names a production server: its
            // text may be that server's.
            let line = tab.view.commandWithOutput().map { String($0.prefix { $0 != "\n" }) }   // the command `output()` reads
            if let p = await tab.learnedOrigin(ran: line).server, SavedServer.isProd(p), !(t.map { ServerLock.same($0, p) } ?? false) {
                return .failure("That tab's text may be from \(label(p)), a production server: the user can attach it to the chat themselves.")
            }
            guard let out = tab.view.output(), !out.isEmpty else { return .failure("Nothing to read there: no command printed anything, or a full-screen program is running.") }
            return handOver(out, limit: 16_000, keepEnd: true)
        },
        "run_command": { s, _, targets in
            guard let t = s.servers[targets[0].place], case .run(let command) = targets[0].access else { return .failure("Commands run on servers only.") }
            let ran = await run(t, command, in: targets[0].path)
            // The production log, as a command the user ran is written — and by whom.
            let log = { (exit: Int32?, error: String?) in AuditLog.write(t, "command", paths: [targets[0].path].compactMap { $0 }, command: command, exit: exit, error: error, by: "ai") }
            switch ran {
            case .failure(is CancellationError):
                log(nil, "stopped")
                return .failure("Stopped. The command may still be running on the server.")
            case .failure(let e):
                log(255, e.localizedDescription)
                return .failure("It didn't run: \(e.localizedDescription)")
            case .success(let r):
                log(r.status, r.status == nil ? "not waited for" : nil)
                if r.status == 0, s.plans != nil { s.commands.append((t, AISecrets.mask(command).text, targets[0].path)) }
                return told(r)
            }
        },
        "server_info": { s, _, targets in
            guard let t = s.servers[targets[0].place] else { return .failure("server_info is for a server; this Mac isn't one.") }
            // Server Info's own commands (Tools) — Kermo's, never a tool of that name from the user's folder: this
            // runs with no more than the right to read.
            let tool = s.app.tools.library.tools.first { $0.preset.id == "sysinfo" && $0.builtIn }?.preset
            let commands = ["load", "disks"].compactMap { id -> String? in
                guard let a = tool?.toolActions?.first(where: { $0.spec.id == id && $0.spec.readonly == true }), case .one(let c)? = a.run.command else { return nil }
                return c
            }
            let env = SSHAskpass.env
            guard case .success(let home) = await work({ try SFTP.home(t, env: env, cancel: $0) }) else { return .failure("\(label(t)) didn't answer.") }
            guard case .success(let r) = await run(t, (["uname -a"] + commands).joined(separator: "\necho\n")) else { return .failure("home folder: \(home)\nThe rest wasn't read.") }
            AuditLog.write(t, "command", paths: [], command: "server info", exit: r.status, by: "ai")
            var result = told(r)
            result.text = "home folder: \(home)\n" + result.text
            return result
        },
    ]

    /// What the user has in front of them. A folder's names and a selection are the place's content: told only where
    /// the chat may read (any grant there), else just where the panel stands.
    private func focus() -> AIResult {
        var server = false
        let c = app.aiContext
        let text = Self.focus(c, name: Self.label) { t in
            guard t?.sudo != true, self.scope.grants[self.place(t)] != nil else { return false }   // a root panel's isn't the user's grant to give
            if t.map(SavedServer.isProd) == true {
                if self.noProduction { return false }   // a grant from before Never Send
                self.readProduction = true
            }
            if t != nil { server = true }
            return true
        }
        // A local tab's text too — whoever is logged in there, as `terminal_output` counts it.
        let terminal = c.terminal.map { $0.server == nil && ($0.command != nil || $0.selection != nil) && scope.grants[place(nil)] != nil } ?? false
        if server || terminal { hasRead = true }
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
            lines.append("Terminal: a tab on \(at(t.server)) as far as Kermo can tell — who is logged in there now isn't known")
            if may(t.server) {
                if let cmd = t.command { lines.append("  last command line: \(cmd.prefix(400))") }
                if let sel = t.selection { lines.append("  selection:\n" + String(sel.prefix(4000))) }
            } else if t.command != nil || t.selection != nil { lines.append("  its text: not in this chat's scope") }
        }
        return lines.joined(separator: "\n")
    }

    /// The model's own request to widen the scope, all a task needs at once: the question a call outside it gets,
    /// one line a need. Each need is checked before anything is asked; any wrong one refuses them all; those the
    /// chat has already aren't asked again. As many as a sheet lists (an outside agent's question is one).
    private func requestScope(_ args: [String: ToolValue]) async -> AIResult {
        guard case .array(let items)? = args["needs"], (1...Confirm.listed).contains(items.count) else {
            return .failure("request_scope takes 1 to \(Confirm.listed) needs: ask for the least the task needs.")
        }
        var needs: [AIScope.Need] = [], whys: [String] = []
        for case .object(let o) in items {   // their shape `targets` checked
            func text(_ k: String) -> String { if case .string(let s)? = o[k] { s } else { "" } }
            let name = text("server")
            guard let t = await server(named: name) else { return .failure(Self.unknown(name)) }
            if noProduction, t.map(SavedServer.isProd) == true { return Self.refusedProduction.1 }
            let p = place(t)
            switch text("level") {
            case "view": needs.append(.init(place: p, level: .view))
            case "all": needs.append(.init(place: p, level: .all))
            case "write":
                guard let f = AITarget.normal(text("folder"), home: t == nil ? NSHomeDirectory() : nil) else {
                    return .failure("“write” needs its folder as an absolute path — no “..”, and no “~” on a server.")
                }
                needs.append(.init(place: p, level: .work, folder: f))
            case "commands":
                guard t != nil else { return .failure("Commands run on servers only, not on this Mac.") }
                needs.append(.init(place: p, level: .work, commands: true))
            default: return .failure("A need's level is view, write, commands or all.")
            }
            whys.append(text("why"))
        }
        guard !readOnly || needs.allSatisfy({ $0.level == .view }) else { return .failure("In Ask the assistant only reads: it can't be allowed more.") }
        let missing = needs.indices.filter { !scope.covers(needs[$0]) }
        if !missing.isEmpty {
            guard await allow(missing.map { needs[$0] }, whys: missing.map { whys[$0] }, afterRead: hasRead) else { return .failure("The user didn't allow it. Nothing was done.") }
        }
        return AIResult((missing.isEmpty ? "Already allowed: " : "Allowed until the chat ends: ") + needs.map { "\(name($0.place)): " + Self.words($0.level, $0.folder.map { [$0] } ?? [], $0.commands) }.joined(separator: "; ") + ".")
    }
}
