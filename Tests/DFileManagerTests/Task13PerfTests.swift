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

/// ⎋ in the middle of a local count stops it there: the folder being counted gets no size (a part of it isn't one), the
/// ones after it aren't counted. The count of the first one waits until ⎋ came.
@MainActor @Test func escStopsALocalCountMidway() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    for name in ["one", "two"] { try FileManager.default.createDirectory(atPath: d + "/" + name, withIntermediateDirectories: true) }
    let entered = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
    final class Counted: @unchecked Sendable { let lock = NSLock(); var names: [String] = [] }
    let counted = Counted()
    let real = PanelViewController.measureLocal
    PanelViewController.measureLocal = { path, isCancelled in
        guard path.hasPrefix(d) else { return real(path, isCancelled) }   // another test's
        counted.lock.withLock { counted.names.append((path as NSString).lastPathComponent) }
        entered.signal()
        go.wait()
        return real(path, isCancelled)
    }
    defer { PanelViewController.measureLocal = real }
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.table.numberOfRows == 2 }
    panel.computeAllDirSizes()
    await withCheckedContinuation { c in DispatchQueue.global().async { entered.wait(); c.resume() } }
    panel.cancelBusy()
    go.signal()
    try await Task.sleep(for: .milliseconds(300))
    #expect(counted.lock.withLock { counted.names } == ["one"] && panel.dirSizes.isEmpty)
    #expect(!panel.statusText.contains("Counting"))
}

/// A server folder du couldn't read all of is "at least" its size.
@MainActor @Test func aPartialSizeIsAtLeast() {
    let dir = FileItem(name: "var", kind: .dir, size: 0, mtime: 0, mode: 0o755, flags: 0)
    #expect(PanelViewController.sizeText(dir, measured: 2048, partial: true).hasPrefix("≥ "))
    #expect(!PanelViewController.sizeText(dir, measured: 2048).hasPrefix("≥"))
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

/// A walk on this Mac that takes a moment doesn't flash "Counting folder sizes…": the message waits 0.4 s (⎋ doesn't).
@MainActor @Test func busyMessageCanWait() async {
    let d = tempDir()   // its own: the shared temp folder changes all the time, and each reload says "Loading…"
    defer { try? FileManager.default.removeItem(atPath: d) }
    FileManager.default.createFile(atPath: d + "/f", contents: nil)
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { (0..<panel.table.numberOfRows).contains { panel.item(at: $0)?.name == "f" } }   // listed: no "Loading…" to come
    let started = Date(), gate = DispatchSemaphore(value: 0), running = CancelFlag()
    let walk = Task { await panel.busy("Slow", after: 0.4) { _ in running.cancel(); gate.wait() } }
    await waitUntil { running.isCancelled }
    if Date().timeIntervalSince(started) < 0.3 { #expect(panel.busyMessage == nil, "not yet") }
    await waitUntil { panel.busyMessage != nil }
    #expect(panel.busyMessage == "Slow ⎋ cancels")
    gate.signal()
    _ = await walk.value
    #expect(panel.busyMessage == nil)
}
