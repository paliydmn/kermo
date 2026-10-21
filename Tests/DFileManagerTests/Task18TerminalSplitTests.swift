import AppKit
import DFMCore
import Testing
@testable import DFileManager

// Task 18: a terminal tab of several panes, as VS Code's split.

@MainActor private var windows: [NSWindow] = []   // the terminal holds its host view unowned

@MainActor private func terminal() -> EmbeddedTerminal {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let panels = NSView(frame: w.contentView!.bounds)
    w.contentView!.addSubview(panels)
    windows.append(w)
    return EmbeddedTerminal(covering: panels)
}

private let a = SFTPTarget(host: "a@dfm-18.invalid"), b = SFTPTarget(host: "b@dfm-18.invalid"), c = SFTPTarget(host: "c@dfm-18.invalid")

@MainActor private func targets(_ term: EmbeddedTerminal) -> [[String]] { term.groups.map { $0.panes.map { $0.target?.host ?? "shell" } } }

/// ⌘⇧\ on a local shell: a shell under it, in its folder, focused; the tab keeps its way; four panes at most.
@MainActor @Test func splitAddsAShellInTheSameFolder() async throws {
    let dir = NSTemporaryDirectory() + "dfm-18-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    let real = String(cString: realpath(dir, &buf))
    let term = terminal()
    defer { term.tabs.forEach { $0.view.process?.terminate() } }
    _ = term.show(cwd: real)
    let first = try #require(term.current)
    term.split(vertical: false)
    #expect(term.groups.count == 1 && term.tabs.count == 2 && term.current !== first && term.groups[0].vertical == false)
    let second = try #require(term.current)
    for _ in 0..<500 where second.shellCwd != real { try await Task.sleep(for: .milliseconds(10)) }
    #expect(second.shellCwd == real, "the same folder")
    term.split(vertical: true)
    #expect(term.groups[0].vertical == false, "a split tab keeps its way")
    term.split(vertical: true)
    term.split(vertical: true)
    #expect(term.tabs.count == EmbeddedTerminal.maxPanes, "the fifth is refused")
    #expect(!first.header.isHidden && !second.header.isHidden, "several panes: each has its header")
}

/// Join puts another tab's panes after the current one's, the first of them focused; Move Pane to New Tab takes one out;
/// a closed pane hands the focus to the one before it; a session's sidebar row focuses its pane.
@MainActor @Test func joinUnsplitCloseAndSelect() throws {
    let term = terminal()
    term.restore([.init(vertical: false, panes: [a, b]), .init(vertical: true, panes: [c])])
    #expect(targets(term) == [[a.host, b.host], [c.host]] && term.saved == [.init(vertical: false, panes: [a, b]), .init(vertical: true, panes: [c])])
    _ = term.show()
    #expect(term.joinable.count == 1)
    term.join(term.groups[1])
    #expect(targets(term) == [[a.host, b.host, c.host]] && term.current?.target == c && term.groups[0].vertical == false)

    term.focusPane(by: -1, vertical: true)
    #expect(term.current?.target == c, "⌥⌘← in a tab of panes one above another: nothing")
    term.focusPane(by: -1, vertical: false)
    #expect(term.current?.target == b)

    term.unsplit()
    #expect(targets(term) == [[a.host, c.host], [b.host]] && term.current?.target == b)
    term.select(term.tabs.first { $0.target == c }!.id)
    #expect(term.current?.target == c)
    term.close(confirm: false)
    #expect(targets(term) == [[a.host], [b.host]] && term.current?.target == a)
    #expect(term.groups[0].pane.header.isHidden, "one pane: no header")
}

/// No room: a tab of three takes no tab of two.
@MainActor @Test func joinKeepsToFourPanes() {
    let term = terminal()
    term.restore([.init(vertical: true, panes: [a, b, c]), .init(vertical: true, panes: [a, b])])
    _ = term.show()
    #expect(term.joinable.isEmpty)
    term.join(term.groups[1])
    #expect(term.groups.count == 2)
}

/// 1.3's `sshTabs`: each session in a tab of its own.
@MainActor @Test func oldSavedTabsComeBackOneATab() {
    let term = terminal()
    term.restore([a, b])
    #expect(targets(term) == [[a.host], [b.host]] && term.saved.allSatisfy { $0.panes.count == 1 })
}

/// The wheel and clicks go to the pane under the mouse, not the focused one.
@MainActor @Test func theMouseFindsThePaneUnderIt() throws {
    let term = terminal()
    term.restore([.init(vertical: true, panes: [a, b])])
    _ = term.show()
    let g = term.groups[0]
    g.split.window!.contentView!.layoutSubtreeIfNeeded()
    let v = g.panes[1].view
    let p = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
    let e = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0, windowNumber: v.window!.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    #expect(g.focused == 0 && term.paneIndex(under: e, in: g) == 1)
}
