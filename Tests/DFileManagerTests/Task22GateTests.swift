import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 22 PR 2, phase 0: what a server action gets past today — the lock, the production question, the log.

@MainActor private var keptApps: [AppDelegate] = []

@MainActor private func gateApp(_ dir: String) -> AppDelegate {
    _ = NSApplication.shared
    let app = AppDelegate()
    keptApps.append(app)
    app.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))   // the terminal's drawer covers it: kept by the window
    app.window.contentView = host
    app.terminal = EmbeddedTerminal(covering: host)
    app.panels = [PanelViewController(tabs: [dir], index: 0, showHidden: false)]
    app.panels.forEach { $0.loadViewIfNeeded() }
    return app
}

@MainActor private func gateUntil(_ done: () -> Bool) async {
    for _ in 0..<300 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
}

extension ServerLockTests {   // swap `ServerLock.servers`, `authenticate` and `AppDelegate.answering`
    /// The server every test here acts on: this Mac's sftp-server under a port of its own — a lock on "localhost"
    /// itself would be every other test's server's while these run.
    private var here: SFTPTarget { .local(port: 1) }   // nobody listens there, should a test get past the gate

    private func gateServer(locked: Bool, prod: Bool) -> SavedServer {
        var s = SavedServer(target: here)
        (s.locked, s.prod) = (locked, prod)
        return s
    }

    private func gateDir() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t22gate-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// ⌘E / F2 on a locked server's panel after its five minutes (the screen locked meanwhile): Touch ID first, as
    /// F5, F6, a rename and a service's restart ask. Refused, nothing runs (before the gate it went on to ssh, to a host
    /// that doesn't exist).
    @Test func aCommandOnALockedServerAsksTouchIDFirst() async throws {
        let dir = try gateDir(), server = gateServer(locked: true, prod: false)
        var asked: [String] = [], answer = true
        ServerLock.servers = { [server] }
        ServerLock.authenticate = { asked.append($0); return answer }
        defer { ServerLock.servers = { [] }; ServerLock.relock(); try? FileManager.default.removeItem(atPath: dir) }
        let app = gateApp(dir), panel = app.panels[0]
        defer { panel.shutdown() }
        panel.loadRemote(here, dir: dir, select: nil)
        await gateUntil { panel.remote?.dir == dir }
        try #require(panel.remote?.dir == dir && asked.count == 1)

        ServerLock.relock()
        answer = false
        app.runShell("touch ran-locked", in: .window)
        await gateUntil { asked.count == 2 }
        try? await Task.sleep(for: .milliseconds(50))
        defer { NSApp.windows.filter { $0.title.contains("ran-locked") }.forEach { $0.close() } }
        #expect(asked.count == 2, "Touch ID before a command on a locked server: \(asked)")
        #expect(!NSApp.windows.contains { $0.title.contains("ran-locked") }, "refused: no output window, nothing started")
    }

    /// ⌘E with the terminal app on a locked production server: the SSH tab asks Touch ID — refused, nothing ran, and
    /// the production log has no line saying it did.
    @Test func aCommandThatStayedLockedIsNotInTheLog() async throws {
        let dir = try gateDir(), server = gateServer(locked: true, prod: true)
        var answer = true, asked = 0
        ServerLock.servers = { [server] }
        ServerLock.authenticate = { _ in asked += 1; return answer }
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
        let app = gateApp(dir), panel = app.panels[0]
        defer { panel.shutdown() }
        panel.loadRemote(here, dir: dir, select: nil)
        await gateUntil { panel.remote?.dir == dir }
        try #require(panel.remote?.dir == dir)

        ServerLock.relock()
        answer = false
        let before = asked
        app.runShell("uptime", in: .terminalApp)   // not dangerous: no question
        await gateUntil { asked == before + 1 }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(asked == before + 1, "Touch ID was asked")
        #expect(app.terminal.tabs.isEmpty, "no tab for what stayed locked")
        Config.flush()
        let log = (try? String(contentsOfFile: AuditLog.path, encoding: .utf8)) ?? ""
        #expect(log.isEmpty, "nothing ran (the tab stayed locked), yet the log says: \(log)")
    }

    /// D-216 item 2: Run on Servers with an ~/.ssh/config alias of a production server nobody has connected by yet —
    /// a dangerous command asks as on the server itself.
    @Test func runOnServersAsksForAProductionServersAlias() async throws {
        let dir = try gateDir(), config = dir + "/config"
        try "Host t22gate\n  HostName 192.0.2.40\n  User root\n".write(toFile: config, atomically: true, encoding: .utf8)
        var prod = SavedServer(address: "root@192.0.2.40")!
        (prod.prod, prod.locked) = (true, true)
        var questions: [String] = []
        let sshG = ServerLock.sshG, answering = AppDelegate.answering
        ServerLock.sshG = { SFTP.sshG($0, config: config) }
        ServerLock.servers = { [prod] }
        ServerLock.authenticate = { _ in questions.append("Touch ID"); return true }
        AppDelegate.answering = { title, buttons, _ in questions.append(title); return buttons.count - 1 }   // Cancel
        defer {
            ServerLock.sshG = sshG
            ServerLock.servers = { [] }
            ServerLock.relock()
            AppDelegate.answering = answering
            try? FileManager.default.removeItem(atPath: dir)
        }
        let app = gateApp(dir)
        defer { app.panels[0].shutdown() }
        let alias = RunOnServersSheet.Choice(title: "t22gate", target: SFTPTarget(host: "t22gate"), saved: nil)
        let started = await app.runOnServers("rm -f /tmp/t22gate-x", [alias])
        NSApp.windows.filter { $0.title.contains("t22gate-x") }.forEach { $0.close() }
        #expect(questions.count == 2 && questions.first == "Touch ID", "Touch ID, then the production question: \(questions)")
        #expect(!started, "Cancel: nothing started")
    }

    /// F7, New File, F8, permissions and Extract on a locked server's panel after its five minutes: Touch ID first, as
    /// F5 and F6 there — refused, no question follows and nothing is sent.
    @Test func fileChangesOnALockedServerAskTouchIDFirst() async throws {
        let dir = try gateDir(), server = gateServer(locked: true, prod: false)
        FileManager.default.createFile(atPath: dir + "/a.tar", contents: Data())
        var asked: [String] = [], answer = true, questions: [String] = []
        let answering = AppDelegate.answering
        ServerLock.servers = { [server] }
        ServerLock.authenticate = { asked.append($0); return answer }
        AppDelegate.answering = { title, buttons, _ in questions.append(title); return buttons.count - 1 }
        defer {
            ServerLock.servers = { [] }
            ServerLock.relock()
            AppDelegate.answering = answering
            try? FileManager.default.removeItem(atPath: dir)
        }
        let app = gateApp(dir), panel = app.panels[0]
        defer { panel.shutdown() }
        panel.loadRemote(here, dir: dir, select: nil)
        await gateUntil { panel.remote?.dir == dir && panel.remoteCursor != nil }
        panel.moveCursor(toName: "a.tar")
        try #require(panel.remoteCursor?.item.name == "a.tar" && asked.count == 1)

        answer = false
        let keys: [(String, @MainActor () -> Void)] = [("F7", app.mkdirDialog), ("New File", app.newFileDialog), ("F8", app.deletePermanently),
                                                        ("permissions", app.attributesDialog), ("Extract", app.extractDialog)]
        for (i, (name, press)) in keys.enumerated() {
            ServerLock.relock()
            press()
            await gateUntil { asked.count == i + 2 }
            try? await Task.sleep(for: .milliseconds(50))
            #expect(asked.count == i + 2, "\(name): Touch ID first — \(asked)")
            #expect(app.window.attachedSheet == nil && questions.isEmpty, "\(name): refused, nothing asked after")
        }
        #expect(FileManager.default.fileExists(atPath: dir + "/a.tar") && (try? FileManager.default.contentsOfDirectory(atPath: dir)) == ["a.tar"])
    }
}
