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
    let filters = UserDefaults.standard.object(forKey: "recentFilters")
    defer { UserDefaults.standard.set(filters, forKey: "recentFilters") }
    for i in 1...300 {   // real folders: the count isn't stubbed (another test's stand-in is global)
        try FileManager.default.createDirectory(atPath: d + "/dir\(i)", withIntermediateDirectories: false)
        FileManager.default.createFile(atPath: d + "/dir\(i)/f", contents: Data(count: i))
    }
    FileManager.default.createFile(atPath: d + "/file", contents: Data(count: 7))
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.listedItems.count == 301 }
    panel.computeAllDirSizes()   // all 300 asked for; their sizes come in only after this turn, the filter on by then
    panel.applyFilter("dir1")    // dir1, dir10…dir19, dir100…dir199: 111 folders shown
    let shown = Int64((1...300).filter { String($0).hasPrefix("1") }.reduce(0, +))
    await waitUntil { panel.dirSizes.count == 300 && panel.statusText.contains(PanelViewController.countText(111, "items", shown)) }
    #expect(panel.statusText.contains(PanelViewController.countText(111, "items", shown)), "the hidden folders' sizes aren't in it")
    #expect(panel.dirSizes["dir250"] == 250)
    panel.applyFilter("")
    #expect(panel.statusText.contains(PanelViewController.countText(301, "items", 45_150 + 7)))
}

/// A header click on a big listing sorts off the main thread: the rows stay as they were till it's back, and then the
/// cursor is still on its name.
@MainActor @Test func aBigListingSortsOffTheMainThread() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let sorts = UserDefaults.standard.object(forKey: "folderSort")
    defer { UserDefaults.standard.set(sorts, forKey: "folderSort") }
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.statusText.contains("0 items") }
    let n = PanelViewController.sortOnMain + 1000
    let flag = panel.beginSearch("t13")
    panel.addSearchResults((0..<n).shuffled().map { item(String(format: "f%05d", $0), size: Int64($0)) }, from: flag)
    panel.finishSearch(flag)
    let byName = (0..<n).map { String(format: "f%05d", $0) }
    await waitUntil { panel.listedItems.map(\.name) == byName }
    #expect(panel.listedItems.map(\.name) == byName)
    panel.moveCursor(toName: "f03000")
    let before = panel.listedItems.map(\.name)
    panel.table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
    #expect(panel.listedItems.map(\.name) == before)   // not sorted yet: off the main thread
    await waitUntil { panel.listedItems.first?.name != before.first }
    #expect(panel.listedItems.map(\.size) == (0..<n).reversed().map(Int64.init))
    #expect(panel.currentName == "f03000")
    // The cursor moved on the old rows while it sorts stays where it went.
    panel.table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
    panel.moveCursor(toName: "f00100")
    await waitUntil { panel.listedItems.first?.name == "f00000" }
    #expect(panel.currentName == "f00100")
}

/// A search still running sorts and filters each batch as it comes, also over 5000 hits with a filter typed; done,
/// it shows them sorted.
@MainActor @Test func aRunningSearchFiltersEachBatch() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.statusText.contains("0 items") }
    let flag = panel.beginSearch("t13")
    panel.addSearchResults((0..<6000).map { item(String(format: "x%05d", 5999 - $0)) }, from: flag)
    panel.beginFilter()
    panel.filterField.stringValue = "x0000"
    panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.filterField))
    #expect(panel.listedItems.count == 10)
    panel.addSearchResults([item("x00000b")], from: flag)
    #expect(panel.listedItems.count == 11)
    panel.finishSearch(flag)
    await waitUntil { panel.listedItems.first?.name == "x00000" }
    #expect(panel.listedItems.map(\.name) == (0..<10).map { String(format: "x%05d", $0) }.flatMap { $0 == "x00000" ? [$0, "x00000b"] : [$0] })
}

/// A file renamed from one Unicode spelling to the other ("e" + accent to "é") is a change: the re-list shows it.
@MainActor @Test func aReListSeesAnotherSpellingOfAName() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let nfd = "Cafe\u{301}.txt", nfc = "Caf\u{e9}.txt"
    FileManager.default.createFile(atPath: d + "/" + nfd, contents: Data())
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.listedItems.count == 1 }
    #expect(panel.listedItems.first.map { Array($0.name.utf8) } == Array(nfd.utf8))
    #expect(rename(d + "/" + nfd, d + "/" + nfc) == 0)
    panel.reload()
    await waitUntil { panel.listedItems.first.map { Array($0.name.utf8) } == Array(nfc.utf8) }
    #expect(panel.listedItems.first.map { Array($0.name.utf8) } == Array(nfc.utf8))
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

/// A re-list that finds the folder as shown leaves the rows alone (the same array, nothing re-filtered or redrawn);
/// one that finds a change shows it.
@MainActor @Test func anUnchangedReListLeavesTheRows() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    for name in ["a", "b"] { FileManager.default.createFile(atPath: d + "/" + name, contents: Data()) }
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.listedItems.count == 2 }
    try await Task.sleep(for: .milliseconds(300))   // the first listing's link resolve and git look are done
    func rowsBuffer() -> UnsafeRawPointer? { panel.listedItems.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) } }
    let before = rowsBuffer()
    panel.reload()
    try await Task.sleep(for: .seconds(1))   // nothing to wait for: it must not come
    #expect(rowsBuffer() == before && panel.listedItems.map(\.name) == ["a", "b"])
    FileManager.default.createFile(atPath: d + "/c", contents: Data())
    panel.reload()
    await waitUntil { panel.listedItems.count == 3 }
    #expect(rowsBuffer() != before)
}
