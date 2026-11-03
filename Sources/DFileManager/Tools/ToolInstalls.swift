import AppKit
import DFMCore

/// What Kermo's own Install… ran on a server (`tools/installed.json`, protocol §10.6): the saved server and the login it
/// ran as, the tool, the version its `version` read right after, what ran, when.
struct ToolInstalled: Codable, Equatable {
    var server: String
    var target: SFTPTarget
    var tool: String
    var version: String?
    var command: String
    var at: Date

    /// "3 Nov".
    var day: String { at.formatted(.dateTime.day().month(.abbreviated)) }
}

// Software that stays on a server (protocol §10.6): Install… and Uninstall… on a tool's page — long actions Kermo
// makes of the preset's `install` and `uninstall` — what Kermo installed where, and Clean Up Kermo Files on a
// server's page.
extension ToolRunner {
    /// The row Install… (Uninstall…) of `tool` on `t`'s server runs on: its tool page says how it goes.
    static func installRow(_ tool: String, on t: SFTPTarget, uninstall: Bool = false) -> String {
        ServerRow.key(t.asUser) + (uninstall ? " uninstall:" : " install:") + tool
    }

    /// What Kermo installed of `tool` on `s`, and when.
    func installed(_ tool: String, on s: SavedServer) -> ToolInstalled? { installed.first { $0.server == s.id.uuidString && $0.tool == tool } }

    /// Why Install… (Uninstall…) of `tool` isn't offered on `s` (at `t`) — said on its row in place of the button;
    /// nil: it is. Not for a tool not in use (its checks would run), on a read-only server, nor where installs are off
    /// (production's default); Uninstall only where Kermo installed it; the server's system known, with a command for
    /// its package manager, or a script with a sha256 to check it by.
    func whyNoInstall(_ tool: LoadedTool, on s: SavedServer, _ t: SFTPTarget, uninstall: Bool = false) -> String? {
        guard let i = uninstall ? tool.preset.uninstall : tool.preset.install else { return uninstall ? "it has no uninstall" : "it installs nothing" }
        guard trust.trusts(tool) else { return "\(tool.preset.title) isn't in use yet" }
        if s.readOnly { return "read-only: no installs" }
        if !s.allowsInstalls { return "installs are off for " + (s.prod ? "production" : "this server") + " (Edit Server…)" }
        if uninstall, installed(tool.preset.id, on: s) == nil { return "Kermo didn't install it there" }
        guard let facts = answer(t)?.answer.facts else { return "not checked yet" }
        guard i.run(pkg: facts.pkg) != nil else { return "no \(uninstall ? "uninstall" : "install") for " + (facts.said.isEmpty ? "its system" : facts.said) }
        if i.command(pkg: facts.pkg) == nil, i.script?.sha256 == nil { return "its script has no sha256 to check it by" }
        return nil
    }

    /// Install… of `tool` on `s` at `t` (§10.6), or Uninstall…: the lock; its prechecks; a script fetched and checked;
    /// then as any long action (`perform`): the question with the exact command, what stays on the server, its `after`
    /// (Uninstall: what it `keeps`) — templates the question fills in; the job in Activity, the line on the tool's
    /// page. What stopped it before the question, else its run — done once it's asked and, if you said so, started.
    func install(_ tool: LoadedTool, on s: SavedServer, _ t: SFTPTarget, uninstall: Bool = false) async -> (stop: String?, run: Task<Void, Never>?) {
        let p = tool.preset, t = t.asUser, name = p.tool ?? p.title, verb = uninstall ? "Uninstall" : "Install"
        func stop(_ why: String) -> (stop: String?, run: Task<Void, Never>?) { ("\(verb) \(name) on \(s.title): \(why) — nothing ran", nil) }
        if let why = whyNoInstall(tool, on: s, t, uninstall: uninstall) { return stop(why) }
        guard let i = uninstall ? p.uninstall : p.install, let pkg = answer(t)?.answer.facts.pkg,
              var a = i.action(pkg: pkg, title: name, uninstall: uninstall) else { return (nil, nil) }
        guard await ServerLock.authorize(t, "\(verb.lowercased()) \(name) on") else { return stop("it stays locked") }
        if let why = await prechecked(i, of: p, name, on: s, t) { return stop(why) }
        var copy = tool
        copy.preset.env = nil   // the tool's own values (a repository, a password file) aren't the installer's
        var notes: [String] = []
        if let run = a.run.script, let sc = i.script {
            switch await fetch(sc) {
            case .failure(let e): return stop(e.localizedDescription)
            case .success(let (text, sum)):
                copy.scripts[run] = text
                notes.append("The vendor's script, fetched on this Mac and checked: sha256 \(sum.prefix(12))… — \(sc.said). Show Exactly What Runs shows it.")
            }
        }
        if uninstall, let r = installed(p.id, on: s) { notes.append("Kermo installed \([name, r.version].compactMap { $0 }.joined(separator: " ")) here on \(r.day).") }
        if let stays = p.install?.leaves?.said { notes.append((uninstall ? "Install left: " : "Stays on the server after it: ") + stays + ".") }
        notes += [uninstall ? i.keeps.map { "Stays after it: \($0)." } : i.after].compactMap { $0 }
        a.spec.message = notes.joined(separator: "\n")
        return (nil, perform(a, of: copy, row: nil, onRow: false, id: Self.installRow(p.id, on: t, uninstall: uninstall), from: nil, on: s, t))
    }

    /// `i`'s prechecks in one run as the login user (§10.5): why one stopped it, or nil when all passed.
    private func prechecked(_ i: ToolInstall, of p: ToolPreset, _ name: String, on s: SavedServer, _ t: SFTPTarget) async -> String? {
        guard let checks = i.precheck, !checks.isEmpty else { return nil }
        guard let pre = i.prechecks(scope(p, on: s, t)) else { return "a value its checks need isn't set" }
        let env = SSHAskpass.env, command = Self.command
        let r = await app.active.busy("Checking \(s.title) for \(name)…") { flag in try ToolExec.run({ _ in pre }, on: t, timeout: 30, cancel: flag, env: env, command: command) }
        guard case .success(let ran) = r, ran.started else {
            let why = switch r { case .success(let ran): ran.stopped ?? ran.errors; case .failure(let e): e.localizedDescription }
            return "its checks didn't run: " + why.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return i.refusal(prechecks: ran.text, nonce: pre.nonce)
    }

    /// The vendor's script, fetched on this Mac (https; file:// a folder on a disk, as a catalog's) and taken only with
    /// the sha256 the tool names: its text and its sha256.
    private func fetch(_ sc: ToolInstall.Script) async -> Result<(text: String, sum: String), Error> {
        guard let url = URL(string: sc.url), ["https", "file"].contains(url.scheme ?? "") else {
            return .failure(JobErrorMessage("\(sc.url) isn't an https:// (or file://) address"))
        }
        let data: Data
        do { data = try await Updates.get(url) } catch {
            return .failure(JobErrorMessage("its script couldn't be fetched from \(sc.url): \(error.localizedDescription)"))
        }
        let sum = ToolCatalog.sum(data)
        guard sum == sc.sha256?.lowercased() else {
            return .failure(JobErrorMessage("the script at \(sc.url) isn't the one the tool names (sha256 \(sum.prefix(12))…, not \(sc.sha256?.prefix(12) ?? "")…)"))
        }
        return .success((String(decoding: data, as: UTF8.self), sum))
    }

    /// The action an Install or Uninstall job ran, for its line and Retry: as `install` makes it for that server's
    /// system now.
    func installAction(_ p: ToolPreset, on t: SFTPTarget, uninstall: Bool) -> ToolAction? {
        answer(t).flatMap { (uninstall ? p.uninstall : p.install)?.action(pkg: $0.answer.facts.pkg, title: p.tool ?? p.title, uninstall: uninstall) }
    }

    /// An Install or Uninstall job ended (`ToolJobs.finish`): the server asked again — the program is there now, or
    /// half, or gone. Where it went well, `installed.json` says so: an install with what its `version` says now, read
    /// as the login user (§10.5); an uninstall's record gone — the tool may be gone from Kermo by then (Remove…).
    func installEnded(_ j: ToolJob) {
        askAgain(j.target)
        app.toolsKnown(on: j.target)
        guard j.ok, !j.server.isEmpty else { return }
        guard j.action == ToolInstall.actionID else {
            installed.removeAll { $0.server == j.server && $0.tool == j.tool }
            if let dir = Self.own?.path { Config.save("installed.json", installed, in: dir) }
            return ToolsWindow.refresh()
        }
        guard let tool = library.tools.first(where: { $0.preset.id == j.tool }), let i = tool.preset.install,
              let pkg = answer(j.target)?.answer.facts.pkg else { return }
        let command = i.command(pkg: pkg) ?? i.script?.said ?? ""
        let s = app.savedServer(at: j.target) ?? SavedServer(target: j.target), t = j.target, env = SSHAskpass.env, run = Self.command
        let read = tool.preset.version.flatMap { v in try? ToolPayload.of(ToolRun(command: .one(v.command), sudo: false), in: tool.preset, scope: scope(tool.preset, on: s, t)).payload }
        Task {
            let out = await Blocking.run { read.flatMap { p in try? ToolExec.run({ _ in p }, on: t, timeout: 10, cancel: CancelFlag(), env: env, command: run) }?.text }
            installed.removeAll { $0.server == j.server && $0.tool == j.tool }
            installed.append(ToolInstalled(server: j.server, target: j.target, tool: j.tool, version: out.flatMap { tool.preset.version?.found(in: $0) }, command: command, at: Date()))
            if let dir = Self.own?.path { Config.save("installed.json", installed, in: dir) }
            ToolsWindow.refresh()
        }
    }

    /// "dpl 0.7.1, 2 Nov" for each tool Kermo installed on `s`.
    func installedSaid(on s: SavedServer) -> [String] {
        installed.filter { $0.server == s.id.uuidString }.map { r in [r.tool, r.version].compactMap { $0 }.joined(separator: " ") + ", " + r.day }
    }

    /// Clean Up Kermo Files (§10.6, Q20): `~/.cache/kermo` on `t`'s server — its size, then removed, asked first; not
    /// while a long job runs from it, nor while a change of this Kermo's runs there (a job's upload goes there before
    /// the job has a pid). In the production log as any change. What came of it, as the server's page says it.
    func cleanUp(on s: SavedServer, _ t: SFTPTarget, window: NSWindow?) async -> (line: String, failed: Bool) {
        let t = t.asUser, env = SSHAskpass.env, command = Self.command, panel = app.active
        let busy = { [app] in app.serviceRuns.keys.contains { $0.hasPrefix(ServerRow.key(t) + " ") } }
        if busy() { return ("A change runs on \(s.title): Clean Up once it's done", false) }
        guard await ServerLock.authorize(t, "clean up Kermo's files on") else { return ("\(s.title) stays locked", false) }
        func run(_ remove: Bool) async -> ToolExec.Ran? {
            let r = await panel.busy("Kermo's files on \(s.title)…") { flag in
                try ToolExec.run({ _ in ToolLong.cleanUp(remove: remove) }, on: t, timeout: 30, cancel: flag, env: env, command: command)
            }
            return (try? r.get()).flatMap { $0.started ? $0 : nil }
        }
        guard let looked = await run(false), looked.status == 0 else { return ("Kermo's files on \(s.title) couldn't be looked at", true) }
        let (bytes, running) = ToolLong.cleanUpSaid(looked.text)
        guard let bytes else { return ("No Kermo files on \(s.title)", false) }
        if running > 0 { return ("A long job runs on \(s.title) from Kermo's files: Clean Up once it ends (Activity, ⌥⌘J)", false) }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        var c = Confirm("Remove Kermo's files on \(s.title)?", on: t, action: "Remove")
        c.items = [Confirm.Item(name: "~/.cache/kermo", size: size)]
        c.runs = "Long jobs' logs and what was uploaded for them: Activity can't show those logs after this."
        c.command = "rm -rf ~/.cache/kermo"
        c.irreversible = true
        guard await app.confirm(c, on: window) == 0 else { return ("Kermo's files on \(s.title): kept", false) }
        if busy() { return ("A change started on \(s.title) meanwhile: Kermo's files stay", false) }
        let removed = await run(true)
        AuditLog.write(t, "tools clean up", paths: ["~/.cache/kermo"], command: c.command, exit: removed?.status, error: removed == nil ? "didn't run" : nil)
        guard let ran = removed else { return ("Kermo's files on \(s.title) couldn't be removed", true) }
        switch ran.status {
        case 0: return ("Kermo's files on \(s.title) are removed (\(size))", false)
        case 3: return ("A long job started on \(s.title) meanwhile: its files stay", false)
        default: return ("Kermo's files on \(s.title) couldn't all be removed: " + (ran.errors.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(ran.status)"), true)
        }
    }
}
