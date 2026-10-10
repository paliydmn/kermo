import Foundation
import Testing
@testable import DFMCore

// I7: Compare (⇧F2) and Synchronize (⌘⇧S) with a server — here this Mac's own sftp-server (`SFTPTarget.local()`).

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r10sync-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
private func write(_ path: String, _ text: String, mtime: Double = 1_000_000) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
    try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: path)
}
private func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

private let server = Endpoint.sftp(.local())

/// Compares `l` (this Mac) with `r` listed over SFTP, as ⇧F2 and ⌘⇧S do.
private func compare(_ l: String, _ r: String) -> [DirSync.Item] {
    let (a, b) = (DirSync.lister(.local), DirSync.lister(server))
    defer { a.close(); b.close() }
    return DirSync.compare(left: l, right: r, list: a.list, listRight: b.list, tolerance: 1)
}

/// ⇧F2 walks into folders on both sides, also on a server: the folder holding a difference is what's marked.
@Test func compareWithAServerIsRecursive() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let (l, r) = (d + "/L", d + "/R")
    write(l + "/app/conf/a.txt", "new", mtime: 2_000_000); write(r + "/app/conf/a.txt", "old")
    write(l + "/data/x.txt", "x");                         write(r + "/data/x.txt", "x"); write(r + "/data/only.txt", "far")
    write(l + "/same/s.txt", "s");                         write(r + "/same/s.txt", "s")

    let plan = compare(l, r)
    #expect(plan.filter { $0.action != .equal }.map(\.path).sorted() == ["app/conf/a.txt", "data/only.txt"])
    let m = DirCompare.marks(plan)
    #expect(m.left == ["app"] && m.right == ["data"] && m.unreadable == 0)
}

/// ⌘⇧S between this Mac and a server copies each way, nested, through FileJob over SFTP; afterwards both match.
@Test func syncWithAServerCopiesBothWays() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let (l, r) = (d + "/L", d + "/R")
    write(l + "/a/b/new.txt", "up", mtime: 2_000_000); write(r + "/a/keep.txt", "k")
    write(r + "/c/d/far.txt", "down", mtime: 3_000_000); write(l + "/c/e.txt", "e")
    write(l + "/edit.txt", "newer", mtime: 4_000_000); write(r + "/edit.txt", "older")

    let jobs = DirSync.jobs(compare(l, r), left: l, right: r, sides: (.local, server))
    // → a/b (a folder only here), c/e.txt, edit.txt; ← a/keep.txt, c/d
    #expect(jobs.map(\.label) == ["Sync → localhost:\(r) (3)", "Sync ← \((l as NSString).abbreviatingWithTildeInPath) (2)"])
    for (job, _) in jobs {
        job.run()
        #expect(job.progress.errors.isEmpty && job.progress.state == .done, "\(job.progress.errors)")
    }
    #expect(read(r + "/a/b/new.txt") == "up" && read(l + "/c/d/far.txt") == "down" && read(r + "/edit.txt") == "newer")
    #expect(compare(l, r).allSatisfy { $0.action == .equal }, "dates came along")
}

/// Mirror onto a server deletes what's only there (no Trash) — except what changed since Compare.
@Test func mirrorOntoAServerDeletesOnlyWhatCompareSaw() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let (l, r) = (d + "/L", d + "/R")
    write(l + "/a.txt", "a"); write(r + "/a.txt", "a")
    write(r + "/extra/x.txt", "x"); write(r + "/later.txt", "r")

    let plan = DirSync.mirror(compare(l, r), toRight: true)
    write(r + "/later.txt", "edited after Compare", mtime: 5_000_000)
    let jobs = DirSync.jobs(plan, left: l, right: r, sides: (.local, server))
    #expect(jobs.count == 1 && jobs[0].job.kind == .delete && jobs[0].label == "Sync: 2 only on the right → deleted (localhost:\(r))")
    jobs[0].job.run()
    #expect(!FileManager.default.fileExists(atPath: r + "/extra") && read(r + "/later.txt") == "edited after Compare")
    #expect(jobs[0].job.progress.errors == [r + "/later.txt: changed since Compare, skipped"])
}

/// A server's /srv/app and this Mac's /srv/app are two places: what Compare saw at each stays apart.
@Test func syncKeepsWhatEachSideHadApartUnderOnePath() {
    let a = FileItem(name: "f", kind: .file, size: 1, mtime: 1, mode: 0o644, flags: 0)
    let b = FileItem(name: "f", kind: .file, size: 2, mtime: 2, mode: 0o644, flags: 0)
    let it = DirSync.Item(path: "f", left: a, right: b, action: .toRight, isConflict: false)
    let job = DirSync.jobs([it], left: "/srv/app", right: "/srv/app", sides: (.local, server))[0].job
    #expect(job.expected["/srv/app/f"]??.size == 1 && job.expectedTarget["/srv/app/f"]??.size == 2)
}
