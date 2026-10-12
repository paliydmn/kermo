import Foundation
import Testing
@testable import DFMCore

// Task 13: speed of long actions.

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t13-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

/// `roundTrips` left out the waits for a write's answer, a read's (its end of file too), a close and a batch's
/// closes, so a bound let real round trips through: a 2 KB read counted 2 and took 4 RTTs on a far server. Each
/// wait counts now; a batch or pipeline in flight, once per wave.
@Test func roundTripsCountEveryWait() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try Data(repeating: 1, count: 2048).write(to: URL(fileURLWithPath: d + "/small"))
    try Data(repeating: 2, count: 128 * SFTPClient.chunk).write(to: URL(fileURLWithPath: d + "/big"))
    for i in 0..<3 { try FileManager.default.createDirectory(atPath: d + "/dirs/\(i)", withIntermediateDirectories: true) }
    let c = try SFTPClient(.local())
    defer { c.close() }
    func trips(_ body: () throws -> Void) rethrows -> Int {
        let before = c.roundTrips
        try body()
        return c.roundTrips - before
    }
    func readAll(_ path: String, _ size: Int64) throws {
        let r = try c.openRead(path, sizeHint: size)
        while try r.read() != nil {}
        r.close()
    }
    #expect(try trips { try readAll(d + "/small", 2048) } == 2, "open, read with the end of file (the close isn't waited for)")
    #expect(try trips { try readAll(d + "/big", Int64(128 * SFTPClient.chunk)) } == 4, "open, 2 waves of 64 reads, end of file")
    #expect(try trips {
        let w = try c.openWrite(d + "/out")
        try w.write(Data(repeating: 3, count: 128 * SFTPClient.chunk))
        try w.finish()
    } == 4, "open, 2 waves of 64 writes, close")
    var listed = 0
    #expect(trips { listed = c.list((0..<3).map { d + "/dirs/\($0)" }).count } == 2, "open, then the reads with the end of file: each for all 3 at once")
    #expect(listed == 3)
}

/// A small file's read asked for a whole chunk: it came back short, and asking for the rest was one more wait
/// before the end of file. The last read ends at the size now, and the end is asked for in the same wave — still
/// read to the end whatever the size turned out to be.
@Test func readStopsAtTheSizeAndAsksForTheEndAlong() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let data = Data((0..<100_000).map { UInt8($0 % 251) })
    try data.write(to: URL(fileURLWithPath: d + "/f"))
    FileManager.default.createFile(atPath: d + "/empty", contents: nil)
    let c = try SFTPClient(.local())
    defer { c.close() }
    func read(_ path: String, from offset: Int64 = 0, hint: Int64) throws -> Data {
        let r = try c.openRead(path, offset: offset, sizeHint: hint)
        defer { r.close() }
        var out = Data()
        while let piece = try r.read() { out += piece }
        return out
    }
    #expect(try read(d + "/f", hint: 100_000) == data)
    #expect(try read(d + "/f", hint: 2048) == data, "grew since the stat")
    #expect(try read(d + "/f", hint: 300_000) == data, "shrank since the stat")
    #expect(try read(d + "/f", hint: 0) == data, "no stat")
    #expect(try read(d + "/f", from: 40_000, hint: 100_000) == data[40_000...])
    #expect(try read(d + "/f", from: 100_000, hint: 100_000).isEmpty)
    #expect(try read(d + "/empty", hint: 0).isEmpty)
    let tail = d + "/tail"
    #expect(try c.download(d + "/f", to: tail, last: 100).size == 100_000)
    #expect(FileManager.default.contents(atPath: tail) == data.suffix(100))
}

/// A listing sent one READDIR at a time and waited: a server sends some 100 names an answer, so 10 000 names were
/// 100 waits one after another. 8 in flight now (4 a folder when many are listed together), the ones past the end
/// dropped: every name once, a wave per 800 names.
@Test func listingKeepsReadsInFlight() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let sizes = [0, 100, 800, 1000]
    for n in sizes {
        try FileManager.default.createDirectory(atPath: d + "/\(n)", withIntermediateDirectories: true)
        for i in 0..<n { FileManager.default.createFile(atPath: d + "/\(n)/f\(i)", contents: nil) }
    }
    let c = try SFTPClient(.local())
    defer { c.close() }
    var trips: [Int] = []
    for n in sizes {
        let before = c.roundTrips
        let names = try c.list(d + "/\(n)").map(\.name)
        trips.append(c.roundTrips - before)
        #expect(names.count == n && Set(names).count == n)
    }
    // Open, then a wave per 8 answers ("." and ".." come too): 0–100 names, 2 answers at most with the end.
    #expect(trips == [2, 2, 3, 3], "\(trips)")
    let before = c.roundTrips
    let listed = c.list(sizes.map { d + "/\($0)" })
    #expect(listed.map(\.items.count) == sizes)
    #expect(c.roundTrips - before == 1 + 3, "open; 4 reads a folder a wave: 1000 names are 11 answers and the end")
}

/// Downloading a server folder looked at each file again (lstat) though its listing had just said what it was: one
/// wait more a file. What the listing said goes on now.
@Test func downloadTakesWhatTheListingSaw() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let fm = FileManager.default
    try fm.createDirectory(atPath: d + "/src", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: d + "/to", withIntermediateDirectories: true)
    for i in 0..<20 { try Data(repeating: UInt8(i), count: 2048).write(to: URL(fileURLWithPath: d + "/src/f\(i)")) }
    let fs = RemoteFS(.local(), env: [:])
    let c = try fs.session(), before = c.roundTrips
    let job = FileJob(.copy, sources: [d + "/src"], from: .sftp(.local()), to: .local, destDir: d + "/to")
    job.runAcross(fs)
    #expect(job.progress.state == .done && job.progress.errors.isEmpty, "\(job.progress.errors)")
    #expect((0..<20).allSatisfy { fm.contents(atPath: d + "/to/src/f\($0)") == Data(repeating: UInt8($0), count: 2048) })
    // Scanning: lstat, the folder (open, its reads with the end); the copy: the same 3; each file: open, its read
    // with the end (the close isn't waited for).
    #expect(c.roundTrips - before == 3 + 3 + 20 * 2, "\(c.roundTrips - before)")
}

/// Stop during "Scanning…" before a copy waited for the walk of the whole tree to end.
@Test func stoppedCopyStopsScanning() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    for i in 0..<20 {
        try FileManager.default.createDirectory(atPath: d + "/tree/\(i)", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: d + "/tree/\(i)/f", contents: Data([1]))
    }
    try FileManager.default.createDirectory(atPath: d + "/to", withIntermediateDirectories: true)
    let job = FileJob(.copy, sources: [d + "/tree"], destDir: d + "/to")
    job.cancel()
    job.run()
    #expect(job.progress.totalFiles == 0, "not walked: \(job.progress.totalFiles)")
    #expect(!FileManager.default.fileExists(atPath: d + "/to/tree"))
}

/// Comparing by content, and searching by it, looked at Stop only between files: a pair of 4 GB images, or one
/// big log, was read to its end first. Both stop at the next 1 MB now — and a stopped comparison is never "equal".
@Test func contentReadsStopAtTheNextChunk() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let data = Data(repeating: 7, count: 3 << 20) + Data("needle".utf8)
    try data.write(to: URL(fileURLWithPath: d + "/a"))
    try data.write(to: URL(fileURLWithPath: d + "/b"))
    #expect(DirSync.filesEqual(d + "/a", d + "/b"))
    #expect(FileSearch.fileContains(d + "/a", Array("needle".utf8), caseSensitive: true))
    var looks = 0
    let afterOne = { looks += 1; return looks > 1 }   // stopped after the first chunk
    #expect(!DirSync.filesEqual(d + "/a", d + "/b", isCancelled: afterOne))
    #expect(looks == 2)
    looks = 0
    #expect(!FileSearch.fileContains(d + "/a", Array("needle".utf8), caseSensitive: true, isCancelled: afterOne))
    #expect(looks == 2)
    #expect(!DirSync.filesEqual(d + "/a", d + "/b", isCancelled: { true }))
}

/// After an auto-reload, links to folders showed and sorted as files (`etc`, `tmp`, `var` in `/` with hidden
/// files shown): what was known of them went onto the re-list after it had been sorted.
@Test func reListKeepsLinksToFoldersWithTheFolders() {
    func item(_ name: String, _ kind: FileItem.Kind) -> FileItem { FileItem(name: name, kind: kind, size: 1, mtime: 0, mode: 0o755, flags: 0) }
    let listed = [item("b.txt", .file), item("etc", .link), item("a", .dir), item("zlink", .link)]
    let rows = listed.keepingLinkDirs(["etc", "a"]).sortedForPanel(by: .name, ascending: true)
    #expect(rows.map(\.name) == ["a", "etc", "b.txt", "zlink"])
    #expect(rows.filter(\.linkDir).map(\.name) == ["etc"], "only a link is a link to a folder")
    #expect(listed.keepingLinkDirs([]).filter(\.linkDir).isEmpty)
}

/// 70 folders (more than `window`) on each of 3 levels below `root`, a 1-byte file in each.
private func makeLevels(_ root: String) throws {
    for i in 0..<70 {
        for sub in ["", "/a", "/a/b"] {
            try FileManager.default.createDirectory(atPath: root + "/\(i)" + sub, withIntermediateDirectories: true)
            try Data([1]).write(to: URL(fileURLWithPath: root + "/\(i)" + sub + "/f"))
        }
    }
}

/// "Scanning…" before a copy from a server (and F8, Skip) walked the tree one folder at a time: 4 round trips a
/// folder. Level by level now, `window` folders together: the round trips grow with the depth, not the folders.
@Test func measureWalksAServerLevelByLevel() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try makeLevels(d + "/t")
    let fs = RemoteFS(.local(), env: [:])
    defer { fs.close() }
    let c = try fs.session(), before = c.roundTrips
    let job = FileJob(.copy, sources: [])
    let m = job.measure(fs, d + "/t")
    #expect(m.files == 210 && m.bytes == 210 && m.depth == 3)
    // lstat; the top: open, then its reads with the end (closes aren't waited for); each level of 70: 2 batches of the same
    // 2. One at a time: 845.
    #expect(c.roundTrips - before == 1 + 2 + 3 * 4, "\(c.roundTrips - before)")
    // Each folder's totals, for Skip.
    #expect(job.measured[d + "/t"]! == (210, 210) && job.measured[d + "/t/5"]! == (3, 3) && job.measured[d + "/t/5/a/b"]! == (1, 1))
}

/// Skip on a folder (a conflict) walked it again to count it done; now it adds what "Scanning…" counted.
@Test func skippedFolderCountsWhatScanningCounted() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try makeLevels(d + "/src/t")
    try FileManager.default.createDirectory(atPath: d + "/dst/t", withIntermediateDirectories: true)
    try Data("in the way".utf8).write(to: URL(fileURLWithPath: d + "/dst/t/5"))   // a file where folder 5 goes
    let job = FileJob(.copy, sources: [d + "/src/t"], from: .sftp(.local()), to: .local, destDir: d + "/dst")
    job.resolveConflict = { c in (c.bothDirs ? .overwrite : .skip, false) }
    job.run()
    let p = job.progress
    #expect(p.state == .done && p.errors.isEmpty, "\(p.errors)")
    #expect(p.totalFiles == 210 && p.doneFiles == 210 && p.doneBytes == 210)
    #expect(FileManager.default.fileExists(atPath: d + "/dst/t/6/a/b/f") && !FileManager.default.fileExists(atPath: d + "/dst/t/5/f"))
}

/// F8 on a server listed and deleted one folder at a time (only a folder's files together): ~6 round trips a
/// folder. Level by level now: 64 folders listed together, their files removed together; the folders last,
/// deepest level first, 64 together.
@Test func deleteOnAServerGoesLevelByLevel() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try makeLevels(d + "/t")
    let fs = RemoteFS(.local(), env: [:])
    defer { fs.close() }
    let job = FileJob(.delete, sources: [d + "/t"], from: .sftp(.local()), to: .sftp(.local()), destDir: nil)
    let a = try #require(try fs.lstat(d + "/t"))
    let c = try fs.session(), before = c.roundTrips
    job.removeAcross(fs, [(d + "/t", a)])
    #expect(job.progress.errors.isEmpty, "\(job.progress.errors)")
    #expect(!FileManager.default.fileExists(atPath: d + "/t"))
    // The top: open, then its reads with the end (closes aren't waited for); each level of 70: 2 batches of those 2 and 1
    // for the files; the folders: 2 + 2 + 2 + 1.
    // One at a time: 1265.
    #expect(c.roundTrips - before == 2 + 3 * 6 + 7, "\(c.roundTrips - before)")
}

/// F8 of many items (or a Mirror's deletions) on a server looked at and deleted each on its own: a file 2 round
/// trips, a folder 7. All together now: one look at every one, the files 64 at a time, the folders walked together.
@Test func deleteOnAServerTakesAllItemsTogether() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    for i in 0..<70 {
        try Data([1]).write(to: URL(fileURLWithPath: d + "/f\(i)"))
        try FileManager.default.createDirectory(atPath: d + "/d\(i)", withIntermediateDirectories: true)
        try Data([1]).write(to: URL(fileURLWithPath: d + "/d\(i)/x"))
    }
    // And one inside a folder also picked (search results): it goes with the folder, no error.
    let sources = (0..<70).map { d + "/f\($0)" } + (0..<70).map { d + "/d\($0)" } + [d + "/d5/x"]
    let fs = RemoteFS(.local(), env: [:])
    let c = try fs.session(), before = c.roundTrips
    let job = FileJob(.delete, sources: sources, from: .sftp(.local()), to: .sftp(.local()), destDir: nil)
    job.deleteAcross(fs)
    let p = job.progress
    #expect(p.state == .done && p.errors.isEmpty && p.doneFiles == 141 && p.totalFiles == 141, "\(p.errors)")
    #expect(try FileManager.default.contentsOfDirectory(atPath: d).isEmpty)
    // 141 looks: 3; the files: 64 + 6; the folders: 2 batches of open, the reads with the end, and their files; their
    // RMDIRs: 2.
    // One at a time: 631.
    #expect(c.roundTrips - before == 3 + 2 + 6 + 2, "\(c.roundTrips - before)")
}

/// A file that can't go is asked about alone (Retry / Skip), and the folders above it stay without a "not empty"
/// each.
@Test func deleteOnAServerReportsOnlyWhatStays() throws {
    let d = tempDir()
    defer { chmod(d + "/t/7/a/b", 0o755); try? FileManager.default.removeItem(atPath: d) }
    try makeLevels(d + "/t")
    chmod(d + "/t/7/a/b", 0o555)   // its file can't go
    let skip = FileJob(.delete, sources: [d + "/t"], from: .sftp(.local()), to: .sftp(.local()), destDir: nil)
    skip.run()
    #expect(skip.progress.errors.count == 1 && skip.progress.errors.first?.hasPrefix(d + "/t/7/a/b/f: ") == true, "\(skip.progress.errors)")
    #expect(try FileManager.default.contentsOfDirectory(atPath: d + "/t") == ["7"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: d + "/t/7/a") == ["b"], "its own file went")

    let retry = FileJob(.delete, sources: [d + "/t"], from: .sftp(.local()), to: .sftp(.local()), destDir: nil)
    retry.resolveError = { path, _ in
        chmod((path as NSString).deletingLastPathComponent, 0o755)   // it can go now
        return (.retry, false)
    }
    retry.run()
    #expect(retry.progress.errors.isEmpty && !FileManager.default.fileExists(atPath: d + "/t"), "\(retry.progress.errors)")
}

/// Compare with a server listed one folder at a time, one side after the other. Level by level now, 64 folders
/// together, both sides at once; the rows come out as before.
@Test func compareWithAServerGoesLevelByLevel() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try makeLevels(d + "/L")
    try FileManager.default.copyItem(atPath: d + "/L", toPath: d + "/R")   // dates too
    try Data([2]).write(to: URL(fileURLWithPath: d + "/R/33/a/b/new"))
    let fs = RemoteFS(.local(), env: [:])
    defer { fs.close() }
    let c = try fs.session(), before = c.roundTrips
    let plan = DirSync.compare(left: d + "/L", right: d + "/R", listRight: DirSync.lister(fs), tolerance: 1)
    #expect(plan.count == 211 && plan.filter { $0.action != .equal }.map(\.path) == ["33/a/b/new"])
    #expect(plan.prefix(4).map(\.path) == ["0/a/b/f", "0/a/f", "0/f", "1/a/b/f"], "as a walk into each folder in turn")
    // The server's side: the top: open, then its reads with the end (closes aren't waited for); each level of 70: 2
    // batches of those 2. One at a time: 844.
    #expect(c.roundTrips - before == 2 + 3 * 4, "\(c.roundTrips - before)")
}

/// Synchronize looked at each side of each pair on its own (then the scan and the copy looked again): ~5 round
/// trips a pair before its first byte. Every pair's two sides together now, what's seen used on.
@Test func syncLooksAtEveryPairTogether() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let fm = FileManager.default, (l, r) = (d + "/L", d + "/R")
    func write(_ p: String, _ s: String, _ t: Double) throws {
        try fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(s.utf8).write(to: URL(fileURLWithPath: p))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: t)], ofItemAtPath: p)
    }
    for i in 0..<70 { try write(l + "/f\(i)", "new", 2_000_000); try write(r + "/f\(i)", "old", 1_000_000) }

    let c = try SFTPClient(.local())
    defer { c.close() }
    let before = c.roundTrips
    let looked = c.lstat((0..<70).map { r + "/f\($0)" } + [r + "/missing"])
    #expect(c.roundTrips - before == 2, "64, then 7 more")
    #expect(looked.count == 71 && looked[0].value??.size == 3 && looked[70].value! == nil)

    let server = Endpoint.sftp(.local())
    let (a, b) = (DirSync.lister(.local), DirSync.lister(server))
    let plan = DirSync.compare(left: l, right: r, list: a.list, listRight: b.list, tolerance: 1)
    a.close(); b.close()
    // After Compare: a source edited, a target edited, a target gone. Those three stay as they are.
    try write(l + "/f1", "edited", 3_000_000); try write(r + "/f2", "edited", 3_000_000); try fm.removeItem(atPath: r + "/f3")
    let jobs = DirSync.jobs(plan, left: l, right: r, sides: (.local, server))
    try #require(jobs.count == 1)
    let job = jobs[0].job
    job.run()
    #expect(Set(job.progress.errors) == Set([l + "/f1", r + "/f2", r + "/f3"].map { $0 + ": changed since Compare, skipped" }))
    #expect(job.progress.state == .done && job.progress.totalFiles == 67 && job.progress.doneFiles == 67)
    func read(_ p: String) -> String? { fm.contents(atPath: p).map { String(decoding: $0, as: UTF8.self) } }
    #expect(read(r + "/f0") == "new" && read(r + "/f69") == "new" && read(r + "/f1") == "old" && read(r + "/f2") == "edited" && read(r + "/f3") == nil)
}
