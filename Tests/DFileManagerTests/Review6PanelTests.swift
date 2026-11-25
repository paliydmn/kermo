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

/// В7: an empty folder shown, a go-to that fails (a stale favorite, a mistyped path) jumped home — on a server panel,
/// out of the server. It stays now; only a tab with nothing of it shown yet goes home, as before.
@MainActor @Test func aFailedGoToFromAnEmptyFolderStays() async throws {
    let dir = try tempDir(), gone = "/dfm-no-such-folder-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await until { panel.emptyShown?.title == "Empty folder" }
    try #require(panel.emptyShown?.title == "Empty folder", "listed: else it goes home, as a tab with nothing shown yet")
    panel.navigate(to: gone)
    await until { panel.statusError }
    #expect(panel.statusText.hasPrefix(gone), "\(panel.statusText)")
    await until(2) { panel.path != dir }   // the home listing, had it gone there
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

/// ⌘F (or a sidebar tag) inside an archive searched the folder around it, as its dialog says, but the archive stayed:
/// the header said results while ⌫ and ↩ went by the archive — ⌫ showed its entries under the search's title.
@MainActor @Test func aSearchFromAnArchiveLeavesIt() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: dir + "/a.txt", contents: Data("a".utf8))
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.arguments = ["-q", "z.zip", "a.txt"]
    zip.currentDirectoryURL = URL(fileURLWithPath: dir)
    try zip.run()
    zip.waitUntilExit()
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await until { panel.listedItems.count == 2 }
    panel.enterArchive(dir + "/z.zip")
    await until { panel.archive != nil }
    let flag = panel.beginSearch("*.txt", in: dir, root: dir)
    panel.addSearchResults([FileItem(name: "a.txt", kind: .file, size: 1, mtime: 0, mode: 0o644, flags: 0)], from: flag)
    panel.finishSearch(flag)
    #expect(panel.archive == nil && panel.searchTitle != nil)
    panel.goUp()   // leaves the results for the folder
    await until { panel.searchTitle == nil && panel.listedItems.count == 2 }
    #expect(panel.searchTitle == nil && panel.archive == nil && panel.path == dir)
}

/// What the panel shows is one answer, in the order its header and path have always read the optionals: a list, then
/// search results (a server's too), an archive, a server, a parked tab, this Mac's folder.
@MainActor @Test func whatThePanelShowsGoesByOneOrder() {
    final class Rows: ListSource {
        let title = "Rows", target = SFTPTarget.local(), columns: [ListColumn] = [], content: ListContent? = nil
        func read(_ cancel: CancelFlag) async throws -> ListContent { ListContent(rows: []) }
    }
    let web = SFTPTarget(host: "web"), list = ListPanel(Rows())
    func at(list: ListPanel? = nil, search: Bool = false, archive: Bool = false, remote: SFTPTarget? = nil, parked: SFTPTarget? = nil) -> String {
        switch PanelViewController.showing(list: list, search: search, archive: archive, remote: remote.map { ($0, "/srv") },
                                         parked: parked.map { ($0, "/etc") }, path: "/tmp") {
        case .list: "list"
        case .results(let t): "results \(t?.host ?? "-")"
        case .archive: "archive"
        case .server(let t, let dir): "server \(t.host):\(dir)"
        case .parked(let t, let dir): "parked \(t.host):\(dir)"
        case .folder(let p): "folder \(p)"
        }
    }
    #expect(at(list: list, search: true, archive: true, remote: web, parked: web) == "list")
    #expect(at(search: true, archive: true, remote: web) == "results web", "a server's search results")
    #expect(at(search: true) == "results -")
    #expect(at(archive: true, remote: web, parked: web) == "archive")
    #expect(at(remote: web, parked: web) == "server web:/srv")
    #expect(at(parked: web) == "parked web:/etc")
    #expect(at() == "folder /tmp")
    #expect(PanelViewController.Showing.folder("/").isFolderListing && PanelViewController.Showing.server(web, dir: "/").isFolderListing)
    #expect(!PanelViewController.Showing.results(server: nil).isFolderListing && !PanelViewController.Showing.parked(web, dir: "/").isFolderListing)
}
