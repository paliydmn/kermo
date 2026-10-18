import Foundation
import Testing
@testable import DFMCore

/// Each test gets a fresh sandbox dir with `src/` and `dst/`.
private struct Sandbox {
    let root: String
    var src: String { root + "/src" }
    var dst: String { root + "/dst" }

    init() {
        root = NSTemporaryDirectory() + "dfm-test-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(atPath: root + "/dst", withIntermediateDirectories: true)
    }

    func write(_ rel: String, _ text: String, mtime: Date? = nil) {
        let path = root + "/" + rel
        try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
        if let mtime { try! FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path) }
    }
    func read(_ rel: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: root + "/" + rel))).map { String(decoding: $0, as: UTF8.self) }
    }
    func exists(_ rel: String) -> Bool { FileJob.lstat(root + "/" + rel) != nil }
    func p(_ rel: String) -> String { root + "/" + rel }
}

@discardableResult private func run(_ kind: FileJob.Kind, _ sources: [String], to dir: String? = nil, name: String? = nil,
                 conflict: FileJob.ConflictChoice = .skip) -> FileJob {
    let job = FileJob(kind, sources: sources, destDir: dir, targetName: name)
    job.resolveConflict = { _ in (conflict, true) }
    job.run()
    return job
}

@Test func copiesFilePreservingContentAndMtime() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    let old = Date(timeIntervalSince1970: 1_000_000_000)
    s.write("src/a.txt", "hello", mtime: old)
    let job = run(.copy, [s.p("src/a.txt")], to: s.dst)
    #expect(s.read("dst/a.txt") == "hello")
    #expect(s.exists("src/a.txt"))
    let m = try! FileManager.default.attributesOfItem(atPath: s.p("dst/a.txt"))[.modificationDate] as! Date
    #expect(m == old)
    #expect(job.progress.state == .done)
    #expect(job.progress.doneFiles == 1 && job.progress.doneBytes == 5)
}

@Test func copiesTreeWithSymlinkAndXattr() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/tree/a.txt", "a")
    s.write("src/tree/sub/b.txt", "bb")
    try! FileManager.default.createSymbolicLink(atPath: s.p("src/tree/link"), withDestinationPath: "a.txt")
    #expect(setxattr(s.p("src/tree/a.txt"), "com.dfm.test", "v", 1, 0, 0) == 0)

    let job = run(.copy, [s.p("src/tree")], to: s.dst)
    #expect(s.read("dst/tree/a.txt") == "a")
    #expect(s.read("dst/tree/sub/b.txt") == "bb")
    #expect(try! FileManager.default.destinationOfSymbolicLink(atPath: s.p("dst/tree/link")) == "a.txt")
    #expect(getxattr(s.p("dst/tree/a.txt"), "com.dfm.test", nil, 0, 0, 0) == 1)
    let p = job.progress
    #expect(p.doneFiles == p.totalFiles && p.totalFiles == 3)
    #expect(p.doneBytes == p.totalBytes)
}

@Test func conflictSkipKeepsDestination() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a.txt", "new")
    s.write("dst/a.txt", "old")
    run(.copy, [s.p("src/a.txt")], to: s.dst, conflict: .skip)
    #expect(s.read("dst/a.txt") == "old")
}

@Test func conflictOverwriteReplacesAtomically() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a.txt", "new")
    s.write("dst/a.txt", "old")
    run(.copy, [s.p("src/a.txt")], to: s.dst, conflict: .overwrite)
    #expect(s.read("dst/a.txt") == "new")
    let leftovers = try! FileManager.default.contentsOfDirectory(atPath: s.dst).filter { $0.hasPrefix(".dfm-partial") }
    #expect(leftovers.isEmpty)
}

@Test func conflictKeepBothNumbersLikeFinder() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a.txt", "new")
    s.write("dst/a.txt", "old")
    s.write("dst/a 2.txt", "older")
    run(.copy, [s.p("src/a.txt")], to: s.dst, conflict: .keepBoth)
    #expect(s.read("dst/a.txt") == "old")
    #expect(s.read("dst/a 3.txt") == "new")
}

@Test func conflictOverwriteIfNewer() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/old.txt", "src", mtime: Date(timeIntervalSince1970: 1000))
    s.write("dst/old.txt", "dst", mtime: Date(timeIntervalSince1970: 2000))
    s.write("src/new.txt", "src", mtime: Date(timeIntervalSince1970: 3000))
    s.write("dst/new.txt", "dst", mtime: Date(timeIntervalSince1970: 2000))
    run(.copy, [s.p("src/old.txt"), s.p("src/new.txt")], to: s.dst, conflict: .overwriteIfNewer)
    #expect(s.read("dst/old.txt") == "dst")
    #expect(s.read("dst/new.txt") == "src")
}

@Test func overwriteMergesDirectories() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/d/new.txt", "n")
    s.write("src/d/both.txt", "src")
    s.write("dst/d/keep.txt", "k")
    s.write("dst/d/both.txt", "dst")
    run(.copy, [s.p("src/d")], to: s.dst, conflict: .overwrite)
    #expect(s.read("dst/d/keep.txt") == "k")
    #expect(s.read("dst/d/new.txt") == "n")
    #expect(s.read("dst/d/both.txt") == "src")
}

@Test func moveOnSameVolumeRenames() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/d/x.txt", "x")
    let job = run(.move, [s.p("src/d")], to: s.dst)
    #expect(!s.exists("src/d"))
    #expect(s.read("dst/d/x.txt") == "x")
    #expect(job.progress.doneFiles == 1)
}

@Test func moveMergeRemovesEmptiedSource() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/d/a.txt", "a")
    s.write("dst/d/b.txt", "b")
    run(.move, [s.p("src/d")], to: s.dst, conflict: .overwrite)
    #expect(!s.exists("src/d"))
    #expect(s.read("dst/d/a.txt") == "a")
    #expect(s.read("dst/d/b.txt") == "b")
}

@Test func moveMergeKeepsSourceWhenChildSkipped() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/d/a.txt", "a")
    s.write("dst/d/a.txt", "other")
    let job = FileJob(.move, sources: [s.p("src/d")], destDir: s.dst)
    job.resolveConflict = { c in (c.bothDirs ? .overwrite : .skip, false) }   // merge dirs, skip the file
    job.run()
    #expect(s.read("src/d/a.txt") == "a")      // nothing lost
    #expect(s.read("dst/d/a.txt") == "other")
}

@Test func copyIntoItselfIsRejected() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/d/a.txt", "a")
    let job = FileJob(.copy, sources: [s.p("src/d")], destDir: s.p("src/d"))
    job.resolveError = { _, _ in (.skip, false) }
    job.run()
    #expect(job.progress.errors.count == 1)
    #expect(!s.exists("src/d/d"))
}

@Test func copyIntoSameFolderDuplicates() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a.txt", "a")
    run(.copy, [s.p("src/a.txt")], to: s.src)
    #expect(s.read("src/a 2.txt") == "a")
}

@Test func copyWithTargetNameRenames() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a.txt", "a")
    run(.copy, [s.p("src/a.txt")], to: s.dst, name: "b.txt")
    #expect(s.read("dst/b.txt") == "a")
}

@Test func deleteRemovesTree() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/d/a.txt", "a")
    let job = run(.delete, [s.p("src/d")])
    #expect(!s.exists("src/d"))
    #expect(job.progress.state == .done)
}

@Test func cancelledJobDoesNothing() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a.txt", "a")
    let job = FileJob(.copy, sources: [s.p("src/a.txt")], destDir: s.dst)
    job.cancel()
    job.run()
    #expect(!s.exists("dst/a.txt"))
    #expect(job.progress.state == .cancelled)
}

@Test func errorAbortStopsJob() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a.txt", "a")
    s.write("src/b.txt", "b")
    chmod(s.dst, 0o500)   // read-only destination
    defer { chmod(s.dst, 0o755) }
    let job = FileJob(.copy, sources: [s.p("src/a.txt"), s.p("src/b.txt")], destDir: s.dst)
    nonisolated(unsafe) var asked = 0
    job.resolveError = { _, _ in asked += 1; return (.abort, false) }
    job.run()
    #expect(asked == 1)
    #expect(job.progress.state == .failed)
}

@Test func resultsRecordWhatUndoNeeds() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/new.txt", "n")
    s.write("src/clash.txt", "c")
    s.write("dst/clash.txt", "old")
    let copy = run(.copy, [s.p("src/new.txt"), s.p("src/clash.txt")], to: s.dst, conflict: .overwrite)
    // Only the newly created item is undoable; the overwritten one is not.
    #expect(copy.results.map(\.dst) == [s.p("dst/new.txt")])

    let keep = run(.copy, [s.p("src/clash.txt")], to: s.dst, conflict: .keepBoth)
    #expect(keep.results.map(\.dst) == [s.p("dst/clash 2.txt")])

    let move = run(.move, [s.p("src/new.txt")], to: s.dst, conflict: .keepBoth)   // dst/new.txt exists from the copy
    #expect(move.results.map(\.src) == [s.p("src/new.txt")])
    #expect(move.results.map(\.dst) == [s.p("dst/new 2.txt")])
}

@Test func trashReportsWhereItWent() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/bye.txt", "x")
    let job = run(.trash, [s.p("src/bye.txt")])
    #expect(!s.exists("src/bye.txt"))
    let dst = job.results.first?.dst ?? ""
    #expect(dst.contains("/.Trash"))
    #expect(FileManager.default.fileExists(atPath: dst))
    try? FileManager.default.removeItem(atPath: dst)   // don't leave test files in the user's Trash
}

@Test func syncPlanAndExecution() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    let old = Date(timeIntervalSince1970: 1_000_000), new = Date(timeIntervalSince1970: 2_000_000)
    s.write("src/same.txt", "x", mtime: old);   s.write("dst/same.txt", "x", mtime: old)
    s.write("src/edit.txt", "v2", mtime: new);  s.write("dst/edit.txt", "v1", mtime: old)
    s.write("src/back.txt", "a", mtime: old);   s.write("dst/back.txt", "bb", mtime: new)
    s.write("src/clash.txt", "aa", mtime: old); s.write("dst/clash.txt", "b", mtime: old)
    s.write("src/onlyL/deep/f.txt", "L")
    s.write("dst/onlyR.txt", "R")
    s.write("src/both/inner.txt", "new", mtime: new); s.write("dst/both/inner.txt", "old", mtime: old)

    let plan = DirSync.compare(left: s.src, right: s.dst)
    let byPath = Dictionary(uniqueKeysWithValues: plan.map { ($0.path, $0) })
    #expect(byPath["same.txt"]?.action == .equal)
    #expect(byPath["edit.txt"]?.action == .toRight)
    #expect(byPath["back.txt"]?.action == .toLeft)
    #expect(byPath["clash.txt"]?.action == .skip && byPath["clash.txt"]?.isConflict == true)
    #expect(byPath["onlyL"]?.action == .toRight)            // a missing folder is one row
    #expect(byPath["onlyR.txt"]?.action == .toLeft)
    #expect(byPath["both/inner.txt"]?.action == .toRight)   // common folders are walked into
    #expect(byPath["both"] == nil)

    let toRight = plan.filter { $0.action == .toRight }.map { (src: s.src + "/" + $0.path, dst: s.dst + "/" + $0.path) }
    let toLeft = plan.filter { $0.action == .toLeft }.map { (src: s.dst + "/" + $0.path, dst: s.src + "/" + $0.path) }
    FileJob(copyPairs: toRight).run()
    FileJob(copyPairs: toLeft).run()
    #expect(s.read("dst/edit.txt") == "v2" && s.read("src/back.txt") == "bb")
    #expect(s.read("dst/onlyL/deep/f.txt") == "L" && s.read("src/onlyR.txt") == "R")
    #expect(s.read("dst/both/inner.txt") == "new")
    #expect(s.read("dst/clash.txt") == "b" && s.read("src/clash.txt") == "aa")   // conflicts untouched
    #expect(DirSync.compare(left: s.src, right: s.dst).filter { $0.action != .equal && !$0.isConflict }.isEmpty)
}

@Test func syncByContentCatchesSameSizeEdits() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    let t = Date(timeIntervalSince1970: 1_000_000)
    s.write("src/a.txt", "abc", mtime: t)
    s.write("dst/a.txt", "abd", mtime: t)
    #expect(DirSync.compare(left: s.src, right: s.dst).first?.action == .equal)
    let deep = DirSync.compare(left: s.src, right: s.dst, byContent: true)
    #expect(deep.first?.isConflict == true)
}

// MARK: - Conflicts, errors, and edge cases

@Test func conflictCancelStopsTheWholeJob() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a.txt", "a"); s.write("dst/a.txt", "old")
    s.write("src/b.txt", "b")
    let job = run(.copy, [s.p("src/a.txt"), s.p("src/b.txt")], to: s.dst, conflict: .cancel)
    #expect(job.progress.state == .cancelled)
    #expect(s.read("dst/a.txt") == "old" && !s.exists("dst/b.txt"))
    #expect(job.results.isEmpty)
}

@Test func conflictCallbackSeesBothSides() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a.txt", "abc", mtime: Date(timeIntervalSince1970: 3000))
    s.write("dst/a.txt", "12345", mtime: Date(timeIntervalSince1970: 1000))
    let job = FileJob(.copy, sources: [s.p("src/a.txt")], destDir: s.dst)
    nonisolated(unsafe) var seen: FileJob.Conflict?
    job.resolveConflict = { c in seen = c; return (.skip, false) }
    job.run()
    #expect(seen?.srcSize == 3 && seen?.dstSize == 5)
    #expect(seen?.srcMtime == 3000 && seen?.dstMtime == 1000)
    #expect(seen?.bothDirs == false && seen?.src == s.p("src/a.txt") && seen?.dst == s.p("dst/a.txt"))
}

@Test func conflictAskedOncePerItemUnlessAppliedToAll() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    for n in ["a", "b", "c"] { s.write("src/\(n)", "new"); s.write("dst/\(n)", "old") }
    let srcs = ["a", "b", "c"].map { s.p("src/\($0)") }
    let each = FileJob(.copy, sources: srcs, destDir: s.dst)
    nonisolated(unsafe) var asked = 0
    each.resolveConflict = { _ in asked += 1; return (.skip, false) }
    each.run()
    #expect(asked == 3)
    let all = FileJob(.copy, sources: srcs, destDir: s.dst)
    asked = 0
    all.resolveConflict = { _ in asked += 1; return (.overwrite, true) }
    all.run()
    #expect(asked == 1 && s.read("dst/c") == "new")
}

@Test func errorRetryAfterFixingTheProblem() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a.txt", "a")
    chmod(s.dst, 0o500)
    defer { chmod(s.dst, 0o755) }
    let job = FileJob(.copy, sources: [s.p("src/a.txt")], destDir: s.dst)
    nonisolated(unsafe) var asked = 0
    job.resolveError = { _, message in
        asked += 1
        chmod(s.dst, 0o755)   // "fix" it, then retry
        #expect(message.contains("Permission denied"))
        return (.retry, false)
    }
    job.run()
    #expect(asked == 1 && job.progress.errors.isEmpty && job.progress.state == .done)
    #expect(s.read("dst/a.txt") == "a")
}

@Test func errorSkipAppliedToAllAsksOnce() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a.txt", "a"); s.write("src/b.txt", "b")
    chmod(s.dst, 0o500)
    defer { chmod(s.dst, 0o755) }
    let job = FileJob(.copy, sources: [s.p("src/a.txt"), s.p("src/b.txt")], destDir: s.dst)
    nonisolated(unsafe) var asked = 0
    job.resolveError = { _, _ in asked += 1; return (.skip, true) }
    job.run()
    #expect(asked == 1 && job.progress.errors.count == 2)
    #expect(job.progress.state == .done)   // skipped items don't fail the job
    #expect(job.progress.errors.allSatisfy { $0.hasPrefix(s.p("src/")) })
}

@Test func missingSourceIsReported() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    let job = run(.copy, [s.p("src/ghost.txt")], to: s.dst)
    #expect(job.progress.errors == ["\(s.p("src/ghost.txt")): No such file or directory"])
    #expect(job.progress.state == .done && job.results.isEmpty)
}

@Test func overwriteReplacesFileWithFolderAndFolderWithFile() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/d/inner.txt", "i")
    s.write("dst/d", "I am a file")
    s.write("src/f", "I am a file")
    s.write("dst/f/inner.txt", "i")
    run(.copy, [s.p("src/d"), s.p("src/f")], to: s.dst, conflict: .overwrite)
    #expect(s.read("dst/d/inner.txt") == "i")
    #expect(s.read("dst/f") == "I am a file")
}

@Test func overwriteIfNewerAlwaysMergesFolders() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    let old = Date(timeIntervalSince1970: 1000), new = Date(timeIntervalSince1970: 2000)
    s.write("src/d/newer.txt", "src", mtime: new); s.write("dst/d/newer.txt", "dst", mtime: old)
    s.write("src/d/older.txt", "src", mtime: old); s.write("dst/d/older.txt", "dst", mtime: new)
    try! FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: s.p("src/d"))   // the folder itself is "older"
    run(.copy, [s.p("src/d")], to: s.dst, conflict: .overwriteIfNewer)
    #expect(s.read("dst/d/newer.txt") == "src" && s.read("dst/d/older.txt") == "dst")
}

@Test func topLevelSymlinkIsCopiedAsALink() throws {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/target.txt", "t")
    try FileManager.default.createSymbolicLink(atPath: s.p("src/link"), withDestinationPath: "target.txt")
    try FileManager.default.createSymbolicLink(atPath: s.p("src/dangling"), withDestinationPath: "/nowhere/at/all")
    let job = run(.copy, [s.p("src/link"), s.p("src/dangling")], to: s.dst)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: s.p("dst/link")) == "target.txt")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: s.p("dst/dangling")) == "/nowhere/at/all")
    #expect(!s.exists("dst/target.txt"))
    #expect(job.progress.errors.isEmpty && job.progress.doneFiles == 2)
}

@Test func readOnlySourceFolderCopiesAndKeepsItsMode() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/ro/a.txt", "a")
    chmod(s.p("src/ro/a.txt"), 0o640)
    chmod(s.p("src/ro"), 0o500)
    defer { chmod(s.p("src/ro"), 0o700); chmod(s.p("dst/ro"), 0o700) }
    let job = run(.copy, [s.p("src/ro")], to: s.dst)
    #expect(job.progress.errors.isEmpty)
    #expect(s.read("dst/ro/a.txt") == "a")
    #expect(FileJob.lstat(s.p("dst/ro")).map { $0.st_mode & 0o777 } == 0o500)
    #expect(FileJob.lstat(s.p("dst/ro/a.txt")).map { $0.st_mode & 0o777 } == 0o640)
}

@Test func copyKeepsFinderFlags() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/h.txt", "h")
    #expect(chflags(s.p("src/h.txt"), UInt32(UF_HIDDEN)) == 0)
    run(.copy, [s.p("src/h.txt")], to: s.dst)
    #expect(FileJob.lstat(s.p("dst/h.txt")).map { $0.st_flags & UInt32(UF_HIDDEN) } == UInt32(UF_HIDDEN))
}

/// A file locked in Finder (uchg): copyfile put the lock on the hidden partial too, so the rename failed ("Operation
/// not permitted") and the partial, locked, stayed in the destination. Now the copy lands, locked as Finder's would be.
@Test func copyOfALockedFileLandsLocked() throws {
    let s = Sandbox()
    defer {
        for dir in [s.src, s.dst] { for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] { lchflags(dir + "/" + n, 0) } }
        try? FileManager.default.removeItem(atPath: s.root)
    }
    s.write("src/a.txt", "locked")
    #expect(lchflags(s.p("src/a.txt"), UInt32(UF_IMMUTABLE)) == 0)
    let job = run(.copy, [s.p("src/a.txt")], to: s.dst)
    #expect(job.progress.errors.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: s.dst) == ["a.txt"])
    #expect(s.read("dst/a.txt") == "locked")
    #expect(FileJob.lstat(s.p("dst/a.txt")).map { $0.st_flags & UInt32(UF_IMMUTABLE) } == UInt32(UF_IMMUTABLE))
}

@Test func moveOntoItselfIsANoOp() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a.txt", "a")
    let job = run(.move, [s.p("src/a.txt")], to: s.src)
    #expect(s.read("src/a.txt") == "a" && !s.exists("src/a 2.txt"))
    #expect(job.results.isEmpty && job.progress.errors.isEmpty && job.progress.state == .done)
}

@Test func moveIntoItselfIsRejected() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/d/a.txt", "a")
    let job = run(.move, [s.p("src/d")], to: s.p("src/d/deeper"))
    #expect(job.progress.errors.first?.hasSuffix("Cannot move a folder into itself") == true)
    #expect(s.read("src/d/a.txt") == "a")
}

@Test func moveFileOverExistingFileReplacesIt() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a.txt", "new"); s.write("dst/a.txt", "old")
    let job = run(.move, [s.p("src/a.txt")], to: s.dst, conflict: .overwrite)
    #expect(s.read("dst/a.txt") == "new" && !s.exists("src/a.txt"))
    #expect(job.results.isEmpty)   // overwrote something: not undoable
}

@Test func targetNameOnlyAppliesToASingleSource() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a", "a"); s.write("src/b", "b")
    let job = run(.copy, [s.p("src/a"), s.p("src/b")], to: s.dst, name: "renamed")
    #expect(job.targetName == nil)
    #expect(s.read("dst/a") == "a" && s.read("dst/b") == "b" && !s.exists("dst/renamed"))
}

@Test func startRunsInBackgroundAndCallsOnFinish() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a.txt", "a")
    let job = FileJob(.copy, sources: [s.p("src/a.txt")], destDir: s.dst)
    let done = DispatchSemaphore(value: 0)
    job.onFinish = { done.signal() }
    job.start()
    #expect(done.wait(timeout: .now() + 10) == .success)
    #expect(job.progress.state == .done && s.read("dst/a.txt") == "a")
}

@Test func trashAndDeleteFolders() throws {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/gone/deep/x", "x")
    let job = run(.trash, [s.p("src/gone")])
    let dst = try #require(job.results.first?.dst)
    defer { try? FileManager.default.removeItem(atPath: dst) }
    #expect(!s.exists("src/gone") && FileManager.default.fileExists(atPath: dst + "/deep/x"))

    let missing = run(.delete, [s.p("src/nothing")])
    #expect(missing.progress.errors.count == 1 && missing.progress.state == .done && missing.progress.doneFiles == 1)
}

@Test func uniqueNameHandlesOddNames() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("dst/noext", "1"); s.write("dst/noext 2", "2")
    #expect(FileJob.uniqueName(s.p("dst/noext")) == s.p("dst/noext 3"))
    s.write("dst/.zshrc", "z")
    #expect(FileJob.uniqueName(s.p("dst/.zshrc")) == s.p("dst/.zshrc 2"))   // a dotfile has no extension
    s.write("dst/a.tar.gz", "t")
    #expect(FileJob.uniqueName(s.p("dst/a.tar.gz")) == s.p("dst/a.tar 2.gz"))
    #expect(FileJob.uniqueName(s.p("dst/free.txt")) == s.p("dst/free 2.txt"))   // numbering starts at 2 even if free
}

@Test func copyPairsReplaceTargetsAndCreateFolders() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a.txt", "new"); s.write("dst/a.txt", "old")
    s.write("src/folder/f.txt", "f")
    let job = FileJob(copyPairs: [(s.p("src/a.txt"), s.p("dst/a.txt")), (s.p("src/folder"), s.p("dst/renamed"))])
    job.run()
    #expect(s.read("dst/a.txt") == "new" && s.read("dst/renamed/f.txt") == "f")
    #expect(job.progress.state == .done && job.progress.totalFiles == 2 && job.progress.doneFiles == 2)
    #expect(job.results.map(\.dst) == [s.p("dst/renamed")])
}

@Test func pausedJobWaitsUntilResumed() {
    let s = Sandbox()
    defer { try? FileManager.default.removeItem(atPath: s.root) }
    s.write("src/a.txt", String(repeating: "x", count: 4 << 20))
    let job = FileJob(.copy, sources: [s.p("src/a.txt")], destDir: s.dst)
    job.isPaused = true
    let done = DispatchSemaphore(value: 0)
    job.onFinish = { done.signal() }
    job.start()
    // An APFS clone never calls copyfile's progress callback, so pause must also be checked between files.
    let whilePaused = done.wait(timeout: .now() + 1)   // an unpaused clone finishes in milliseconds
    #expect(whilePaused == .timedOut)
    job.isPaused = false
    if whilePaused == .timedOut { #expect(done.wait(timeout: .now() + 10) == .success) }
    #expect(job.progress.state == .done)
    #expect(s.read("dst/a.txt")?.utf8.count == 4 << 20)
}
