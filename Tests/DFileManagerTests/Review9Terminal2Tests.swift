import AppKit
import DFMCore
import Testing
@testable import DFileManager

/// T6: a terminal tab gets the user's locale (LANG, LC_*) and TMPDIR, SHELL, the agent socket and PATH, plus TERM,
/// COLORTERM, TERM_PROGRAM and COLORFGBG (its background is always dark); en_US.UTF-8 only when the user has no LANG.
@Test func terminalEnvironmentKeepsTheUsersLocale() {
    let env = EmbeddedTerminal.environment(["LANG": "uk_UA.UTF-8", "LC_ALL": "uk_UA.UTF-8", "LC_TYPE": "x", "TMPDIR": "/var/t/",
                                            "SHELL": "/bin/bash", "SSH_AUTH_SOCK": "/s", "PATH": "/bin", "SECRET": "no"])
    for v in ["LANG=uk_UA.UTF-8", "LC_ALL=uk_UA.UTF-8", "TMPDIR=/var/t/", "SHELL=/bin/bash", "SSH_AUTH_SOCK=/s", "PATH=/bin",
              "TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=Kermo", "COLORFGBG=15;0"] {
        #expect(env.contains(v), "\(v)")
    }
    #expect(!env.contains { $0.hasPrefix("LC_TYPE=") || $0.hasPrefix("SECRET=") })
    #expect(Set(env.map { $0.prefix { $0 != "=" } }).count == env.count, "each variable once")

    let bare = EmbeddedTerminal.environment([:])
    #expect(bare.contains("LANG=en_US.UTF-8") && bare.contains("SHELL=\(EmbeddedTerminal.loginShell)"))
    #expect(bare.contains { $0.hasPrefix("TMPDIR=/") })
}

@MainActor private var hosts: [NSView] = []   // the terminal holds its host view unowned

@MainActor private func terminal() -> EmbeddedTerminal {
    _ = NSApplication.shared
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let panels = NSView(frame: parent.bounds)
    parent.addSubview(panels)
    hosts.append(parent)
    return EmbeddedTerminal(covering: panels)
}

@MainActor private func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = [], at time: TimeInterval = 0,
                            repeat rep: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: time, windowNumber: 0, context: nil,
                     characters: chars, charactersIgnoringModifiers: chars, isARepeat: rep, keyCode: code)!
}

@MainActor private func text(_ tab: EmbeddedTerminal.Tab) -> String {
    String(decoding: tab.view.getTerminal().getBufferAsData(), as: UTF8.self)
}

/// T4: an SSH tab whose connection ended says ↩ reconnects and ⎋ closes it, and ⎋ does.
@MainActor @Test func aDisconnectedSSHTabClosesOnEscape() throws {
    let term = terminal()
    var exited = false
    term.onExit = { exited = true }
    term.restore([SFTPTarget(host: "dfm-t4.invalid")])
    let tab = try #require(term.current)
    _ = term.show()
    #expect(text(tab).contains("↩ Reconnect   ⎋ Close"))
    #expect(!term.handleKey(key(53, "\u{1b}", .shift)), "⇧⎋ is not ⎋")
    #expect(term.handleKey(key(53, "\u{1b}")))
    #expect(term.tabs.isEmpty && exited)
}

/// T5: ⌘K in the terminal clears it as in Terminal — the scrollback and the lines above the prompt go, the prompt line
/// moves to the top with the cursor where it was.
@MainActor @Test func cmdKClearsTheTerminal() throws {
    let term = terminal()
    term.restore([SFTPTarget(host: "dfm-t5.invalid")])
    let tab = try #require(term.current)
    _ = term.show()
    tab.view.feed(text: (1...60).map { "old line \($0)" }.joined(separator: "\r\n") + "\r\nme$ ls")
    #expect(term.handleKey(key(40, "k", .command)))
    #expect(!text(tab).contains("old line"), "scrollback and screen")
    #expect(text(tab).hasPrefix("me$ ls"))
    #expect(tab.view.getTerminal().getCursorLocation() == (6, 0))
    #expect(!term.handleKey(key(40, "k", [.command, .shift])))
}

/// T5: ⌘K leaves a full-screen program's screen (vim, less, mc: the alternate buffer) as it is — and still isn't Connect.
@MainActor @Test func cmdKLeavesAFullScreenProgramAlone() throws {
    let term = terminal()
    term.restore([SFTPTarget(host: "dfm-t5c.invalid")])
    let tab = try #require(term.current)
    _ = term.show()
    tab.view.feed(text: "\u{1b}[?1049h\u{1b}[H" + (1...10).map { "vim line \($0)" }.joined(separator: "\r\n") + "\u{1b}[5;3H")
    let (before, cursor) = (text(tab), tab.view.getTerminal().getCursorLocation())
    #expect(term.handleKey(key(40, "k", .command)))
    #expect(text(tab) == before && tab.view.getTerminal().getCursorLocation() == cursor)
}

/// T5: ⌃O twice within 0.4 s brings the same tab back (an SSH one too, not a local shell) and sends the program in it a
/// ⌃O; any other key, a held ⌃O's repeat, later, or after a hide that wasn't ⌃O does nothing.
@MainActor @Test func ctrlOTwiceSendsCtrlOToTheTerminal() async throws {
    let term = terminal()
    defer { term.tabs.forEach { $0.view.process?.terminate() } }
    term.restore([SFTPTarget(host: "dfm-t5b.invalid")])
    let tab = try #require(term.current)
    tab.exitStatus = nil   // a stand-in ssh: raw tty (else the line discipline eats ⌃O as VDISCARD), prints the byte it gets
    term.launch(tab, "/bin/sh", ["-c", "stty raw -echo; echo ready; head -c 1 | od -An -tx1; sleep 5"], cwd: nil)
    for _ in 0..<300 where !text(tab).contains("ready") { try await Task.sleep(for: .milliseconds(10)) }
    _ = term.show()

    let now = ProcessInfo.processInfo.systemUptime
    _ = term.show()
    _ = term.hide()   // a command hid it (Connect, a tag), not ⌃O
    #expect(term.showPassingCtrlO(key(31, "\u{0f}", .control, at: now + 0.1)) == nil, "not armed")
    _ = term.show()
    _ = term.hide(key(31, "\u{0f}", .control, at: now))
    #expect(term.showPassingCtrlO(key(31, "\u{0f}", .control, at: now + 0.1, repeat: true)) == nil, "a held ⌃O")
    #expect(term.showPassingCtrlO(key(31, "\u{0f}", .control, at: now + 1)) == nil, "too late")
    #expect(term.showPassingCtrlO(key(31, "o", .command, at: now)) == nil, "not ⌃O")
    #expect(!term.isShown)
    #expect(term.showPassingCtrlO(key(31, "\u{0f}", .control, at: now + 0.1)) === tab.view)
    #expect(term.isShown && term.current === tab)
    for _ in 0..<300 where !text(tab).contains("0f") { try await Task.sleep(for: .milliseconds(10)) }
    #expect(text(tab).contains("0f"), "the program got ⌃O")
}

/// T3: OSC 7 ("file://host/path", percent-encoded) gives the folder; anything else nothing.
@Test func osc7GivesTheFolder() {
    #expect(EmbeddedTerminal.osc7Path("file://web-1/var/log") == "/var/log")
    #expect(EmbeddedTerminal.osc7Path("file:///home/me/a%20b%D1%96") == "/home/me/a bі")
    #expect(EmbeddedTerminal.osc7Path("file://web-1/") == "/")
    #expect(EmbeddedTerminal.osc7Path("file://web-1") == nil)
    #expect(EmbeddedTerminal.osc7Path("http://web-1/x") == nil)
    #expect(EmbeddedTerminal.osc7Path("/var/log") == nil)
}

/// T3: `cd` in an SSH tab whose shell reports it (OSC 7) is that tab's folder on the server, told to the app (prompt,
/// the server's panel) once per change and only for the tab in front.
@MainActor @Test func anSSHTabFollowsItsShellsFolder() throws {
    let term = terminal()
    var told: [String?] = []
    term.onDirectory = { told.append($0.cwd) }
    term.restore([SFTPTarget(host: "dfm-t3.invalid"), SFTPTarget(host: "dfm-t3b.invalid")])
    let (a, b) = (term.tabs[0], term.tabs[1])
    _ = term.show()
    #expect(term.current === a)
    a.view.feed(text: "\u{1b}]7;file://web-1/var/log\u{7}me@web-1:/var/log$ ")
    a.view.feed(text: "\u{1b}]7;file://web-1/var/log\u{1b}\\")   // the next prompt, same folder
    #expect(a.cwd == "/var/log" && told == ["/var/log"])
    b.view.feed(text: "\u{1b}]7;file://db-1/srv\u{7}")
    #expect(b.cwd == "/srv" && told == ["/var/log"], "a tab behind doesn't move anything")
    _ = term.hide()
    a.view.feed(text: "\u{1b}]7;file://web-1/var/www\u{7}")   // `git pull` done while the user works in the panel
    #expect(a.cwd == "/var/www" && told == ["/var/log"], "hidden, the panels are the user's")
}

/// T3: a local shell's OSC 7 counts only for the folder the shell is in: not what a program run in it says (`ssh`, or
/// a `printf` / `cat` long done by the time its bytes are read).
@MainActor @Test func aLocalShellFollowsOnlyItsOwnFolders() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t3-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let term = terminal()
    defer { term.tabs.forEach { term.close($0.id, confirm: false) } }
    var told: [String?] = []
    term.onDirectory = { told.append($0.cwd) }
    term.newShell(cwd: dir)
    let shell = try #require(term.current)
    _ = term.show()
    // At its prompt (I2: a program running in it isn't the shell): drawn, and the shell has the terminal.
    for _ in 0..<1000 where !(shell.isAtPrompt && !text(shell).allSatisfy(\.isWhitespace)) { try await Task.sleep(for: .milliseconds(10)) }

    shell.view.feed(text: "\u{1b}]7;file://evil/usr/share\u{7}")   // exists, at the prompt — but not the shell's
    #expect(told.isEmpty && shell.cwd == nil)
    shell.view.feed(text: "\u{1b}]7;file://mac/nonexistent-dfm-t3\u{7}")
    #expect(told.isEmpty)
    shell.view.feed(text: "\u{1b}]7;file://mac\(dir)\u{7}")
    #expect(told == [dir] && shell.cwd == dir)
}
