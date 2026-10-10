import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

@MainActor
private func waitUntil(_ done: () -> Bool) async {
    for _ in 0..<1000 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
}

/// I8: in search results on a server, ↩ on a hit opens its folder there with the cursor on it, and `..` goes back
/// to the folder searched — not up a level, and never off the server.
@MainActor @Test func serverSearchResultsGoToTheHitsFolder() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-i8p-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dir + "/sub/hit.log", contents: Data())
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    panel.loadRemote(.local(), dir: dir, select: nil)
    await waitUntil { panel.remote?.dir == dir }
    try #require(panel.remote?.dir == dir)

    let flag = panel.beginSearch("*.log in localhost:\(dir)")
    panel.addSearchResults([FileItem(name: "sub/hit.log", kind: .file, size: 0, mtime: 0, mode: 0, flags: 0)], from: flag)
    panel.finishSearch(flag)
    panel.goUp()   // leaves the results for the folder searched
    await waitUntil { panel.searchTitle == nil }
    #expect(panel.remote?.dir == dir && panel.searchTitle == nil)

    let again = panel.beginSearch("*.log in localhost:\(dir)")
    panel.addSearchResults([FileItem(name: "sub/hit.log", kind: .file, size: 0, mtime: 0, mode: 0, flags: 0)], from: again)
    panel.moveCursor(toName: "sub/hit.log")
    panel.openCursor(intoPackage: false)
    await waitUntil { panel.remote?.dir == dir + "/sub" }
    #expect(panel.remote?.dir == dir + "/sub" && panel.searchTitle == nil)
    #expect(panel.remoteCursor?.item.name == "hit.log")
}
