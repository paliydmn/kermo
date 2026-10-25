import AppKit
import Quartz
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 9 §6, misc: P17, P18, P19, R2b.

@MainActor
private func tempDir(_ files: [String]) throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-misc-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for f in files { FileManager.default.createFile(atPath: dir + "/" + f, contents: Data("x\n".utf8)) }
    return dir
}

@MainActor
private func waitListed(_ panel: PanelViewController, _ count: Int) async {
    for _ in 0..<2000 where panel.listedItems.count != count { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor private func press(_ v: NSView, _ chars: String, _ keyCode: UInt16, mods: NSEvent.ModifierFlags = []) {
    v.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                                     characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!)
}

/// The cell the panel would show for `name` in `column`.
@MainActor private func cell(_ panel: PanelViewController, _ column: String, _ name: String) -> NSTableCellView? {
    panel.moveCursor(toName: name)
    return panel.tableView(panel.table, viewFor: panel.table.tableColumn(withIdentifier: .init(column)), row: panel.table.selectedRow) as? NSTableCellView
}

/// R2b: F3 on a server fetches only the tail of what reads like a log (`.log`, rotated, `.txt`, no extension, plain
/// text by type); a CSV, JSON, database or archive is fetched whole, since its start matters.
@Test func onlyLogLikeServerFilesAreViewedByTheirTail() {
    for name in ["syslog", "app.log", "app.log.3", "syslog.1", "notes.txt", "build.out", "nohup.err", "readme.text", "messages.0"] {
        #expect(Viewer.tailLimit(for: name) == Viewer.remoteLimit, "\(name)")
    }
    for name in ["data.csv", "data.json", "dump.sqlite", "app.log.gz", "archive.tar", "photo.jpg", "config.yaml", "notes.md", "a.bin"] {
        #expect(Viewer.tailLimit(for: name) == nil, "\(name)")
    }
}

/// R2b: hex of a server file's tail shows where the bytes are in the server's file, not in the local copy.
@MainActor @Test func hexOfARemoteTailShowsTheRealOffsets() async throws {
    _ = NSApplication.shared
    let d = try tempDir([])
    defer { try? FileManager.default.removeItem(atPath: d) }
    let url = URL(fileURLWithPath: d + "/syslog")
    try Data("tail of the log\n".utf8).write(to: url)
    let from: Int64 = 5_000_000_000, at = "12a05f200  "   // past 32 bits: 5 GB
    #expect(Viewer.read(url, .hex, base: UInt64(from)).0.hasPrefix(at))
    #expect(Viewer.read(url, .hex).0.hasPrefix("00000000  "))

    let v = Viewer(url, remote: (SFTPTarget(host: "web"), "/var/log/syslog", from))
    defer { v.close() }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    for _ in 0..<500 where v.window?.subtitle.hasPrefix("Loading") == true { try await Task.sleep(for: .milliseconds(10)) }
    press(tv, "h", 4)
    for _ in 0..<500 where !tv.string.hasPrefix(at) { try await Task.sleep(for: .milliseconds(10)) }   // the hex load is off main
    #expect(tv.string.hasPrefix(at), "\(tv.string.prefix(20))")
}

/// P17: Quick Look may still ask for an index of the listing it last counted; nothing to show is nil, not a trap.
@MainActor @Test func quickLookIndexPastTheListingIsNil() async throws {
    _ = NSApplication.shared
    let dir = try tempDir(["a.txt"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    defer { panel.shutdown() }
    panel.loadViewIfNeeded()
    await waitListed(panel, 1)
    panel.moveCursor(toName: "a.txt")
    #expect(panel.numberOfPreviewItems(in: nil) == 1)
    #expect((panel.previewPanel(nil, previewItemAt: 0) as? NSURL)?.path == dir + "/a.txt")
    #expect(panel.previewPanel(nil, previewItemAt: 1) == nil)
    #expect(panel.previewPanel(nil, previewItemAt: 99) == nil)
}

private final class CountingPreview: QLPreviewPanel {
    var reloads = 0
    override func reloadData() { reloads += 1 }
}

/// P17: a re-list that leaves the previewed items as they were (a download growing next door re-lists every 3 s)
/// doesn't reload the preview — a playing video would start over; a change of marks still does.
@MainActor @Test func quickLookReloadsOnlyWhenItsItemsChange() async throws {
    _ = NSApplication.shared
    let dir = try tempDir(["a.txt", "b.txt"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    defer { panel.shutdown() }
    panel.loadViewIfNeeded()
    await waitListed(panel, 2)
    panel.moveCursor(toName: "a.txt")
    let ql = CountingPreview(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    panel.beginPreviewPanelControl(ql)
    defer { panel.endPreviewPanelControl(ql) }
    FileManager.default.createFile(atPath: dir + "/c.part", contents: Data())
    panel.reload()
    await waitListed(panel, 3)
    #expect(ql.reloads == 0, "the cursor file is the same: nothing to reload")
    panel.setMarks(["b.txt"])
    #expect(ql.reloads == 1)
}

/// P18: a mark is bold and colored; VoiceOver hears "marked" too, and not on the row next to it (cells are reused).
@MainActor @Test func markedRowsSaySoToAccessibility() async throws {
    _ = NSApplication.shared
    let dir = try tempDir(["a.txt", "b.txt"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    defer { panel.shutdown() }
    panel.loadViewIfNeeded()
    await waitListed(panel, 2)
    panel.setMarks(["a.txt"])
    #expect(cell(panel, "name", "a.txt")?.textField?.accessibilityLabel() == "marked")
    #expect((cell(panel, "name", "b.txt")?.textField?.accessibilityLabel() ?? "").isEmpty)
    panel.unmarkAll()
    #expect((cell(panel, "name", "a.txt")?.textField?.accessibilityLabel() ?? "").isEmpty)
}

/// A mark is a shape too: a ✓ in the name's gutter, in the mark's color — the accent in the System theme, white on the
/// focused cursor (the system's selection is the accent too).
@MainActor @Test func markedRowsHaveACheck() async throws {
    _ = NSApplication.shared
    let dir = try tempDir(["a.txt", "b.txt"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    defer { panel.shutdown() }
    panel.loadViewIfNeeded()
    await waitListed(panel, 2)
    panel.setMarks(["a.txt"])
    let a = try #require(cell(panel, "name", "a.txt") as? PanelCell), b = try #require(cell(panel, "name", "b.txt") as? PanelCell)
    #expect(!a.check.isHidden && b.check.isHidden)
    #expect(a.check.contentTintColor == a.textField?.textColor && Theme.all[0].marked == Palette.accent)
    let marked = a.textField?.textColor
    a.backgroundStyle = .emphasized
    #expect(a.textField?.textColor == .alternateSelectedControlTextColor && a.check.contentTintColor == .alternateSelectedControlTextColor)
    a.backgroundStyle = .normal
    #expect(a.textField?.textColor == marked)
}

/// P18: the git column's letters have words for VoiceOver, green (staged) and red told apart as well.
@MainActor @Test func gitLettersHaveWords() {
    #expect(PanelViewController.gitCell(" M").2 == "modified")
    #expect(PanelViewController.gitCell("M ").2 == "modified, staged")
    #expect(PanelViewController.gitCell("A ").2 == "added, staged")
    #expect(PanelViewController.gitCell(" D").2 == "deleted")
    #expect(PanelViewController.gitCell("R ").2 == "renamed, staged")
    #expect(PanelViewController.gitCell("UU").2 == "conflict")
    #expect(PanelViewController.gitCell("??").2 == "untracked")
    #expect(PanelViewController.gitCell("!!").2 == "ignored")
    #expect(PanelViewController.gitCell("•").2 == "changes inside")
}

/// The git column takes no color that means something else: modified amber, added green, untracked and deleted grey,
/// a conflict red with a warning sign; never production's purple or root's orange. Staged is told by bold.
@MainActor @Test func gitLettersKeepToTheirColors() {
    let cells = [" M", "M ", "A ", " D", "R ", "UU", "??", "•"].map(PanelViewController.gitCell)
    #expect(cells.map(\.letter) == ["M", "M", "A", "D", "R", "U", "?", "•"])
    #expect(cells.map(\.color) == [Palette.warn, Palette.warn, Palette.ok, .secondaryLabelColor, Palette.warn, Palette.fail, .secondaryLabelColor, Palette.warn])
    #expect(cells.map(\.staged) == [false, true, true, false, true, false, false, false])
    func weight(_ s: NSAttributedString) -> CGFloat? {
        ((s.attribute(.font, at: s.length - 1, effectiveRange: nil) as? NSFont)?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
    }
    let text = cells.map { PanelViewController.gitText($0, size: 12) }
    #expect(weight(text[1])! > weight(text[0])!, "staged in bold")
    #expect(text[3].attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue, "deleted, struck through")
    #expect(text[5].string == "\u{FFFC}U" && text[5].attribute(.attachment, at: 0, effectiveRange: nil) != nil, "a conflict after its sign")
}

/// P18: the git cell of an untracked file carries "untracked" (and a file without a mark carries nothing).
@MainActor @Test(.enabled(if: GitStatus.available)) func gitCellsCarryTheirWord() async throws {
    _ = NSApplication.shared
    let dir = try tempDir(["new.txt"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let p = try Process.run(URL(fileURLWithPath: "/usr/bin/git"), arguments: ["init", "-q", dir])
    p.waitUntilExit()
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    defer { panel.shutdown() }
    panel.loadViewIfNeeded()
    await waitListed(panel, 1)
    let column = panel.table.tableColumn(withIdentifier: .init("git"))!
    for _ in 0..<500 where column.isHidden { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!column.isHidden)
    let c = cell(panel, "git", "new.txt")
    #expect(c?.textField?.stringValue == "?" && c?.textField?.accessibilityLabel() == "untracked")
}

/// P18: the ops window's Pause button says "Resume" while the job is paused (its picture was the only change).
@MainActor @Test func pauseButtonSaysResumeWhilePaused() {
    _ = NSApplication.shared
    let row = JobRow(job: FileJob(.copy, sources: [], from: .local, to: .local, destDir: nil), title: "copy", onCancel: {}, onStartNow: {})
    #expect(row.pause.image?.accessibilityDescription == "Pause" && row.pause.toolTip == "Pause")
    row.pause.performClick(nil)
    #expect(row.job.isPaused)
    #expect(row.pause.image?.accessibilityDescription == "Resume" && row.pause.toolTip == "Resume")
    row.pause.performClick(nil)
    #expect(row.pause.image?.accessibilityDescription == "Pause" && row.pause.toolTip == "Pause")
}

/// P19: typing in the toolbar search ranks once typing pauses, for what the field says then — not per keystroke.
@MainActor @Test func toolbarSearchRanksAfterTypingPauses() async throws {
    _ = NSApplication.shared
    let s = HeaderSearch()
    var asked: [String] = []
    s.results = { q, _ in asked.append(q); return [("In This Panel", [SearchHit(title: q, target: .file(q))])] }
    for q in ["a", "ab", "abc"] {
        s.item.searchField.stringValue = q
        s.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: s.item.searchField))
    }
    #expect(asked.isEmpty, "nothing ranked while typing")
    for _ in 0..<500 where asked.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .milliseconds(200))   // long enough for a second ranking, were one coming
    #expect(asked == ["abc"], "one ranking, of what the field says now")
}

/// P19: ↩ before the pause is over ranks what was typed first — the rows still up are the last query's (the recent
/// commands, "Move to Trash" among them), and those aren't what runs.
@MainActor @Test func toolbarSearchEnterInsideThePauseRunsTheTypedHit() async throws {
    _ = NSApplication.shared
    let s = HeaderSearch()
    var asked: [String] = [], chosen: [SearchHit] = []
    s.results = { q, _ in
        asked.append(q)
        return q.isEmpty ? [("Recent", [SearchHit(title: "Move to Trash", target: .command("file.trash"))])]
                         : [("Commands", [SearchHit(title: q, target: .command(q))])]
    }
    s.onChoose = { h, _ in chosen.append(h) }
    s.focus()
    for _ in 0..<500 where asked.isEmpty { try await Task.sleep(for: .milliseconds(10)) }   // the recents are up
    for q in ["z", "zi", "zip"] {
        s.item.searchField.stringValue = q
        s.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: s.item.searchField))
    }
    _ = s.control(s.item.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    for _ in 0..<500 where chosen.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(chosen.map(\.target) == [.command("zip")])
    #expect(asked == ["", "zip"], "what was typed got ranked, not its prefixes")
}

/// P18: the sidebar is reachable from the keyboard — Focus Sidebar puts the keys there (a click or Tab never does),
/// ↩ opens the selected place, ⎋ hands them back. Shortcuts (⌘⌃⌥, F-keys, ⇥) still reach the panels from there; bare
/// keys don't — ⌦ there used to trash the panel's file.
@MainActor @Test func sidebarTakesTheKeysOnRequestOnly() throws {
    _ = NSApplication.shared
    let sidebar = SidebarController()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentViewController = sidebar
    sidebar.show([SidebarSection(id: "misc-test", title: "Test", command: "go.bookmark", places: [.folder("/tmp"), .folder("/usr")])])
    var opened: [Place] = [], left = 0
    sidebar.onOpen = { p, _ in opened.append(p) }
    sidebar.onLeave = { left += 1 }
    let outline = try #require(((sidebar.view as? NSStackView)?.arrangedSubviews.first as? NSScrollView)?.documentView as? NSOutlineView)
    window.makeFirstResponder(outline)
    #expect(window.firstResponder !== outline, "the key view loop and a click pass it by")

    sidebar.focus()
    #expect(window.firstResponder === outline)
    sidebar.highlight("/usr")
    press(outline, "\r", 36)
    #expect(opened == [.folder("/usr")])
    press(outline, "\u{1b}", 53)
    #expect(left == 1)

    var forwarded: [UInt16] = []
    sidebar.onCommandKey = { forwarded.append($0.keyCode); return true }
    press(outline, "\u{F728}", 117)   // ⌦
    press(outline, " ", 49)
    press(outline, "\u{8}", 51)       // ⌫
    press(outline, "/", 44)
    #expect(forwarded.isEmpty, "bare keys stay in the sidebar")
    press(outline, "\u{F708}", 96)    // F5
    press(outline, "\u{F705}", 120, mods: .shift)   // ⇧F2
    press(outline, "\t", 48)
    press(outline, "k", 40, mods: .command)
    press(outline, "5", 23, mods: .option)
    #expect(forwarded == [96, 120, 48, 40, 23], "shortcuts reach the panels")
}
