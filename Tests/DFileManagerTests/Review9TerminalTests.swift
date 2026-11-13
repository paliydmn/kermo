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
    ssh.exitStatus = nil
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

/// R27: a tab started again while its last process is still there — Reconnect in the moment that process has ended but
/// SwiftTerm hasn't said so yet (it winds down, and ignores a start then; the same path, but not one a test can hold) —
/// starts once that end is told, and only the new process's end counts for the tab. Closed meanwhile (⌘W), it starts
/// nothing. Each old process is reaped.
@MainActor @Test func aTabStartedOrClosedAsItsProcessEndsStillReapsIt() async throws {
    _ = NSApplication.shared
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let panels = NSView(frame: parent.bounds)
    parent.addSubview(panels)
    let term = EmbeddedTerminal(covering: panels)
    defer { term.tabs.forEach { $0.view.process?.terminate() } }

    /// A tab started again while its first process still runs.
    func startedTwice() throws -> (EmbeddedTerminal.Tab, pid_t) {
        term.restore([SFTPTarget(host: "dfm-r27-gap-\(term.tabs.count).invalid")])
        let tab = try #require(term.tabs.last)
        tab.exitStatus = nil
        term.launch(tab, "/bin/sh", ["-c", "sleep 0.3; exit 4"], cwd: nil)
        let pid = tab.view.process.shellPid
        term.launch(tab, "/bin/sh", ["-c", "sleep 0.3; exit 5"], cwd: nil)   // as Reconnect does
        #expect(tab.view.process.shellPid == pid && tab.relaunch != nil, "waits for the first one's end")
        return (tab, pid)
    }

    let (again, old) = try startedTwice()
    let (gone, closed) = try startedTwice()
    term.close(gone.id, confirm: false)
    #expect(!term.tabs.contains { $0 === gone })
    for _ in 0..<300 where again.exitStatus == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(again.exitStatus == 5 << 8, "the tab ends with its new process, not the old one")
    for _ in 0..<300 where gone.exitStatus == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(gone.exitStatus == EmbeddedTerminal.bySignal, "a closed tab starts nothing: it ends with its first process (⌘W's SIGHUP)")
    for pid in [old, closed] {
        var s: Int32 = 0
        #expect(waitpid(pid, &s, WNOHANG) == -1 && errno == ECHILD, "reaped, no zombie")
    }
}
