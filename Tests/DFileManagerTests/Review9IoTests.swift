import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

/// P9: calls stuck in the kernel — a hung server's ssh, a dead NFS/SMB mount — one per core, through the panel's own
/// off-main path: a local folder still lists. They used to hold every thread of the Swift concurrency pool.
@MainActor @Test func hungCallsDontStallLocalListings() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dfm-io-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: dir + "/f", contents: nil)
    let hung = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    hung.loadViewIfNeeded()
    for _ in 0..<500 where hung.table.numberOfRows < 2 { try await Task.sleep(for: .milliseconds(10)) }

    let n = ProcessInfo.processInfo.activeProcessorCount
    let stuck = DispatchSemaphore(value: 0), entered = Counter()
    var calls: [Task<Result<Bool, Error>, Never>] = []
    defer { for _ in 0..<n { stuck.signal() } }   // also when an expectation below fails
    for _ in 0..<n {
        calls.append(Task { await hung.busy("Listing on hung host…") { _ in
            entered.add()
            return stuck.wait(timeout: .now() + 30) == .success
        } })
    }
    for _ in 0..<500 where entered.value < n { try await Task.sleep(for: .milliseconds(10)) }
    #expect(entered.value == n)

    let local = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    local.loadViewIfNeeded()
    for _ in 0..<300 where local.table.numberOfRows < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(local.table.numberOfRows == 2, "the local folder listed while \(n) calls hang")

    for _ in 0..<n { stuck.signal() }
    for c in calls { #expect(try await c.value.get()) }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func add() { lock.withLock { n += 1 } }
}

/// P9: while a folder's listing hangs (a dead mount), panel reloads of it wait for one more listing instead of
/// each taking a thread; once it returns, that one listing shows what changed meanwhile. Another folder lists at once.
@MainActor @Test func panelReloadsOfAHungFolderShareOneListing() async throws {
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dfm-io-\(UUID().uuidString)").path, other = dir + "-other"
    for d in [dir, other] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
    defer { for d in [dir, other] { try? fm.removeItem(atPath: d) } }
    fm.createFile(atPath: dir + "/a", contents: nil)
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    for _ in 0..<500 where panel.table.numberOfRows < 2 { try await Task.sleep(for: .milliseconds(10)) }

    let stuck = DispatchSemaphore(value: 0), entered = Counter()
    defer { stuck.signal() }
    let hung = Task { [path = panel.path] in await PanelViewController.listings.run(path) {
        entered.add()
        _ = stuck.wait(timeout: .now() + 10)
        return .failure(CocoaError(.fileReadUnknown))
    } }
    for _ in 0..<300 where entered.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
    for _ in 0..<20 { panel.reload() }
    fm.createFile(atPath: dir + "/new", contents: nil)
    try await Task.sleep(for: .milliseconds(200))
    #expect(panel.table.numberOfRows == 2, "nothing listed while the folder hangs")

    let side = PanelViewController(tabs: [other], index: 0, showHidden: false)
    side.loadViewIfNeeded()
    fm.createFile(atPath: other + "/f", contents: nil)
    for _ in 0..<300 where side.table.numberOfRows < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(side.table.numberOfRows == 2, "another folder lists while that one hangs")

    stuck.signal()
    _ = await hung.value
    for _ in 0..<300 where panel.table.numberOfRows < 3 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(panel.table.numberOfRows == 3, "the queued reloads got a fresh listing, with the new file")
}
