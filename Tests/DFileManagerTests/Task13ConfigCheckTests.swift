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
    #expect(AppDelegate.checkNote(.noProgram("nginx"), of: rule) == "no check for this file (no nginx there)")
    #expect(AppDelegate.checkNote(.needsRoot, of: rule) == "check needs root — ⌃⌘R opens the panel as root")
    #expect(AppDelegate.checkNote(.notRun("cancelled"), of: rule) == "unchecked: cancelled", "an \"after\" check that didn't run: the save is in")
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
    #expect(plain.message == "Reload after saving “site.conf”?" && plain.info == "Runs “systemctl reload nginx” on me@web as root." && plain.default == 0)
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
