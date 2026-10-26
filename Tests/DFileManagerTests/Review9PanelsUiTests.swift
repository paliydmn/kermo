import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

@MainActor
private func tempDir(_ files: [String] = []) throws -> String {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dfm-panelsui-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for f in files { FileManager.default.createFile(atPath: dir + "/" + f, contents: Data()) }
    return dir
}

@MainActor
private func waitUntil(_ done: () -> Bool) async {
    for _ in 0..<2000 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
private func loaded(_ dir: String, count: Int) async -> PanelViewController {
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    await waitUntil { panel.listedItems.count == count }
    return panel
}

@MainActor
private func inWindow(_ panel: PanelViewController) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentViewController = panel
    return window
}

@MainActor
private func pathCommand(_ panel: PanelViewController, _ text: String, _ sel: Selector) {
    let tv = NSTextView()
    tv.string = text
    _ = panel.control(NSTextField(), textView: tv, doCommandBy: sel)   // any control but the filter field is the path field
}

// MARK: - P8: ⌘L on a local folder

/// ⌘L selects the whole path, so typing replaces it instead of landing after it (`~/a/~/b`).
@MainActor @Test func pathEditingSelectsTheWholePath() async throws {
    let dir = try tempDir(["f"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = await loaded(dir, count: 1)
    let window = inWindow(panel)
    defer { panel.shutdown(); window.close() }
    panel.beginPathEditing()
    let editor = try #require(window.firstResponder as? NSTextView)
    #expect(editor.string == dir + "/")
    #expect(editor.selectedRange() == NSRange(location: 0, length: editor.string.utf16.count))
}

/// ↩ on a path that doesn't exist says so in the status line (it used to only beep).
@MainActor @Test func pathEditingFlashesOnAMissingPath() async throws {
    let dir = try tempDir(["f"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = await loaded(dir, count: 1)
    defer { panel.shutdown() }
    pathCommand(panel, dir + "/nope", #selector(NSResponder.insertNewline(_:)))
    await waitUntil { panel.statusText.hasPrefix("No such folder") }   // looked at off the main thread (A4, task 11)
    #expect(panel.statusText == "No such folder: \(dir)/nope")
    #expect(panel.path == dir)
}

/// ⎋ in the path field brings back the 🔍 / 📦 header, not the folder behind the results.
@MainActor @Test func escapeRestoresTheSearchAndArchiveHeaders() async throws {
    let dir = try tempDir(["f"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = await loaded(dir, count: 1)
    let window = inWindow(panel)
    defer { panel.shutdown(); window.close() }

    _ = panel.beginSearch("*.log in \(dir)")
    #expect(panel.headerText == "*.log in \(dir)")
    panel.beginPathEditing()
    #expect(panel.headerText == dir + "/")
    pathCommand(panel, dir + "/", #selector(NSResponder.cancelOperation(_:)))
    #expect(panel.headerText == "*.log in \(dir)")
    panel.goUp()   // leaves the results
    await waitUntil { panel.searchTitle == nil && panel.listedItems.count == 1 }

    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["cf", dir + "/a.tar", "f"]
    tar.currentDirectoryURL = URL(fileURLWithPath: dir)
    try tar.run()
    tar.waitUntilExit()
    panel.enterArchive(dir + "/a.tar")
    await waitUntil { panel.archive != nil }
    #expect(panel.headerText == "\(dir)/a.tar")
    panel.beginPathEditing()
    pathCommand(panel, dir + "/", #selector(NSResponder.cancelOperation(_:)))
    #expect(panel.headerText == "\(dir)/a.tar")
}

// MARK: - P10: control characters in a name

@MainActor
private func cell(_ panel: PanelViewController, _ column: String, row: Int) -> NSTableCellView {
    panel.tableView(panel.table, viewFor: panel.table.tableColumn(withIdentifier: .init(column)), row: row) as! NSTableCellView
}

@Test func controlCharactersInANameStayOnOneLine() {
    func item(_ n: String) -> FileItem { FileItem(name: n, kind: .file, size: 0, mtime: 0, mode: 0, flags: 0) }
    #expect(item("two\nlines.txt").displayName == "two␤lines.txt")
    #expect(item("crlf\r\nend").displayName == "crlf␤end")
    #expect(item("tab\tbell\u{7}.log").displayName == "tab?bell?.log")
    #expect(item("plain ü.txt").displayName == "plain ü.txt")
}

/// The Name cell shows ␤ for the newline; the item (what rename and copy use) keeps the real name.
@MainActor @Test func nameCellShowsANewlineAsASymbol() async throws {
    let dir = try tempDir(["two\nlines.txt"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = await loaded(dir, count: 1)
    defer { panel.shutdown() }
    #expect(cell(panel, "name", row: 1).textField?.stringValue == "two␤lines.txt")
    #expect(panel.listedItems[0].name == "two\nlines.txt")
}

// MARK: - P11: symlinks and special files

/// A special file and a folder not measured leave the Size column empty — no DOS "<DIR>" — and the special file's kind
/// goes to the row's tooltip; bytes are "B", as short as the other units.
@MainActor @Test func sizeColumnNamesSpecialFilesAndLinkNotesSayWhy() {
    func item(_ kind: FileItem.Kind, mode: UInt32 = 0, size: Int64 = 0) -> FileItem { FileItem(name: "x", kind: kind, size: size, mtime: 0, mode: mode, flags: 0) }
    let fifo = item(.other, mode: UInt32(S_IFIFO) | 0o644)
    #expect(PanelViewController.sizeText(fifo, measured: nil) == "" && PanelViewController.specialKind(fifo) == "Named pipe (FIFO)")
    #expect(PanelViewController.specialKind(item(.other, mode: UInt32(S_IFSOCK))) == "Socket")
    #expect(PanelViewController.specialKind(item(.other, mode: UInt32(S_IFCHR) | 0o666)) == "Character device")
    #expect(PanelViewController.specialKind(item(.file)) == nil)
    #expect(PanelViewController.sizeText(item(.dir), measured: nil) == "")
    #expect(PanelViewController.sizeText(item(.dir), measured: 2048) == ByteCountFormatter().string(fromByteCount: 2048))
    #expect(PanelViewController.sizeText(item(.dir), measured: 2048, partial: true) == "≥ " + ByteCountFormatter().string(fromByteCount: 2048))
    #expect(PanelViewController.sizeText(item(.file, size: 310), measured: nil) == "310 B" && ByteCountFormatter.short(0) == "0 B")
    #expect(ByteCountFormatter.short(999) == "999 B" && ByteCountFormatter.short(1000) == ByteCountFormatter().string(fromByteCount: 1000))
    #expect(PanelViewController.countText(7, "items", 310) == "7 items · 310 B")
    #expect(PanelViewController.linkNote("/etc/hosts", 0) == "→ /etc/hosts")
    #expect(PanelViewController.linkNote("gone", ENOENT) == "→ gone (dangling)")
    #expect(PanelViewController.linkNote("b", ELOOP) == "→ b (loop)")
    let d = NSTemporaryDirectory() + "dfm-fifo-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: d) }
    mkfifo(d + "/fifo", 0o644)
    #expect((try? SFTP.list(.local(), d))?.first.flatMap(PanelViewController.specialKind) == "Named pipe (FIFO)", "a server's FIFO too")
}

/// Links show where they point (tooltip, and after the name when the column has room); a dangling one and a loop
/// say so in red; a FIFO shows its type instead of "Zero KB".
@MainActor @Test func panelShowsLinkTargetsDanglingLoopsAndAFifo() async throws {
    let dir = try tempDir(["f"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let fm = FileManager.default
    try fm.createSymbolicLink(atPath: dir + "/ok", withDestinationPath: "f")
    try fm.createSymbolicLink(atPath: dir + "/dangling", withDestinationPath: "nowhere")
    try fm.createSymbolicLink(atPath: dir + "/a", withDestinationPath: "b")
    try fm.createSymbolicLink(atPath: dir + "/b", withDestinationPath: "a")
    #expect(mkfifo(dir + "/pipe", 0o644) == 0)
    let panel = await loaded(dir, count: 6)
    let window = inWindow(panel)
    defer { panel.shutdown(); window.close() }
    window.contentView?.layoutSubtreeIfNeeded()
    func row(_ name: String) -> Int { panel.listedItems.firstIndex { $0.name == name }! + 1 }
    func name(_ n: String) -> NSTableCellView { cell(panel, "name", row: row(n)) }
    await waitUntil { name("ok").toolTip != nil }

    #expect(name("ok").toolTip == "→ f")
    #expect(name("ok").textField?.attributedStringValue.string == "ok  → f")
    #expect(name("ok").textField?.textColor != .systemRed)
    #expect(name("dangling").toolTip == "→ nowhere (dangling)")
    #expect(name("dangling").textField?.textColor == .systemRed)
    #expect(name("a").toolTip == "→ b (loop)")
    #expect(name("a").textField?.textColor == .systemRed)
    #expect(name("f").toolTip == nil)
    panel.table.tableColumn(withIdentifier: .init("name"))!.width = 60   // no room: the name alone, the target stays in the tooltip
    #expect(name("ok").textField?.attributedStringValue.string == "ok" && name("ok").toolTip == "→ f")

    let pipe = try #require(panel.listedItems.first { $0.name == "pipe" })
    #expect(pipe.kind == .other && mode_t(truncatingIfNeeded: pipe.mode) & S_IFMT == S_IFIFO)
    #expect(cell(panel, "size", row: row("pipe")).textField?.stringValue == "" && name("pipe").toolTip == "Named pipe (FIFO)")
    #expect(cell(panel, "size", row: row("f")).textField?.stringValue == "0 B")

    // Search results (like archives and servers) are not the folder's entries: a result named like its link wears nothing.
    let flag = panel.beginSearch("x")
    panel.addSearchResults([FileItem(name: "dangling", kind: .link, size: 0, mtime: 0, mode: 0, flags: 0)], from: flag)
    #expect(cell(panel, "name", row: 1).toolTip == nil && cell(panel, "name", row: 1).textField?.textColor != .systemRed)
}

/// A link's target is listed like a name: a newline or a bidi override in it can't reach the cell or the tooltip.
@MainActor @Test func linkTargetsAreListedLikeNames() {
    #expect(PanelViewController.linkNote("x\ny", ENOENT) == "→ x␤y (dangling)")
    #expect(PanelViewController.linkNote("rtl-\u{202E}txt.exe", 0) == "→ rtl-⟨U+202E⟩txt.exe")
}

/// The cell on screen, not a fresh one from the delegate.
@MainActor
private func liveCell(_ panel: PanelViewController, _ column: String, row: Int) -> NSTableCellView? {
    panel.view.window?.contentView?.layoutSubtreeIfNeeded()
    return panel.table.view(atColumn: panel.table.column(withIdentifier: .init(column)), row: row, makeIfNecessary: false) as? NSTableCellView
}

/// "→ target" fits or not per cell, so a narrower Name column drops it from the cells already on screen and a
/// wider one brings it back — not only on the next listing.
@MainActor @Test func resizingTheNameColumnRebuildsLinkCells() async throws {
    let dir = try tempDir(["f"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createSymbolicLink(atPath: dir + "/ok", withDestinationPath: "f")
    let panel = await loaded(dir, count: 2)
    let window = inWindow(panel)
    defer { panel.shutdown(); window.close() }
    let row = panel.listedItems.firstIndex { $0.name == "ok" }! + 1
    func live() -> String? { liveCell(panel, "name", row: row)?.textField?.attributedStringValue.string }
    await waitUntil { live() == "ok  → f" }
    #expect(live() == "ok  → f")
    let column = panel.table.tableColumn(withIdentifier: .init("name"))!
    column.width = 60
    #expect(live() == "ok")
    column.width = 300
    #expect(live() == "ok  → f")
}

/// A folder's links resolve one at a time (a target on a share that stopped answering would otherwise hold a thread per
/// reload, until no listing got one); the listing itself never waits for them. When the resolve lands, the whole row
/// of a dangling link turns red — the Size and Modified cells already on screen too, not only the name.
@MainActor @Test func linkResolvesRunOnePerFolderAndColorTheWholeRow() async throws {
    let dir = try tempDir(["f"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createSymbolicLink(atPath: dir + "/dangling", withDestinationPath: "nowhere")
    let stuck = DispatchSemaphore(value: 0), entered = DispatchGroup()
    defer { stuck.signal() }
    entered.enter()
    let hung = Task { await PanelViewController.linkResolves.run(dir) { entered.leave(); _ = stuck.wait(timeout: .now() + 10); return [:] } }
    await waitUntil { entered.wait(timeout: .now()) == .success }
    let panel = await loaded(dir, count: 2)
    let window = inWindow(panel)
    defer { panel.shutdown(); window.close() }
    for _ in 0..<20 { panel.reload() }
    FileManager.default.createFile(atPath: dir + "/new", contents: Data())
    panel.reload()
    await waitUntil { panel.listedItems.count == 3 }
    #expect(panel.listedItems.count == 3, "the listing never waits for the links")
    let row = panel.listedItems.firstIndex { $0.name == "dangling" }! + 1
    try await Task.sleep(for: .milliseconds(200))
    #expect(liveCell(panel, "name", row: row)?.toolTip == nil, "no resolve of its own while one hangs")
    #expect(liveCell(panel, "size", row: row)?.textField?.textColor != .systemRed)

    stuck.signal()
    _ = await hung.value
    await waitUntil { liveCell(panel, "name", row: row)?.toolTip != nil }
    #expect(liveCell(panel, "name", row: row)?.toolTip == "→ nowhere (dangling)")
    for column in ["name", "size", "mtime"] { #expect(liveCell(panel, column, row: row)?.textField?.textColor == .systemRed, "\(column)") }
}

// MARK: - P20: "7 items, Zero KB"

@MainActor @Test func statusLineLeavesOutASizeItDoesNotKnow() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    for d in ["one", "two"] { try FileManager.default.createDirectory(atPath: dir + "/" + d, withIntermediateDirectories: false) }
    let panel = await loaded(dir, count: 2)
    defer { panel.shutdown() }
    #expect(panel.statusText == "2 items", "\(panel.statusText)")
    panel.setMarks(["one", "two"])
    #expect(panel.statusText == "2 marked", "\(panel.statusText)")
    #expect(PanelViewController.countText(7, "items", 0) == "7 items")
    #expect(PanelViewController.countText(2, "marked", 1536) == "2 marked · " + ByteCountFormatter().string(fromByteCount: 1536))
}
