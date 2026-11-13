import AppKit
@testable import DFMCore
import SwiftTerm
import Testing
@testable import DFileManager

// The terminal's mouse as in PuTTY: a selection copies, a right-click pastes.

/// What the main queue holds now has run: SwiftTerm's word to the gate (`onMain`), a selection's copy (it waits there
/// for the terminal's lock to be let go). Whatever was to happen from a `feed` or a click has happened.
@MainActor func drained() async { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }

/// Waits up to 2 s for what a program does on its own time.
@MainActor func waitFor(_ what: String, _ cond: () -> Bool) async throws {
    for _ in 0..<200 where !cond() { try await Task.sleep(for: .milliseconds(10)) }
    try #require(cond(), "timed out: \(what)")
}

@MainActor private func text(_ v: TerminalView) -> String { String(decoding: v.getBufferAsData(), as: UTF8.self) }

/// A view running a stand-in program (raw tty, no echo) once it has said "ready"; it prints what it reads (`od -c`).
@MainActor private func standIn(_ script: String) async throws -> DropTerminalView {
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    v.startProcess(executable: "/bin/sh", args: ["-c", "stty raw -echo; " + script + "; sleep 5"])
    try await waitFor("the stand-in started") { text(v).contains("ready") }
    return v
}

/// A selection goes to the clipboard as it's made (here: ⌘A, made at once); `terminalCopyOnSelect` false: it doesn't.
@MainActor @Test func aSelectionInTheTerminalIsCopied() async {
    let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString))
    defer { pb.releaseGlobally(); DropTerminalView.leftButtonDown = { NSEvent.pressedMouseButtons & 1 != 0 } }
    DropTerminalView.leftButtonDown = { false }   // the real mouse may be held by whoever works on this Mac meanwhile
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    v.pasteboard = pb
    v.feed(text: "hello world")
    v.selectAll()
    await drained()
    #expect(pb.string(forType: .string)?.contains("hello world") == true)

    pb.clearContents()
    pb.setString("kept", forType: .string)
    let was = UserDefaults.standard.object(forKey: "terminalCopyOnSelect")
    UserDefaults.standard.set(false, forKey: "terminalCopyOnSelect")
    v.selectAll()   // decided now; back at once, before another test's copy could read it
    UserDefaults.standard.set(was, forKey: "terminalCopyOnSelect")
    await drained()
    #expect(pb.string(forType: .string) == "kept")
}

/// The program's output drops or moves a selection on SwiftTerm's own thread: that copies nothing (nor may it touch
/// the view there).
@MainActor @Test func aSelectionDroppedByOutputCopiesNothing() async throws {
    let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString))
    defer { pb.releaseGlobally(); DropTerminalView.leftButtonDown = { NSEvent.pressedMouseButtons & 1 != 0 } }
    DropTerminalView.leftButtonDown = { false }
    let v = try await standIn("echo ready; read x; printf '\\033[2J'; echo cleared")   // the screen is redrawn under the selection
    defer { v.process.terminate() }
    v.pasteboard = pb
    v.selectAll()
    await drained()
    #expect(pb.string(forType: .string)?.contains("ready") == true)
    pb.clearContents()
    pb.setString("kept", forType: .string)
    v.send(txt: "\n")
    try await waitFor("the program redrew") { text(v).contains("cleared") }
    await drained()
    #expect(!v.selectionActive, "the output dropped it")
    #expect(pb.string(forType: .string) == "kept")
}

/// A plain right-click is a mouse-reading program's (mc, htop); ⇧ pastes there anyway.
@Test func aRightClickPastesUnlessTheProgramReadsTheMouse() {
    #expect(DropTerminalView.rightClickPastes(shift: false, programReadsMouse: false))
    #expect(!DropTerminalView.rightClickPastes(shift: false, programReadsMouse: true))
    #expect(DropTerminalView.rightClickPastes(shift: true, programReadsMouse: true))
}

/// Only several lines, into a risky tab, whose shell didn't ask for bracketed paste, ask first.
@Test func severalLinesIntoARiskyShellAsk() {
    #expect(DropTerminalView.pasteAsks("ls\nrm -rf x\n", bracketed: false, risky: true))
    #expect(DropTerminalView.pasteAsks("a\rb", bracketed: false, risky: true))
    #expect(!DropTerminalView.pasteAsks("ls -la", bracketed: false, risky: true), "one line without ↩: nothing runs")
    #expect(!DropTerminalView.pasteAsks("ls\nrm\n", bracketed: true, risky: true), "zsh, bash 5.1: nothing runs till ↩")
    #expect(!DropTerminalView.pasteAsks("ls\nrm\n", bracketed: false, risky: false))
}

extension ServerLockTests {
/// Risky: a production server's SSH tab, or one logged in as root@; not a local shell or another server's.
@Test func whereAPasteOfSeveralLinesAsks() {
    var prod = SavedServer(address: "deploy@web1.invalid")!
    prod.prod = true
    prod.name = "web1"
    ServerLock.servers = { [prod] }
    defer { ServerLock.servers = { [] } }
    func risk(_ k: EmbeddedTerminal.Kind) -> String? {
        EmbeddedTerminal.Tab(kind: k, view: DropTerminalView(frame: .zero)).view.pasteRisk().map { $0.chips.map(\.word).joined(separator: " ") + " " + $0.place }
    }
    #expect(risk(.ssh(prod.target)) == "PROD web1", "by its saved name")
    #expect(risk(.ssh(SFTPTarget(host: "root@db.invalid"))) == "ROOT root@db.invalid")
    #expect(risk(.ssh(SFTPTarget(host: "me@db.invalid"))) == nil)
    #expect(risk(.shell) == nil)
}
}

/// OSC 52 (Claude Code's copy) writes the clipboard — from the tab in front only.
@MainActor @Test func osc52WritesTheClipboard() async throws {
    let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString))
    defer { pb.releaseGlobally() }
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    try #require(v.terminalDelegate is TerminalGate)   // else SwiftTerm's own would write the real clipboard
    v.pasteboard = pb
    func osc52(_ s: String) async { v.feed(text: s); await drained() }
    await osc52("\u{1b}]52;c;" + Data("привіт, Claude".utf8).base64EncodedString() + "\u{7}")
    #expect(pb.string(forType: .string) == "привіт, Claude")
    await osc52("\u{1b}]52;;" + Data("no target".utf8).base64EncodedString() + "\u{1b}\\")
    #expect(pb.string(forType: .string) == "no target", "an empty target, ST-ended")
    await osc52("\u{1b}]52;c;?\u{7}")
    #expect(pb.string(forType: .string) == "no target")
    let long = String(repeating: "довга відповідь Claude\n", count: 1500)   // ~60 KB of base64
    await osc52("\u{1b}]52;c;" + Data(long.utf8).base64EncodedString() + "\u{7}")
    #expect(pb.string(forType: .string) == long)
    v.isHidden = true
    await osc52("\u{1b}]52;c;" + Data("hidden".utf8).base64EncodedString() + "\u{7}")
    #expect(pb.string(forType: .string) == long, "a tab not in front")
}

/// No program reads the clipboard: an OSC 52 read (`?`) gets no answer — the program reads only what's typed next.
@MainActor @Test func aProgramCantReadTheClipboard() async throws {
    let v = try await standIn("printf '\\033]52;c;?\\007'; echo ready; dd bs=1 count=4 2>/dev/null | od -An -c")
    defer { v.process.terminate() }
    #expect(v.terminalDelegate is TerminalGate)
    try await Task.sleep(for: .milliseconds(300))   // an answer, if any, would be on its way by now
    v.send(txt: "zzzz")
    try await waitFor("the program read 4 bytes") { text(v).contains("z   z") || text(v).contains("]   5   2") }
    #expect(!text(v).contains("]   5   2"), "no answer with the clipboard in it")
}

/// Nor kitty's clipboard (OSC 5522): the gate offers none and refuses each request.
@MainActor @Test func kittysClipboardIsRefused() {
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let g = try! #require(v.terminalDelegate as? TerminalGate)
    #expect(g.kittyClipboardCapabilities(source: v).isEmpty)
    #expect(g.kittyClipboardAvailableMimeTypes(source: v, location: .standard) == [], "nil: SwiftTerm would read the pasteboard")
    #expect(g.kittyClipboardRead(source: v, location: .standard, mimeType: "text/plain") == .denied)
    #expect(g.kittyClipboardWrite(source: v, location: .standard, content: KittyClipboardWriteContent(representations: [])) == .denied)
    let ask = g.kittyClipboardRequestPermission(source: v, request: KittyClipboardPermissionRequest(direction: .read, location: .standard, name: "", mimeTypes: [], canRememberPassword: false))
    #expect({ if case .deny = ask { true } else { false } }())
}

/// The wheel is a program's when it reads the mouse (Claude Code, htop, vim's mouse=a), as in Terminal.app.
@MainActor @Test func theWheelGoesToAProgramThatReadsTheMouse() async throws {
    let v = try await standIn("printf '\\033[?1000h\\033[?1006h'; echo ready; dd bs=1 count=5 2>/dev/null | od -An -c")
    defer { v.process.terminate() }
    v.scrollWheel(with: NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!)!)
    try await waitFor("the program read the wheel") { text(v).contains("<   6   4") }   // ESC [ < 64 …: button 4, up
}

/// D-093: in a full-screen program that doesn't read the mouse (less, man, git log) the wheel is ↑ / ↓.
@MainActor @Test func theWheelScrollsLess() async throws {
    let v = try await standIn("printf '\\033[?1049h'; echo ready; dd bs=1 count=3 2>/dev/null | od -An -c")
    defer { v.process.terminate() }
    v.scrollWheel(with: NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!)!)
    try await waitFor("the program read ↑") { text(v).contains("033   [   A") }
}

/// ⇧-drag in a program that reads the mouse selects (and so copies) here; a plain drag is the program's.
@MainActor @Test func shiftSelectsInAProgramThatReadsTheMouse() async {
    let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString))
    defer { pb.releaseGlobally(); DropTerminalView.leftButtonDown = { NSEvent.pressedMouseButtons & 1 != 0 } }
    DropTerminalView.leftButtonDown = { false }
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    v.pasteboard = pb
    v.feed(text: "hello world\u{1b}[?1000h")
    pb.clearContents()
    pb.setString("kept", forType: .string)
    drag(v, from: 0, to: 8, row: 0, [])
    await drained()
    #expect(!v.selectionActive && pb.string(forType: .string) == "kept", "the program's drag")
    drag(v, from: 0, to: 8, row: 0, .shift)
    await drained()
    #expect(pb.string(forType: .string)?.hasPrefix("hello") == true, "\(pb.string(forType: .string) ?? "nil")")
}

/// ⌥-drag selects a block (Terminal.app's, iTerm2's): the same columns of each line.
@MainActor @Test func optionDragSelectsABlock() async {
    let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString))
    defer { pb.releaseGlobally(); DropTerminalView.leftButtonDown = { NSEvent.pressedMouseButtons & 1 != 0 } }
    DropTerminalView.leftButtonDown = { false }
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    v.pasteboard = pb
    v.feed(text: "abcdefgh\r\nijklmnop\r\nqrstuvwx")
    drag(v, from: 2, to: 4, row: 0, toRow: 2, .option)
    await drained()
    #expect(pb.string(forType: .string)?.split(whereSeparator: \.isNewline) == ["cd", "kl", "st"])   // up to the cell it ends in
}

/// A drag from cell `from` to cell `to` (columns; rows from the top), the mouse in each cell's middle.
@MainActor private func drag(_ v: TerminalView, from: Int, to: Int, row: Int, toRow: Int? = nil, _ mods: NSEvent.ModifierFlags) {
    let f = v.font   // SwiftTerm's cell: W's advance, the line's height
    let (cw, ch) = (("W" as NSString).size(withAttributes: [.font: f]).width, ceil(f.ascender - f.descender + f.leading))
    func at(_ col: Int, _ row: Int) -> NSPoint { NSPoint(x: (CGFloat(col) + 0.5) * cw, y: v.bounds.height - (CGFloat(row) + 0.5) * ch) }
    func e(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: t, location: p, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    v.mouseDown(with: e(.leftMouseDown, at(from, row)))
    v.mouseDragged(with: e(.leftMouseDragged, at((from + to) / 2, row)))
    v.mouseDragged(with: e(.leftMouseDragged, at(to, toRow ?? row)))
    v.mouseUp(with: e(.leftMouseUp, at(to, toRow ?? row)))
}

/// The main complaint (task 21): a drag past the top edge scrolls the scrollback, and the selection follows.
@MainActor @Test func aDragPastTheEdgeScrolls() async throws {
    let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString))
    defer { pb.releaseGlobally(); DropTerminalView.leftButtonDown = { NSEvent.pressedMouseButtons & 1 != 0 } }
    DropTerminalView.leftButtonDown = { false }
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    v.pasteboard = pb
    v.feed(text: (1...200).map { "line \($0)" }.joined(separator: "\r\n"))
    func e(_ t: NSEvent.EventType, _ y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: t, location: NSPoint(x: 20, y: y), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    v.mouseDown(with: e(.leftMouseDown, 20))   // a line near the bottom
    v.mouseDragged(with: e(.leftMouseDragged, 100))
    v.mouseDragged(with: e(.leftMouseDragged, 260))   // above the view: held there
    try await waitFor("the scrollback scrolled") { v.scrollPosition < 0.9 }
    v.mouseUp(with: e(.leftMouseUp, 260))
    await drained()
    let lines = pb.string(forType: .string)?.split(whereSeparator: \.isNewline) ?? []
    #expect(lines.count > 20, "more than the screen's 13 lines: from above it down to where the drag began")
}

/// A find's match is a selection too, but it never goes to the clipboard: typed into the find bar, ⌘G with the bar up
/// and after it's closed. ⌘A still copies, the bar up or not.
@MainActor @Test func aFindMatchIsntCopied() async {
    _ = NSApplication.shared
    let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString)), find = NSPasteboard(name: .find)
    let wasFind = find.string(forType: .string)   // SwiftTerm writes the find string Mac-wide: the user's comes back
    defer {
        pb.releaseGlobally()
        DropTerminalView.leftButtonDown = { NSEvent.pressedMouseButtons & 1 != 0 }
        find.clearContents()
        if let wasFind { find.setString(wasFind, forType: .string) }
    }
    DropTerminalView.leftButtonDown = { false }
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    w.contentView!.addSubview(v)
    v.pasteboard = pb
    v.feed(text: "hello world\r\nhello again\r\nand hello once more")
    pb.clearContents()
    pb.setString("kept", forType: .string)
    func action(_ a: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = a.rawValue
        v.performTextFinderAction(item)
    }
    func field(in view: NSView) -> NSSearchField? { (view as? NSSearchField) ?? view.subviews.lazy.compactMap { field(in: $0) }.first }

    v.selectAll()   // ⌘A copies; then ⌘F takes the selection as what to find, and finds it
    await drained()
    pb.clearContents()
    pb.setString("kept", forType: .string)
    action(.showFindInterface)
    await drained()
    #expect(pb.string(forType: .string) == "kept", "⌘F with a selection")
    guard let f = field(in: v) else { Issue.record("no find bar"); return }
    f.stringValue = "hello"   // as typed: the field has the keys, each letter finds
    (f.delegate as? NSSearchFieldDelegate)?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: f))
    #expect(v.getSelection() == "hello", "a match is selected")
    await drained()
    #expect(pb.string(forType: .string) == "kept", "typed into the bar")
    action(.nextMatch)   // ⌘G, the bar up
    #expect(v.getSelection() == "hello")
    await drained()
    #expect(pb.string(forType: .string) == "kept", "⌘G with the bar up")

    w.makeFirstResponder(v)   // a click back in the text, the bar still up: ⌘A is the user's
    v.selectAll()
    await drained()
    #expect(pb.string(forType: .string)?.contains("hello again") == true, "⌘A copies with the bar up")

    pb.clearContents()
    pb.setString("kept", forType: .string)
    action(.hideFindInterface)
    action(.nextMatch)   // ⌘G, the bar closed: the find pasteboard's "hello"
    #expect(v.getSelection() == "hello")
    await drained()
    #expect(pb.string(forType: .string) == "kept", "⌘G with the bar closed")
    v.selectAll()
    await drained()
    #expect(pb.string(forType: .string)?.contains("hello once more") == true, "⌘A copies")
}

/// ⌘-click on an OSC 8 link opens nothing: its target needn't be what the line shows. The view's other calls go on
/// through the gate as before.
@MainActor @Test func aLinksHiddenTargetIsntOpened() {
    _ = NSApplication.shared
    var refused = 0
    let was = TerminalGate.refused
    TerminalGate.refused = { refused += 1 }
    defer { TerminalGate.refused = was }
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    w.contentView!.addSubview(v)
    #expect(v.terminalDelegate is TerminalGate)
    v.feed(text: "\u{1b}]8;;file:///nonexistent-kermo-test/Some.app\u{1b}\\https://docs.example\u{1b}]8;;\u{1b}\\\r\nsee https://example.com/x")
    let ch = ceil(v.font.ascender - v.font.descender + v.font.leading)
    func click(row: Int) {
        v.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 3, y: 200 - (CGFloat(row) + 0.5) * ch), modifierFlags: .command,
                                           timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!)
    }
    click(row: 0)   // ⌘-click on the link's first cell
    #expect(refused == 1)
    v.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 8 * ("W" as NSString).size(withAttributes: [.font: v.font]).width, y: 200 - 1.5 * ch),
                                       modifierFlags: .command, timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!)
    #expect(refused == 1, "a visible https:// isn't a link yet (task 21 PR 4)")
}

/// A path a server prints is never resolved as this Mac's file (the links of task 21 PR 4); a local tab's against its
/// shell's folder.
@MainActor @Test func anSSHTabsPathsArentThisMacs() {
    #expect(!EmbeddedTerminal.Tab(kind: .ssh(SFTPTarget(host: "me@db.invalid")), view: DropTerminalView(frame: .zero)).view.resolvesLinksAgainstShellDirectory)
    #expect(EmbeddedTerminal.Tab(kind: .shell, view: DropTerminalView(frame: .zero)).view.resolvesLinksAgainstShellDirectory)
}

/// The gate passes the view's own calls on (a call it left out would get the protocol's default): here the pty's size
/// follows the view's.
@MainActor @Test func theGatePassesTheViewsCallsOn() async throws {
    let v = try await standIn("echo ready; read x; stty size")
    defer { v.process.terminate() }
    v.setFrameSize(NSSize(width: 640, height: 320))
    let d = v.terminalDimensions
    try #require(d.cols > 60)
    v.send(txt: "\n")
    try await waitFor("the program said its size") { text(v).contains("\(d.rows) \(d.cols)") }
}
