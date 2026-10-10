import AppKit
import DFMCore
import Testing
@testable import DFileManager

// Task 12: the ⌃O terminal for a CLI user.

@MainActor private var hosts: [NSView] = []   // the terminal holds its host view unowned

@MainActor private func terminal() -> EmbeddedTerminal {
    _ = NSApplication.shared
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let panels = NSView(frame: parent.bounds)
    parent.addSubview(panels)
    hosts.append(parent)
    return EmbeddedTerminal(covering: panels)
}

@MainActor private func text(_ tab: EmbeddedTerminal.Tab) -> String {
    String(decoding: tab.view.getTerminal().getBufferAsData(), as: UTF8.self)
}

private func osc7(_ path: String) -> String { "\u{1b}]7;file://mac\(path)\u{7}" }

@MainActor private func waitUntil(_ what: String, _ cond: () -> Bool) async throws {
    for _ in 0..<1000 where !cond() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(cond(), "timed out: \(what)")
}

/// The shell has drawn its prompt and has the terminal (rc files done).
@MainActor private func atPrompt(_ tab: EmbeddedTerminal.Tab) async {
    var calm = 0
    for _ in 0..<1000 where calm < 5 {
        calm = !text(tab).allSatisfy(\.isWhitespace) && tab.isAtPrompt ? calm + 1 : 0
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// A fresh folder under the real (symlink-resolved, as the kernel reports it) temporary directory.
private func tempDir(_ name: String) throws -> String {
    let dir = NSTemporaryDirectory() + "dfm-12-" + UUID().uuidString + "/" + name
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    return String(cString: realpath(dir, &buf))   // /private/var/…, as the kernel says it (Foundation's resolvers leave /private off)
}

/// A tab without a process, for what needs none.
@MainActor private func idleTab(_ term: EmbeddedTerminal) -> EmbeddedTerminal.Tab {
    term.restore([SFTPTarget(host: "dfm-12.invalid")])
    return term.tabs[0]
}

/// Runs `body` with the three terminal keys as given (nil: absent), then puts back whatever they held.
@MainActor private func withDefaults(_ values: [String: Any?], _ body: () throws -> Void) rethrows {
    let d = UserDefaults.standard
    let saved = values.keys.map { ($0, d.object(forKey: $0)) }
    defer { saved.forEach { d.set($1, forKey: $0) } }
    values.forEach { d.set($1, forKey: $0) }
    try body()
}

/// 3: 10 000 lines of scrollback (SwiftTerm's default is 500): the start of a build's output is still there.
@MainActor @Test func aTabKeeps10000LinesOfScrollback() {
    let tab = idleTab(terminal())
    #expect(tab.view.getTerminal().options.scrollback == 10_000)
    tab.view.feed(text: (1...2000).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n")
    #expect(text(tab).contains("\nline 1\nline 2\n") && text(tab).contains("line 2000"))   // above it: the tab's own "Not connected"
}

/// 4: ⌘+ / ⌘− is remembered (`terminalFontSize`, clamped to 9…36 on the way back in); `terminalFont` names the font
/// (Nerd Fonts for p10k / starship), an unknown name falls back to SF Mono.
@MainActor @Test func fontSizeAndFamilyAreRemembered() {
    withDefaults(["terminalFontSize": 13.0, "terminalFont": nil]) {
        let a = terminal()
        a.zoom(by: 2)
        #expect(a.fontSize == 15 && UserDefaults.standard.double(forKey: "terminalFontSize") == 15)
        let b = terminal()
        #expect(b.fontSize == 15 && idleTab(b).view.font.pointSize == 15, "a new terminal (a restart) starts at the saved size")
    }
    withDefaults(["terminalFontSize": 100.0]) { #expect(terminal().fontSize == 36) }
    withDefaults(["terminalFontSize": 1.0]) { #expect(terminal().fontSize == 9) }
    withDefaults(["terminalFontSize": nil]) { #expect(terminal().fontSize == 13) }
    withDefaults(["terminalFont": "NoSuchFont-xyz"]) {
        #expect(EmbeddedTerminal.font(size: 13) == .monospacedSystemFont(ofSize: 13, weight: .regular))
    }
    withDefaults(["terminalFont": "Menlo", "terminalFontSize": 13.0]) {
        let tab = idleTab(terminal())
        #expect(tab.view.font.familyName == "Menlo" && tab.view.font.pointSize == 13)
    }
}

/// 9: `terminalOptionIsMeta false` lets ⌥ type the layout's `@ | [ ]` instead of sending ESC+key; unset, ⌥ is Meta.
@MainActor @Test func optionAsMetaHasASwitch() {
    withDefaults(["terminalOptionIsMeta": false]) { #expect(idleTab(terminal()).view.optionAsMetaKey == false) }
    withDefaults(["terminalOptionIsMeta": nil]) { #expect(idleTab(terminal()).view.optionAsMetaKey == true) }
}

/// 5: a local tab is named after its shell's folder ("~" at home), by the kernel's word — no shell setup needed —
/// and again on every `cd` the shell reports (OSC 7, the README snippet); a title the shell sets (OSC 2) wins.
@MainActor @Test func aLocalTabIsNamedAfterItsFolder() async throws {
    #expect(EmbeddedTerminal.folderName("/Users/me/src/a b") == "a b")
    #expect(EmbeddedTerminal.folderName(NSHomeDirectory()) == "~" && EmbeddedTerminal.folderName("/") == "/")

    let dir = try tempDir("x y"), other = try tempDir("other")
    defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }
    let term = terminal()
    defer { term.tabs.forEach { term.close($0.id, confirm: false) } }
    term.newShell(cwd: dir)
    let tab = try #require(term.current)
    _ = term.show()
    await atPrompt(tab)
    #expect(tab.shellCwd == dir && tab.label == "x y")

    var changes = 0
    term.onChange = { changes += 1 }
    #expect(term.cd(other))
    try await waitUntil("the shell moved") { tab.shellCwd == other }
    await atPrompt(tab)
    #expect(tab.label == "other", "the kernel's word, whatever the shell prints")
    tab.view.feed(text: osc7(other))   // the snippet's precmd
    #expect(tab.cwd == other && changes > 0, "told: the tab bar is redrawn")
    tab.view.feed(text: "\u{1b}]2;my title\u{7}")
    #expect(tab.label == "my title")
}

/// 2: ⌃↩ / ⌃⇧↩ with the terminal up type the quoted name / paths into the current tab's shell — only a tab on the
/// panel's machine, only text free of C0 / DEL (the line editor would act on those before the shell sees a quote).
@MainActor @Test func insertTypesIntoTheShellOfTheSameMachine() async throws {
    #expect(ShellContext.isTypeable("'a b' ") && !ShellContext.isTypeable("a\nb") && !ShellContext.isTypeable("x\u{7f}"))
    #expect(ShellContext(dir: "/tmp/d", otherDir: nil, cursor: "a b", targets: ["a b", "c"]).expand("%S") == "'/tmp/d/a b' /tmp/d/c")

    let term = terminal()
    defer { term.tabs.forEach { $0.view.process?.terminate() } }
    let web = SFTPTarget(host: "dfm-12-web.invalid")
    term.restore([web])
    let ssh = try #require(term.current)
    ssh.exitStatus = nil   // a stand-in ssh: a plain shell that echoes what it gets
    term.launch(ssh, "/bin/sh", ["-i"], cwd: nil)
    try await waitUntil("its prompt") { ssh.isAtPrompt }
    _ = term.show()
    #expect(!term.insert("'a b' ", on: nil), "a local panel's name into a server's shell: no")
    #expect(!term.insert("'a b' ", on: SFTPTarget(host: "dfm-12-db.invalid")), "another server's: no")
    #expect(!term.insert("a\nb ", on: web), "a control character: no")
    #expect(term.insert("'a b' ", on: web))
    try await waitUntil("typed") { text(ssh).contains("'a b' ") }
    #expect(!text(ssh).contains("a\nb "))

    term.newShell(cwd: NSHomeDirectory())   // a local tab for a local panel
    let shell = try #require(term.current)
    try await waitUntil("its prompt") { shell.isAtPrompt }
    #expect(!term.insert("'c d' ", on: web))
    #expect(term.insert("'c d' ", on: nil))
    try await waitUntil("typed") { text(shell).contains("'c d' ") }
    #expect(!text(ssh).contains("'c d' "), "only the tab in front")
}

/// 7: files dropped on a local tab are typed as quoted paths; an SSH tab takes none (this Mac's paths mean nothing
/// there), nor does any tab a path with a control character.
@MainActor @Test func droppedFilesAreTypedAsQuotedPaths() async throws {
    func pasteboard(_ paths: [String]) -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        return pb
    }
    #expect(DropTerminalView.typed(from: pasteboard(["/tmp/a b", "/tmp/c"])) == "'/tmp/a b' /tmp/c ")
    #expect(DropTerminalView.typed(from: pasteboard(["/tmp/a\nb"])) == nil)
    #expect(DropTerminalView.typed(from: pasteboard([])) == nil)

    let term = terminal()
    defer { term.tabs.forEach { $0.view.process?.terminate() } }
    term.restore([SFTPTarget(host: "dfm-12-drop.invalid")])
    let ssh = try #require(term.current)
    #expect(!ssh.view.acceptsLocalPaths && !ssh.view.drop(pasteboard(["/tmp/c"])))
    #expect(!text(ssh).contains("/tmp/c"))

    term.newShell(cwd: NSHomeDirectory())
    let shell = try #require(term.current)
    try await waitUntil("its prompt") { shell.isAtPrompt }
    #expect(shell.view.acceptsLocalPaths && shell.view.drop(pasteboard(["/tmp/a b", "/tmp/c"])))
    try await waitUntil("typed") { text(shell).contains("'/tmp/a b' /tmp/c ") }
    #expect(!shell.view.drop(pasteboard(["/tmp/a\nb"])))
}

/// 1: ⌘E ↩ types the command into a local shell at its prompt — after a ` cd` when it's elsewhere, over a half-typed
/// line — or into a new tab when none is free (a program has the terminal); a control character is refused outright.
@MainActor @Test func cmdEReturnRunsInTheEmbeddedShell() async throws {
    let dir = try tempDir("one"), other = try tempDir("two")
    defer { for d in [dir, other] { try? FileManager.default.removeItem(atPath: (d as NSString).deletingLastPathComponent) } }
    let term = terminal()
    defer { term.tabs.forEach { term.close($0.id, confirm: false) } }
    #expect(term.run("ls 'a\nb'", cwd: dir) == nil && term.tabs.isEmpty && !term.isShown, "a control character: refused before anything starts")
    #expect(term.run("true", cwd: dir + "/\u{1}") == nil && term.tabs.isEmpty)

    // No shell yet: a new one in `dir`, the command typed ahead of its first prompt.
    try #require(term.run("touch m1", cwd: dir) != nil)
    let shell = try #require(term.current)
    #expect(term.isShown && term.tabs.count == 1 && shell.kind == .shell)
    try await waitUntil("m1") { FileManager.default.fileExists(atPath: dir + "/m1") }
    await atPrompt(shell)

    // The shell is elsewhere: ` cd` first (a leading space: HIST_IGNORE_SPACE keeps it out of the history); a half-typed line goes.
    shell.view.send(txt: "echo hel")
    try #require(term.run("touch m2", cwd: other) != nil)
    try await waitUntil("m2") { FileManager.default.fileExists(atPath: other + "/m2") }
    // The echo reaches the buffer after the pty read, off the main thread: wait for it (the folder wraps over the 75-column screen; m2 proves where).
    try await waitUntil("cd echoed") { text(shell).contains(" cd /") }
    #expect(!text(shell).contains("heltouch"))
    #expect(shell.shellCwd == other && term.tabs.count == 1)
    await atPrompt(shell)

    // A program has the terminal: the command goes to a new tab, the program gets nothing.
    shell.view.send(txt: "cat\r")
    try await waitUntil("cat has the terminal") { !shell.isAtPrompt }
    try #require(term.run("touch m3", cwd: other) != nil)
    #expect(term.tabs.count == 2 && term.current !== shell)
    try await waitUntil("m3") { FileManager.default.fileExists(atPath: other + "/m3") }
    #expect(!text(shell).contains("touch m3"))
}
