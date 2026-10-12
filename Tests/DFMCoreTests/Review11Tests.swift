import Foundation
import Testing
@testable import DFMCore

// Task 11 review.

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r11-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
private func write(_ path: String, _ text: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

/// H1: the server listing came from `sftp -b ls` text: a name with a line break listed as two rows (F8 on the ghost
/// deleted the real "new"), and `{…}` was brace-expanded, listing other files.
@Test func serverListingShowsEachNameOnceAndAsItIs() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    write(d + "/new", "real")
    write(d + "/new\nline.txt", "")
    write(d + "/x/inside_plain.txt", "")
    write(d + "/{x}/inside_brace.txt", "")
    write(d + "/d1/a", ""); write(d + "/d2/b", "")
    write(d + "/d{1,2}/in_dbrace.txt", "")

    let items = try SFTP.list(.local(), d)
    #expect(Set(items.map(\.name)) == ["new", "new\nline.txt", "x", "{x}", "d1", "d2", "d{1,2}"] && items.count == 7)
    #expect(try SFTP.list(.local(), d + "/{x}").map(\.name) == ["inside_brace.txt"])
    #expect(try SFTP.list(.local(), d + "/d{1,2}").map(\.name) == ["in_dbrace.txt"])
    #expect(items.first { $0.name == "new" }?.size == 4)

    // F8 on the "new" row removes "new", nothing else.
    let c = try SFTPClient(.local())
    defer { c.close() }
    try c.remove(d + "/" + #require(items.first { $0.name == "new" }).name)
    #expect(!FileManager.default.fileExists(atPath: d + "/new") && FileManager.default.fileExists(atPath: d + "/new\nline.txt"))
}

/// H1: a name that isn't UTF-8 (Latin-1 "café") must come back from a listing as a string that addresses the same
/// bytes — else F3 says "No such file" and an action may hit another file. (macOS won't make such a name; the
/// wire codec is tested here, the round trip on a real server in QASSH.)
@Test func nonUTF8NamesSurviveTheWire() throws {
    for raw: [UInt8] in [Array("caf".utf8) + [0xE9] + Array(".txt".utf8), [0xFF, 0xFE], Array("ok-ü".utf8),
                         Array("\u{F00E9}".utf8)] {   // a real character of the escape block itself
        var p = Packet(SFTPClient.READDIR)
        p.string(Data(raw))
        var r = Reader(p.body.dropFirst(5))
        let name = try r.text()
        var back = Packet(SFTPClient.READDIR)
        back.string(name)
        #expect(Array(back.body.dropFirst(9)) == raw, "\(raw)")
    }
    var r = Reader({ var p = Packet(SFTPClient.READDIR); p.string(Data([0x63, 0xE9])); return p.body.dropFirst(5) }())
    #expect(try r.text().listed == "c\\xE9", "shown as its byte, not a blank box")
    #expect("ok-ü".listed == "ok-ü")
}

private let spotlightIndexesHome = {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    p.arguments = ["-onlyin", NSHomeDirectory(), "-count", "kMDItemFSName == 'README*'"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    let n = Int(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    p.waitUntilExit()
    return (n ?? 0) > 0
}()

/// H2: a Spotlight search read all of mdfind's output before the first hit (⎋ did nothing meanwhile: 7 s for a home
/// folder of 400 000 items), and an empty name (`kMDItemFSName == '*'`) found nothing at all on macOS 27.
@Test(.enabled(if: spotlightIndexesHome)) func spotlightHitsStreamAndStopOnCancel() {
    var q = SearchQuery(root: NSHomeDirectory())
    q.name = "*"
    q.spotlight = true
    q.includeHidden = true
    var hits = 0
    let start = Date()
    FileSearch.run(q, isCancelled: { hits >= 100 || Date().timeIntervalSince(start) > 20 }) { _ in hits += 1 }
    #expect(hits >= 100)
    #expect(Date().timeIntervalSince(start) < 3, "stopped at the 100th hit, not after mdfind's last line")
}

/// A9: the ⌘⇧M preview lstat'ed every changed name and compiled the regex for every file, on each key — thousands
/// of network calls per key on a NAS. The preview checks the folder's names (listed once); Apply still asks the disk.
@Test func multiRenamePreviewNeedsNoDisk() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    FileManager.default.createFile(atPath: d + "/keep", contents: nil)
    FileManager.default.createFile(atPath: d + "/a", contents: nil)
    var asked: [String] = []
    #expect(BatchRename.conflicts([(d + "/a", d + "/KEEP")]) { asked.append($0); return $0.hasSuffix("/KEEP") } == [d + "/a"])
    #expect(asked == [d + "/KEEP"])
    #expect(BatchRename.conflicts([(d + "/a", d + "/new")]) { _ in false }.isEmpty)
    #expect(throws: BatchRename.Failure.self) { try BatchRename.run([(d + "/a", d + "/keep")]) }   // Apply: the disk itself

    var p = RenamePattern()
    p.find = #"(\d+)"#
    p.replace = "<$1>"
    p.regex = true
    #expect(try p.apply([("a1", 0), ("b22", 0), ("c", 0)], parent: d) == ["a<1>", "b<22>", "c"])
    p.find = "("
    #expect(throws: (any Error).self) { try p.apply([("a", 0)], parent: d) }
}

/// A6: `/` and `&` on a big log scanned its mapping for seconds; a copytruncate meanwhile turned that into SIGBUS —
/// the app gone, an editor's unsaved text with it. They read the file in pieces now: one cut short is read to its
/// new end.
@Test func viewerScansReadTheFileNotItsMapping() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let path = d + "/app.log"
    var text = ""
    for i in 0..<200_000 { text += i == 1000 ? "a NEEDLE here\n" : i == 150_000 ? "late needle\n" : "line \(i) of the log\n" }
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    let early = text.utf8.count - text.drop { $0 != "N" }.utf8.count
    let mapped = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)   // as the viewer holds it
    #expect(truncate(path, 1 << 20) == 0)   // copytruncate: touching `mapped` past 1 MB would now be SIGBUS
    let needle = Array("needle".utf8)
    #expect(BigFile.find(needle, inFile: path, from: 0, caseSensitive: false) == early)
    #expect(BigFile.find(needle, inFile: path, from: early + 1, caseSensitive: false) == nil, "the late one is gone with the cut")
    #expect(BigFile.find(needle, inFile: path, from: 0, caseSensitive: false, chunk: 7) == early, "across piece edges")
    for chunk in [4 << 20, 33] {
        let (kept, more) = LineFilter("needle")!.apply(fileAt: path, limit: 1 << 20, chunk: chunk)
        #expect(String(decoding: kept, as: UTF8.self) == "a NEEDLE here\n" && !more, "\(chunk)")
    }
    #expect(LineFilter("!line")!.apply(fileAt: path, limit: 1 << 20, chunk: 33).0 == Data("a NEEDLE here\n".utf8))
    _ = mapped.count
}

/// N23: F6 within one server walked the whole tree before the rename (2 s for 1 230 files on a LAN; minutes for
/// 50 000 on a far server) and once more after it, only for the progress bar. It renames at once and counts items.
@Test func moveOnOneServerRenamesWithoutWalkingTheTree() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    for i in 0..<3 { for j in 0..<4 { write(d + "/tree/s\(i)/f\(j)", "x") } }
    try FileManager.default.createDirectory(atPath: d + "/to", withIntermediateDirectories: true)
    let job = FileJob(.move, sources: [d + "/tree"], from: .sftp(.local()), to: .sftp(.local()), destDir: d + "/to")
    job.run()
    #expect(job.progress.errors.isEmpty)
    #expect(job.progress.totalFiles == 1 && job.progress.doneFiles == 1, "items, not the \(job.progress.totalFiles) files below")
    #expect(FileManager.default.fileExists(atPath: d + "/to/tree/s2/f3") && !FileManager.default.fileExists(atPath: d + "/tree"))
}

/// A11: each small file uploaded took ~8 requests one after another (2 of them not needed), and F8 on a server
/// folder one round trip per file — 10 000 files at 100 ms RTT, hours. Now: the file's mode and date go right
/// behind its close, and a folder's files are removed with all their requests in flight.
@Test func serverWritesTakeFewerRoundTrips() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let c = try SFTPClient(.local())
    defer { c.close() }
    var trips = c.roundTrips
    let w = try c.openWrite(d + "/.part", exclusive: true)
    try w.write(Data("hello".utf8))
    #expect(try w.finish(mtime: 1_000_000_000, mode: 0o640) == nil)
    #expect(c.roundTrips - trips <= 2, "open, then close + mode and date together: \(c.roundTrips - trips)")
    var st = stat()
    stat(d + "/.part", &st)
    #expect(st.st_mode & 0o7777 == 0o640 && st.st_mtimespec.tv_sec == 1_000_000_000)

    trips = c.roundTrips
    try c.rename(d + "/.part", d + "/a.txt")
    #expect(c.roundTrips - trips == 2, "a look first: a server whose RENAME replaces (SFTPGo, rclone) mustn't")
    FileManager.default.createFile(atPath: d + "/b.txt", contents: nil)
    #expect(throws: SFTPError.self) { try c.rename(d + "/a.txt", d + "/b.txt") }   // still never over a file
    #expect(try String(contentsOfFile: d + "/a.txt", encoding: .utf8) == "hello")

    for i in 0..<50 { FileManager.default.createFile(atPath: d + "/f\(i)", contents: nil) }
    trips = c.roundTrips
    let failed = c.remove((0..<50).map { d + "/f\($0)" } + [d + "/missing"])
    #expect(failed.map(\.path) == [d + "/missing"])
    #expect(c.roundTrips - trips <= 2, "\(c.roundTrips - trips)")
    #expect(!FileManager.default.fileExists(atPath: d + "/f49"))
}

/// N4: a server's symlinks showed the link's own size and no target. The listing now says where each points, and
/// whether that's there (asked with the listing, all in flight together).
@Test func serverListingSaysWhereLinksPoint() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try FileManager.default.createDirectory(atPath: d + "/usr/bin", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: d + "/bin", withDestinationPath: "usr/bin")
    try FileManager.default.createSymbolicLink(atPath: d + "/gone", withDestinationPath: "nope")
    var links: [String: String] = [:]
    _ = try SFTP.list(.local(), d, links: { name, target, error in links[name] = "\(target) \(error)" })
    #expect(links == ["bin": "usr/bin 0", "gone": "nope \(ENOENT)"])
}

/// A13: an SSH tab and an SFTP panel opened on one server at once logged in twice — the password asked twice, and
/// the master that lost the socket out of Disconnect's and ⌘Q's reach. Logins to one server take turns now.
@Test func loginsToOneServerTakeTurns() throws {
    let t = SFTPTarget(host: "dfm-a13-\(UUID().uuidString.prefix(6)).invalid")
    let first = try #require(SFTP.beginLogin(t, cancel: nil))
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { first.end() }
    let started = Date()
    let second = SFTP.beginLogin(t, cancel: nil)   // waits for the first
    #expect(second != nil && Date().timeIntervalSince(started) >= 0.3)
    let other = SFTP.beginLogin(SFTPTarget(host: "dfm-other.invalid"), cancel: nil)   // another server: at once
    other?.end()
    let flag = CancelFlag()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { flag.cancel() }
    #expect(SFTP.beginLogin(t, cancel: flag) == nil, "⎋ stops the wait")
    second?.end()
    SFTP.beginLogin(t, cancel: nil)?.end()   // free again
}

/// N4 (decided): a symlink to a folder sorts with the folders and reads <DIR>, here and on a server (/bin → usr/bin).
@Test func linksToFoldersSortWithFolders() throws {
    func item(_ name: String, _ kind: FileItem.Kind, linkDir: Bool = false) -> FileItem {
        var it = FileItem(name: name, kind: kind, size: 7, mtime: 0, mode: 0o755, flags: 0)
        it.linkDir = linkDir
        return it
    }
    let sorted = [item("a.txt", .file), item("bin", .link, linkDir: true), item("zdir", .dir), item("lnk", .link)]
        .sortedForPanel(by: .name, ascending: true)
    #expect(sorted.map(\.name) == ["bin", "zdir", "a.txt", "lnk"])

    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try FileManager.default.createDirectory(atPath: d + "/usr/bin", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: d + "/bin", withDestinationPath: "usr/bin")
    try FileManager.default.createSymbolicLink(atPath: d + "/f", withDestinationPath: "nope")
    let listed = try SFTP.list(.local(), d, links: { _, _, _ in })
    #expect(listed.first { $0.name == "bin" }?.linkDir == true && listed.first { $0.name == "f" }?.linkDir == false)
}

/// N5: Keep Existing for a tar on a server listed "tar: x: skipping existing file" in red, as if it failed. GNU
/// tar's --skip-old-files says that only with -v: without it, only real errors come out.
@Test func keepExistingOnAServerIsQuiet() {
    let keep = RemoteArchive.extractCommand("/srv/a.tar.gz", to: "/srv/out", keep: true)
    #expect(keep.contains("tar -x --skip-old-files -f") && keep.contains("tar -x -v -k -f"), "\(keep)")
    #expect(RemoteArchive.extractCommand("/srv/a.tar.gz", to: "/srv/out", keep: false).contains("tar -x -v -f"))
}

/// N9: a disk pulled out mid-copy kept a hidden .dfm-partial-… (66 MB) and its ._ twin; nobody would ever know.
/// The next copy into that folder removes the ones over a day old (a newer one may be another copy still running).
@Test func nextCopyRemovesOldPartials() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    write(d + "/src/a.txt", "a")
    for side in ["local", "server"] {
        let dest = d + "/dest-" + side
        for n in [".dfm-partial-old", "._.dfm-partial-old", ".dfm-partial-fresh"] { write(dest + "/" + n, "x") }
        let old = Date().addingTimeInterval(-2 * 86_400)
        for n in [".dfm-partial-old", "._.dfm-partial-old"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dest + "/" + n)
        }
        let job = FileJob(.copy, sources: [d + "/src/a.txt"], from: side == "local" ? .local : .sftp(.local()), to: .local, destDir: dest)
        job.run()
        #expect(job.progress.errors.isEmpty)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dest)) == [".dfm-partial-fresh", "a.txt"], "\(side)")
    }
}

/// Code review: / and & read the file by its path while the window showed its mapping — after logrotate (a new file
/// under the name) or appends, the scan saw another file than the one shown. They read the open file the mapping
/// was made from, up to its size. A short read is no end; a line with no end is read once, not copied per piece.
@Test func viewerScansReadTheFileShown() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let path = d + "/app.log", needle = Array("needle".utf8)
    try Data("one\nNEEDLE in the old\nthree\n".utf8).write(to: URL(fileURLWithPath: path))
    let shown = try #require(BigFile.map(path))
    try FileManager.default.moveItem(atPath: path, toPath: path + ".1")   // logrotate
    try Data("new file, needle here\n".utf8).write(to: URL(fileURLWithPath: path))
    let old = try FileHandle(forWritingTo: URL(fileURLWithPath: path + ".1"))
    try old.seekToEnd()
    try old.write(contentsOf: Data("needle appended\n".utf8))
    try old.close()
    #expect(BigFile.find(needle, in: shown, from: 0, caseSensitive: false) == 4)
    #expect(BigFile.find(needle, in: shown, from: 5, caseSensitive: false) == nil, "past what's shown")
    #expect(LineFilter("needle")!.apply(shown, limit: 1 << 20).0 == Data("NEEDLE in the old\n".utf8))
    #expect(BigFile.find([], inFile: path, from: 0, caseSensitive: false) == nil)

    let long = d + "/min.json"
    try Data((String(repeating: "x", count: 100_000) + "needle").utf8).write(to: URL(fileURLWithPath: long))
    #expect(LineFilter("needle")!.apply(fileAt: long, limit: 1 << 20, chunk: 1000).0.count == 100_006)
}

/// Code review: a running copy sets the source's (old) date on its partial just before the rename, so a copy into
/// the same folder could take it for a day-old leftover and remove it. The name says when it was begun now.
@Test func aRunningCopysPartialIsNotSwept() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    write(d + "/src/a.txt", "a")
    let running = FileJob.partialName(), old = ".dfm-partial-\(Int(Date().timeIntervalSince1970) - 3 * 86_400)-\(UUID().uuidString)"
    for n in [running, old, "._" + old] { write(d + "/dest/" + n, "x") }
    let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)
    for n in [running, old, "._" + old] { try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: d + "/dest/" + n) }
    FileJob(.copy, sources: [d + "/src/a.txt"], destDir: d + "/dest").run()
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: d + "/dest")) == [running, "a.txt"])
    #expect(FileJob.partialMade("x.txt") == nil && FileJob.partialMade(".dfm-partial-" + UUID().uuidString) == 0)
}
