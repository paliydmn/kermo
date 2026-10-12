import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 13: speed of long actions.

@MainActor private func waitUntil(_ done: () -> Bool) async {
    for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
}
private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t13-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

/// Folder sizes on this Mac are counted as on a server: one walk at a time, which ⎋ and leaving the folder stop.
/// A walk left behind went on to its end (all of `/`).
@MainActor @Test func localFolderSizes() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    for (name, n) in [("one", 3), ("two", 5)] {
        try FileManager.default.createDirectory(atPath: d + "/" + name, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: d + "/\(name)/f", contents: Data(count: n))
    }
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.table.numberOfRows == 2 }
    panel.computeAllDirSizes()
    await waitUntil { panel.dirSizes.count == 2 }
    #expect(panel.dirSizes == ["one": 3, "two": 5])
}

/// After an auto-reload, links to folders showed and sorted as files, and the resolve after it left them there.
@MainActor @Test func reloadKeepsLinksToFoldersWithTheFolders() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    for name in ["docs", "target"] { try FileManager.default.createDirectory(atPath: d + "/" + name, withIntermediateDirectories: true) }
    FileManager.default.createFile(atPath: d + "/a.txt", contents: nil)
    try FileManager.default.createSymbolicLink(atPath: d + "/linkdir", withDestinationPath: d + "/target")
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    func names() -> [String] { (0..<panel.table.numberOfRows).compactMap { panel.item(at: $0)?.name }.filter { $0 != ".." } }
    let folders = ["docs", "linkdir", "target"]
    await waitUntil { names() == folders + ["a.txt"] }   // once resolved
    #expect(names() == folders + ["a.txt"])
    FileManager.default.createFile(atPath: d + "/b.txt", contents: nil)
    panel.reload()
    await waitUntil { names().contains("b.txt") }
    #expect(names() == folders + ["a.txt", "b.txt"])
}
