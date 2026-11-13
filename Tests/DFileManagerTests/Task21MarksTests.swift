import AppKit
@testable import DFMCore
import SwiftTerm
import Testing
@testable import DFileManager

// Task 21 PR 3: marks on ↩ (⌘↑ / ⌘↓), Copy Output of Last Command, Open in Editor.

@MainActor private func view(cols: Int = 80, rows: Int = 24) -> DropTerminalView {
    _ = NSApplication.shared
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    v.resize(cols: cols, rows: rows)
    v.pasteboard = NSPasteboard(name: .init("dfm-t21-" + UUID().uuidString))
    return v
}
@MainActor private func key(_ c: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                     characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code)!
}
/// A view sized by its frame, as in a window: 600 × 400.
@MainActor private func framed() -> DropTerminalView {
    _ = NSApplication.shared
    return DropTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
}
/// ↩ typed, as the app's key monitor shows it to the view before the view sends it on.
@MainActor private func enter(_ v: DropTerminalView) { v.typed(key("\r", 36)) }
/// `cmd` typed at the prompt (its echo), ↩, what it printed, the next prompt.
@MainActor private func run(_ v: DropTerminalView, _ cmd: String, _ out: [String]) {
    v.feed(text: cmd)
    enter(v)
    v.feed(text: "\r\n" + out.map { $0 + "\r\n" }.joined() + "$ ")
}
private func lines(_ n: Int, _ p: String) -> [String] { (0..<n).map { "\(p) \($0)" } }
@MainActor private func top(_ v: TerminalView) -> String { v.terminalStateSnapshot().visibleRows.first?.text ?? "" }
@MainActor private func live(_ v: TerminalView) -> Bool {
    let s = v.terminalContentSnapshot(region: .rows(0..<0))!
    return s.capturedRange.lowerBound + v.terminalStateSnapshot().viewportRow == s.liveTopRow
}

/// M1: ↩ marks the first row of the line it was typed on — not in a full-screen program, one per row; not ⌃↩ (the
/// app's); not while a shell that turns bracketed paste on at its prompt has it off (a command runs, `read`). Kermo's
/// own lines: a ↩ that runs marks, a bracketed paste's line breaks don't (Send to Terminal's: the line waits for its
/// ↩); Execute's ↩ after its paste does.
@MainActor @Test func aReturnMarksTheLineItWasTypedOn() throws {
    let v = view()
    v.feed(text: "$ ")
    run(v, "ls", ["a", "b"])
    run(v, "df", ["x"])
    #expect(v.marks.map(\.row) == [0, 3])
    enter(v)
    enter(v)   // nothing printed meanwhile: the same row
    #expect(v.marks.map(\.row) == [0, 3, 5])
    v.feed(text: "\u{1b}[?1049h~\r\n~")   // vim
    enter(v)
    v.feed(text: "\u{1b}[?1049l")
    #expect(v.marks.map(\.row) == [0, 3, 5], "not on the alternate screen")
    v.feed(text: "\r\n$ x")
    v.typed(key("\r", 36, .control))
    v.type("\u{1b}[200~ls\rpwd\u{1b}[201~")
    #expect(v.marks.map(\.row) == [0, 3, 5])
    v.type("\u{15}\u{1b}[200~ls\u{1b}[201~\r")
    #expect(v.marks.map(\.row) == [0, 3, 5, 6])

    let w = view(cols: 20, rows: 10)
    w.feed(text: "$ " + String(repeating: "x", count: 30))   // a long command wraps
    enter(w)
    #expect(w.marks.map(\.row) == [0])

    let z = view()   // zsh: bracketed paste on at its prompt, off while `make` runs
    z.feed(text: "\u{1b}[?2004h$ make")
    enter(z)
    z.feed(text: "\u{1b}[?2004l\r\nbuilding\r\n")
    enter(z)   // ↩ pressed into the output
    z.feed(text: "done\r\n\u{1b}[?2004h$ ls")
    enter(z)
    #expect(z.marks.map(\.row) == [0, 3])

    #expect(DropTerminalView.returns(ArraySlice("ls\r".utf8)) && DropTerminalView.returns(ArraySlice("\u{15}\u{1b}[200~ls\u{1b}[201~\r".utf8)))
    #expect(!DropTerminalView.returns(ArraySlice("\u{1b}[200~ls\rpwd\r\u{1b}[201~".utf8)) && !DropTerminalView.returns(ArraySlice("\u{1b}[A".utf8)))

    let term = terminal()   // the app's key monitor hands the keys to `handleKey` first (nothing is typed into the shell)
    term.newShell(cwd: NSTemporaryDirectory())
    defer { term.tabs.forEach { term.close($0.id, confirm: false) } }
    let tab = try #require(term.current)
    _ = term.show()
    #expect(!term.handleKey(key("\r", 36)) && tab.view.marks.count == 1)
    #expect(!term.handleKey(key("\r", 36, .command)) && tab.view.marks.count == 1, "⌘↩ isn't the program's")
}

/// M2: ⌘↑ from the live screen is the last command, then the one before; its row goes to the top as far as it scrolls;
/// ⌘↓ the next, and after the last the live screen; ⌘↓ there — nowhere. Typing: from the last again.
@MainActor @Test func cmdUpAndDownGoFromMarkToMark() throws {
    let v = view(rows: 10)
    v.feed(text: "$ ")
    run(v, "one", lines(30, "o"))   // row 0
    run(v, "two", lines(30, "t"))   // row 31
    run(v, "three", ["3"])          // row 62: on the live screen with its output
    #expect(v.marks.map(\.row) == [0, 31, 62])
    #expect(!v.goToMark(by: 1), "the live screen: nothing after")
    #expect(v.goToMark(by: -1) && live(v), "the last command is on the screen: nowhere to scroll")
    #expect(v.output() == "3")
    #expect(v.goToMark(by: -1) && top(v) == "$ two" && v.output() == lines(30, "t").joined(separator: "\n"), "⌘↑ ⌘↑ ⇧⌘A: the one before's")
    let bar = try #require(v.markBar), h = v.caretFrame.height
    #expect(!v.isFlipped && h > 0 && abs(bar.frame.maxY - v.bounds.maxY) < 0.5 && abs(bar.frame.height - h) < 0.5, "beside the top row: y goes up")
    #expect(v.goToMark(by: -1) && top(v) == "$ one")
    #expect(!v.goToMark(by: -1), "none before")
    #expect(v.goToMark(by: 1) && top(v) == "$ two")
    #expect(v.goToMark(by: 1) && live(v))
    #expect(v.goToMark(by: 1) && live(v) && !v.goToMark(by: 1), "after the last: the live screen; then nowhere")
    #expect(v.goToMark(by: -1) && v.goToMark(by: -1) && top(v) == "$ two")
    v.typed(key("x", 7))   // typed: the last command again
    #expect(v.output() == "3")

    v.scrollTo(row: 40)   // by hand: from the top row in view
    #expect(v.goToMark(by: -1) && top(v) == "$ two")
    v.scrollTo(row: 40)
    #expect(v.goToMark(by: 1) && live(v), "the next after the view's top: three's, on the live screen")
}

/// O2: Copy Output takes the rows after the command's own (it wraps) up to the next mark or the prompt, wrapped rows
/// joined (a space where one wrapped kept), spaces at a line's end and blank lines at the end dropped; the last command
/// that printed anything; nothing printed or a full-screen program: nothing, the clipboard as it was.
@MainActor @Test func copyOutputTakesWhatACommandPrinted() throws {
    let v = view(cols: 40, rows: 10)
    let long = String(repeating: "a", count: 39) + " " + String(repeating: "b", count: 30)
    v.feed(text: "$ ")
    run(v, "cat " + String(repeating: "f", count: 40), [long, "pad   ", "", ""])   // the command wraps too
    #expect(v.output() == long + "\npad")
    run(v, "true", [])
    enter(v)   // ↩ at an empty prompt
    #expect(v.output() == long + "\npad", "the last that printed anything")
    #expect(v.goToMark(by: -1) && v.output() == nil, "⌘↑ to the empty ↩: nothing")

    let term = terminal()
    term.restore([SFTPTarget(host: "dfm-t21.invalid")])
    let tab = try #require(term.current)
    _ = term.show()
    tab.view.pasteboard = NSPasteboard(name: .init("dfm-t21-" + UUID().uuidString))
    tab.view.pasteboard.clearContents()
    tab.view.pasteboard.setString("before", forType: .string)
    tab.view.feed(text: "\u{1b}[2J\u{1b}[H$ ")
    run(tab.view, "true", [])
    term.copyOutput()
    #expect(tab.view.pasteboard.string(forType: .string) == "before", "nothing printed: the clipboard as it was")
    run(tab.view, "echo hi", ["hi"])
    term.copyOutput()
    #expect(tab.view.pasteboard.string(forType: .string) == "hi")
    tab.view.feed(text: "\u{1b}[?1049h")
    #expect(tab.view.output() == nil && !tab.view.goToMark(by: -1), "a full-screen program has the tab")
}

/// What renumbers rows drops the marks — a mark never lands on someone else's line: `clear` (\e[3J with the history not
/// full keeps the first row's number, 0), ⌘K, RIS, a width change, a lower drawer cutting a full scrollback; ⌃L only the
/// marks it erased; the scrollback's cut only the oldest.
@MainActor @Test func whatRenumbersRowsDropsTheMarks() throws {
    func two(_ v: DropTerminalView) { v.feed(text: "$ "); run(v, "one", lines(20, "o")); run(v, "two", lines(20, "t")) }

    var v = view(rows: 10)   // `clear`, then a command: old marks gone
    two(v)
    run(v, "clear", [])
    v.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J$ ")
    run(v, "cat big", lines(100, "b"))   // more rows than there were
    #expect(v.goToMark(by: -1) && top(v) == "$ cat big" && !v.goToMark(by: -1))

    v = view(rows: 10)   // `clear && cat big` on one line: the numbers held — the lines didn't
    two(v)
    v.feed(text: "clear && cat big")
    enter(v)
    v.feed(text: "\r\n\u{1b}[H\u{1b}[2J\u{1b}[3J" + lines(100, "b").map { $0 + "\r\n" }.joined() + "$ ")
    #expect(v.output() == lines(100, "b").dropFirst(43).joined(separator: "\n"), "a known limit: its own rows after its mark's row")
    var stops = 0
    while v.goToMark(by: -1) { stops += 1 }
    #expect(stops == 1, "its own mark only: one's and two's rows hold other lines now")

    let term = terminal()   // ⌘K
    term.restore([SFTPTarget(host: "dfm-t21.invalid")])
    let tab = try #require(term.current)
    _ = term.show()
    two(tab.view)
    #expect(term.handleKey(key("k", 40, .command)))
    #expect(!tab.view.goToMark(by: -1))

    v = view(rows: 10)   // RIS
    two(v)
    v.feed(text: "\u{1b}c$ ")
    #expect(!v.goToMark(by: -1))

    v = view(rows: 10)   // narrower
    two(v)
    v.resize(cols: 40, rows: 10)
    #expect(!v.goToMark(by: -1))

    v = framed()   // a lower drawer: the scrollback not full — rows held as they were, marks kept; full — dropped
    two(v)
    let was = v.terminalStateSnapshot().dimensions
    v.setFrameSize(NSSize(width: 600, height: 200))
    #expect(v.terminalStateSnapshot().dimensions.cols == was.cols && v.terminalStateSnapshot().dimensions.rows < was.rows)
    #expect(v.goToMark(by: -1) && v.goToMark(by: -1) && top(v) == "$ one")
    v = framed()
    v.changeScrollback(30)
    two(v)
    run(v, "three", lines(20, "3"))   // its mark far above the cursor, its row not looked at yet
    v.setFrameSize(NSSize(width: 600, height: 200))
    #expect(!v.goToMark(by: -1))

    v = view(rows: 10)   // ⌃L: the screen's go, the scrollback's stay
    two(v)
    run(v, "x", ["y"])
    v.feed(text: "\u{1b}[H\u{1b}[2J$ ")
    #expect(v.goToMark(by: -1) && top(v) == "$ two" && v.goToMark(by: -1) && top(v) == "$ one" && !v.goToMark(by: -1))

    v = view(rows: 10)   // the scrollback cut: the oldest go, the rest stay put
    v.changeScrollback(40)
    two(v)
    run(v, "three", lines(20, "3"))
    #expect(v.goToMark(by: -1) && top(v) == "$ three" && v.goToMark(by: -1) && top(v) == "$ two" && !v.goToMark(by: -1))
}

/// M4: a shell's OSC 133 prompts are stops where no mark is — above the first (a width change dropped them).
@MainActor @Test func osc133PromptsWhereThereAreNoMarks() {
    let v = view(rows: 10)
    for i in 0..<3 { v.feed(text: "\u{1b}]133;A\u{7}$ cmd\(i)\r\n" + lines(15, "o\(i)").map { $0 + "\r\n" }.joined()) }   // run before Kermo's ↩
    v.feed(text: "\u{1b}]133;A\u{7}$ ")
    run(v, "mine", lines(15, "m"))
    #expect(v.goToMark(by: -1) && top(v) == "$ mine")
    #expect(v.goToMark(by: -1) && top(v) == "$ cmd2", "above the first mark: the shell's prompt")
    #expect(v.goToMark(by: -1) && top(v) == "$ cmd1")
    #expect(v.goToMark(by: 1) && top(v) == "$ cmd2" && v.goToMark(by: 1) && top(v) == "$ mine")
}

/// Rows to text: wrapped rows go on their line, `row`'s line found.
@Test func rowsJoinIntoLines() {
    func r(_ n: Int, _ t: String, wrapped: Bool = false) -> TerminalContentRowSnapshot {
        TerminalContentRowSnapshot(absoluteRow: n, cells: t.map { TerminalCellSnapshot(text: String($0), width: 1, attribute: Attribute.empty) }, isWrapped: wrapped)
    }
    let t = DropTerminalView.text([r(5, "ab "), r(6, "cd", wrapped: true), r(7, "e  "), r(8, ""), r(9, " ")], row: 7)
    #expect(t.text == "ab cd\ne" && t.line == 1)
    #expect(DropTerminalView.text([r(0, "x")], row: 3).line == 0)
}

@MainActor private var hosts: [NSView] = []
@MainActor private func terminal() -> EmbeddedTerminal {
    _ = NSApplication.shared
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)), panels = NSView(frame: parent.bounds)
    parent.addSubview(panels)
    hosts.append(parent)
    return EmbeddedTerminal(covering: panels)
}

private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t21-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}
/// A fresh editor window with its drafts in `dir`.
@MainActor private func fresh(_ dir: String) -> EditorHost {
    gone()
    EditorHost.restore(dir, onServer: { _, _, _, _ in ({ _ in }, {}) })
    return EditorHost.tabs
}
@MainActor private func gone() {
    guard let h = EditorHost.shared else { return }
    for e in h.docs { e.closed(); e.host = nil }
    h.drafts?.release()
    h.window?.orderOut(nil)
    EditorHost.shared = nil
}
/// An app with a terminal over its panels, an SSH tab in it shown (no ssh runs): `rows` rows of 80 columns.
@MainActor private func app(_ host: String = "dfm-t21.invalid", rows: Int = 10) throws -> (AppDelegate, EmbeddedTerminal, EmbeddedTerminal.Tab) {
    let app = AppDelegate()
    app.commands = app.makeCommands()
    let term = terminal()
    app.terminal = term
    app.window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    app.panels = [PanelViewController(tabs: [NSTemporaryDirectory()], index: 0, showHidden: false)]   // the commands' `active`
    term.restore([SFTPTarget(host: host)])
    let tab = try #require(term.current)
    _ = term.show()
    tab.view.resize(cols: 80, rows: rows)
    tab.view.pasteboard = NSPasteboard(name: .init("dfm-t21-" + UUID().uuidString))
    tab.view.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H$ ")
    return (app, term, tab)
}

extension EditorWindowTests {
    /// M2: in the terminal ⌘↑ ⌘↓ ⇧⌘A are Previous / Next Mark and Copy Output — Go's and Mark's items say so there, and
    /// the key bar; ⌫ (Enclosing Folder's other key) stays the shell's; in the panels they're as they were. «⋯» lists
    /// View ▸ Terminal Pane with the marks' keys.
    @Test func theMarksKeysInTheTerminal() throws {
        _ = NSApplication.shared
        let (app, term, tab) = try app()
        AppDelegate.keyWindow = { app.window }
        defer { AppDelegate.keyWindow = { NSApp.keyWindow } }
        term.setFull(true)   // the keys go to the terminal (its size as laid out: before the marks, a width change drops them)
        #expect(app.terminalActive)
        run(tab.view, "one", lines(60, "o"))
        run(tab.view, "two", ["2"])
        let menu = app.makeMenu(), item = { (id: String) in menu.allItems.first { $0.representedObject as? String == id }! }
        let click = { (id: String) in _ = app.perform(item(id).action!, with: item(id)) }   // the menu item, as its key from the menu
        click("go.up")
        click("go.up")
        #expect(top(tab.view) == "$ one")
        click("mark.none")
        #expect(tab.view.pasteboard.string(forType: .string) == lines(60, "o").joined(separator: "\n"))
        click("open.inside")
        #expect(live(tab.view))
        tab.view.pasteboard.clearContents()
        app.run("mark.none")   // the palette's "Unmark All": the panel's, not the clipboard
        #expect(tab.view.pasteboard.string(forType: .string) == nil)

        for (id, title) in [("go.up", "Previous Mark"), ("open.inside", "Next Mark"), ("mark.none", "Copy Output of Last Command")] {
            _ = app.validateMenuItem(item(id))
            #expect(item(id).title == title)
        }
        #expect(AppDelegate.takesFromTerminal("go.up", command: true, inText: false) && !AppDelegate.takesFromTerminal("go.up", command: false, inText: false), "⌫: the shell's")
        #expect(!AppDelegate.takesFromTerminal("go.up", command: true, inText: true) && AppDelegate.takesFromTerminal("app.palette", command: true, inText: true),
                "⌘↑ in the find bar's field moves its caret")
        let bar = KeyBarView()
        bar.terminalShown = { true }
        bar.frame = NSRect(x: 0, y: 0, width: 2000, height: 30)
        bar.reload(app.commands)
        #expect(bar.shownSlots.contains(KeySlot(key: "⌘↑", label: "Prev Mark", id: "term.mark.prev"))
                && bar.shownSlots.contains(KeySlot(key: "⇧⌘A", label: "Copy Output", id: "term.output.copy")))
        let more = app.terminalMenu()
        #expect(more.items.map { $0.isSeparatorItem ? "—" : $0.title + " " + $0.keyEquivalent } == ["Open in Editor o", "Open Output in Editor ", "Copy Output of Last Command a", "—",
                                                                                                  "Previous Mark \u{F700}", "Next Mark \u{F701}"])
        #expect(more.items.allSatisfy { $0.isSeparatorItem || app.validateMenuItem($0) })
        let view = submenu(menu, "View/Terminal Pane")?.items.map(\.title)
        #expect(view == ["Open in Editor", "Open Output in Editor", "Copy Output of Last Command", "", "Previous Mark", "Next Mark"])

        term.setFull(false)   // the drawer, the keys in a panel
        #expect(!app.terminalActive && app.validateMenuItem(item("term.editor")), "⌥⌘O: the drawer's pane, from a panel too")
        _ = term.hide()
        #expect(!app.terminalActive)
        for (id, title) in [("go.up", "Enclosing Folder"), ("open.inside", "Open Inside"), ("mark.none", "Unmark All")] {
            _ = app.validateMenuItem(item(id))
            #expect(item(id).title == title)
        }
        #expect(!app.validateMenuItem(item("term.editor")), "⌥⌘O: the terminal hidden — nothing to open")
    }

    /// O1: Open in Editor — the pane's scrollback and screen as a read-only copy: named after its server and the time,
    /// placed there with its folder, its chips; the caret on the row at the top of the terminal's view; no draft, no
    /// session; Send / Execute to that server as its user and folder (into that pane while it takes text). Again from
    /// the pane: its copy's tab, not another tab; Edit: an Untitled with the text, a draft from now on. The selection
    /// alone; a full-screen program's screen alone; Open Output in Editor: the command's output.
    @Test func openInEditorMakesAReadOnlyCopy() throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { gone(); try? FileManager.default.removeItem(atPath: dir) }
        let h = fresh(dir + "/drafts")
        let (app, _, tab) = try app("root@dfm-t21.invalid")
        tab.cwd = "/var/log"
        let script = NSObject()   // a document Execute ran in this pane before
        AppDelegate.ownTabs.setObject(tab.id as NSUUID, forKey: script)
        run(tab.view, "seq", lines(40, "l"))
        tab.view.scrollTo(row: 21)   // "l 20" at the top
        app.terminalToEditor(output: false)
        let e = try #require(h.active)
        let text = (["$ seq"] + lines(40, "l") + ["$"]).joined(separator: "\n")
        #expect(e.name.hasPrefix("Terminal — root@dfm-t21.invalid ") && e.heading.subtitle == "Read-only · root@dfm-t21.invalid · /var/log")
        #expect(e.textView.string == text && e.chips.contains(.root))
        #expect(e.textView.selectedRange() == NSRange(location: (text as NSString).range(of: "l 20").location, length: 0))
        #expect(e.snapshot != nil && !e.textView.isEditable && e.sessionDoc == nil && e.reopenable == nil)
        let place = try #require(e.terminalPlace)
        #expect(place.target == SFTPTarget(host: "root@dfm-t21.invalid") && place.folder == "/var/log" && place.path == nil)
        #expect(AppDelegate.ownTabs.object(forKey: e) == tab.id as NSUUID, "Execute: into the pane it came from")
        #expect(AppDelegate.ownTabs.object(forKey: script) == tab.id as NSUUID, "the script's tab stays its")

        app.terminalToEditor(output: false)
        let again = try #require(h.active)
        #expect(again !== e && h.docs.count == 1, "its copy's tab")
        again.edit()
        let u = try #require(h.active)
        #expect(u.snapshot == nil && u.name.hasPrefix("Untitled") && u.textView.string == text && u.isEdited && u.textView.isEditable && u.sessionDoc != nil)
        #expect(h.docs.count == 1 && u.terminalPlace?.target == nil, "an Untitled: the caller's machine")
        app.terminalToEditor(output: false)
        #expect(h.docs.count == 2 && h.docs.contains { $0 === u }, "the Untitled stays; a new copy")

        app.terminalToEditor(output: true)
        #expect(h.active?.name.hasPrefix("Output — ") == true && h.active?.textView.string == lines(40, "l").joined(separator: "\n"))
        tab.view.selectAll()
        app.terminalToEditor(output: false)
        #expect(h.active?.textView.string.hasPrefix("$ seq\nl 0\n") == true)
        tab.view.selectNone()
        tab.view.feed(text: "\u{1b}[?1049h\u{1b}[HVIM")
        app.terminalToEditor(output: false)
        #expect(h.active?.textView.string == "VIM", "a full-screen program: its screen")
        #expect(h.docs.filter { $0.snapshot != nil }.count == 1, "one copy per pane")
    }
}

@MainActor private func submenu(_ menu: NSMenu, _ path: String) -> NSMenu? {
    var m: NSMenu? = menu
    for title in path.split(separator: "/") { m = m?.items.first { $0.submenu?.title == String(title) }?.submenu }
    return m
}
