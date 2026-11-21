import AppKit
import DFMCore

// The assistant's way into Tools (task 23 PR 9): `tools` says what a server has, `tool_action` runs an action as its
// button does — the tool trusted and in use there, `why`, the row read again by its key, the values checked as the
// form checks them, the payload; then, in `AISession`'s chain, the scope, the gate and one question, the run, the
// production log "by ai". Nothing runs another way.

extension ToolRunner {
    /// An action the assistant names: of a tool you use (trusted), on the tool or on a row of its list.
    struct ForAI {
        let tool: LoadedTool, action: ToolAction, onRow: Bool
    }

    /// `toolID`'s action `actionID`, as the library has it now; nil: none.
    func forAI(_ toolID: String, _ actionID: String) -> ForAI? {
        guard let tool = library.trusted(trust).first(where: { $0.preset.id == toolID }) else { return nil }
        let p = tool.preset
        if p.list != nil, let a = p.listActions.first(where: { $0.spec.id == actionID }) { return ForAI(tool: tool, action: a, onRow: true) }
        return ((p.toolActions ?? []) + [p.commandAction].compactMap { $0 }).first { $0.spec.id == actionID }.map { ForAI(tool: tool, action: $0, onRow: false) }
    }

    /// What an action is to the chat's scope: a look only if Kermo wrote it (a built-in's `readonly` — your tool's is
    /// a claim, and the model may have written it); asked every time if it's `dangerous` or `confirm`. Not known: the
    /// strictest.
    static func access(_ f: ForAI?) -> AITarget.Access {
        guard let f else { return .tool(changes: true, asks: true) }
        let s = f.action.spec
        return .tool(changes: !(f.tool.builtIn && s.readonly == true), asks: s.dangerous == true || s.confirm == true)
    }

    /// A refusal in words, as the model gets it.
    struct NotForAI: Error { let result: AIResult }

    /// What `toolID`'s action `actionID` is to the scope (`access`) — or, before anyone is asked, why it isn't run:
    /// no such action of a tool you use, or one the user presses (`notForAI`).
    func accessForAI(_ toolID: String, _ actionID: String) -> Result<AITarget.Access, NotForAI> {
        guard let f = forAI(toolID, actionID) else { return .failure(NotForAI(result: .failure("No action “\(actionID)” of a tool “\(toolID)” you use: tools(server) lists them. Nothing ran."))) }
        if let no = Self.notForAI(f.action, of: f.tool.preset) {
            return .failure(NotForAI(result: .failure("“\((f.action.spec.title ?? f.action.spec.id).replacingOccurrences(of: "…", with: ""))”: \(no) — the user presses it in Tools. Nothing ran.")))
        }
        return .success(Self.access(f))
    }

    /// Why the assistant doesn't run `a` itself — the user presses it in Tools —, or nil: it runs on this Mac, it
    /// opens something (a window that follows, rows one level down, a terminal, the editor, a place in Kermo), it's a
    /// long job, it takes a secret or a file from this Mac, or Kermo doesn't run it from a button.
    static func notForAI(_ a: ToolAction, of p: ToolPreset) -> String? {
        let s = a.spec
        if (a.run.where ?? p.where) == .mac { return "it runs on this Mac" }
        if s.long == true { return "it's a long job" }
        if s.edit != nil || s.open != nil || s.goto != nil || ![nil, .line, .window, .silent].contains(s.output) { return "it opens something for the user" }
        if (s.inputs ?? []).contains(where: { $0.info.type == .secret || $0.uploads }) { return "it takes a secret or a file from this Mac" }
        return runs(a, of: p) ? nil : "Kermo doesn't run it from here"
    }

    // MARK: tools

    /// `tools`: the tools in use on `t`'s server, each with its actions; with `toolID`, its list's rows read now.
    func toolsText(on t: SFTPTarget, tool toolID: String?) async -> AIResult {
        let name = AISession.label(t)
        guard await answerNow(t) != nil, let inUse = using(t)?.tools else { return .failure("\(name) didn't say what it has.") }
        let shown = inUse.filter { $0.preset.list != nil || !(($0.preset.toolActions ?? []) + [$0.preset.commandAction].compactMap { $0 }).isEmpty }
        guard let toolID else {
            guard !shown.isEmpty else { return AIResult("No tools are in use on \(name).") }
            return AISession.handOver("Tools in use on \(name) — tool_action runs an action as its button does:\n\n" + shown.map { describe($0, on: t) }.joined(separator: "\n\n"))
        }
        guard let tool = shown.first(where: { $0.preset.id == toolID }) else { return .failure("No tool “\(toolID)” is in use on \(name): tools(server) lists them.") }
        var text = describe(tool, on: t)
        if tool.preset.list != nil {
            let s = app.savedServer(at: t) ?? SavedServer(target: t.asUser), lister = ToolListSource.lister(app, tool, s, t), env = SSHAskpass.env
            switch await AISession.work({ try lister.read(env, $0, header: false) }) {
            case .failure(let e): text += "\n\nIts list wasn't read: \(e.localizedDescription)"
            case .success(let read):
                let rows = read.rows.prefix(AISession.namesLimit).map { r in [r.key, r.title, r.subtitle, r.detail].map { AISession.oneLine($0, mask: false) }.joined(separator: "\t") }
                text += "\n\nIts rows (\(read.rows.count)):\n" + (rows.isEmpty ? "none" : "key\ttitle\tsubtitle\tdetail\n" + rows.joined(separator: "\n"))
                    + (read.rows.count > rows.count ? "\n[\(read.rows.count - rows.count) more rows not shown.]" : "")
            }
        }
        return AISession.handOver(text)
    }

    /// A tool as the model reads it: its id and title, what it's for, what it still needs, its actions — those the user
    /// presses themselves apart.
    private func describe(_ tool: LoadedTool, on t: SFTPTarget) -> String {
        let p = tool.preset, known = answer(t)?.answer
        var lines = ["\(p.id) — \(p.title)" + (p.about.map { ": " + $0 } ?? "")]
        if !toSetUp(tool, on: t).isEmpty { lines.append("  Set Up on \(AISession.label(t)) first — the user's, in Tools: its actions don't run till then.") }
        if p.list != nil { lines.append("  rows: its list — tools(server, tool: \"\(p.id)\") reads them") }
        var theirs: [String] = []
        for (onRow, actions) in [(true, p.list == nil ? [] : p.listActions), (false, (p.toolActions ?? []) + [p.commandAction].compactMap { $0 })] {
            let visible = known?.visible(actions, of: p) ?? actions
            var mine: [String] = []
            for a in visible {
                let title = "\(a.spec.id) “\(a.spec.title ?? a.spec.id)”"
                if let no = Self.notForAI(a, of: p) { theirs.append("\(title) (\(no))"); continue }
                guard case .tool(let changes, let asks) = Self.access(ForAI(tool: tool, action: a, onRow: onRow)) else { continue }
                let how = [changes ? "changes" : "reads", asks ? "asks every time" : nil, (a.run.sudo ?? p.sudo ?? false) ? "as root" : nil].compactMap { $0 }
                let inputs = (a.spec.inputs ?? []).map { i in
                    let kind = switch i.info.type {
                    case .choice: "one of " + (i.info.options ?? []).joined(separator: ", ")
                    case .choiceFrom: "one of what the server lists"
                    default: "text"
                    }
                    return "\(i.info.name) (" + ([i.info.title, kind, i.info.optional == true ? "optional" : nil, i.info.default.map { "default " + $0 }, i.info.placeholder.map { "like " + $0 },
                                                   i.info.pattern.map { "pattern " + $0 }].compactMap { $0 }).joined(separator: "; ") + ")"
                }
                mine.append("    \(title) (\(how.joined(separator: ", ")))" + (inputs.isEmpty ? "" : " — inputs: " + inputs.joined(separator: ", ")))
            }
            if !mine.isEmpty { lines.append(onRow ? "  on a row:" : "  on the tool:"); lines += mine }
        }
        if !theirs.isEmpty { lines.append("  the user's, in Tools: " + theirs.joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }

    // MARK: tool_action

    /// `tool_action`'s look, the server unlocked and before the question: the action as the library has it now —
    /// the one the scope read (`seen`), or nothing —, in use on `t`'s server, `why`, its row read again by its key,
    /// the values checked as the form checks them, the payload. The question (when the scope asks) says what runs,
    /// as whom, on which row, and the action's message; the runner holds the tool's change, checks a row that
    /// `verify`s once more, and runs what was asked about.
    func lookForAI(_ args: [String: ToolValue], on t: SFTPTarget, seen: AITarget.Access) async -> AISession.Looked {
        func text(_ k: String) -> String? { if case .string(let s)? = args[k] { s } else { nil } }
        let name = AISession.label(t), toolID = text("tool") ?? "", actionID = text("action") ?? ""
        guard let f = forAI(toolID, actionID) else { return .no(.failure("No action “\(actionID)” of a tool “\(toolID)” you use: tools(server) lists them. Nothing ran.")) }
        guard Self.access(f) == seen else { return .no(.failure("\(f.tool.preset.title) changed while Kermo looked. Nothing ran.")) }
        let (tool, a, p) = (f.tool, f.action, f.tool.preset), verb = (a.spec.title ?? a.spec.id).replacingOccurrences(of: "…", with: "")
        if let no = Self.notForAI(a, of: p) { return .no(.failure("“\(verb)”: \(no) — the user presses it in Tools. Nothing ran.")) }
        guard await answerNow(t) != nil, using(t)?.tools.contains(where: { $0.path == tool.path }) == true else {
            return .no(.failure("\(p.title) isn't in use on \(name): tools(server) lists what is. Nothing ran."))
        }
        guard toSetUp(tool, on: t).isEmpty else { return .no(.failure("\(p.title) needs Set Up on \(name) first — the user's, in Tools. Nothing ran.")) }
        let s = app.savedServer(at: t) ?? SavedServer(target: t.asUser), env = SSHAskpass.env
        var row: ToolRow?
        if f.onRow {
            guard let key = text("row") else { return .no(.failure("“\(a.spec.id)” acts on a row: give its key, as tools(server, tool) lists them. Nothing ran.")) }
            let lister = ToolListSource.lister(app, tool, s, t)
            switch await AISession.work({ try lister.read(env, $0, header: false) }) {
            case .failure(let e): return .no(.failure("\(p.title)'s list on \(name) wasn't read: \(e.localizedDescription). Nothing ran."))
            case .success(let read):
                guard let r = read.rows.first(where: { $0.key == key }) else { return .no(.failure("No row “\(key)” in \(p.title)'s list on \(name) now. Nothing ran.")) }
                guard a.offered(on: r.record) else { return .no(.failure("“\(a.spec.id)” isn't offered on the row “\(key)”. Nothing ran.")) }
                row = r
            }
        } else if args["row"] != nil { return .no(.failure("“\(a.spec.id)” is the tool's, not a row's: leave row out. Nothing ran.")) }
        if let why = why(a, of: tool, row: row, onRow: f.onRow, id: ServerRow.key(t.asUser) + " " + p.id + " ai", on: s, t) { return .no(.failure(why)) }

        // The values, as the form would take them: a choice is one of its choices, each value as its field checks it.
        var given: [String: String] = [:]
        if case .array(let items)? = args["inputs"] {
            for case .object(let o) in items { if case .string(let n)? = o["name"], case .string(let v)? = o["value"] { given[n] = v } }
        }
        let inputs = a.spec.inputs ?? []
        if let stray = given.keys.sorted().first(where: { n in !inputs.contains { $0.info.name == n } }) {
            return .no(.failure("“\(a.spec.id)” takes no value “\(stray)”: tools(server, tool) lists what it takes. Nothing ran."))
        }
        let form = ToolForm(a, of: tool, scope(p, on: s, t, rows: row?.records ?? []), filled: given)
        defer { form.close() }
        if inputs.contains(where: { $0.info.type == .choiceFrom }) {
            form.load(on: t, env: env)
            await withTaskCancellationHandler { await form.loading?.value } onCancel: { Task { @MainActor in form.close() } }   // Stop ends its reads
            guard !Task.isCancelled else { return .no(.failure("Stopped. Nothing ran.")) }
        }
        for i in inputs {
            let choices: [String]? = switch i.info.type {
            case .choice: i.info.options ?? []
            case .choiceFrom: if case .ready(let list)? = form.choices[i.info.name] { list } else { nil }
            default: nil
            }
            if let v = given[i.info.name], let choices, !choices.contains(v) {
                return .no(.failure("\(i.info.name): “\(v)” isn't one of \(choices.prefix(50).joined(separator: ", ")). Nothing ran."))
            }
            // A choice the form would make by itself — the server's first jail, a list's first — is the user's to see: the
            // model names it; only a `choice`'s own default, one of its options, stands.
            if given[i.info.name] == nil, let choices, i.info.type == .choiceFrom || !(i.info.default.map(choices.contains) ?? false) {
                return .no(.failure("\(i.info.name): give one of \(choices.prefix(50).joined(separator: ", ")). Nothing ran."))
            }
            if let no = form.problem(i) { return .no(.failure("\(i.info.name): \(no). Nothing ran.")) }
        }
        let scope = form.filled
        if let why = Self.refusal(a, of: p, scope) { return .no(.failure("\(verb): \(why). Nothing ran.")) }
        let payload: ToolPayload, willRun: String
        do { (payload, willRun) = try ToolPayload.of(a.run, in: p, scope: scope, scripts: tool.scripts) } catch { return .no(.failure("\(verb): \(error). Nothing ran.")) }

        let sudo = a.run.sudo ?? p.sudo ?? false
        var c = Confirm("Let the assistant run “\(verb)” on \(name)?", on: t.asRoot(sudo), action: "Allow Once")
        if let row { c.items = [Confirm.Item(name: row.title)] }
        (c.runs, c.command) = ("\(p.title): " + AppDelegate.runs(on: t.asRoot(sudo)), willRun)
        c.note = a.spec.message.map { ToolTemplate.text($0, scope) }
        c.irreversible = a.spec.dangerous == true
        c.returnCancels = true
        let verify = row != nil && (a.spec.verify ?? (a.spec.dangerous == true))
        let lister = verify ? ToolListSource.lister(app, tool, s, t) : nil, rowKey = row?.key, record = row?.record
        // A change holds the tool's change, as the button's does — an own tool's `readonly` too: it's a change to the scope.
        let holds: Bool = if case .tool(true, _) = seen { true } else { false }
        let key = ServerRow.key(t.asUser) + " " + p.id
        return .go(overwrites: false, { _, _, _ in
            if holds {
                if let other = self.changing[key] { return .failure("\(p.title) on \(name) is busy: \(other.replacingOccurrences(of: "…", with: "")) runs. Nothing ran.") }
                self.changing[key] = verb
            }
            defer { if holds { self.changing[key] = nil } }
            let timeout = a.run.timeout ?? 30
            let r = await AISession.work { flag in
                if let lister, let rowKey {   // the row as it was asked about, field for field, or nothing runs
                    guard try lister.read(env, flag, header: false).current(rowKey) == record else { throw Changed() }
                }
                return try Self.exec(a.run, of: tool, scope, on: t, timeout: timeout, env: env, cancel: flag)
            }
            _ = self.ran(r, a, of: p, on: t, shown: payload.shown, by: "ai")
            // An open list of the tool there, read again as after its button (D-233 (2)).
            if !Self.looks(a), a.spec.refresh != false { self.jobs.reread(ServerRow.key(t.asUser) + " tool:" + p.id, on: t) }
            return Self.told(r, a, scope)
        }, asks: c)
    }

    /// What a run came to, for the model: how it ended (and its `done`), then what it printed — the payload's
    /// secrets and the sudo password as •••.
    private static func told(_ r: Result<(ran: ToolExec.Ran, payload: ToolPayload), Error>, _ a: ToolAction, _ scope: ToolTemplate.Scope) -> AIResult {
        switch r {
        case .failure(is CancellationError): return .failure("Stopped. It may have run on the server.")
        case .failure(is ToolExec.NoPassword): return .failure("No sudo password was given. Nothing ran.")
        case .failure(is Changed): return .failure("The row changed since Kermo looked. Nothing ran.")
        case .failure(let e): return .failure("It didn't run: \(e.localizedDescription)")
        case .success(let (ran, payload)):
            let ok = ran.stopped == nil && a.run.succeeded(ran.status)
            let how = ran.stopped.map { "Stopped: \($0)." } ?? "exit \(ran.status)" + (ok ? a.spec.done.map { " — " + ToolTemplate.text($0, scope) } ?? "" : "")
            let errors = ran.errors.isEmpty ? "" : "[stderr]\n" + payload.mask(ran.errors, password: ran.password)
            var result = AISession.handOver([how, payload.mask(ran.text, password: ran.password), errors].filter { !$0.isEmpty }.joined(separator: "\n"))
            result.isError = !ok
            return result
        }
    }
}
