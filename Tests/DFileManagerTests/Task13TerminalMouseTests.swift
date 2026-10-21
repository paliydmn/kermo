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
