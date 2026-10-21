import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 13: a server config's check when it's saved — what the app says of it.

/// A failed check: what it said (its last 30 lines), that the server's file is as it was, and where the text is —
/// unsaved in the editor, or in its copy when the editor is gone (a save from another app).
@MainActor @Test func checkFailedSaysWhatAndWhere() {
    let rule = ConfigCheck(match: "/etc/sudoers", check: "visudo -cf %f", root: true)
    let e = SFTPClient.CheckFailed(rule: rule, status: 1, output: ">>> /etc/.dfm-partial-1: syntax error near line 3 <<<\nparse error in /etc/.dfm-partial-1 near line 3\n")
    let (message, info) = AppDelegate.checkFailed(e, name: "sudoers", host: "me@web", kept: nil)
    #expect(message == "“sudoers” didn't pass “visudo” on me@web")
    #expect(info == ">>> /etc/.dfm-partial-1: syntax error near line 3 <<<\nparse error in /etc/.dfm-partial-1 near line 3\n\n"
            + "Not saved there: the file on me@web is as it was. Your text stays unsaved here.")
    let long = SFTPClient.CheckFailed(rule: rule, status: 1, output: (1...40).map { "line \($0)" }.joined(separator: "\n"))
    let shown = AppDelegate.checkFailed(long, name: "sudoers", host: "me@web", kept: "/tmp/dfm-sftp-x/sudoers").info
    #expect(shown.hasPrefix("…\nline 11\n") && shown.contains("line 40\n\n") && !shown.contains("line 10\n") && shown.hasSuffix("Your text is kept in /tmp/dfm-sftp-x/sudoers."))
    #expect(AppDelegate.checkFailed(SFTPClient.CheckFailed(rule: rule, status: 3, output: ""), name: "s", host: "h", kept: nil).info.hasPrefix("It exited with 3."))
    // "After": what the server's file is now, as the save put it.
    var after = SFTPClient.CheckFailed(rule: ConfigCheck(match: "/etc/nginx/*", check: "nginx -t", when: .after), status: 1, output: "nginx: [emerg] unexpected \"}\"")
    after.now = "Put back: the file on me@web is as it was before this save."
    #expect(AppDelegate.checkFailed(after, name: "site.conf", host: "me@web", kept: nil)
            == ("“site.conf” didn't pass “nginx” on me@web", "nginx: [emerg] unexpected \"}\"\n\nPut back: the file on me@web is as it was before this save. Your text stays unsaved here."))
}

/// The status line after a save: what checked it, or why nothing did — never quiet about a check that didn't run.
/// A check that couldn't run (sudo refused) stops the save, and says so.
@MainActor @Test func checkNotesInTheStatusLine() {
    let rule = ConfigCheck(match: "/etc/nginx/*", check: "nginx -t", root: true)
    #expect(AppDelegate.checkNote(.passed("ok"), of: rule) == "checked: nginx")
    #expect(AppDelegate.checkNote(.noProgram("no nginx there"), of: rule) == "no check for this file (no nginx there)")
    #expect(AppDelegate.checkNote(.needsRoot, of: rule) == "check needs root — ⌃⌘R opens the panel as root")
    #expect(AppDelegate.checkNote(.notRun("cancelled"), of: rule) == "unchecked: cancelled", "an \"after\" check that didn't run: the save is in")
    // A built-in reload on a user's panel isn't offered (it needs root): the status line says so. Not on a root panel,
    // not for the user's own rule (offered), not when the check didn't pass, not for a rule without a reload.
    let user = SFTPTarget(host: "me@web"), units = ConfigCheck.rule(for: "/etc/systemd/system/app.service", in: ConfigCheck.builtIn)
    #expect(AppDelegate.reloadNote(units, .passed(""), on: user) == "reload needs root — ⌃⌘R opens the panel as root")
    #expect(AppDelegate.reloadNote(units, .passed(""), on: user.asRoot()) == nil)
    #expect(AppDelegate.reloadNote(units, .failed(status: 1, output: ""), on: user) == nil)
    #expect(AppDelegate.reloadNote(ConfigCheck(match: "/opt/a", check: nil, reload: "app reload"), nil, on: user) == nil)
    #expect(AppDelegate.reloadNote(ConfigCheck.rule(for: "/etc/nftables.conf", in: ConfigCheck.builtIn), .needsRoot, on: user) == nil)
    #expect(AppDelegate.reloadNote(nil, nil, on: user) == nil)
    let saved = URL(fileURLWithPath: "/tmp/dfm-sftp-x/sudoers")
    let notRun = ConfigCheck.NotRun(message: "“visudo” couldn't run on web as root: sudo on web refused: Sorry.")
    #expect(AppDelegate.notUploaded(saved, host: "web", notRun, editorOpen: true)
            == "“sudoers” wasn't saved to web: its check didn't run. “visudo” couldn't run on web as root: sudo on web refused: Sorry.")
    #expect(AppDelegate.notUploaded(saved, host: "web", notRun, editorOpen: false)?.hasSuffix("Your text is kept in /tmp/dfm-sftp-x/sudoers.") == true)
}

/// Edit Validators… is in ⌘⇧P and the Kermo menu. The file it starts is an example that parses — rules of its own,
/// none of the built-in ones (copied there, those would never get Kermo's changes).
@MainActor @Test func editValidatorsStartsAnExample() throws {
    let c = AppDelegate().makeCommands().first { $0.id == "validators.edit" }
    #expect(c?.title == "Edit Validators…" && c?.menu == "Kermo")
    let (rules, problem) = ConfigCheck.rules(Data(AppDelegate.validatorsExample.utf8))
    let mine = rules.dropLast(ConfigCheck.builtIn.count)
    #expect(problem == nil && mine.count == 2 && mine.allSatisfy { r in !ConfigCheck.builtIn.contains { $0.match == r.match } })
    #expect(ConfigCheck.rule(for: "/etc/caddy/Caddyfile", in: rules)?.check == "caddy validate --adapter caddyfile --config %f")
}

extension ServerLockTests {
/// "Reload …?" names the command and who runs it; on a production server it says so first and ↩ answers Cancel (no
/// second R1 question: this one is it). sshd moving to a new port says what that does to connections.
@Test func reloadAsksFirstOnProduction() {
    let root = SFTPTarget(host: "me@web").asRoot()
    let plain = AppDelegate.reloadQuestion("systemctl reload nginx", name: "site.conf", on: root)
    #expect(plain.message == "Reload after saving “site.conf”?" && plain.info == "Runs “systemctl reload nginx” on me@web as root.")
    #expect(plain.default == nil, "↩ Reload, ⎋ Cancel: an alert's own keys")
    #expect(AppDelegate.reloadQuestion("app reload", name: "a.yaml", on: root.asRoot(false)).info == "Runs “app reload” on me@web.")
    var prod = SavedServer(address: "me@web")!
    prod.prod = true
    ServerLock.servers = { [prod] }
    defer { ServerLock.servers = { [] } }
    let asked = AppDelegate.reloadQuestion("systemctl reload nginx", name: "site.conf", on: root)
    #expect(asked.info == "“me@web” is a production server. Runs “systemctl reload nginx” on me@web as root." && asked.default == 2, "↩ is Cancel")
    let socket = AppDelegate.reloadQuestion(ConfigCheck.sshdSocketReload, name: "sshd_config", on: root).info
    #expect(socket.hasSuffix("this connection stays, new ones go to the new port."))
}
}

/// Compare before a reload: the text the save replaced, in an owner-only copy of its own named as the file, against
/// the text saved; the diff names them "host:/path (before this save)" and "host:/path", not their temp paths.
@MainActor @Test func compareBeforeReloadShowsTheSavesChange() throws {
    let before = try #require(AppDelegate.textBefore(Data("listen 80;\n".utf8), name: "site.conf"))
    defer { TempCopies.remove((before as NSString).deletingLastPathComponent) }
    #expect((before as NSString).lastPathComponent == "site.conf" && FileManager.default.contents(atPath: before) == Data("listen 80;\n".utf8))
    let mode = { (p: String) in ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? NSNumber)?.intValue }
    #expect(mode(before) == 0o600 && mode((before as NSString).deletingLastPathComponent) == 0o700)
    #expect(TempCopies.holds(URL(fileURLWithPath: before)), "swept with the server copies")
    let a = AppDelegate.DiffSide(path: before, name: "me@web:/etc/nginx/site.conf (before this save)")
    #expect(AppDelegate.diffCommand(before, "/tmp/x/site.conf", labels: (a.label, "me@web:/etc/nginx/site.conf"))
            == "diff -u --label 'me@web:/etc/nginx/site.conf (before this save)' --label me@web:/etc/nginx/site.conf \(ShellContext.quote(before)) /tmp/x/site.conf")
}

extension ServerLockTests {
/// The production log: a JSON line per action on a production server (none for any other, none once `auditLog` is
/// off), appended; the file is owner-only, put back to that if loosened by hand. Root says so.
@Test func productionLogLines() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-audit-" + UUID().uuidString
    let was = AuditLog.path
    AuditLog.path = dir + "/audit.jsonl"
    var prod = SavedServer(address: "me@web:2222")!
    prod.prod = true
    ServerLock.servers = { [prod] }
    let off = UserDefaults.standard.object(forKey: "auditLog")
    defer { AuditLog.path = was; ServerLock.servers = { [] }; UserDefaults.standard.set(off, forKey: "auditLog"); try? FileManager.default.removeItem(atPath: dir) }
    UserDefaults.standard.removeObject(forKey: "auditLog")
    let web = SFTPTarget(host: "me@web", port: 2222)
    AuditLog.write(web, "command", paths: ["/srv/app"], command: "systemctl restart app", exit: 0)
    AuditLog.write(SFTPTarget(host: "me@test"), "save", paths: ["/etc/hosts"], exit: 0)
    AuditLog.write(web.asRoot(), "save", paths: ["/etc/nginx/nginx.conf"], exit: 1, error: "“nginx” failed. Put back.")
    Config.flush()   // written off the main thread, in order
    let lines = try String(contentsOfFile: AuditLog.path, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(lines.count == 2, "not a production server: no line")
    let first = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
    #expect(first["server"] as? String == "me@web:2222" && first["action"] as? String == "command" && first["paths"] as? [String] == ["/srv/app"])
    #expect(first["command"] as? String == "systemctl restart app" && first["exit"] as? Int == 0 && first["root"] == nil && first["error"] == nil)
    #expect((first["time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } != nil, "an ISO 8601 time")
    #expect(lines[1].hasPrefix(#"{"action":"save","error":"“nginx” failed. Put back.","exit":1,"paths":["/etc/nginx/nginx.conf"],"root":true,"server":"me@web:2222","time":""#))
    let mode = { ((try? FileManager.default.attributesOfItem(atPath: AuditLog.path))?[.posixPermissions] as? NSNumber)?.intValue }
    #expect(mode() == 0o600)
    chmod(AuditLog.path, 0o644)
    UserDefaults.standard.set(false, forKey: "auditLog")
    AuditLog.write(web, "command", paths: ["/"], command: "ls", exit: 0)
    Config.flush()
    #expect((try String(contentsOfFile: AuditLog.path, encoding: .utf8)).split(separator: "\n").count == 2, "off: nothing")
    UserDefaults.standard.removeObject(forKey: "auditLog")
    AuditLog.write(web, "command", paths: ["/"], command: "ls", exit: 0)
    Config.flush()
    #expect((try String(contentsOfFile: AuditLog.path, encoding: .utf8)).split(separator: "\n").count == 3 && mode() == 0o600)
    // A line that can't be written is said once, until one is again.
    var said: [String] = []
    func written() async {   // the writes done, and what they said handed back to the main thread
        Config.flush()
        try? await Task.sleep(for: .milliseconds(50))
    }
    AuditLog.failed = { said.append($0) }
    defer { AuditLog.failed = nil }
    AuditLog.path = "/dev/null/kermo/audit.jsonl"
    AuditLog.write(web, "command", paths: ["/"], command: "ls", exit: 0)
    AuditLog.write(web, "command", paths: ["/"], command: "ls", exit: 0)
    await written()
    #expect(said.count == 1 && said[0].hasPrefix("Production log not written (/dev/null/kermo/audit.jsonl): "), "\(said)")
    AuditLog.path = dir + "/audit.jsonl"
    AuditLog.write(web, "command", paths: ["/"], command: "ls", exit: 0)
    AuditLog.path = "/dev/null/kermo/audit.jsonl"
    AuditLog.write(web, "command", paths: ["/"], command: "ls", exit: 0)
    await written()
    #expect(said.count == 2, "written once in between: said again")
    // Show Production Log is in ⌘⇧P and the Admin menu.
    let c = AppDelegate().makeCommands().first { $0.id == "admin.auditLog" }
    #expect(c?.title == "Show Production Log" && c?.menu == "Admin")
}

/// Every place that asks before changing a production server writes its line once done: ⌘S and Revert, ⇧F6 /
/// permissions / new folder, F5 / F6 / F8 and Synchronize's jobs, a reload. (A command — ⌘E, F2 — runs in an output
/// window over ssh, which the test target doesn't have; extract goes through dialogs: checked in the app.)
@Test func productionLogHooks() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-audith-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let was = AuditLog.path
    AuditLog.path = dir + "/audit.jsonl"
    let validators = AppDelegate.validatorsPath
    AppDelegate.validatorsPath = dir + "/validators.json"   // none: this Mac's own doesn't count
    var prod = SavedServer(address: "localhost")!
    prod.prod = true
    ServerLock.servers = { [prod] }
    defer { AuditLog.path = was; AppDelegate.validatorsPath = validators; ServerLock.servers = { [] }; try? FileManager.default.removeItem(atPath: dir) }
    func log() -> [[String: Any]] {
        Config.flush()
        return ((try? String(contentsOfFile: AuditLog.path, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    func wait(_ n: Int) async { for _ in 0..<250 where log().count < n { try? await Task.sleep(for: .milliseconds(20)) } }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    panel.loadRemote(.local(), dir: dir, select: nil)
    for _ in 0..<250 where panel.remote == nil || panel.connecting != nil { try? await Task.sleep(for: .milliseconds(20)) }
    let app = AppDelegate()
    app.panels = [panel]

    // ⌘S and Revert (new files: no version to keep, so the history folder isn't touched).
    try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/l"))
    let state = AppDelegate.RemoteEdit(baseline: .nothing)
    state.prodConfirmed = true
    #expect(await app.upload(URL(fileURLWithPath: dir + "/l"), to: dir + "/saved.conf", on: .local(), state))
    #expect(await app.upload(URL(fileURLWithPath: dir + "/l"), to: dir + "/reverted.conf", on: .local(), state, force: true, action: "revert"))
    // ⇧F6.
    app.remoteOp("Rename", .local(), paths: [dir + "/saved.conf", dir + "/renamed.conf"]) { try $0.rename(dir + "/saved.conf", dir + "/renamed.conf", replace: false) }
    await wait(3)
    // F8, and Synchronize's delete.
    for sync in [false, true] {
        let job = FileJob(.delete, sources: [dir + (sync ? "/reverted.conf" : "/renamed.conf")], from: .sftp(.local()), to: .sftp(.local()), destDir: nil)
        job.run()
        if sync { app.syncJobs.add(job) }
        app.jobFinished(job)
    }
    #expect(app.syncJobs.allObjects.isEmpty, "forgotten once finished")
    // F6 from one production server to another: a line for each end.
    var other = SavedServer(address: "me@db")!
    other.prod = true
    ServerLock.servers = { [prod, other] }
    AuditLog.write(FileJob(.move, sources: ["/a"], from: .sftp(.local()), to: .sftp(SFTPTarget(host: "me@db")), destDir: "/b"), sync: false)
    // F6 within one server: one line. Synchronize's copies: each file's two places.
    AuditLog.write(FileJob(.move, sources: ["/a"], from: .sftp(.local()), to: .sftp(.local()), destDir: "/b"), sync: false)
    AuditLog.write(FileJob(copyPairs: [("/here/a", "/srv/a")], from: .local, to: .sftp(.local())), sync: true)
    // A reload that ran, and one whose program isn't there.
    await app.reload("true", after: URL(fileURLWithPath: dir + "/l"), to: dir + "/x.conf", on: .local(), in: panel)
    await app.reload("kermo-no-such-reload", after: URL(fileURLWithPath: dir + "/l"), to: dir + "/x.conf", on: .local(), in: panel)
    // ⎋ while a reload runs: it may have run there — said so.
    Task { try? await Task.sleep(for: .milliseconds(300)); panel.cancelBusy() }
    await app.reload("sleep 3", after: URL(fileURLWithPath: dir + "/l"), to: dir + "/x.conf", on: .local(), in: panel)

    let got = log().map { ($0["action"] as? String ?? "?", $0["server"] as? String ?? "?", $0["exit"] as? Int ?? -1) }
    #expect(got.map(\.0) == ["save", "revert", "rename", "delete", "sync delete", "move", "move", "move", "sync copy", "reload", "reload", "reload"], "\(got)")
    #expect(got.map(\.2) == [0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 127, -1], "\(got)")
    #expect(log()[11]["error"] as? String == "cancelled, may have run" && log()[11]["exit"] == nil)
    #expect(log()[8]["paths"] as? [String] == ["/here/a → /srv/a"])
    #expect(log()[2]["paths"] as? [String] == [dir + "/saved.conf", dir + "/renamed.conf"])
    #expect(log()[5]["server"] as? String == "localhost" && log()[6]["server"] as? String == "me@db" && log()[6]["to"] as? String == "/b")
    #expect(log()[9]["command"] as? String == "true" && log()[9]["paths"] as? [String] == [dir + "/x.conf"])
}
}

/// F5 / F6 onto a production server, into a path a save checks first (sudoers, sshd_config): the question says the copy
/// isn't checked. Nothing for "after" paths, other paths, or none at all.
@Test func copiesIntoCheckedPathsSaySo() {
    let rules = ConfigCheck.rules(Data(#"[{"match": "/opt/app/*.yaml", "check": "app check %f"}]"#.utf8)).rules
    #expect(AppDelegate.uncheckedNote(["/etc/sudoers.d/90-admins"], rules: rules)
            == "\n\n“90-admins” isn't checked: a copy goes in as it is. Open it with F4 and save it to have it checked.")
    #expect(AppDelegate.uncheckedNote(["/etc/ssh/sshd_config", "/etc/hosts", "/opt/app/a.yaml"], rules: rules).hasPrefix("\n\n2 of them aren't checked"))
    #expect(AppDelegate.uncheckedNote(["/etc/nginx/nginx.conf", "/etc/hosts"], rules: rules) == "", "after rules, unchecked paths: nothing")
    #expect(AppDelegate.uncheckedNote([], rules: rules) == "")
}
