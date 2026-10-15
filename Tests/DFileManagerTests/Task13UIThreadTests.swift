import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 13: what the main thread no longer does in big folders.

@MainActor private func waitUntil(_ done: () -> Bool) async {
    for _ in 0..<500 { if done() { return }; try? await Task.sleep(for: .milliseconds(10)) }
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

/// A header click on a big listing sorts off the main thread: the rows stay as they were till it's back, and then the
/// cursor is still on its name.
@MainActor @Test func aBigListingSortsOffTheMainThread() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.statusText.contains("0 items") }
    let n = PanelViewController.sortOnMain + 1000
    let flag = panel.beginSearch("t13")
    panel.addSearchResults((0..<n).shuffled().map { item(String(format: "f%05d", $0), size: Int64($0)) }, from: flag)
    panel.finishSearch(flag)
    await waitUntil { panel.listedItems.first?.name == "f00000" }
    #expect(panel.listedItems.map(\.name) == (0..<n).map { String(format: "f%05d", $0) })
    panel.moveCursor(toName: "f03000")
    let before = panel.listedItems.map(\.name)
    panel.table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
    #expect(panel.listedItems.map(\.name) == before)   // not sorted yet: off the main thread
    await waitUntil { panel.listedItems.first?.name != before.first }
    #expect(panel.listedItems.map(\.size) == (0..<n).reversed().map(Int64.init))
    #expect(panel.currentName == "f03000")
}

/// The filter over a big listing, its names folded once off the main thread, shows what each name folded on every
/// key did: typed on, back, a glob, Cyrillic in another case, NFD.
@MainActor @Test func aBigListingsFilterMatchesAsBefore() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.statusText.contains("0 items") }
    let names = (0..<(PanelViewController.sortOnMain + 500)).map { i in
        (i % 3 == 0 ? "Файл-" : i % 3 == 1 ? "file" : "cafe\u{301}") + "\(i).\(["log", "txt"][i % 2])"
    }
    let flag = panel.beginSearch("t13")
    panel.addSearchResults(names.map { item($0) }, from: flag)
    panel.finishSearch(flag)
    let sorted = names.map { item($0) }.sortedForPanel(by: .name, ascending: true).map(\.name)
    await waitUntil { panel.listedItems.map(\.name) == sorted }
    func shown() -> Set<String> { Set(panel.listedItems.map(\.name)) }
    func expected(_ text: String) -> Set<String> { Set(names.filter { Mask(filter: text)!.matches($0) }) }
    panel.beginFilter()
    for text in ["f", "fi", "fil", "file1", "file", "ФАЙЛ-1", "café", "*.LOG", "1*.log", "1"] {
        let want = expected(text)   // once: the wait asks again and again
        panel.filterField.stringValue = text
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.filterField))
        await waitUntil { shown() == want }
        #expect(shown() == want, "\(text)")
    }
}
