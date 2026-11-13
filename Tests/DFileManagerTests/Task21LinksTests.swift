import AppKit
@testable import DFMCore
@testable import SwiftTerm   // the lookups' counter (`testingImplicitLinkCandidates`)
import Testing
@testable import DFileManager

// Task 21 PR 4: ⌘-click on a path or an address in the terminal (L2), the ⇧-click anchor (S2).

private typealias P = TerminalLink.Place

/// L2: what a ⌘-click's text is taken for. A path is absolute (a relative one from `base`, "~/" from `home`), its
/// :line[:col] taken off; one with spaces may end at each of them; http(s) and mailto are web addresses; `file:` a path;
/// another scheme, `$VAR/`, a relative path without a base, an invisible character: nothing.
@Test func whatAClickedLinkIsTakenFor() {
    func r(_ link: String, base: String? = "/w", home: String? = "/Users/me") -> TerminalLink? { TerminalLink.route(link, base: base, home: home) }
    #expect(r("./src/a.py:42") == .path([P(path: "/w/src/a.py", line: "42")]))
    #expect(r("src/a.py:42:def") == .path([P(path: "/w/src/a.py", line: "42")]), "grep's line, no space after it")
    #expect(r("src/main.rs:10:5") == .path([P(path: "/w/src/main.rs", line: "10:5")]))
    #expect(r("../up/x.c:3") == .path([P(path: "/up/x.c", line: "3")]))
    #expect(r(".hidden/x.cfg") == .path([P(path: "/w/.hidden/x.cfg", line: nil)]))
    #expect(r("/etc/nginx/./nginx.conf") == .path([P(path: "/etc/nginx/nginx.conf", line: nil)]))
    #expect(r("~/notes.txt") == .path([P(path: "/Users/me/notes.txt", line: nil)]))
    #expect(r("~/notes.txt", home: nil) == .path([P(path: "~/notes.txt", line: nil)]), "an SSH tab's: the server's home")
    #expect(r("/tmp/out file.txt and more") == .path([P(path: "/tmp/out file.txt and more", line: nil), P(path: "/tmp/out file.txt and", line: nil),
                                                      P(path: "/tmp/out file.txt", line: nil), P(path: "/tmp/out", line: nil)]))
    #expect(r("/path/x.conf .") == .path([P(path: "/path/x.conf .", line: nil), P(path: "/path/x.conf", line: nil)]))
    if case .path(let cuts) = r("/a" + String(repeating: " b", count: 20)) { #expect(cuts.count == 8) } else { Issue.record("a path") }
    #expect(r("file:///etc/hosts") == .path([P(path: "/etc/hosts", line: nil)]))
    #expect(r("file://localhost/etc/a%20b") == .path([P(path: "/etc/a b", line: nil)]))
    #expect(r("https://example.com/a") == .web("https://example.com/a"))
    #expect(r("HTTP://example.com") == .web("HTTP://example.com"))
    #expect(r("mailto:a@b.example") == .web("mailto:a@b.example"))
    for nothing in ["ssh://host/x", "git://h/r", "tel:+380123", "magnet:?xt=1", "ftp://h/x", "ipfs://x", "gemini://x", "news:x",
                    "file://other/etc/hosts", "file:///etc/hosts?x", "file:rel",
                    "$HOME/x.txt", "dir/$VAR/x.txt",
                    "/tmp/a\u{200B}b.txt", "/tmp/\u{202E}txt.exe", "/tmp/a\u{2066}b", "/tmp/a\nb", "/tmp/a\u{7}b", "/tmp/a\u{2028}b", "/tmp/a\u{FEFF}b", ""] {
        #expect(r(nothing) == nil, "\(nothing.debugDescription)")
    }
    #expect(r("src/a.py", base: nil) == nil, "relative, no folder to start from")
    #expect(r("./a.py:7 and more") == .path([P(path: "/w/a.py", line: "7")]), "one place, whatever the cut")
    #expect(r("main.swift:12") == .path([P(path: "/w/main.swift", line: "12")]), "a dot: not a scheme")
    #expect(r("~/../shared/app.yml", home: nil) == nil, "out of the server's home: it's only known there")
    #expect(r("~/../shared/app.yml") == .path([P(path: "/Users/shared/app.yml", line: nil)]))
    for hidden in ["file:///tmp/%E2%80%AEtxt.exe", "file:///tmp/a%0Ab", "/etc/pass\u{FE0F}wd", "/tmp/a\u{3164}b"] {
        #expect(r(hidden) == nil, "\(hidden.debugDescription)")
    }
    #expect(r("src/a.py", base: "/srv/\u{202E}ppa") == nil, "the folder a shell told is text too")
    #expect(r("/abs/a.py", base: nil) == .path([P(path: "/abs/a.py", line: nil)]))
}

/// What a click on it opens on this Mac: the first place that's there — a file in the editor (at its line), one past
/// 32 MB in the viewer, a folder in a panel; ⌥: a panel with it under the cursor. Nothing there: nil.
@Test func whatAClickOpensHere() throws {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t21l-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: d) }
    try FileManager.default.createDirectory(atPath: d + "/sub", withIntermediateDirectories: true)
    try Data("x".utf8).write(to: URL(fileURLWithPath: d + "/out file.txt"))
    let big = FileHandle(forWritingAtPath: { FileManager.default.createFile(atPath: d + "/big.log", contents: nil); return d + "/big.log" }())!
    try big.truncate(atOffset: UInt64(Editor.sizeLimit) + 1)   // sparse: nothing written
    try big.close()
    try FileManager.default.createSymbolicLink(atPath: d + "/to-sub", withDestinationPath: d + "/sub")
    func open(_ link: String, reveal: Bool = false) -> TerminalLink.Opening? {
        guard case .path(let places) = TerminalLink.route(link, base: d, home: nil) else { return nil }
        return TerminalLink.here(places, reveal: reveal)
    }
    #expect(open("./out file.txt:7:2 and more") == .editor(P(path: d + "/out file.txt", line: "7:2")), "the line's mark ends the path")
    #expect(open("./out file.txt and more") == .editor(P(path: d + "/out file.txt", line: nil)))
    #expect(open("./out file.txt:7:2") == .editor(P(path: d + "/out file.txt", line: "7:2")))
    #expect(open("./big.log") == .viewer(d + "/big.log"))
    #expect(open("./sub") == .panel(d + "/sub", into: true))
    #expect(open("./to-sub") == .panel(d + "/to-sub", into: true), "a link to a folder: the folder")
    #expect(open("./sub", reveal: true) == .panel(d + "/sub", into: false))
    #expect(open("./big.log", reveal: true) == .panel(d + "/big.log", into: false))
    #expect(open("./nothing.txt") == nil)
}

/// The same on a server, over SFTP as the session's user (here: this Mac's sftp-server): the places looked up together,
/// "~/" from the server's home; a FIFO or a device: nothing.
@Test func whatAClickOpensOnTheServer() throws {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t21l-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: d) }
    try FileManager.default.createDirectory(atPath: d + "/sub", withIntermediateDirectories: true)
    try Data("x".utf8).write(to: URL(fileURLWithPath: d + "/out file.txt"))
    #expect(mkfifo(d + "/pipe", 0o644) == 0)
    try FileManager.default.createSymbolicLink(atPath: d + "/to-sub", withDestinationPath: d + "/sub")
    let c = try SFTPClient(SFTPTarget.local())
    defer { c.close() }
    func open(_ link: String, base: String? = nil, reveal: Bool = false) throws -> TerminalLink.Opening? {
        guard case .path(let places) = TerminalLink.route(link, base: base ?? d, home: nil) else { return nil }
        return try TerminalLink.there(places, reveal: reveal, on: c)
    }
    #expect(try open(d + "/out file.txt and more") == .editor(P(path: d + "/out file.txt", line: nil)))
    #expect(try open("out file.txt:3") == .editor(P(path: d + "/out file.txt", line: "3")))
    #expect(try open("./sub") == .panel(d + "/sub", into: true))
    #expect(try open("./to-sub") == .panel(d + "/to-sub", into: true))
    #expect(try open("./sub", reveal: true) == .panel(d + "/sub", into: false))
    #expect(try open("./pipe") == nil)
    #expect(try open("./nothing") == nil)
    let home = try c.realpath("."), there = try #require(try FileManager.default.contentsOfDirectory(atPath: home).first {
        var s = stat()
        return stat(home + "/" + $0, &s) == 0 && s.st_mode & S_IFMT == S_IFREG && s.st_size < Editor.sizeLimit
    })
    #expect(try open("~/" + there) == .editor(P(path: home + "/" + there, line: nil)), "~/ is the server's home")
}

/// An SSH tab's paths are its server's — "/etc/hosts" is there, never this Mac's —, relative ones from what its shell
/// told (OSC 7), "~/" the server's; a local tab's start from its shell's folder as the kernel has it, not from what a
/// program printed (`cwd`).
@MainActor @Test func anSSHTabsLinksAreItsServers() {
    let ssh = EmbeddedTerminal.Tab(kind: .ssh(SFTPTarget(host: "me@web.invalid")), view: DropTerminalView(frame: .zero))
    ssh.cwd = "/srv/app"
    #expect(ssh.linkPlace.server == SFTPTarget(host: "me@web.invalid") && ssh.linkPlace.base == "/srv/app" && ssh.linkPlace.home == nil)
    let local = EmbeddedTerminal.Tab(kind: .shell, view: DropTerminalView(frame: .zero))
    local.cwd = "/printed/by/a/program"
    #expect(local.linkPlace.server == nil && local.linkPlace.base == nil && local.linkPlace.home == NSHomeDirectory(), "no shell: no folder")
    let (_, base, home) = ssh.linkPlace
    for link in ["/etc/hosts", "file:///etc/hosts", "~/.ssh/config"] {
        guard case .path(let places) = TerminalLink.route(link, base: base, home: home) else { Issue.record("\(link): a path"); continue }
        #expect(!places.contains { $0.path.hasPrefix(NSHomeDirectory()) }, "\(link): not this Mac's home")
    }
}

/// A local tab running `ssh` (or a container's shell) shows another machine's text: its paths open nothing here. Any other
/// program there is this Mac's.
@MainActor @Test func aLocalTabRunningSSHOpensNoPathHere() async throws {
    _ = NSApplication.shared
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t21l-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: d) }
    for name in ["ssh", "make"] { try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: d + "/" + name) }
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)), panels = NSView(frame: parent.bounds)
    parent.addSubview(panels)
    let term = EmbeddedTerminal(covering: panels)
    defer { term.tabs.forEach { term.close($0.id, confirm: false) } }
    term.newShell(cwd: d)
    let shell = try #require(term.current)
    _ = term.show()
    var calm = 0   // its prompt drawn and its rc files done: what's typed before may be lost
    for _ in 0..<3000 where calm < 5 {
        calm = shell.isAtPrompt && !String(decoding: shell.view.getBufferAsData(), as: UTF8.self).allSatisfy(\.isWhitespace) ? calm + 1 : 0
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!shell.showsAnotherMachine, "the shell itself")
    var refused = 0, web: [String] = []
    let app = AppDelegate()
    app.linkRefused = { refused += 1 }
    app.openWeb = { _, link in web.append(link) }
    for (name, remote) in [("make", false), ("ssh", true), ("exec ./ssh", true)] {   // `exec`: the shell is ssh now
        shell.view.send(txt: " \(name.hasPrefix("exec") ? name : "./" + name) 30\r")   // a leading space: not in your history (HIST_IGNORE_SPACE)
        let program = name.hasPrefix("exec") ? "ssh" : name
        for _ in 0..<3000 where shell.foreground != program { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shell.foreground == program && shell.showsAnotherMachine == remote, "\(name)")
        if remote {
            app.openLink(TerminalLinkRequest(link: "/etc/hosts", params: [:], isExplicit: false), flags: .command, in: shell)
            app.openLink(TerminalLinkRequest(link: "https://example.com", params: [:], isExplicit: false), flags: .command, in: shell)
            #expect(refused == 1 && web == ["https://example.com"], "a path: another machine's; an address opens")
            (refused, web) = (0, [])
        }
        shell.view.send(txt: "\u{3}")   // ⌃C
        for _ in 0..<3000 where shell.isRunning && !shell.isAtPrompt { try await Task.sleep(for: .milliseconds(10)) }
    }
}

@MainActor private final class Rig {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    var got: [(link: String, flags: NSEvent.ModifierFlags)] = []
    var cell: NSSize { v.caretFrame.size }
    init() {
        _ = NSApplication.shared
        w.contentView!.addSubview(v)
        v.pasteboard = NSPasteboard(name: .init("dfm-t21l-" + UUID().uuidString))
        v.onLink = { [unowned self] r, f in got.append((r.link, f)) }
    }
    /// The middle of a cell of the screen as it's scrolled (`row` 0: the view's top).
    func point(col: Int, row: Int) -> NSPoint { NSPoint(x: (CGFloat(col) + 0.5) * cell.width, y: v.frame.height - (CGFloat(row) + 0.5) * cell.height) }
    func event(_ t: NSEvent.EventType, _ p: NSPoint, _ f: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.mouseEvent(with: t, location: p, modifierFlags: f, timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
    }
    func click(col: Int, row: Int, _ f: NSEvent.ModifierFlags = []) {
        v.mouseDown(with: event(.leftMouseDown, point(col: col, row: row), f))
        v.mouseUp(with: event(.leftMouseUp, point(col: col, row: row), f))
    }
    var top: Int { v.terminalStateSnapshot().viewportRow }
}

/// L2: a ⌘-click on a path or an address the text shows reaches the tab with its keys (⌥ too: a panel); without ⌘ it's
/// a click — and no link is looked up as the mouse moves —; an OSC 8 link's hidden target never does.
@MainActor @Test func aCommandClickGivesTheTabTheLink() {
    let r = Rig()
    var refused = 0
    let was = TerminalGate.refused
    TerminalGate.refused = { refused += 1 }
    defer { TerminalGate.refused = was }
    r.v.feed(text: "\u{1b}]8;;file:///nonexistent/Some.app\u{1b}\\https://docs.example\u{1b}]8;;\u{1b}\\ and /etc/hosts\r\n")
    r.v.feed(text: String(repeating: " ", count: r.v.terminalStateSnapshot().dimensions.cols - 4) + "/srv/x.conf")   // wraps
    r.click(col: 27, row: 0)
    #expect(r.got.isEmpty, "no ⌘: a click")
    r.click(col: 27, row: 0, .command)
    r.click(col: 27, row: 0, [.command, .option])
    r.click(col: 2, row: 2, .command)
    #expect(r.got.map(\.link) == ["/etc/hosts", "/etc/hosts", "/srv/x.conf"] && !r.got[0].flags.contains(.option) && r.got[1].flags.contains(.option))
    #expect(r.v.getSelection() == nil, "⌥⌘: no block selection either")
    r.click(col: 2, row: 0, .command)
    #expect(refused == 1 && r.got.count == 3, "OSC 8: its target is hidden")

    let t = r.v.terminal!, before = t.testingImplicitLinkCandidates
    for i in 0..<50 { r.v.mouseMoved(with: r.event(.mouseMoved, r.point(col: 20 + i % 20, row: 0), [])) }
    #expect(t.testingImplicitLinkCandidates == before, "without ⌘ nothing is looked up")
}

/// S2: a plain click leaves an anchor; a ⇧-click with nothing selected selects from it — scrolled away meanwhile, above
/// or below —, copied once. With a selection ⇧ extends it (SwiftTerm's); no anchor, or a program reading the mouse: as
/// before.
@MainActor @Test func aShiftClickSelectsFromTheLastClick() async {
    let r = Rig()
    DropTerminalView.leftButtonDown = { false }   // the real one may be held; never put back (Task13TerminalMouseTests)
    r.v.feed(text: (0..<100).map { "line \($0)" }.joined(separator: "\r\n"))
    let live = r.top
    r.click(col: 3, row: 0, .shift)
    #expect(r.v.getSelection() == nil, "no anchor: nothing")
    r.v.scrollTo(row: 0)
    r.click(col: 2, row: 10)  // "ne 10"
    #expect(r.v.anchor?.row == 10)
    r.v.scrollTo(row: live)
    let copies = r.v.pasteboard.changeCount
    r.click(col: 4, row: 95 - live, .shift)
    await drained()
    let s = r.v.getSelection() ?? ""
    #expect(s.hasPrefix("ne 10\nline 11\n") && s.hasSuffix("line 94\nline"), "\(s.prefix(20))…\(s.suffix(20))")
    #expect(r.v.pasteboard.changeCount == copies + 1 && r.v.pasteboard.string(forType: .string) == s, "copied once, the end")
    #expect(r.top == live, "nothing scrolled")
    r.click(col: 3, row: 97 - live, .shift)
    #expect(r.v.getSelection()?.hasSuffix("line 96\nlin") == true, "with a selection: SwiftTerm's extend")

    r.click(col: 1, row: 2)   // clears it; the new anchor is below the view once it's scrolled up
    #expect(r.v.getSelection() == nil && r.v.anchor?.row == live + 2)
    r.v.scrollTo(row: 0)
    r.click(col: 2, row: 1, .shift)
    let below = r.v.getSelection() ?? ""
    #expect(below.hasPrefix("ne 1\nline 2\n") && below.contains("line \(live + 1)\nl"), "from here down to it")

    // The anchor goes: its row reads otherwise (redrawn in place; a `clear` and new output), ⌘K; a program's click
    // leaves it.
    r.v.scrollTo(row: live)
    r.click(col: 0, row: 3)
    r.v.feed(text: "\u{1b}7\u{1b}[4;1Hredrawn\u{1b}8")   // the same row, another text: nothing renumbered
    r.click(col: 0, row: 5, .shift)
    #expect(r.v.getSelection() == nil)
    r.click(col: 0, row: 3)
    r.v.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J" + (0..<100).map { "other \($0)" }.joined(separator: "\r\n"))
    r.click(col: 0, row: 5, .shift)
    #expect(r.v.getSelection() == nil)
    r.click(col: 0, row: 3)
    r.v.dropMarks()
    r.click(col: 0, row: 5, .shift)
    #expect(r.v.getSelection() == nil && r.v.anchor == nil)
    r.click(col: 0, row: 3)
    let anchor = r.v.anchor?.row
    r.v.feed(text: "\u{1b}[?1000h")
    r.click(col: 0, row: 6)
    #expect(anchor != nil && r.v.anchor?.row == anchor, "a program's click isn't one")
}

@MainActor private func editorGone() {
    guard let h = EditorHost.shared else { return }
    for e in h.docs { e.closed(); e.host = nil }
    h.drafts?.release()
    h.window?.orderOut(nil)
    EditorHost.shared = nil
}

extension EditorWindowTests {
    /// L2: a clicked file opens at its line — "30", "7:3" —; open already, its tab goes there. A server's too (over the
    /// local SFTP server: downloaded, then the line), again from its open tab.
    @Test func aClickedPathOpensAtItsLine() async throws {
        _ = NSApplication.shared
        let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t21l-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { editorGone(); try? FileManager.default.removeItem(atPath: dir) }
        editorGone()
        EditorHost.restore(dir + "/drafts", onServer: { _, _, _, _ in ({ _ in }, {}) })
        let text = (1...50).map { "line \($0)" }.joined(separator: "\n") + "\n"
        for f in ["a.txt", "s.txt"] { try Data(text.utf8).write(to: URL(fileURLWithPath: dir + "/" + f)) }
        func at(_ e: Editor?) -> String? {
            guard let e else { return nil }
            let before = (e.textView.string as NSString).substring(to: e.textView.selectedRange().location)
            return "\(before.filter { $0 == "\n" }.count + 1):\(before.count - (before.lastIndex(of: "\n").map { before.distance(from: before.startIndex, to: $0) + 1 } ?? 0) + 1)"
        }
        let url = URL(fileURLWithPath: dir + "/a.txt")
        Editor.open(url, line: "30")
        try await waitFor("opened") { editorDoc(url) != nil }
        #expect(at(editorDoc(url)) == "30:1")
        Editor.open(url, line: "7:3")
        #expect(at(editorDoc(url)) == "7:3", "open already: there")

        let app = AppDelegate()
        app.window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        app.panels = [PanelViewController(tabs: [dir], index: 0, showHidden: false)]
        app.panels.forEach { $0.loadViewIfNeeded() }
        Editor.app = { app }
        let t = SFTPTarget.local(), path = dir + "/s.txt"
        app.remoteOpen(.edit, t, path, line: "12", in: app.panels[0])
        try await waitFor("downloaded") { Editor.editing(t, path) != nil }
        #expect(at(Editor.editing(t, path)) == "12:1")
        app.remoteOpen(.edit, t, path, line: "40", in: app.panels[0])
        #expect(at(Editor.editing(t, path)) == "40:1", "its open tab")

        // ⌘-click, all the way: an SSH tab's "/etc/hosts" is its server's (here the local SFTP server stands in for one),
        // never this Mac's; a big file that isn't text opens nothing; a local tab's file is this Mac's.
        var refused = 0
        app.linkRefused = { refused += 1 }
        let click = { (link: String, tab: EmbeddedTerminal.Tab) in app.openLink(TerminalLinkRequest(link: link, params: [:], isExplicit: false), flags: .command, in: tab) }
        let ssh = EmbeddedTerminal.Tab(kind: .ssh(t), view: DropTerminalView(frame: .zero))
        click("/etc/hosts", ssh)
        try await waitFor("the server's") { Editor.editing(t, "/etc/hosts") != nil }
        #expect(editorDoc(URL(fileURLWithPath: "/etc/hosts")) == nil, "not this Mac's")
        let big = FileHandle(forWritingAtPath: { FileManager.default.createFile(atPath: dir + "/big.bin", contents: nil); return dir + "/big.bin" }())!
        try big.truncate(atOffset: UInt64(Editor.sizeLimit) + 1)   // sparse: nothing written
        try big.close()
        click(dir + "/big.bin", ssh)
        try await waitFor("refused") { refused == 1 }
        let local = EmbeddedTerminal.Tab(kind: .shell, view: DropTerminalView(frame: .zero)), b = URL(fileURLWithPath: dir + "/b.txt")
        try Data(text.utf8).write(to: b)
        click(b.path + ":9", local)
        try await waitFor("this Mac's") { editorDoc(b) != nil }
        #expect(at(editorDoc(b)) == "9:1" && Editor.editing(t, b.path) == nil)
    }
}
