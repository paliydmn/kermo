import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

@MainActor private var hosts: [NSView] = []   // the terminal holds its host view unowned

@MainActor private func terminal() -> EmbeddedTerminal {
    _ = NSApplication.shared
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let panels = NSView(frame: parent.bounds)
    parent.addSubview(panels)
    hosts.append(parent)
    return EmbeddedTerminal(covering: panels)
}

private func osc7(_ path: String) -> String { "\u{1b}]7;file://mac\(path)\u{7}" }

/// The shell has drawn its prompt and has the terminal (rc files done).
@MainActor private func atPrompt(_ tab: EmbeddedTerminal.Tab) async {
    var calm = 0
    for _ in 0..<1000 where calm < 5 {
        let drawn = !String(decoding: tab.view.getTerminal().getBufferAsData(), as: UTF8.self).allSatisfy(\.isWhitespace)
        calm = drawn && tab.isAtPrompt ? calm + 1 : 0
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// I2: a program in a local shell (`cat` of a file with an OSC 7 in it, `tail -f`) prints the same bytes as the shell,
/// even for the folder the shell is in: only the shell at its prompt moves the panel.
@MainActor @Test func aProgramInALocalShellDoesntMoveThePanel() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-i2-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let term = terminal()
    defer { term.tabs.forEach { term.close($0.id, confirm: false) } }
    var told: [String?] = []
    term.onDirectory = { told.append($0.cwd) }
    term.newShell(cwd: dir)
    let shell = try #require(term.current)
    _ = term.show()
    await atPrompt(shell)

    shell.view.send(txt: "/bin/sleep 30\r")
    for _ in 0..<500 where shell.isAtPrompt { try await Task.sleep(for: .milliseconds(10)) }
    try #require(!shell.isAtPrompt)
    shell.view.feed(text: osc7(dir))
    #expect(told.isEmpty && shell.cwd == nil, "sleep has the terminal")

    shell.view.send([0x03])   // ⌃C: the shell's prompt again
    await atPrompt(shell)
    shell.view.feed(text: osc7(dir))
    #expect(told == [dir] && shell.cwd == dir)
}

/// I2: a `cd` in an SSH tab while the terminal is hidden moves no panel (nor clears its marks) — not then, and not once
/// the terminal is back and the next prompt says the same folder: only the next `cd` does.
@MainActor @Test func anSSHTabsHiddenCdMovesNothingLater() {
    let term = terminal()
    var told: [String?] = []
    term.onDirectory = { told.append($0.cwd) }
    term.restore([SFTPTarget(host: "dfm-i2.invalid")])
    let tab = term.tabs[0]
    _ = term.show()
    tab.view.feed(text: osc7("/var/log"))
    _ = term.hide()
    tab.view.feed(text: osc7("/var/www"))
    _ = term.show()
    tab.view.feed(text: osc7("/var/www"))   // the next prompt
    #expect(told == ["/var/log"])
    tab.view.feed(text: osc7("/srv"))
    #expect(told == ["/var/log", "/srv"])
}
