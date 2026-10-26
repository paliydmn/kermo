import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

/// R13: two server calls waiting on one panel (New folder still going when F4 starts): the status line keeps the one
/// still running when the other ends, and ⎋ cancels both.
@MainActor @Test func overlappingBusyCallsStayShownAndBothCancel() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dfm-busy-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: dir + "/f", contents: nil)
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    for _ in 0..<500 where panel.table.numberOfRows < 2 { try await Task.sleep(for: .milliseconds(10)) }   // "..", then "f": the folder's own load, which clears the status line, done
    // Waits for ⎋, or gives up after a few seconds and succeeds (a call ⎋ didn't reach).
    let untilCancelled: @Sendable (CancelFlag) -> Int = { flag in
        let end = Date() + 3
        while !flag.isCancelled && Date() < end { usleep(10_000) }
        return 1
    }
    let older = Task { await panel.busy("New folder on host…", untilCancelled) }
    while panel.busyMessage != "New folder on host… ⎋ cancels" { await Task.yield() }
    _ = await panel.busy("Checking “/x”…") { _ in 2 }
    #expect(panel.busyMessage == "New folder on host… ⎋ cancels")

    let newer = Task { await panel.busy("Downloading “f”…", untilCancelled) }
    while panel.busyMessage != "Downloading “f”… ⎋ cancels" { await Task.yield() }
    let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                               characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    #expect(panel.table.onKey?(esc) == true)
    for r in [await older.value, await newer.value] { #expect(throws: CancellationError.self) { try r.get() } }
    #expect(panel.busyMessage == nil)
}

/// A folder's re-list (its watcher, a save's reload) ended by setting no message at all: an operation still running
/// on the panel lost its "… ⎋ cancels", and a message just flashed ("no history: file over 5 MB") went within a
/// listing's time. Both stay now; marking (the user's own doing) still replaces the flash.
@MainActor @Test func reListKeepsTheStatusMessages() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dfm-busy-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: dir + "/f", contents: nil)
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    for _ in 0..<500 where panel.table.numberOfRows < 2 { try await Task.sleep(for: .milliseconds(10)) }
    func reList(adding name: String) async throws {
        FileManager.default.createFile(atPath: dir + "/" + name, contents: nil)
        panel.reload()
        for _ in 0..<500 where !panel.listedItems.contains(where: { $0.name == name }) { try await Task.sleep(for: .milliseconds(10)) }
        try #require(panel.listedItems.contains { $0.name == name })
    }

    let running = Task { await panel.busy("Counting folder sizes…") { flag in while !flag.isCancelled { usleep(10_000) } } }
    while panel.busyMessage == nil { await Task.yield() }
    try await reList(adding: "g")
    #expect(panel.busyMessage == "Counting folder sizes… ⎋ cancels" && panel.statusText == "Counting folder sizes…", "\(panel.statusText)")
    #expect(!panel.cancelButton.isHidden, "the ⎋ hint is a red Cancel button")
    panel.view.layoutSubtreeIfNeeded()
    #expect(panel.cancelButton.alignmentRect(forFrame: panel.cancelButton.frame).height >= 13, "\(panel.cancelButton.frame)")
    panel.cancelButton.performClick(nil)
    #expect((try? await running.value.get()) == nil, "cancelled")
    #expect(panel.cancelButton.isHidden)

    panel.flashTime = 600   // a loaded Mac's re-list may take longer than the usual 2.5 s
    panel.flash("Saved · no history: file over 5 MB")
    try await reList(adding: "h")
    #expect(panel.statusText == "Saved · no history: file over 5 MB")
    panel.moveCursor(toName: "f")
    panel.toggleMark(move: 0)
    #expect(panel.statusText == "1 marked", "\(panel.statusText)")
}

/// A running wait can say something else midway (a save's check after the file is replaced: "Checking …", no "⎋
/// cancels"); when it ends, the status line is cleared as before, or shows a wait still running. Ended already: nothing.
@MainActor @Test func aBusyWaitCanSaySomethingElse() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dfm-busy-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: dir + "/f", contents: nil)
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    for _ in 0..<500 where panel.table.numberOfRows < 2 { try await Task.sleep(for: .milliseconds(10)) }   // "..", "f": its own load done
    let flag = CancelFlag(), go = CancelFlag()
    let save = Task { await panel.busy("Saving “a.conf” to web…", flag: flag) { _ in while !go.isCancelled { usleep(5_000) }; return 1 } }
    while panel.busyMessage != "Saving “a.conf” to web… ⎋ cancels" { await Task.yield() }
    panel.busy(flag, says: "Checking “a.conf” on web (nginx -t)…")
    #expect(panel.busyMessage == "Checking “a.conf” on web (nginx -t)…")
    go.cancel()
    _ = await save.value
    #expect(panel.busyMessage == nil)
    panel.busy(flag, says: "late")
    #expect(panel.busyMessage == nil, "ended: nothing")
}
