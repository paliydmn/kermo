import AppKit
import DFMCore

/// What Kermo's own Install… ran on a server (`tools/installed.json`, protocol §10.6): the saved server, the tool, the
/// version its `version` read right after, what ran, when.
struct ToolInstalled: Codable, Equatable {
    var server: String
    var tool: String
    var version: String?
    var command: String
    var at: Date
}

// Software that stays on a server (protocol §10.6): Install… on a tool's page — a long action Kermo makes of the
// preset's `install` — what Kermo installed where, and Clean Up Kermo Files on a server's page.
extension ToolRunner {
    /// The row Install… of `tool` on `t`'s server runs on: its tool page says how it goes.
    static func installRow(_ tool: String, on t: SFTPTarget) -> String { ServerRow.key(t.asUser) + " install:" + tool }

    /// Why Install… of `tool` isn't offered on `s` (at `t`) — said on its row in place of the button; nil: it is. Not
    /// on a read-only server, nor where installs are off (production's default); the server's system known, with a
    /// command for its package manager, or a script with a sha256 to check it by.
    func whyNoInstall(_ tool: LoadedTool, on s: SavedServer, _ t: SFTPTarget) -> String? {
        guard let i = tool.preset.install else { return "it installs nothing" }
        if s.readOnly { return "read-only: no installs" }
        if !s.allowsInstalls { return "installs are off for " + (s.prod ? "production" : "this server") + " (Edit Server…)" }
        guard let facts = answer(t)?.answer.facts else { return "not checked yet" }
        guard i.run(pkg: facts.pkg) != nil else { return "no install for " + (facts.said.isEmpty ? "its system" : facts.said) }
        if i.command(pkg: facts.pkg) == nil, i.script?.sha256 == nil { return "its script has no sha256 to check it by" }
        return nil
    }

    /// Install… of `tool` on `s` at `t` (§10.6): the lock; its prechecks in one run as the login user — one that fails says
    /// why, and nothing runs; a script fetched on this Mac and checked against its sha256, or nothing runs; then as any
    /// long action (`perform`): the question with the exact command, what stays on the server, its `after`; the job in
    /// Activity, the line on the tool's page. What stopped it before the question; nil once it's asked.
    func install(_ tool: LoadedTool, on s: SavedServer, _ t: SFTPTarget) async -> String? {
        let p = tool.preset, t = t.asUser, name = p.tool ?? p.title
        if let why = whyNoInstall(tool, on: s, t) { return "Install \(name): \(why) — nothing ran" }
        guard let i = p.install, let pkg = answer(t)?.answer.facts.pkg, var a = i.action(pkg: pkg, title: name) else { return nil }
        guard await ServerLock.authorize(t, "install \(name) on") else { return "Install \(name): \(s.title) stays locked — nothing ran" }
        let env = SSHAskpass.env, command = Self.command, panel = app.active
        if let checks = i.precheck, !checks.isEmpty {
            guard let pre = i.prechecks(scope(p, on: s, t)) else { return "Install \(name): a value its checks need isn't set — nothing ran" }
            let r = await panel.busy("Checking \(s.title) for \(name)…") { flag in try ToolExec.run({ _ in pre }, on: t, timeout: 30, cancel: flag, env: env, command: command) }
            guard case .success(let ran) = r, ran.started else {
                let why = switch r { case .success(let ran): ran.stopped ?? ran.errors; case .failure(let e): e.localizedDescription }
                return "Install \(name): its checks didn't run on \(s.title): \(why.trimmingCharacters(in: .whitespacesAndNewlines)) — nothing ran"
            }
            if let why = i.refusal(prechecks: ran.text, nonce: pre.nonce) { return "Install \(name) on \(s.title): \(why) — nothing ran" }
        }
        var copy = tool
        copy.preset.env = nil   // the tool's own values (a repository, a password file) aren't the installer's
        var notes: [String] = []
        if let run = a.run.script, let sc = i.script {
            guard let url = URL(string: sc.url), ["https", "file"].contains(url.scheme ?? "") else { return "Install \(name): \(sc.url) isn't an https address — nothing ran" }
            let data: Data
            do { data = try await Updates.get(url) } catch { return "Install \(name): its script couldn't be fetched from \(sc.url): \(error.localizedDescription) — nothing ran" }
            let sum = ToolCatalog.sum(data)
            guard sum == sc.sha256?.lowercased() else {
                return "Install \(name): the script at \(sc.url) isn't the one the tool names (sha256 \(sum.prefix(12))…, not \(sc.sha256?.prefix(12) ?? "")…) — nothing ran"
            }
            copy.scripts[run] = String(decoding: data, as: UTF8.self)
            let values = (sc.env ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            notes.append("The vendor's script, fetched on this Mac and checked: sha256 \(sum.prefix(12))…" + (values.isEmpty ? "" : ", with \(values)")
                         + ". Show Exactly What Runs shows it.")
        }
        if let stays = i.lines.last(where: { $0.what == "stays on the server" }) { notes.append("Stays on the server after it: \(stays.how).") }
        notes += [i.after.map { ToolTemplate.text($0, scope(p, on: s, t)) }].compactMap { $0 }
        a.spec.message = notes.joined(separator: "\n")
        perform(a, of: copy, row: nil, onRow: false, id: Self.installRow(p.id, on: t), from: nil, on: s, t)
        return nil
    }

    /// The action an Install job ran, for its line and Retry: as `install` makes it for that server's system now.
    func installAction(_ p: ToolPreset, on t: SFTPTarget) -> ToolAction? {
        answer(t).flatMap { p.install?.action(pkg: $0.answer.facts.pkg, title: p.tool ?? p.title) }
    }

    /// An Install job ended (`ToolJobs.finish`): the server asked again — the program is there now, or half — and, where
    /// it went well, kept in `installed.json` with what its `version` says now, read as the login user (§10.5).
    func installEnded(_ j: ToolJob) {
        askAgain(j.target)
        app.toolsKnown(on: j.target)
        guard j.ok, !j.server.isEmpty, let tool = library.tools.first(where: { $0.preset.id == j.tool }), let i = tool.preset.install,
              let pkg = answer(j.target)?.answer.facts.pkg else { return }
        let command = i.command(pkg: pkg) ?? i.script.map { ([$0.url] + ($0.env ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }).joined(separator: " ") } ?? ""
        let s = app.savedServer(at: j.target) ?? SavedServer(target: j.target), t = j.target, env = SSHAskpass.env, run = Self.command
        let read = tool.preset.version.flatMap { v in try? ToolPayload.of(ToolRun(command: .one(v.command), sudo: false), in: tool.preset, scope: scope(tool.preset, on: s, t)).payload }
        Task {
            let out = await Blocking.run { read.flatMap { p in try? ToolExec.run({ _ in p }, on: t, timeout: 10, cancel: CancelFlag(), env: env, command: run) }?.text }
            installed.removeAll { $0.server == j.server && $0.tool == j.tool }
            installed.append(ToolInstalled(server: j.server, tool: j.tool, version: out.flatMap { tool.preset.version?.found(in: $0) }, command: command, at: Date()))
            if let dir = Self.own?.path { Config.save("installed.json", installed, in: dir) }
            ToolsWindow.refresh()
        }
    }

    /// "dpl 0.7.1, 2 Nov" for each tool Kermo installed on `s`.
    func installedSaid(on s: SavedServer) -> [String] {
        installed.filter { $0.server == s.id.uuidString }.map { r in
            [r.tool, r.version].compactMap { $0 }.joined(separator: " ") + ", " + r.at.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    /// Clean Up Kermo Files (§10.6, Q20): `~/.cache/kermo` on `t`'s server — its size, then removed, asked first; not
    /// while a long job runs from it. What came of it, as the server's page says it.
    func cleanUp(on s: SavedServer, _ t: SFTPTarget, window: NSWindow?) async -> (line: String, failed: Bool) {
        let t = t.asUser, env = SSHAskpass.env, command = Self.command, panel = app.active
        guard await ServerLock.authorize(t, "clean up Kermo's files on") else { return ("\(s.title) stays locked", false) }
        func run(_ remove: Bool) async -> ToolExec.Ran? {
            let r = await panel.busy("Kermo's files on \(s.title)…") { flag in
                try ToolExec.run({ _ in ToolLong.cleanUp(remove: remove) }, on: t, timeout: 30, cancel: flag, env: env, command: command)
            }
            return (try? r.get()).flatMap { $0.started ? $0 : nil }
        }
        guard let looked = await run(false), looked.status == 0 else { return ("Kermo's files on \(s.title) couldn't be looked at", true) }
        let (bytes, running) = ToolLong.cleanUp(looked.text)
        guard let bytes else { return ("No Kermo files on \(s.title)", false) }
        if running > 0 { return ("A long job runs on \(s.title) from Kermo's files: Clean Up once it ends (Activity, ⌥⌘J)", false) }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        var c = Confirm("Remove Kermo's files on \(s.title)?", on: t, action: "Remove")
        c.items = [Confirm.Item(name: "~/.cache/kermo", size: size)]
        c.runs = "Long jobs' logs and what was uploaded for them: Activity can't show those logs after this. Nothing else of Kermo's is on the server."
        c.command = "rm -rf ~/.cache/kermo"
        c.irreversible = true
        guard await app.confirm(c, on: window) == 0 else { return ("Kermo's files on \(s.title): kept", false) }
        guard let ran = await run(true) else { return ("Kermo's files on \(s.title) couldn't be removed", true) }
        switch ran.status {
        case 0: return ("Kermo's files on \(s.title) are removed (\(size))", false)
        case 3: return ("A long job started on \(s.title) meanwhile: its files stay", false)
        default: return ("Kermo's files on \(s.title) couldn't all be removed: " + (ran.errors.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(ran.status)"), true)
        }
    }
}
