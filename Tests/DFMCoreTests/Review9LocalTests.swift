import Foundation
@testable import DFMCore
import Testing

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r9l-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
private func write(_ path: String, _ text: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
}
private func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
private func mode(_ path: String) -> mode_t {
    var s = stat()
    lstat(path, &s)
    return s.st_mode & 0o7777
}

/// S5: ⌘I chmod on a symlink changes the link, never what it points at — a private key stays 0600.
@Test func chmodOnASymlinkLeavesItsTarget() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    write(d + "/id_ed25519", "secret")
    chmod(d + "/id_ed25519", 0o600)
    try FileManager.default.createSymbolicLink(atPath: d + "/key", withDestinationPath: d + "/id_ed25519")

    #expect(FileInfo.setMode(d + "/key", 0o644))
    #expect(mode(d + "/id_ed25519") == 0o600)
    #expect(mode(d + "/key") == 0o644)
}

/// P16: Remove Quarantine walks the tree off the main thread (InfoWindow runs this in `Blocking.run`) and stops when
/// the window closes.
@Test func removeQuarantineWalksTheTreeAndStopsOnCancel() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let paths = [d + "/App.app/Contents/Info.plist", d + "/App.app/Contents/MacOS/app", d + "/App.app/x"]
    paths.forEach { write($0, "x") }
    for p in paths + [d + "/App.app", d + "/App.app/Contents"] {
        #expect(setxattr(p, "com.apple.quarantine", "0081;0;Safari;", 14, 0, XATTR_NOFOLLOW) == 0)
    }
    let cancelled = CancelFlag()
    cancelled.cancel()
    #expect(FileInfo.removeQuarantine(d + "/App.app", cancel: cancelled) == 1)   // the item itself, then stops
    #expect(FileInfo.xattrString(paths[0], "com.apple.quarantine") != nil)

    #expect(FileInfo.removeQuarantine(d + "/App.app") == 4)
    #expect(paths.allSatisfy { FileInfo.xattrString($0, "com.apple.quarantine") == nil })
}

/// L18: Compare matches `Docs` on the left with `docs` on the right (one side may ignore case), but each side's
/// path keeps its own spelling: on a case-sensitive right, `Docs/a.txt` would be a new folder next to `docs`.
@Test func syncWritesEachSideUnderItsOwnSpelling() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let (l, r) = (d + "/L", d + "/R")
    write(l + "/Docs/a.txt", "a")
    write(r + "/docs/b.txt", "b")

    let plan = DirSync.compare(left: l, right: r)
    #expect(plan.map(\.path).sorted() == ["Docs/a.txt", "Docs/b.txt"])
    #expect(plan.compactMap(\.rightPath).sorted() == ["docs/a.txt", "docs/b.txt"])
    let jobs = DirSync.jobs(plan, left: l, right: r).map(\.job)
    let toRight = jobs.first { $0.sources == [l + "/Docs/a.txt"] }, toLeft = jobs.first { $0.sources == [r + "/docs/b.txt"] }
    #expect(toRight.map { Array($0.expected.keys) + $0.expectedTarget.keys } == [l + "/Docs/a.txt", r + "/docs/a.txt"])
    #expect(toLeft.map { Array($0.expected.keys) + $0.expectedTarget.keys } == [r + "/docs/b.txt", l + "/Docs/b.txt"])
    for j in jobs { j.run() }
    #expect(FileManager.default.contentsEqual(atPath: l + "/Docs/b.txt", andPath: r + "/docs/b.txt"))
}

/// L18: two items that get one name in the target (`Makefile` and `makefile` on a case-insensitive volume): the
/// second lands on what this job just wrote. That is always asked, never answered by an earlier "apply to all" —
/// or by Synchronize's own overwrite — so one never silently replaces the other.
@Test func clashWithWhatThisJobJustWroteIsAlwaysAsked() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    write(d + "/up/Makefile", "upper")
    write(d + "/low/makefile", "lower")
    write(d + "/up/notes.txt", "new")
    write(d + "/dst/notes.txt", "old")
    var st = stat()
    guard lstat(d + "/dst/NOTES.TXT", &st) == 0 else { return }   // needs a case-insensitive temp volume (APFS default)

    let job = FileJob(.copy, sources: [d + "/up/notes.txt", d + "/up/Makefile", d + "/low/makefile"], destDir: d + "/dst")
    nonisolated(unsafe) var asked: [FileJob.Conflict] = []
    job.resolveConflict = { c in asked.append(c); return (c.createdByThisJob ? .skip : .overwrite, true) }
    job.run()
    #expect(asked.map { ($0.dst as NSString).lastPathComponent } == ["notes.txt", "makefile"])
    #expect(asked.map(\.createdByThisJob) == [false, true])
    #expect(read(d + "/dst/Makefile") == "upper" && read(d + "/dst/notes.txt") == "new")

    // Synchronize's pairs overwrite without asking — except this.
    try FileManager.default.createDirectory(atPath: d + "/sync", withIntermediateDirectories: true)
    let sync = FileJob(copyPairs: [(d + "/up/Makefile", d + "/sync/Makefile"), (d + "/low/makefile", d + "/sync/makefile")])
    asked = []
    sync.resolveConflict = { c in asked.append(c); return (.skip, false) }
    sync.run()
    #expect(asked.count == 1 && read(d + "/sync/Makefile") == "upper")
}

/// The temp volume ignores case (APFS default); the case clashes below can't happen otherwise.
private func caseInsensitive(_ d: String) -> Bool {
    write(d + "/probe", "")
    defer { unlink(d + "/probe") }
    var st = stat()
    return lstat(d + "/PROBE", &st) == 0
}

/// L18: a folder moved on one volume is one rename, and everything inside it came with it: `y/docs` merged into the
/// `Docs` this job just moved there asks about its `Makefile` too, never answered by an earlier "apply to all"
/// (that would replace the moved file, which exists nowhere else any more).
@Test func clashInsideAFolderThisMoveRenamedIsAsked() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    guard caseInsensitive(d) else { return }
    write(d + "/n/notes.txt", "new")
    write(d + "/dst/notes.txt", "old")
    write(d + "/x/Docs/Makefile", "upper")
    write(d + "/y/docs/Makefile", "lower")

    let job = FileJob(.move, sources: [d + "/n/notes.txt", d + "/x/Docs", d + "/y/docs"], destDir: d + "/dst")
    nonisolated(unsafe) var asked: [FileJob.Conflict] = []
    job.resolveConflict = { c in
        asked.append(c)
        return c.createdByThisJob ? (c.bothDirs ? .overwrite : .skip, false) : (.overwrite, true)
    }
    job.run()
    #expect(asked.map { ($0.dst as NSString).lastPathComponent } == ["notes.txt", "docs", "Makefile"])
    #expect(asked.map(\.createdByThisJob) == [false, true, true])
    #expect(read(d + "/dst/Docs/Makefile") == "upper" && read(d + "/y/docs/Makefile") == "lower")
}

/// L18 over SFTP: a download from a case-sensitive server holding `Makefile` and `makefile` onto this Mac, and an
/// upload the other way, ask about the second one even after "apply to all".
@Test(arguments: [true, false]) func clashWithWhatThisTransferJustWroteIsAsked(download: Bool) {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    guard caseInsensitive(d) else { return }
    write(d + "/n/notes.txt", "new")
    write(d + "/up/Makefile", "upper")
    write(d + "/low/makefile", "lower")
    write(d + "/dst/notes.txt", "old")
    let server = Endpoint.sftp(.local(server: "/usr/libexec/sftp-server"))
    let job = FileJob(.copy, sources: [d + "/n/notes.txt", d + "/up/Makefile", d + "/low/makefile"],
                      from: download ? server : .local, to: download ? .local : server, destDir: d + "/dst")
    nonisolated(unsafe) var asked: [FileJob.Conflict] = []
    job.resolveConflict = { c in asked.append(c); return (c.createdByThisJob ? .skip : .overwrite, true) }
    job.run()
    #expect(job.progress.errors.isEmpty)
    #expect(asked.map { ($0.dst as NSString).lastPathComponent } == ["notes.txt", "makefile"])
    #expect(asked.map(\.createdByThisJob) == [false, true])
    #expect(read(d + "/dst/Makefile") == "upper" && read(d + "/dst/notes.txt") == "new")
}

/// L18 in Synchronize: `Makefile` and `makefile` (or `Docs/` and `docs/`) on a case-sensitive side are one name on
/// the other. Neither drops silently out of the plan: one row, skipped, saying why — and Mirror leaves it skipped.
@Test func syncReportsNamesThatDifferOnlyInCase() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let (l, r) = (d + "/L", d + "/R")
    write(l + "/Makefile", "upper")
    write(l + "/Docs/a.txt", "a")
    write(l + "/b.txt", "b")
    try! FileManager.default.createDirectory(atPath: r, withIntermediateDirectories: true)
    // The left side as a case-sensitive volume lists it: a twin of each, in another case.
    let list: DirSync.Lister = { $0.map { p in
        Result {
            let xs = try DirLister.list(p)
            guard p == l else { return xs }
            return xs + xs.filter { $0.name != "b.txt" }.map {
                FileItem(name: $0.name.lowercased(), kind: $0.kind, size: $0.size, mtime: $0.mtime, mode: $0.mode, flags: $0.flags)
            }
        }
    } }
    let plan = DirSync.compare(left: l, right: r, list: list)
    #expect(plan.map(\.path).sorted() == ["Docs", "Makefile", "b.txt"])
    #expect(plan.first { $0.path == "Makefile" }?.unreadable == "names differ only in case: Makefile, makefile")
    #expect(plan.first { $0.path == "Docs" }?.unreadable == "names differ only in case: Docs, docs")
    let mirrored = DirSync.mirror(plan, toRight: false)
    #expect(mirrored.filter { $0.path != "b.txt" }.allSatisfy { $0.action == .skip })
}
