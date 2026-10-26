import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

@MainActor
private func tempDir(_ files: [String]) throws -> String {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dfm-panels-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for f in files { FileManager.default.createFile(atPath: dir + "/" + f, contents: Data()) }
    return dir
}

/// Up to 20 s: a watcher's re-list waits twice as long as the last listing took, seconds while the whole suite runs.
@MainActor
/// By the clock, up to a minute: a link's target and a file's new size are read at utility QoS, which a loaded full run
/// starves for tens of seconds (D-097).
private func waitListed(_ panel: PanelViewController, _ count: Int) async {
    let end = Date().addingTimeInterval(60)
    while panel.listedItems.count != count, Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
}

/// U1: a narrow panel (4 panels at 1200 pt) gives the width to Name; Modified, then Size, make room and come back when it widens.
@MainActor @Test func narrowPanelKeepsTheNameReadable() throws {
    let dir = try tempDir([])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { panel.shutdown(); window.close() }
    window.contentViewController = panel
    func column(_ id: String) -> NSTableColumn { panel.table.tableColumn(withIdentifier: .init(id))! }
    func layout(_ width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: 400))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    // (panel width, Size shown, Modified shown)
    for (width, size, mtime) in [(600.0, true, true), (295, true, false), (200, false, false), (600, true, true)] {
        layout(width)
        #expect(!column("size").isHidden == size && !column("mtime").isHidden == mtime, "at \(width) pt")
        #expect(column("name").width >= 120, "Name stays readable at \(width) pt")
        let used = panel.table.tableColumns.filter { !$0.isHidden }.reduce(0) { $0 + $1.width + panel.table.intercellSpacing.width }
        #expect(used <= panel.table.enclosingScrollView!.contentSize.width + 1, "nothing cut off at \(width) pt")
    }
}

/// U5: marks and the quick filter belong to a tab; another tab of the same folder starts clean and gets its own back.
@MainActor @Test func marksAndFilterArePerTab() async throws {
    let dir = try tempDir(["a.txt", "b.txt", "c.log"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let recent = UserDefaults.standard.stringArray(forKey: "recentFilters")
    defer { UserDefaults.standard.set(recent, forKey: "recentFilters") }   // applyFilter remembers it

    let panel = PanelViewController(tabs: [dir, dir], index: 0, showHidden: false)
    defer { panel.shutdown() }
    panel.loadViewIfNeeded()
    await waitListed(panel, 3)
    panel.applyFilter("*.txt")
    panel.setMarks(["a.txt"])
    #expect(panel.listedItems.map(\.name) == ["a.txt", "b.txt"])

    panel.switchTab(by: 1)
    await waitListed(panel, 3)
    #expect(panel.listedItems.count == 3, "the other tab isn't filtered")
    #expect(panel.markedNames.isEmpty, "nor marked")
    panel.setMarks(["c.log"])

    panel.switchTab(by: 1)
    await waitListed(panel, 2)
    #expect(panel.listedItems.map(\.name) == ["a.txt", "b.txt"], "the first tab's filter is back")
    #expect(panel.targetItems.map(\.name) == ["a.txt"], "and its marks")

    panel.switchTab(by: 1)
    await waitListed(panel, 3)
    #expect(panel.targetItems.map(\.name) == ["c.log"])
}

@MainActor
private func waitUntil(_ done: () -> Bool) async {
    let end = Date().addingTimeInterval(60)
    while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
}

/// U5: while a switched-to tab's listing is still loading, its marks don't land on the folder still on screen.
@MainActor @Test func aTabsMarksWaitForItsOwnListing() async throws {
    let a = try tempDir(["x", "y"]), b = try tempDir(["x", "z"])
    defer { for d in [a, b] { try? FileManager.default.removeItem(atPath: d) } }
    let panel = PanelViewController(tabs: [a, b], index: 1, showHidden: false)
    defer { panel.shutdown() }
    panel.loadViewIfNeeded()
    await waitUntil { panel.currentDir == b && panel.listedItems.count == 2 }
    panel.setMarks(["x"])

    panel.switchTab(by: 1)
    await waitUntil { panel.currentDir == a && panel.listedItems.count == 2 }
    #expect(panel.markedNames.isEmpty)
    panel.switchTab(by: 1)   // B's listing hasn't arrived: A's rows are still shown
    #expect(panel.currentDir == a && panel.markedNames.isEmpty, "B's mark is on A's x")
    #expect(!panel.targetURLs.map(\.path).contains(a + "/x"))
    await waitUntil { panel.currentDir == b }
    #expect(panel.targetURLs.map(\.path) == [b + "/x"], "B's mark is back on B's x")
}

/// U5: marks made inside an archive name entries, not the files beside it; a tab round-trip doesn't turn them into real ones.
@MainActor @Test func marksInAnArchiveDontLandOnRealFiles() async throws {
    let a = try tempDir(["README.md"]), b = try tempDir([])
    defer { for d in [a, b] { try? FileManager.default.removeItem(atPath: d) } }
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.arguments = ["-q", "pkg.zip", "README.md"]
    zip.currentDirectoryURL = URL(fileURLWithPath: a)
    try zip.run()
    zip.waitUntilExit()
    let panel = PanelViewController(tabs: [a, b], index: 0, showHidden: false)
    defer { panel.shutdown() }
    panel.loadViewIfNeeded()
    await waitListed(panel, 2)
    panel.enterArchive(a + "/pkg.zip")
    await waitUntil { panel.listedItems.map(\.name) == ["README.md"] }   // the folder itself lists 2
    panel.setMarks(["README.md"])
    #expect(panel.markedNames == ["README.md"])

    panel.switchTab(by: 1)
    await waitUntil { panel.currentDir == b }
    panel.switchTab(by: 1)
    await waitUntil { panel.currentDir == a && panel.listedItems.count == 2 }
    #expect(panel.markedNames.isEmpty, "the archive's mark is now on \(a)/README.md")
}

/// U5: ⌘T opens the folder clean — the new tab doesn't carry the old one's marks or filter, and the old one keeps them.
@MainActor @Test func aNewTabStartsWithoutMarksOrFilter() async throws {
    let dir = try tempDir(["a.txt", "b.txt", "c.log"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let recent = UserDefaults.standard.stringArray(forKey: "recentFilters")
    defer { UserDefaults.standard.set(recent, forKey: "recentFilters") }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    defer { panel.shutdown() }
    panel.loadViewIfNeeded()
    await waitListed(panel, 3)
    panel.applyFilter("*.txt")
    panel.setMarks(["a.txt"])

    panel.newTab()
    #expect(panel.markedNames.isEmpty && panel.listedItems.count == 3)
    panel.switchTab(by: 1)
    await waitListed(panel, 2)
    #expect(panel.markedNames == ["a.txt"] && panel.listedItems.map(\.name) == ["a.txt", "b.txt"])
}

/// L8: Compare Folders takes the FAT/exFAT mtime slack from the panel's listing (read off the main thread), not
/// from a statfs on the main thread, which a hung network mount would block.
@MainActor @Test func panelReadsMtimeToleranceWithItsListing() async throws {
    let dir = try tempDir(["a.txt"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    defer { panel.shutdown() }
    panel.loadViewIfNeeded()
    await waitListed(panel, 1)
    #expect(panel.mtimeTolerance == 1)   // APFS
}

/// P2: entering a folder puts the cursor on "..", not on the row number it had; going back up lands on that folder.
@MainActor @Test func enteringAFolderStartsOnTheParentRow() async throws {
    let dir = try tempDir(["a", "b", "c"]), sub = dir + "/sub"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: false)
    for f in ["w", "x", "y", "z"] { FileManager.default.createFile(atPath: sub + "/" + f, contents: Data()) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    defer { panel.shutdown() }
    panel.loadViewIfNeeded()
    await waitListed(panel, 4)
    panel.table.selectRowIndexes([3], byExtendingSelection: false)   // "..", sub, a, b
    panel.navigate(to: sub)
    await waitUntil { panel.currentDir == sub }
    #expect(panel.table.selectedRow == 0 && panel.cursorURL == nil, "the cursor stayed on row \(panel.table.selectedRow)")
    panel.table.selectRowIndexes([3], byExtendingSelection: false)
    panel.goUp()
    await waitUntil { panel.currentDir == dir }
    #expect(panel.cursorURL?.lastPathComponent == "sub")
}

/// P5: a reload keeps the cursor where it is when the listing arrives, not where it was when the reload started.
@MainActor @Test func aReloadDoesntPullTheCursorBack() async throws {
    let dir = try tempDir(["a", "b", "c"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    defer { panel.shutdown() }
    panel.loadViewIfNeeded()
    await waitListed(panel, 3)
    panel.table.selectRowIndexes([1], byExtendingSelection: false)   // a
    FileManager.default.createFile(atPath: dir + "/d", contents: Data())
    panel.reload()
    panel.table.selectRowIndexes([3], byExtendingSelection: false)   // c, while the listing runs
    await waitListed(panel, 4)
    #expect(panel.cursorURL?.lastPathComponent == "c")
}

/// P3: a folder replaced under the panel (`rm -rf build && mkdir build`) is still watched: new files show up.
@MainActor @Test func aReplacedFolderIsStillWatched() async throws {
    let parent = try tempDir([]), build = parent + "/build"
    defer { try? FileManager.default.removeItem(atPath: parent) }
    try FileManager.default.createDirectory(atPath: build, withIntermediateDirectories: false)
    FileManager.default.createFile(atPath: build + "/old", contents: Data())
    let panel = PanelViewController(tabs: [build], index: 0, showHidden: false)
    defer { panel.shutdown() }
    panel.loadViewIfNeeded()
    await waitListed(panel, 1)
    try FileManager.default.removeItem(atPath: build)
    try FileManager.default.createDirectory(atPath: build, withIntermediateDirectories: false)
    await waitListed(panel, 0)
    #expect(panel.currentDir == build)
    FileManager.default.createFile(atPath: build + "/new", contents: Data())
    await waitListed(panel, 1)
    #expect(panel.listedItems.map(\.name) == ["new"], "the watcher is still on the deleted folder")
}

/// P3: a `current` symlink swapped to another release (nothing in the old folder changes) is followed on the next
/// stat round, and the new folder is watched from then on.
@MainActor @Test func aSwappedSymlinkIsFollowed() async throws {
    let root = try tempDir([]), current = root + "/current"
    defer { try? FileManager.default.removeItem(atPath: root) }
    for r in ["r1", "r2"] { try FileManager.default.createDirectory(atPath: root + "/" + r, withIntermediateDirectories: false) }
    FileManager.default.createFile(atPath: root + "/r1/one", contents: Data())
    try FileManager.default.createSymbolicLink(atPath: current, withDestinationPath: "r1")
    let panel = PanelViewController(tabs: [current], index: 0, showHidden: false)
    defer { panel.shutdown() }
    panel.loadViewIfNeeded()
    await waitListed(panel, 1)
    try FileManager.default.createSymbolicLink(atPath: root + "/next", withDestinationPath: "r2")
    #expect(rename(root + "/next", current) == 0)
    panel.refreshStats()
    await waitListed(panel, 0)
    #expect(panel.listedItems.isEmpty, "still showing r1")
    FileManager.default.createFile(atPath: root + "/r2/two", contents: Data())
    await waitListed(panel, 1)
    #expect(panel.listedItems.map(\.name) == ["two"], "the watcher is still on r1")
}

/// P4: a file that grows (a log) shows its new size without anything else changing in its folder.
@MainActor @Test func aGrowingFileShowsItsNewSize() async throws {
    let dir = try tempDir(["app.log"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { panel.shutdown(); window.close() }
    window.contentViewController = panel
    window.contentView?.layoutSubtreeIfNeeded()
    await waitListed(panel, 1)
    let log = try FileHandle(forWritingTo: URL(fileURLWithPath: dir + "/app.log"))
    try log.write(contentsOf: Data(repeating: 65, count: 100))
    try log.close()
    panel.refreshStats()   // what the panel's timer does every few seconds while it's on screen
    await waitUntil { panel.listedItems.first?.size == 100 }
    #expect(panel.listedItems.first?.size == 100)
}

/// P4: scrolled down to watch a growing file, away from the cursor near the top: the re-list doesn't scroll back.
@MainActor @Test func aGrowingFileDoesntScrollBackToTheCursor() async throws {
    let names = (0..<200).map { String(format: "f%03d", $0) }
    let dir = try tempDir(names)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { panel.shutdown(); window.close() }
    window.contentViewController = panel
    window.contentView?.layoutSubtreeIfNeeded()
    await waitListed(panel, 200)
    panel.table.selectRowIndexes([1], byExtendingSelection: false)   // f000
    panel.table.scrollRowToVisible(186)                                // f185, like a trackpad scroll: the cursor stays
    let shown = { panel.table.rows(in: panel.table.visibleRect) }
    #expect(NSLocationInRange(186, shown()) && !NSLocationInRange(1, shown()))
    let log = try FileHandle(forWritingTo: URL(fileURLWithPath: dir + "/f185"))
    try log.write(contentsOf: Data(repeating: 65, count: 100))
    try log.close()
    panel.refreshStats()
    await waitUntil { panel.listedItems.first { $0.name == "f185" }?.size == 100 }
    #expect(panel.listedItems.first { $0.name == "f185" }?.size == 100)
    #expect(NSLocationInRange(186, shown()), "scrolled back to rows \(shown())")
    #expect(panel.table.selectedRow == 1)
}

/// P7: the header search's file hit moves the cursor in search results too (a reload leaves them alone).
@MainActor @Test func aHeaderSearchFileHitMovesTheCursorInResults() async throws {
    let dir = try tempDir(["a.txt", "b.txt"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    defer { panel.shutdown() }
    panel.loadViewIfNeeded()
    await waitListed(panel, 2)
    let flag = panel.beginSearch("*.txt")
    panel.addSearchResults(["a.txt", "b.txt"].map { FileItem(name: $0, kind: .file, size: 0, mtime: 0, mode: 0, flags: 0) }, from: flag)
    panel.finishSearch(flag)
    panel.table.selectRowIndexes([1], byExtendingSelection: false)   // "..", a.txt, b.txt
    panel.moveCursor(toName: "b.txt")
    #expect(panel.table.selectedRow == 2 && panel.searchTitle != nil)
}

/// P7: a reload (after ⌘E, F2, undo, a tag, an extract…) leaves search results and an archive as they are.
@MainActor @Test func aReloadKeepsSearchResultsAndArchives() async throws {
    let dir = try tempDir(["a.txt", "b.txt"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.arguments = ["-q", "pkg.zip", "a.txt"]
    zip.currentDirectoryURL = URL(fileURLWithPath: dir)
    try zip.run()
    zip.waitUntilExit()
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    defer { panel.shutdown() }
    panel.loadViewIfNeeded()
    await waitListed(panel, 3)

    let flag = panel.beginSearch("*.txt")
    panel.addSearchResults([FileItem(name: "a.txt", kind: .file, size: 0, mtime: 0, mode: 0, flags: 0)], from: flag)
    panel.finishSearch(flag)
    panel.reload()
    panel.refreshStats()   // never re-lists results either
    try await Task.sleep(for: .milliseconds(500))
    #expect(panel.searchTitle != nil && panel.listedItems.map(\.name) == ["a.txt"], "the results were reset to the folder")
    panel.goUp()   // ".." still leaves them
    await waitUntil { panel.searchTitle == nil }
    #expect(panel.searchTitle == nil)

    panel.enterArchive(dir + "/pkg.zip")
    await waitUntil { panel.archive != nil }
    panel.reload()
    try await Task.sleep(for: .milliseconds(500))
    #expect(panel.archive != nil && panel.listedItems.map(\.name) == ["a.txt"], "the archive was reset to the folder")
}

/// P2 and P5 on a server (the local sftp-server): a folder opens on "..", a reload leaves the cursor where it is now.
/// Part of ServerLockTests, which locks "localhost" for a while: not run meanwhile.
extension ServerLockTests {
    @Test func aServerFolderStartsOnTheParentRowAndKeepsTheCursor() async throws {
        let dir = try tempDir(["a", "b", "c"]), sub = dir + "/sub"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: false)
        for f in ["w", "x", "y", "z"] { FileManager.default.createFile(atPath: sub + "/" + f, contents: Data()) }
        let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
        defer { panel.shutdown() }
        panel.loadViewIfNeeded()
        panel.loadRemote(.local(), dir: dir, select: nil)
        await waitUntil { panel.remote?.dir == dir && panel.listedItems.count == 4 }
        panel.table.selectRowIndexes([3], byExtendingSelection: false)   // "..", sub, a, b
        panel.loadRemote(.local(), dir: sub, select: nil)
        await waitUntil { panel.remote?.dir == sub }
        #expect(panel.table.selectedRow == 0 && panel.remoteCursor == nil, "the cursor stayed on row \(panel.table.selectedRow)")

        panel.table.selectRowIndexes([1], byExtendingSelection: false)   // w
        FileManager.default.createFile(atPath: sub + "/v", contents: Data())
        panel.reload()
        panel.table.selectRowIndexes([3], byExtendingSelection: false)   // y, while the listing runs
        await waitListed(panel, 5)
        #expect(panel.remoteCursor?.item.name == "y")
    }
}
