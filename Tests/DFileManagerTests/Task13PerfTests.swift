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
