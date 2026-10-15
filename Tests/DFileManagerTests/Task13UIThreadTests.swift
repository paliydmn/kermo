import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 13: what the main thread no longer does in big folders.

@MainActor private func waitUntil(_ done: () -> Bool) async {
    for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
}
private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t13ui-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
private func item(_ name: String, _ kind: FileItem.Kind = .file, size: Int64 = 0) -> FileItem {
    FileItem(name: name, kind: kind, size: size, mtime: 0, mode: 0o644, flags: 0)
}

/// All sizes at once add up to what's listed: a folder the filter hides isn't in the total until it's shown again.
@MainActor @Test func allSizesAddUpWhatsListed() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    for i in 1...300 {   // real folders: the count isn't stubbed (another test's stand-in is global)
        try FileManager.default.createDirectory(atPath: d + "/dir\(i)", withIntermediateDirectories: false)
        FileManager.default.createFile(atPath: d + "/dir\(i)/f", contents: Data(count: i))
    }
    FileManager.default.createFile(atPath: d + "/file", contents: Data(count: 7))
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.listedItems.count == 301 }
    panel.applyFilter("dir1")   // dir1, dir10…dir19, dir100…dir199: 111 folders
    panel.computeAllDirSizes()
    await waitUntil { panel.dirSizes.count == 111 }
    let shown = Int64((1...300).filter { String($0).hasPrefix("1") }.reduce(0, +))
    #expect(panel.statusText.contains(PanelViewController.countText(111, "items", shown)))
    #expect(panel.dirSizes["dir150"] == 150)
    panel.applyFilter("")
    #expect(panel.statusText.contains(PanelViewController.countText(301, "items", shown + 7)))
    panel.computeAllDirSizes()
    await waitUntil { panel.dirSizes.count == 300 }
    #expect(panel.statusText.contains(PanelViewController.countText(301, "items", 45_150 + 7)))
}
