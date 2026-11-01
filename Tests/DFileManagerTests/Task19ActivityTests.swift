import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 19: the Activity list (⌥⌘J) — finished jobs kept with what they left out, Retry Failed, no modal alert.

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-19-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
@MainActor private func waitUntil(timeout: Double = 10, _ done: () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
}
private func write(_ path: String, _ text: String = "x") {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

/// A file that can't be read, deep in a copied folder: filed under the item the copy was on (source and destination),
/// apart from the notes; Retry Failed's job copies just that one, where it was going, asking nothing.
@Test func aFailedFileIsFiledWithItsDestinationAndRetriedAlone() throws {
    let d = tempDir()
    defer { chmod(d + "/src/d/sub/bad.txt", 0o644); try? FileManager.default.removeItem(atPath: d) }
    write(d + "/src/d/a.txt")
    write(d + "/src/d/sub/b.txt")
    write(d + "/src/d/sub/bad.txt", "bad")
    chmod(d + "/src/d/sub/bad.txt", 0)
    try FileManager.default.createDirectory(atPath: d + "/dst", withIntermediateDirectories: true)
    let job = FileJob(.copy, sources: [d + "/src/d"], destDir: d + "/dst")
    job.resolveError = { _, _ in (.skip, false) }
    job.run()
    let p = job.progress
    #expect(p.failed == [FileJob.Failure(path: d + "/src/d/sub/bad.txt", message: "Permission denied", src: d + "/src/d/sub/bad.txt", dst: d + "/dst/d/sub/bad.txt")])
    #expect(p.recent.count == 2 && p.recent.allSatisfy { $0.path.hasSuffix("a.txt") || $0.path.hasSuffix("b.txt") } && p.recent.allSatisfy { $0.size == 1 })
    #expect(p.topsBegun == 1)

    let entry = ActivityEntry(job, title: "Copy “d” → dst", started: Date())
    #expect(entry.result == .errors && entry.errorCount == 1 && entry.notes.isEmpty && !entry.seen && entry.canRetry)
    let groups = ActivityEntry.retryGroups(entry.failed)
    #expect(groups.count == 1 && groups[0].dir == d + "/dst/d/sub" && groups[0].sources == [d + "/src/d/sub/bad.txt"] && groups[0].name == "bad.txt")

    chmod(d + "/src/d/sub/bad.txt", 0o644)
    let again = FileJob(.copy, sources: groups[0].sources, destDir: groups[0].dir, targetName: groups[0].name)
    again.resolveConflict = { _ in Issue.record("asked about a clash"); return (.skip, false) }
    again.run()
    #expect(again.progress.errors.isEmpty)
    #expect(FileManager.default.contents(atPath: d + "/dst/d/sub/bad.txt") == Data("bad".utf8))
}

/// A move that stopped half way (a folder it couldn't write into): Retry Failed moves what's left, and only that —
/// the items already moved aren't sources any more, so none of them comes back as "No such file".
@Test func retryAfterAHalfDoneMoveTakesOnlyWhatsLeft() throws {
    let d = tempDir()
    defer { chmod(d + "/dst/d/x", 0o755); try? FileManager.default.removeItem(atPath: d) }
    write(d + "/src/d/a.txt", "a")
    write(d + "/src/d/x/late.txt", "late")
    try FileManager.default.createDirectory(atPath: d + "/dst/d/x", withIntermediateDirectories: true)
    chmod(d + "/dst/d/x", 0o555)
    let job = FileJob(.move, sources: [d + "/src/d"], destDir: d + "/dst")
    job.resolveConflict = { c in (c.bothDirs ? .overwrite : .skip, false) }
    job.resolveError = { _, _ in (.skip, false) }
    job.run()
    #expect(FileManager.default.fileExists(atPath: d + "/dst/d/a.txt") && !FileManager.default.fileExists(atPath: d + "/src/d/a.txt"))
    let entry = ActivityEntry(job, title: "Move", started: Date())
    let failed = entry.failed.filter { $0.dst != nil }
    #expect(failed.map(\.src) == [d + "/src/d/x/late.txt"])

    chmod(d + "/dst/d/x", 0o755)
    for g in ActivityEntry.retryGroups(entry.failed) {
        let again = FileJob(.move, sources: g.sources, destDir: g.dir, targetName: g.name)
        again.resolveError = { _, _ in (.abort, false) }
        again.run()
        #expect(again.progress.errors.isEmpty)
    }
    #expect(FileManager.default.contents(atPath: d + "/dst/d/x/late.txt") == Data("late".utf8))
    #expect(!FileManager.default.fileExists(atPath: d + "/src/d/x/late.txt"))
}

/// What a job said that isn't a failed item ("kept", "mode and date not kept"): a note, never retried.
@Test func notesAreKeptApartFromFailures() {
    let job = FileJob(.copy, sources: ["/nowhere/a"], destDir: "/tmp")
    job.update { $0.errors = ["/x: appeared while this ran — kept"]; $0.state = .done }
    let e = ActivityEntry(job, title: "Copy", started: Date())
    #expect(e.result == .errors && e.failed.isEmpty && e.notes == ["/x: appeared while this ran — kept"] && !e.canRetry)
    #expect(e.errorLines == "/x: appeared while this ran — kept")
}

/// activity.json: the newest first, 100 at most, read back as written; "seen" and removal are saved too.
@MainActor @Test func historyIsKeptAcrossLaunchesAndCapped() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let h = ActivityHistory(dir: d)
    let job = FileJob(.copy, sources: ["/a"], from: .sftp(SFTPTarget(host: "me@dfm-19.invalid")), to: .local, destDir: "/tmp")
    job.update { $0.state = .failed; $0.errors = ["/a: Permission denied"]; $0.failed = [.init(path: "/a", message: "Permission denied", src: "/a", dst: "/tmp/a")] }
    for i in 0..<105 { h.add(ActivityEntry(job, title: "job \(i)", started: Date())) }
    #expect(h.entries.count == ActivityEntry.limit && h.entries.first?.title == "job 104" && h.unseen == 100)
    h.markSeen()
    h.remove(h.entries.last!.id)
    Config.flush()
    let read = ActivityHistory(dir: d)
    #expect(read.entries == h.entries && read.entries.count == 99 && read.unseen == 0)
    #expect(read.entries[0].from == .sftp(SFTPTarget(host: "me@dfm-19.invalid")) && read.entries[0].failed[0].dst == "/tmp/a")
    var st = stat()
    #expect(lstat(d + "/activity.json", &st) == 0 && st.st_mode & 0o777 == 0o600)
}

/// A job with errors no longer stops the window with an alert: its row stays, saying so, the entry is unseen (the
/// toolbar button's dot, the Dock's badge), and the job itself is let go. A copy without any shows ✓ for a moment, then its row goes.
@MainActor @Test func finishedJobsLeaveARowNotASheet() async throws {
    _ = NSApplication.shared
    let d = tempDir()
    defer { chmod(d + "/bad", 0o644); try? FileManager.default.removeItem(atPath: d) }
    write(d + "/bad")
    write(d + "/good")
    chmod(d + "/bad", 0)
    try FileManager.default.createDirectory(atPath: d + "/out", withIntermediateDirectories: true)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let ops = OpsController(window: window) { _ in }
    let job = FileJob(.copy, sources: [d + "/bad", d + "/good"], destDir: d + "/out")
    ops.enqueue(job, title: "Copy 2 items → out")
    await waitUntil { window.attachedSheet != nil }   // the error, while it runs: Skip / Retry / Abort, as before
    let sheet = try #require(window.attachedSheet)
    ops.changed()   // other tests' queues share the Dock: say it again, then look before anything else runs
    #expect(NSApp.dockTile.contentView != nil, "a bar on the Dock icon while it runs")
    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)   // Skip
    await waitUntil { ops.pending == 0 }
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(window.attachedSheet == nil, "no \"Finished with 1 error\" alert after it")
    #expect(ops.history.entries.count == 1 && ops.history.unseen == 1 && ops.history.entries[0].failed.count == 1)
    #expect(!ops.view.isHidden && ops.view.arrangedSubviews.count == 1, "the row saying it finished with errors")
    #expect(ops.toolbarItem.toolTip?.contains("finished with errors") == true)
    ops.changed()
    #expect(NSApp.dockTile.badgeLabel == "1" && NSApp.dockTile.contentView == nil, "a red 1 on the Dock icon, no bar")
    ops.history.markSeen()
    ops.changed()
    #expect(NSApp.dockTile.badgeLabel == nil, "looked at: the badge goes")

    let ok = FileJob(.copy, sources: [d + "/good"], destDir: d + "/out2")
    try FileManager.default.createDirectory(atPath: d + "/out2", withIntermediateDirectories: true)
    ops.enqueue(ok, title: "Copy “good” → out2")
    await waitUntil { ops.pending == 0 }
    #expect(ops.view.arrangedSubviews.count == 2 && ops.history.entries[0].result == .done)
    await waitUntil(timeout: 5) { ops.view.arrangedSubviews.count == 1 }
    #expect(ops.view.arrangedSubviews.count == 1, "✓ goes after a moment; the one with errors stays")
}

/// ▸ on a running job's row opens its files: the last ones done and the picked items still to come.
/// `enqueue`'s `then` (a Tools upload waits on it): once each job is over — as it's cancelled while still queued (it
/// never starts), and as it finishes.
@MainActor @Test func aJobsThenRunsWhenItsOver() async throws {
    _ = NSApplication.shared
    let d = tempDir()
    defer { chmod(d + "/bad", 0o644); try? FileManager.default.removeItem(atPath: d) }
    write(d + "/bad")
    write(d + "/good")
    chmod(d + "/bad", 0)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let ops = OpsController(window: window) { _ in }
    var over: [String] = []
    ops.enqueue(FileJob(.copy, sources: [d + "/bad"], destDir: d + "/out"), title: "first") { over.append("first \($0.progress.state)") }
    ops.enqueue(FileJob(.copy, sources: [d + "/good"], destDir: d + "/out"), title: "second") { over.append("second \($0.isCancelled)") }
    await waitUntil { window.attachedSheet != nil }   // the first waits on its error: the second stays queued behind it
    let row = try #require(ops.jobRows.last)
    let cancel = try #require(row.view.subviews.compactMap { $0 as? NSStackView }.flatMap(\.arrangedSubviews).compactMap { $0 as? NSButton }.first { $0.toolTip == "Cancel" })
    cancel.sendAction(cancel.action, to: cancel.target)
    #expect(over == ["second true"])
    window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn)   // Skip
    await waitUntil { over.count == 2 }
    #expect(over == ["second true", "first done"])
}

@MainActor @Test func aRowOpensToItsFiles() {
    _ = NSApplication.shared
    let job = FileJob(.copy, sources: ["/a/one", "/a/two", "/a/three"], destDir: "/tmp")
    job.update { $0.state = .running; $0.doneFiles = 7; $0.recent = [.init(path: "/a/one/x.txt", size: 4_800_000), .init(path: "/a/one/y.txt", size: 12)]; $0.currentSize = 3_400_000; $0.currentDone = 1_428_000; $0.current = "z.txt"; $0.topsBegun = 1 }
    let row = JobRow(job: job, title: "Copy", onCancel: {}, onStartNow: {})
    #expect(row.files.isHidden)
    row.toggleFiles()
    let text = row.files.stringValue
    #expect(!row.files.isHidden)
    #expect(text.contains("5 more done") && text.contains("x.txt") && text.contains("y.txt") && text.contains("z.txt"))
    #expect(text.contains("two") && text.contains("three"), "the picked items not begun")
    #expect(text.contains("4,8 MB") || text.contains("4.8 MB"), "a done file's size")
}

/// ⌥⌘J in the View menu (and ⌘⇧P), and the toolbar's button.
@MainActor @Test func activityHasAShortcutAndAToolbarButton() {
    _ = NSApplication.shared
    let app = AppDelegate()
    let c = app.makeCommands().first { $0.id == "view.activity" }
    #expect(c?.keys == [Shortcut("cmd+opt+j")!] && c?.menu == "View")
    #expect(app.toolbarDefaultItemIdentifiers(NSToolbar()).contains(OpsController.toolbarID))
}

/// Many folders that are there already: Merge with "Apply to all remaining folders" merges the rest unasked — but each
/// file that clashes inside is still asked about (a folders' Merge must never overwrite files on its own).
@Test func mergeForAllFoldersStillAsksAboutFiles() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    for f in ["a", "b", "c"] {
        write(d + "/src/\(f)/new.txt", "new")
        write(d + "/src/\(f)/same.txt", "new")
        write(d + "/dst/\(f)/same.txt", "old")
    }
    let job = FileJob(.copy, sources: ["a", "b", "c"].map { d + "/src/" + $0 }, destDir: d + "/dst")
    let asked = NSLock(), box = Box()
    job.resolveConflict = { c in
        asked.withLock { c.bothDirs ? (box.folders += 1) : (box.files += 1) }
        return c.bothDirs ? (.overwrite, true) : (.skip, false)
    }
    job.run()
    #expect(box.folders == 1, "Merge for all: asked once")
    #expect(box.files == 3, "each file inside still asked")
    #expect(FileManager.default.contents(atPath: d + "/dst/c/new.txt") == Data("new".utf8))
    #expect(FileManager.default.contents(atPath: d + "/dst/c/same.txt") == Data("old".utf8))
}
private final class Box: @unchecked Sendable { var folders = 0, files = 0 }
