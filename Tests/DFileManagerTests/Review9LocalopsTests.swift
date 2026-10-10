import Foundation
@testable import DFMCore
import Testing
@testable import DFileManager

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r9local-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
private func write(_ path: String, _ text: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
}
private func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

/// L9: undo of a move to another volume (Mac → a stick) can't be a rename (EXDEV): it goes back as a move job —
/// one per folder, plus one per item that came back under another name (Keep Both). There's no second volume
/// here, so the device check is swapped for one that says "another volume".
@Test func undoOfMoveAcrossVolumesRunsMoveJobs() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    // Undo pairs: from = where the move put it, to = where it was.
    write(d + "/stick/a.txt", "a"); write(d + "/stick/dir/x.txt", "x"); write(d + "/stick/b 2.txt", "b")
    try! FileManager.default.createDirectory(atPath: d + "/mac", withIntermediateDirectories: true)
    let pairs = [(from: d + "/stick/a.txt", to: d + "/mac/a.txt"), (from: d + "/stick/dir", to: d + "/mac/dir"),
                 (from: d + "/stick/b 2.txt", to: d + "/mac/b.txt")]

    let (renames, jobs) = AppDelegate.splitMoves(pairs) { _, _ in false }
    #expect(renames.isEmpty)
    #expect(jobs.count == 2 && jobs.allSatisfy { $0.kind == .move && $0.destDir == d + "/mac" })
    for job in jobs { job.run() }
    #expect(read(d + "/mac/a.txt") == "a" && read(d + "/mac/dir/x.txt") == "x" && read(d + "/mac/b.txt") == "b")
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: d + "/stick")) ?? ["?"]).isEmpty)

    // Same volume: a rename, as before.
    let same = AppDelegate.splitMoves([(from: d + "/mac/a.txt", to: d + "/stick/a.txt")])
    #expect(same.renames.count == 1 && same.jobs.isEmpty)
}

/// L9: the redo after a cross-volume undo moves what the undo actually moved back. Here a new a.txt took the old
/// name on the Mac, so the undo came back as "a 2.txt" (Keep Both): redo moves "a 2.txt" to the stick and leaves
/// the user's new a.txt alone — not the expected mac/a.txt, which would carry their file off without a prompt.
@Test func redoAfterKeepBothMovesWhatTheUndoMoved() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    write(d + "/stick/a.txt", "MOVED"); write(d + "/mac/a.txt", "USER-NEW")
    let (renames, jobs) = AppDelegate.splitMoves([(from: d + "/stick/a.txt", to: d + "/mac/a.txt")]) { _, _ in false }
    #expect(AppDelegate.moved(renames, jobs) == nil)   // not run yet: nothing to redo
    for job in jobs { job.resolveConflict = { _ in (.keepBoth, false) }; job.run() }
    #expect(read(d + "/mac/a 2.txt") == "MOVED")

    let done = AppDelegate.moved(renames, jobs) ?? []
    #expect(done.map(\.from) == [d + "/stick/a.txt"] && done.map(\.to) == [d + "/mac/a 2.txt"])
    let redo = AppDelegate.splitMoves(done.map { (from: $0.to, to: $0.from) }) { _, _ in false }
    for job in redo.jobs { job.run() }
    #expect(read(d + "/mac/a.txt") == "USER-NEW" && read(d + "/stick/a.txt") == "MOVED")
    #expect(!FileManager.default.fileExists(atPath: d + "/mac/a 2.txt"))

    // Skipped (or cancelled before it ran): nothing moved, nothing to redo.
    let skip = AppDelegate.splitMoves([(from: d + "/stick/a.txt", to: d + "/mac/a.txt")]) { _, _ in false }
    for job in skip.jobs { job.run() }   // the default answer to a conflict is Skip
    #expect(AppDelegate.moved(skip.renames, skip.jobs)?.isEmpty == true)
    let queued = AppDelegate.splitMoves([(from: d + "/stick/a.txt", to: d + "/mac/a.txt")]) { _, _ in false }
    queued.jobs.forEach { $0.cancel() }
    #expect(AppDelegate.moved(queued.renames, queued.jobs)?.isEmpty == true)
}

/// L10: undo of a copy where the Trash refuses (SMB, a volume without one) reports why instead of doing nothing.
@Test func undoOfCopyReportsWhatCouldNotBeTrashed() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let (trashed, errors) = AppDelegate.trash([d + "/gone.txt"])   // nothing there: trashItem throws, nothing reaches the Trash
    #expect(trashed.isEmpty)
    #expect(errors.count == 1 && errors[0].hasPrefix("“gone.txt”: "), "\(errors)")
}
