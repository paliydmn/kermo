import AppKit
import DFMCore
import Testing
@testable import DFileManager

/// T2: ⌃O on a local panel shows a live local shell, never a restored (disconnected) SSH tab; a caller that picked
/// a tab itself (sidebar session, ⌘K) keeps it.
@MainActor @Test func ctrlOOnALocalPanelPicksALocalShell() throws {
    _ = NSApplication.shared
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dfm-t2-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let panels = NSView(frame: parent.bounds)
    parent.addSubview(panels)
    let term = EmbeddedTerminal(covering: panels)
    defer { term.tabs.forEach { $0.view.process?.terminate() } }

    term.restore([SFTPTarget(host: "dfm-t2.invalid")])   // after a relaunch: one disconnected SSH tab
    let ssh = try #require(term.current)
    _ = term.show(cwd: dir)
    let shell = try #require(term.current)
    #expect(shell.kind == .shell && shell.isRunning)
    #expect(term.tabs.count == 2)

    term.select(ssh.id)
    _ = term.show(cwd: dir)
    #expect(term.current === shell, "the live shell again, not the SSH tab or a new shell")
    #expect(term.tabs.count == 2)

    term.select(ssh.id)
    _ = term.show()
    #expect(term.current === ssh, "a tab the caller picked stays")
}

/// T7: the terminal's default text reads at 7:1 or better on its background in every theme, its ANSI colors at
/// 4.5:1, and new tabs get those colors and 13 pt.
@MainActor @Test func terminalTextIsReadable() {
    #expect(Theme.contrast(.black, .white) > 20.9 && Theme.contrast(.white, .white) == 1)
    for theme in Theme.all {
        let (fg, bg) = theme.terminal
        #expect(Theme.contrast(fg, bg) >= 7, "\(theme.name): text")
        for (i, c) in EmbeddedTerminal.palette.enumerated() where i % 8 != 0 {   // black and bright black: dim on purpose
            let color = NSColor(srgbRed: CGFloat(c.red) / 65535, green: CGFloat(c.green) / 65535, blue: CGFloat(c.blue) / 65535, alpha: 1)
            #expect(Theme.contrast(color, bg) >= 4.5, "\(theme.name): ANSI \(i)")
        }
    }
    _ = NSApplication.shared
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let panels = NSView(frame: parent.bounds)
    parent.addSubview(panels)
    let term = EmbeddedTerminal(covering: panels)
    term.restore([SFTPTarget(host: "dfm-t7.invalid")])   // a tab without a process
    let view = term.tabs[0].view
    let base = view.font.pointSize   // whatever `terminalFontSize` holds (task 12)
    #expect((9...36).contains(base))
    #expect(Theme.contrast(view.nativeForegroundColor, view.nativeBackgroundColor) >= 7)
    let saved = UserDefaults.standard.object(forKey: "terminalFontSize")
    defer { UserDefaults.standard.set(saved, forKey: "terminalFontSize") }
    term.zoom(by: base < 36 ? 1 : -1)
    #expect(view.font.pointSize == base + (base < 36 ? 1 : -1))
}

/// R27: a process that ends on its own (`exit` typed, a dropped connection) ends its tab every time: an SSH tab says so
/// (status, Reconnect, ○, the sidebar is told), a shell tab closes, and each process is reaped once (no zombie).
@MainActor @Test func aProcessThatEndsOnItsOwnEndsItsTab() async throws {
    _ = NSApplication.shared
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let panels = NSView(frame: parent.bounds)
    parent.addSubview(panels)
    let term = EmbeddedTerminal(covering: panels)
    defer { term.tabs.forEach { $0.view.process?.terminate() } }
    var changes = 0
    term.onChange = { changes += 1 }

    term.restore((0..<8).map { SFTPTarget(host: "dfm-r27-\($0).invalid") })   // SSH tabs; a stand-in ssh runs in each
    let ssh = term.tabs
    for tab in ssh { tab.exitStatus = nil; term.launch(tab, "/bin/sh", ["-c", "echo hi; sleep 0.3; exit 3"], cwd: nil) }
    let pids = ssh.map { $0.view.process.shellPid }
    try #require(ssh.allSatisfy { $0.isRunning })
    let before = changes
    for _ in 0..<300 where ssh.contains(where: { $0.exitStatus == nil }) { try await Task.sleep(for: .milliseconds(10)) }
    for tab in ssh {
        #expect(tab.exitStatus == 3 << 8 && !tab.isRunning && tab.reconnect != nil, "it says why it ended and offers Reconnect")
    }
    #expect(changes > before, "the sidebar hears of it (green badge, idle connection)")
    for pid in pids {
        var s: Int32 = 0
        #expect(waitpid(pid, &s, WNOHANG) == -1 && errno == ECHILD, "reaped, no zombie")
    }

    term.newShell(cwd: NSTemporaryDirectory())
    let shell = try #require(term.current)
    let pid = shell.view.process.shellPid
    shell.view.send(txt: "exit\n")
    for _ in 0..<500 where term.tabs.contains(where: { $0 === shell }) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!term.tabs.contains { $0 === shell }, "`exit` closes a shell's tab")
    var s: Int32 = 0
    #expect(waitpid(pid, &s, WNOHANG) == -1, "reaped, no zombie")
}

/// A tab whose process couldn't start (fork failed; SwiftTerm says so in it): an SSH tab offers Reconnect, a shell's
/// stays, saying why, and closes without asking. One killed says so.
@MainActor @Test func aTabWhoseProcessCouldntStartEnds() async throws {
    _ = NSApplication.shared
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let panels = NSView(frame: parent.bounds)
    parent.addSubview(panels)
    let term = EmbeddedTerminal(covering: panels)
    defer { term.tabs.forEach { $0.view.process?.terminate() } }
    term.restore([SFTPTarget(host: "dfm-fork.invalid")])
    let ssh = try #require(term.tabs.last)
    ssh.exitStatus = nil   // as a Reconnect leaves it: no button, nothing said yet
    ssh.reconnect?.removeFromSuperview()
    ssh.reconnect = nil
    ssh.view.feed(text: "\u{1b}[3J\u{1b}[2J\u{1b}[H")
    term.processFailedToStart(source: ssh.view, error: .forkFailed(EAGAIN))
    #expect(ssh.exitStatus == -1 && ssh.reconnect != nil && !ssh.isRunning)
    #expect(String(decoding: ssh.view.getBufferAsData(), as: UTF8.self).contains("Not connected"))

    term.newShell(cwd: NSTemporaryDirectory())   // its shell runs; the failure is told to it as if it hadn't
    let failed = try #require(term.current)
    term.processFailedToStart(source: failed.view, error: .forkFailed(EAGAIN))
    #expect(term.tabs.contains { $0 === failed } && failed.exitStatus == -1 && failed.busyWith == nil)

    term.restore([SFTPTarget(host: "dfm-killed.invalid")])
    let killed = try #require(term.tabs.last)
    killed.exitStatus = nil
    term.launch(killed, "/bin/sh", ["-c", "kill -9 $$"], cwd: nil)
    for _ in 0..<300 where killed.exitStatus == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(killed.exitStatus == EmbeddedTerminal.bySignal)
    #expect(String(decoding: killed.view.getBufferAsData(), as: UTF8.self).contains("ssh ended by a signal"))
}

/// R27: Reconnect (↩, its button, the menu) is for a session whose end was told: while its ssh logs in or runs it does
/// nothing — never a second ssh in the tab. A tab closed (⌘W) while its process runs ends it; each process is reaped.
@MainActor @Test func reconnectWaitsForTheSessionsEnd() async throws {
    _ = NSApplication.shared
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let panels = NSView(frame: parent.bounds)
    parent.addSubview(panels)
    let term = EmbeddedTerminal(covering: panels)
    defer { term.tabs.forEach { $0.view.process?.terminate() } }

    term.restore([SFTPTarget(host: "dfm-r27-twice.invalid")])
    let tab = try #require(term.tabs.last)
    let button = try #require(tab.reconnect)
    tab.exitStatus = nil   // as `start` leaves it while the login runs, before ssh does
    term.reconnect(tab.id)
    #expect(tab.reconnect === button, "logging in: not started again")
    term.launch(tab, "/bin/sh", ["-c", "sleep 0.3; exit 4"], cwd: nil)
    let old = tab.view.process.shellPid
    term.reconnect(tab.id)
    #expect(tab.view.process.shellPid == old && tab.reconnect === button, "running: no second ssh")
    for _ in 0..<1000 where tab.exitStatus == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(tab.exitStatus == 4 << 8, "its end told: now Reconnect may start it again")

    term.restore([SFTPTarget(host: "dfm-r27-closed.invalid")])
    let gone = try #require(term.tabs.last)
    gone.exitStatus = nil
    term.launch(gone, "/bin/sh", ["-c", "sleep 5"], cwd: nil)
    let closed = gone.view.process.shellPid
    term.close(gone.id, confirm: false)
    #expect(!term.tabs.contains { $0 === gone })
    for _ in 0..<1000 where gone.exitStatus == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(gone.exitStatus == EmbeddedTerminal.bySignal, "⌘W's SIGHUP ended it")
    for pid in [old, closed] {
        var s: Int32 = 0
        #expect(waitpid(pid, &s, WNOHANG) == -1 && errno == ECHILD, "reaped, no zombie")
    }
}
