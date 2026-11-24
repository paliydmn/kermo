import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Review 6, PR 5: the panel — a failed go-to stays, search hits' folders, where the panel is.

@MainActor private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r6p-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// By the clock: a loaded full run keeps the main actor busy.
@MainActor private func until(_ done: () -> Bool, seconds: Double = 20) async {
    let end = Date().addingTimeInterval(seconds)
    while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
}

/// В7: an empty folder shown, a go-to that fails (a stale favorite, a mistyped path) jumped home — on a server panel,
/// out of the server. It stays now; only a tab with nothing of it shown yet goes home, as before.
@MainActor @Test func aFailedGoToFromAnEmptyFolderStays() async throws {
    let dir = try tempDir(), gone = "/dfm-no-such-folder-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await until { panel.emptyShown?.title == "Empty folder" }
    panel.navigate(to: gone)
    await until { panel.statusError }
    #expect(panel.statusText.hasPrefix(gone), "\(panel.statusText)")
    await until({ panel.path != dir }, seconds: 2)   // the home listing, had it gone there
    #expect(panel.path == dir && panel.emptyShown?.title == "Empty folder", "\(panel.path)")

    let restored = PanelViewController(tabs: [gone], index: 0, showHidden: false)
    restored.loadViewIfNeeded()
    defer { restored.shutdown() }
    await until { restored.path == NSHomeDirectory() }
    #expect(restored.path == NSHomeDirectory(), "a restored folder that's gone: home")

    let tabs = PanelViewController(tabs: [dir, gone], index: 0, showHidden: false)
    tabs.loadViewIfNeeded()
    defer { tabs.shutdown() }
    await until { tabs.emptyShown?.title == "Empty folder" }
    tabs.switchTab(by: 1)
    await until { tabs.path == NSHomeDirectory() }
    #expect(tabs.path == NSHomeDirectory(), "a tab whose folder is gone: home, not the empty tab's folder")
}

/// A search's hits are named from its root (`sub/dir`), not from the panel's folder: Space on a found folder measured
/// `path/sub/dir` — another folder, or none — and a drop onto it went there too. A drop on the results themselves went
/// into the folder behind them, which isn't shown: refused, as F5 into them is. ⌘V there too.
@MainActor @Test func searchHitsFoldersAreMeasuredAndDroppedOnWhereTheyAre() async throws {
    let root = try tempDir(), elsewhere = try tempDir()
    defer { for d in [root, elsewhere] { try? FileManager.default.removeItem(atPath: d) } }
    try FileManager.default.createDirectory(atPath: root + "/sub/dir", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: root + "/sub/dir/f", contents: Data(count: 3000))
    let app = AppDelegate()
    app.panels = [PanelViewController(tabs: [elsewhere], index: 0, showHidden: false), PanelViewController(tabs: [elsewhere], index: 0, showHidden: false)]
    app.panels.forEach { $0.loadViewIfNeeded() }
    defer { app.panels.forEach { $0.shutdown() } }
    let panel = app.panels[0]
    await until { panel.emptyShown?.title == "Empty folder" }
    let flag = panel.beginSearch("tagged “Red”", in: root, root: root)
    panel.addSearchResults([FileItem(name: "sub/dir", kind: .dir, size: 0, mtime: 0, mode: 0o755, flags: 0)], from: flag)
    panel.finishSearch(flag)
    panel.computeAllDirSizes()
    await until { panel.dirSizes["sub/dir"] != nil }
    #expect(panel.dirSizes["sub/dir"] == 3000, "\(panel.dirSizes)")

    #expect(panel.dropTarget(row: 1, op: .on) == root + "/sub/dir", "not \(elsewhere)/sub/dir")
    #expect(panel.dropTarget(row: 1, op: .above) == nil && panel.dropTarget(row: -1, op: .on) == nil && panel.dropTarget(row: 0, op: .on) == nil,
            "the results' background and ..: not a folder")
    app.pasteFiles(move: false)   // refused before the pasteboard is read: the user's own isn't touched
    #expect(panel.statusText == "Search results aren't a folder: paste in one", "\(panel.statusText)")
}
