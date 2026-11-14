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
    v.startProcess(executable: "/bin/sh", args: ["-c", "stty raw -echo; " + script + "; exec sleep 5"])
    try await waitFor("the stand-in started") { text(v).contains("ready") }
    return v
}

/// A selection goes to the clipboard as it's made (here: ⌘A, made at once); `terminalCopyOnSelect` false: it doesn't.
@MainActor @Test func aSelectionInTheTerminalIsCopied() async {
    let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString))
    defer { pb.releaseGlobally() }
    // The real mouse may be held by whoever works on this Mac meanwhile. Never put back: a test running alongside
    // would read the real button then, and a held one makes its copy wait for a mouseUp that never comes.
    DropTerminalView.leftButtonDown = { false }
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
    defer { pb.releaseGlobally() }
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
    _ = NSApplication.shared
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    try #require(v.terminalDelegate is TerminalGate)   // else SwiftTerm's own would write the real clipboard
    w.contentView!.addSubview(v)
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
    v.isHidden = false
    v.removeFromSuperview()   // closed, its process winding down
    await osc52("\u{1b}]52;c;" + Data("closed".utf8).base64EncodedString() + "\u{7}")
    #expect(pb.string(forType: .string) == long, "a closed tab")
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

/// The gate answers no read: OSC 52's (the test above shows the way there), kitty's (OSC 5522: it offers none and
/// refuses each request).
@MainActor @Test func kittysClipboardIsRefused() {
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let g = try! #require(v.terminalDelegate as? TerminalGate)
    #expect(g.clipboardRead(source: v) == nil, "OSC 52's read")
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

/// ⌘-click is the terminal's (a link) even in a program that reads the mouse: it gets neither the press nor the release.
/// The press decides: ⌘ added before letting go leaves the click the program's, release and all, and opens no link.
@MainActor @Test func aCommandClickIsntAProgramsClick() async throws {
    let v = try await standIn("printf '\\033[?1000h'; echo ready /etc/hosts; printf '\\r\\n'; exec perl -e '$|=1; printf \"%d \", ord $c while sysread STDIN, $c, 1'")   // each byte it reads
    defer { v.process.terminate() }
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    w.contentView!.addSubview(v)
    var links: [String] = []
    v.onLink = { r, _ in links.append(r.link) }
    func click(col: Int, _ down: NSEvent.ModifierFlags, _ up: NSEvent.ModifierFlags) {
        let p = NSPoint(x: (CGFloat(col) + 0.5) * v.caretFrame.width, y: v.frame.height - 0.5 * v.caretFrame.height)
        func e(_ t: NSEvent.EventType, _ f: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: f, timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        v.mouseDown(with: e(.leftMouseDown, down))
        v.mouseUp(with: e(.leftMouseUp, up))
    }
    click(col: 8, .command, .command)
    #expect(links == ["/etc/hosts"])
    click(col: 8, [], .command)
    // ESC [ M, button 0 then 3 (released), column 8 + 33, row 0 + 33: the second click, whole; nothing of the first.
    try await waitFor("the program read a click") { text(v).contains("\n27 91 77 32 41 33 27 91 77 35 41 33 ") }
    #expect(links == ["/etc/hosts"], "⌘ after the press: no link")
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
    defer { pb.releaseGlobally() }
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
    defer { pb.releaseGlobally() }
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
    defer { pb.releaseGlobally() }
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

/// Kermo's own words in a tab (a session's end, ⌘K's clear) move a find's match up once the scrollback is full: it's
/// still not copied.
@MainActor @Test func aFindMatchMovedByKermosWordsIsntCopied() async {
    _ = NSApplication.shared
    let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString)), find = NSPasteboard(name: .find)
    let wasFind = find.string(forType: .string)
    defer {
        pb.releaseGlobally()
        find.clearContents()
        if let wasFind { find.setString(wasFind, forType: .string) }
    }
    DropTerminalView.leftButtonDown = { false }
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    w.contentView!.addSubview(v)
    v.pasteboard = pb
    v.feed(text: (1...1000).map { "filler \($0)" }.joined(separator: "\r\n") + "\r\nthe needle\r\n")   // past 500 lines: full
    pb.clearContents()
    pb.setString("kept", forType: .string)
    find.clearContents()
    find.setString("needle", forType: .string)
    let item = NSMenuItem()
    item.tag = NSTextFinder.Action.nextMatch.rawValue
    v.performTextFinderAction(item)   // ⌘G
    #expect(v.getSelection() == "needle")
    v.say("\r\n[web-01: Connection closed] ↩ Reconnect   ⎋ Close\r\n")
    await drained()
    #expect(v.getSelection() == "needle", "moved up, still selected")
    #expect(pb.string(forType: .string) == "kept")
}

/// ⌘-click on an OSC 8 link opens nothing: its target needn't be what the line shows. A visible address is the tab's
/// to open. The view's other calls go on through the gate as before.
@MainActor @Test func aLinksHiddenTargetIsntOpened() {
    _ = NSApplication.shared
    var refused = 0, links: [String] = []
    let was = TerminalGate.refused
    TerminalGate.refused = { refused += 1 }
    defer { TerminalGate.refused = was }
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    v.onLink = { r, _ in links.append(r.link) }
    w.contentView!.addSubview(v)
    #expect(v.terminalDelegate is TerminalGate)
    v.feed(text: "\u{1b}]8;;file:///nonexistent-kermo-test/Some.app\u{1b}\\https://docs.example\u{1b}]8;;\u{1b}\\\r\nsee https://example.com/x")
    func click(col: Int, row: Int) {   // ⌘ from the press on: the click is the terminal's
        let p = NSPoint(x: (CGFloat(col) + 0.5) * v.caretFrame.width, y: 200 - (CGFloat(row) + 0.5) * v.caretFrame.height)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: .command, timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            t == .leftMouseDown ? v.mouseDown(with: e) : v.mouseUp(with: e)
        }
    }
    click(col: 0, row: 0)   // ⌘-click on the link's first cell
    #expect(refused == 1)
    click(col: 8, row: 1)
    #expect(refused == 1 && links == ["https://example.com/x"], "a visible https:// is the tab's")
}

/// The folder a server's shell tells (OSC 7) is never a base for a path on this Mac; a local tab's shell's folder is.
@MainActor @Test func anSSHTabsFolderIsntThisMacs() {
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
