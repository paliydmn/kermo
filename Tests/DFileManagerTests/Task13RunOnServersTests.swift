import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

@MainActor private func text(_ w: NSWindow) -> NSTextStorage? { ((w.contentView as? NSScrollView)?.documentView as? NSTextView)?.textStorage }

/// Run on Servers' output (`.local()` targets: this Mac's sh): one window, each line under its server's name — names
/// lined up, stderr in red — then the summary with what failed in red and named, the skipped too. ⎋ stops them all and
/// keeps the window for the summary, then closes it. (Quitting's count of running windows: other tests' windows run
/// meanwhile, so it isn't looked at here.)
@MainActor @Test func severalServersShareOneOutputWindow() async throws {
    _ = NSApplication.shared
    let title = "Run on 3 servers: dfm-" + UUID().uuidString.prefix(6)
    let servers = [MultiRun.Server(name: "web1", target: .local(persist: 1)), MultiRun.Server(name: "db", target: .local(persist: 2))]
    var outcomes: [Int: MultiRun.Outcome] = [:]
    Shell.run("echo hi; echo no >&2; exit 3", on: servers, skipped: ["vault"], env: [:], title: title) { outcomes[$0] = $1 }
    let w = try #require(NSApp.windows.first { $0.title == title })
    for _ in 0..<500 where !w.subtitle.contains("done") { try await Task.sleep(for: .milliseconds(10)) }
    #expect(outcomes == [0: .exit(3), 1: .exit(3)], "each server's, as it ended")
    let storage = try #require(text(w))
    let lines = storage.string.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.filter { $0.hasPrefix("web1 │ ") }.sorted() == ["web1 │ hi", "web1 │ no"] && lines.filter { $0.hasPrefix("db   │ ") }.count == 2,
            "\(lines)")
    #expect(lines.suffix(2) == ["✗ 2 (web1: exit 3, db: exit 3)  🔒 1 skipped (vault)", ""], "\(lines)")
    let err = (storage.string as NSString).range(of: "│ no")
    #expect(storage.attribute(.foregroundColor, at: err.location + 2, effectiveRange: nil) as? NSColor == .systemRed)
    let x = (storage.string as NSString).range(of: "✗")
    #expect(storage.attribute(.foregroundColor, at: x.location, effectiveRange: nil) as? NSColor == .systemRed)
    #expect(storage.attribute(.foregroundColor, at: (storage.string as NSString).range(of: "🔒").location, effectiveRange: nil) as? NSColor == .textColor)
    #expect(w.subtitle.hasPrefix("3 servers · done · ") && w.subtitle.hasSuffix(" · Esc closes"))
    w.close()

    let slow = "Run on 2 servers: dfm-" + UUID().uuidString.prefix(6)
    var ended: [Int: MultiRun.Outcome] = [:]
    Shell.run("echo start; sleep 5; echo done", on: servers, skipped: [], env: [:], title: slow) { ended[$0] = $1 }
    let s = try #require(NSApp.windows.first { $0.title == slow })
    defer { s.close() }
    for _ in 0..<300 where text(s)?.string.components(separatedBy: "start").count != 3 { try await Task.sleep(for: .milliseconds(10)) }
    s.windowController?.cancelOperation(nil)
    for _ in 0..<300 where !s.subtitle.contains("stopped ·") { try await Task.sleep(for: .milliseconds(10)) }
    #expect(ended == [0: .stopped, 1: .stopped] && s.isVisible && text(s)?.string.hasSuffix("⎋ 2 stopped\n") == true)
    #expect(s.subtitle.hasPrefix("2 servers · stopped · "))
    s.windowController?.cancelOperation(nil)
    #expect(!s.isVisible, "⎋ again closes it")
}

/// ⌘R in a several-servers window runs it again (asked with this window, before the main menu's Refresh sees the
/// key) once it's over — not while it runs; started again, this window closes.
@MainActor @Test func commandRRunsItAgain() async throws {
    _ = NSApplication.shared
    let title = "Run on 1 server: dfm-" + UUID().uuidString.prefix(6)
    var asked: [NSWindow?] = [], answer = false, ended = false
    Shell.run("sleep 0.4", on: [MultiRun.Server(name: "here", target: .local())], skipped: [], env: [:], title: title,
              again: { asked.append($0); return answer }) { _, _ in ended = true }
    let w = try #require(NSApp.windows.first { $0.title == title })
    defer { w.close() }
    let r = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: w.windowNumber,
                                          context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
    #expect(w.performKeyEquivalent(with: r) && asked.isEmpty, "not while it runs")
    for _ in 0..<300 where !(ended && w.subtitle.contains("done")) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(w.subtitle.hasSuffix("Esc closes · ⌘R again"), "\(w.subtitle)")
    #expect(w.performKeyEquivalent(with: r))
    for _ in 0..<100 where asked.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(asked.count == 1 && asked[0] === w && w.isVisible, "not started again: it stays")
    answer = true
    _ = w.performKeyEquivalent(with: r)
    for _ in 0..<100 where w.isVisible { try await Task.sleep(for: .milliseconds(10)) }
    #expect(asked.count == 2 && !w.isVisible)
}

/// Any output window: ⎋ stops the command and keeps what it printed (its exit said); ⎋ again closes the window.
@MainActor @Test func escStopsFirstThenCloses() async throws {
    _ = NSApplication.shared
    let title = "dfm esc " + UUID().uuidString.prefix(6)
    var status: Int32?
    Shell.run("echo before; sleep 30", in: NSTemporaryDirectory(), title: title) { status = $0 }
    let w = try #require(NSApp.windows.first { $0.title == title })
    for _ in 0..<300 where text(w)?.string.hasPrefix("before") != true { try await Task.sleep(for: .milliseconds(10)) }
    #expect(w.subtitle.hasSuffix("running… · Esc stops"))
    w.windowController?.cancelOperation(nil)
    for _ in 0..<300 where status == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(status != nil && status != 0 && w.isVisible && text(w)?.string.hasPrefix("before\n") == true, "stopped, still showing it")
    #expect(w.subtitle.hasSuffix(" · Esc closes"), "\(w.subtitle)")
    w.windowController?.cancelOperation(nil)
    #expect(!w.isVisible)
}

extension ServerLockTests {
/// The sheet (U8): every server Connect… lists, the last choice ticked; production in its color, locked with 🔒. The
/// filter narrows by name or address, ⌘A ticks all it shows, and what runs is what's ticked and shown — the button says
/// how many, and is off with none or no command.
@Test func runOnServersSheetPicksWhatRuns() throws {
    _ = NSApplication.shared
    var web = SavedServer(address: "me@web1.invalid")!
    web.name = "web1"
    web.prod = true
    var vault = SavedServer(address: "me@vault.invalid")!
    vault.locked = true
    let choices = [RunOnServersSheet.Choice(title: "web1", target: web.target, saved: web),
                   RunOnServersSheet.Choice(title: "me@vault.invalid", target: vault.target, saved: vault),
                   RunOnServersSheet.Choice(title: "web2", target: SFTPTarget(host: "web2"), saved: nil)]
    let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    var ran: (String, [String])?
    RunOnServersSheet.show(on: parent, choices: choices, ticked: [ServerRow.key(web.target)], command: "") { ran = ($0, $1.map(\.title)) }
    let sheet = try #require(RunOnServersSheet.current)
    defer { sheet.close() }
    #expect((sheet.window?.firstResponder as? NSTextView)?.delegate === sheet.command, "typing goes to the command")
    #expect(sheet.boxes.map(\.title) == ["web1   me@web1.invalid", "🔒 me@vault.invalid", "web2   ~/.ssh/config"])
    #expect(sheet.boxes[0].attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == SavedServer.color)
    #expect(sheet.boxes.map(\.state) == [.on, .off, .off])
    #expect(sheet.runButton.title == "Run on 1 Server" && !sheet.runButton.isEnabled, "no command yet")
    sheet.command.stringValue = "uptime"
    sheet.update()
    #expect(sheet.runButton.isEnabled)
    sheet.filtered("WEB")
    #expect(sheet.boxes.map(\.isHidden) == [false, true, false])
    sheet.tickShown()
    #expect(sheet.runButton.title == "Run on 2 Servers" && sheet.boxes[1].state == .off)
    sheet.boxes[1].state = .on
    sheet.update()
    #expect(sheet.chosen.map(\.title) == ["web1", "web2"], "the hidden one doesn't run, ticked or not")
    sheet.filtered("")
    #expect(sheet.runButton.title == "Run on 3 Servers")
    sheet.filtered("vault")
    sheet.tickShown(false)   // ⇧⌘A
    sheet.filtered("")
    #expect(sheet.boxes.map(\.state) == [.on, .off, .on] && sheet.runButton.title == "Run on 2 Servers")
    sheet.boxes[1].state = .on
    sheet.update()
    sheet.run()
    #expect(ran?.0 == "uptime" && ran?.1 == ["web1", "me@vault.invalid", "web2"] && RunOnServersSheet.current == nil)
}

/// U11: a command that removes or stops things asks once, naming every production server (on none: no question, nor
/// for any other command); locked ones ask for Touch ID one after another before anything runs — refused, skipped. A
/// production server's run is a line in the production log with its exit status.
@Test func runOnServersAsksAndLogs() async throws {
    _ = NSApplication.shared
    var db = SavedServer(address: "me@db.invalid")!, web = SavedServer(address: "localhost")!, vault = SavedServer(address: "me@vault.invalid")!
    (db.prod, web.prod, vault.locked) = (true, true, true)
    var asked: [String] = []
    ServerLock.servers = { [db, web, vault] }
    ServerLock.authenticate = { asked.append($0); return false }
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-runon-" + UUID().uuidString
    let was = AuditLog.path, off = UserDefaults.standard.object(forKey: "auditLog")
    AuditLog.path = dir + "/audit.jsonl"
    UserDefaults.standard.removeObject(forKey: "auditLog")
    defer {
        ServerLock.servers = { [] }
        ServerLock.relock()
        AuditLog.path = was
        UserDefaults.standard.set(off, forKey: "auditLog")
        try? FileManager.default.removeItem(atPath: dir)
    }
    let q = try #require(AppDelegate.runQuestion("sudo systemctl restart nginx", on: [db.target, web.target, SFTPTarget(host: "test")]))
    #expect(q.message == "Run “sudo systemctl restart nginx” on 3 servers?")
    #expect(q.info == "“me@db.invalid” and “localhost” are production servers. It runs on all 3 at once.")
    #expect(AppDelegate.runQuestion("rm x", on: [db.target])?.info == "“me@db.invalid” is a production server.")
    #expect(AppDelegate.runQuestion("rm x", on: [db.target, web.target])?.info == "“me@db.invalid” and “localhost” are production servers. It runs on both at once.")
    #expect(AppDelegate.runQuestion("uptime", on: [db.target]) == nil && AppDelegate.runQuestion("rm -rf /tmp/x", on: [SFTPTarget(host: "test")]) == nil)

    let local = RunOnServersSheet.Choice(title: "web", target: .local(), saved: web)   // .local(): localhost, the production one
    let chosen = [RunOnServersSheet.Choice(title: "vault", target: vault.target, saved: vault), local]
    let (run, skipped) = await AppDelegate.unlocked(chosen)
    #expect(run.map(\.title) == ["web"] && skipped == ["vault"] && asked == ["run a command on “me@vault.invalid”"])

    let title = "Run on 2 servers: echo dfm-" + UUID().uuidString.prefix(6)
    AppDelegate.start(String(title.dropFirst("Run on 2 servers: ".count)) + "; exit 4", on: run, of: 2, skipped: skipped, env: [:])
    let w = try #require(NSApp.windows.first { $0.title.hasPrefix(title) })
    defer { w.close() }
    for _ in 0..<500 where !FileManager.default.fileExists(atPath: AuditLog.path) { try await Task.sleep(for: .milliseconds(10)) }
    let line = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: AuditLog.path))) as? [String: Any])
    #expect(line["action"] as? String == "command" && line["exit"] as? Int == 4 && (line["command"] as? String)?.hasSuffix("; exit 4") == true)
    #expect(line["server"] as? String == "localhost" && line["paths"] as? [String] == [])
}
}
