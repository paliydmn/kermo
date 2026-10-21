import AppKit
@testable import DFMCore
import SwiftTerm
import Testing
@testable import DFileManager

// The terminal's mouse as in PuTTY: a selection copies, a right-click pastes.

/// A selection goes to the clipboard as it's made (here: ⌘A, made at once); `terminalCopyOnSelect` false: it doesn't.
@MainActor @Test func aSelectionInTheTerminalIsCopied() {
    let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString))
    defer { pb.releaseGlobally(); DropTerminalView.leftButtonDown = { NSEvent.pressedMouseButtons & 1 != 0 } }
    DropTerminalView.leftButtonDown = { false }   // the real mouse may be held by whoever works on this Mac meanwhile
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    v.pasteboard = pb
    v.feed(text: "hello world")
    v.selectAll()
    #expect(pb.string(forType: .string)?.contains("hello world") == true)

    pb.clearContents()
    pb.setString("kept", forType: .string)
    let was = UserDefaults.standard.object(forKey: "terminalCopyOnSelect")
    defer { UserDefaults.standard.set(was, forKey: "terminalCopyOnSelect") }
    UserDefaults.standard.set(false, forKey: "terminalCopyOnSelect")
    v.selectAll()
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
        EmbeddedTerminal.Tab(kind: k, view: DropTerminalView(frame: .zero)).view.pasteRisk()
    }
    #expect(risk(.ssh(prod.target)) == "web1 (production)", "by its saved name")
    #expect(risk(.ssh(SFTPTarget(host: "root@db.invalid"))) == "root@db.invalid")
    #expect(risk(.ssh(SFTPTarget(host: "me@db.invalid"))) == nil)
    #expect(risk(.shell) == nil)
}
}

/// OSC 52 (Claude Code's copy) writes the clipboard; a read request (`?`) changes nothing and gets no answer.
@MainActor @Test func osc52WritesTheClipboard() {
    let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString))
    defer { pb.releaseGlobally() }
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    v.pasteboard = pb
    v.feed(text: "\u{1b}]52;c;" + Data("привіт, Claude".utf8).base64EncodedString() + "\u{7}")
    #expect(pb.string(forType: .string) == "привіт, Claude")
    v.feed(text: "\u{1b}]52;;" + Data("no target".utf8).base64EncodedString() + "\u{1b}\\")
    #expect(pb.string(forType: .string) == "no target", "an empty target, ST-ended")
    v.feed(text: "\u{1b}]52;c;?\u{7}")
    #expect(pb.string(forType: .string) == "no target")
    let long = String(repeating: "довга відповідь Claude\n", count: 1500)   // ~60 KB of base64
    v.feed(text: "\u{1b}]52;c;" + Data(long.utf8).base64EncodedString() + "\u{7}")
    #expect(pb.string(forType: .string) == long)
    v.isHidden = true
    v.feed(text: "\u{1b}]52;c;" + Data("hidden".utf8).base64EncodedString() + "\u{7}")
    #expect(pb.string(forType: .string) == long, "a tab not in front")
}

/// The wheel goes to a program that reads the mouse; otherwise it's SwiftTerm's (scrollback).
@MainActor @Test func theWheelGoesToAProgramThatReadsTheMouse() {
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let e = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0)!)!
    #expect(!v.wheel(e))
    v.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")   // as Claude Code, htop
    #expect(v.wheel(e))
    v.allowMouseReporting = false
    #expect(!v.wheel(e))
}

/// ⇧- or ⌥-drag in a program that reads the mouse selects text in the terminal; the button up copies it and gives the mouse back.
@MainActor @Test func shiftSelectsInAProgramThatReadsTheMouse() async {
    let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString))
    defer { pb.releaseGlobally() }
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    v.pasteboard = pb
    v.feed(text: "hello world\u{1b}[?1000h")
    func down(_ f: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: f, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    v.shiftDown(down([]))
    #expect(v.allowMouseReporting, "no ⇧: the program's click")
    v.shiftDown(down(.shift))
    #expect(!v.allowMouseReporting)
    v.selectAll()
    pb.clearContents()
    v.mouseReleased()
    #expect(pb.string(forType: .string)?.contains("hello world") == true)
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(v.allowMouseReporting)
    v.shiftDown(down(.option))
    #expect(!v.allowMouseReporting, "⌥ too, as in iTerm")
    v.mouseReleased()
}
