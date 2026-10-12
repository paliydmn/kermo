import Foundation
import Testing
@testable import DFMCore

// Copy / move between this Mac and "servers": the real /usr/libexec/sftp-server on pipes. A second server is the
// same binary under another name (a symlink), so the two targets differ and server → server really streams.

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-xfer-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private func randomData(_ n: Int) -> Data {
    var d = Data(count: n)
    d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }
    return d
}

/// Another sftp-server, under a name of its own (pkill-able without touching other tests' servers), linked in `dir`.
private func otherServer(in dir: String, _ name: String = "sftp-server-" + UUID().uuidString) -> SFTPTarget {
    let link = dir + "/" + name
    try! FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/usr/libexec/sftp-server")
    return .local(server: link)
}

nonisolated(unsafe) private let fm = FileManager.default
private let old: Double = 1_000_000_000   // 2001-09-09: clearly not "now"

private func mtime(_ p: String) -> Double { (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0 }
private func mode(_ p: String) -> Int { (try? fm.attributesOfItem(atPath: p)[.posixPermissions] as? Int) ?? 0 }

/// tree/ (0750)
///   a.txt, empty, "it's [1] *?.txt", кирилиця/deep.bin (300 KB), link → a.txt, big.bin (3 MB)
private func makeXferTree(_ root: String) -> [String: Data] {
    var files: [String: Data] = [:]
    files["a.txt"] = Data("A".utf8)
    files["empty"] = Data()
    files["it's [1] *?.txt"] = Data("quoted".utf8)
    files["кирилиця/deep.bin"] = randomData(300_000)
    files["big.bin"] = randomData(3_000_000)
    for (rel, data) in files {
        let p = root + "/tree/" + rel
        try! fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! data.write(to: URL(fileURLWithPath: p))
        try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: old), .posixPermissions: 0o640], ofItemAtPath: p)
    }
    try! fm.createSymbolicLink(atPath: root + "/tree/link", withDestinationPath: "a.txt")
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: old)], ofItemAtPath: root + "/tree/кирилиця")
    try! fm.setAttributes([.posixPermissions: 0o750, .modificationDate: Date(timeIntervalSince1970: old)], ofItemAtPath: root + "/tree")
    return files
}

private func expectXferTree(_ root: String, _ files: [String: Data], sourceLocation: SourceLocation = #_sourceLocation) {
    for (rel, data) in files {
        let p = root + "/tree/" + rel
        #expect(fm.contents(atPath: p) == data, "\(rel)", sourceLocation: sourceLocation)
        #expect(mtime(p) == old, "\(rel) mtime", sourceLocation: sourceLocation)
        #expect(mode(p) == 0o640, "\(rel) mode", sourceLocation: sourceLocation)
    }
    #expect((try? fm.destinationOfSymbolicLink(atPath: root + "/tree/link")) == "a.txt", sourceLocation: sourceLocation)
    #expect(mode(root + "/tree") == 0o750, sourceLocation: sourceLocation)
    #expect(mtime(root + "/tree") == old, sourceLocation: sourceLocation)
    #expect(mtime(root + "/tree/кирилиця") == old, sourceLocation: sourceLocation)
    let leftovers = (fm.enumerator(atPath: root)?.allObjects as? [String] ?? []).filter { $0.contains(".dfm-partial-") }
    #expect(leftovers.isEmpty, "partial files left: \(leftovers)", sourceLocation: sourceLocation)
}

private func run(_ job: FileJob) -> FileJob.Progress {
    job.run()
    return job.progress
}

@Test func uploadDownloadAndServerToServer() throws {
    let home = tempDir(), up = tempDir(), down = tempDir(), across = tempDir()
    defer { for d in [home, up, down, across] { try? fm.removeItem(atPath: d) } }
    let a = SFTPTarget.local(), b = otherServer(in: home)
    let files = makeXferTree(home)

    var p = run(FileJob(.copy, sources: [home + "/tree"], from: .local, to: .sftp(a), destDir: up))
    #expect(p.state == .done && p.errors.isEmpty, "\(p.errors)")
    #expect(p.doneFiles == p.totalFiles && p.doneBytes == p.totalBytes && p.totalFiles == 6)
    expectXferTree(up, files)

    p = run(FileJob(.copy, sources: [up + "/tree"], from: .sftp(a), to: .local, destDir: down))
    #expect(p.state == .done && p.errors.isEmpty, "\(p.errors)")
    expectXferTree(down, files)

    p = run(FileJob(.copy, sources: [up + "/tree"], from: .sftp(a), to: .sftp(b), destDir: across))
    #expect(p.state == .done && p.errors.isEmpty, "\(p.errors)")
    #expect(p.doneBytes == p.totalBytes)
    expectXferTree(across, files)
}

@Test func sameServerCopyAndMove() throws {
    let a = SFTPTarget.local()
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let files = makeXferTree(d)
    try fm.createDirectory(atPath: d + "/copy", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: d + "/moved", withIntermediateDirectories: true)

    var p = run(FileJob(.copy, sources: [d + "/tree"], from: .sftp(a), to: .sftp(a), destDir: d + "/copy"))
    #expect(p.state == .done && p.errors.isEmpty, "\(p.errors)")
    #expect(p.doneBytes == p.totalBytes)
    expectXferTree(d + "/copy", files)

    // Copy onto itself duplicates; into itself is refused.
    p = run(FileJob(.copy, sources: [d + "/copy/tree/a.txt"], from: .sftp(a), to: .sftp(a), destDir: d + "/copy/tree"))
    #expect(fm.contents(atPath: d + "/copy/tree/a 2.txt") == Data("A".utf8))
    let job = FileJob(.copy, sources: [d + "/copy/tree"], from: .sftp(a), to: .sftp(a), destDir: d + "/copy/tree/кирилиця")
    job.resolveError = { _, _ in (.skip, false) }
    #expect(run(job).errors.count == 1)

    p = run(FileJob(.move, sources: [d + "/tree"], from: .sftp(a), to: .sftp(a), destDir: d + "/moved"))
    #expect(p.state == .done && p.errors.isEmpty, "\(p.errors)")
    #expect(!fm.fileExists(atPath: d + "/tree"))
    expectXferTree(d + "/moved", files)
    #expect(p.doneFiles == p.totalFiles && p.doneBytes == p.totalBytes)
}

@Test func moveAcrossDeletesOnlyWhatArrived() throws {
    let a = SFTPTarget.local()
    let home = tempDir(), remote = tempDir()
    defer { for d in [home, remote] { try? fm.removeItem(atPath: d) } }
    let files = makeXferTree(home)
    // A clash on one file, answered Skip: that file stays at home, the rest move.
    try fm.createDirectory(atPath: remote + "/tree", withIntermediateDirectories: true)
    try Data("theirs".utf8).write(to: URL(fileURLWithPath: remote + "/tree/a.txt"))
    let job = FileJob(.move, sources: [home + "/tree"], from: .local, to: .sftp(a), destDir: remote)
    nonisolated(unsafe) var asked: [String] = []
    job.resolveConflict = { c in
        asked.append((c.dst as NSString).lastPathComponent)
        return c.bothDirs ? (.overwrite, false) : (.skip, false)
    }
    let p = run(job)
    #expect(p.state == .done && p.errors.isEmpty, "\(p.errors)")
    #expect(asked == ["tree", "a.txt"])
    #expect(fm.contents(atPath: remote + "/tree/a.txt") == Data("theirs".utf8))
    #expect(fm.contents(atPath: home + "/tree/a.txt") == Data("A".utf8))
    #expect(fm.contents(atPath: remote + "/tree/big.bin") == files["big.bin"])
    #expect(!fm.fileExists(atPath: home + "/tree/big.bin"))
    #expect(!fm.fileExists(atPath: home + "/tree/кирилиця"))
    #expect(try fm.contentsOfDirectory(atPath: home + "/tree") == ["a.txt"])
    #expect(p.doneFiles == p.totalFiles && p.doneBytes == p.totalBytes)
}

@Test func conflictChoicesOnAServer() throws {
    let a = SFTPTarget.local()
    let home = tempDir(), remote = tempDir()
    defer { for d in [home, remote] { try? fm.removeItem(atPath: d) } }
    func put(_ p: String, _ s: String, _ t: Double) {
        try! Data(s.utf8).write(to: URL(fileURLWithPath: p))
        try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: t)], ofItemAtPath: p)
    }
    for n in ["o", "s", "k", "newer", "older"] { put(home + "/" + n, "new " + n, old + 100) }
    for n in ["o", "s", "k"] { put(remote + "/" + n, "old " + n, old) }
    put(remote + "/newer", "old newer", old)        // remote older → overwritten
    put(remote + "/older", "old older", old + 500)  // remote newer → kept
    try fm.createDirectory(atPath: home + "/f", withIntermediateDirectories: true)
    put(home + "/f/x", "x", old)
    put(remote + "/f", "a file where the folder goes", old)

    let choices: [String: FileJob.ConflictChoice] = ["o": .overwrite, "s": .skip, "k": .keepBoth, "newer": .overwriteIfNewer,
                                                     "older": .overwriteIfNewer, "f": .overwrite]
    let job = FileJob(.copy, sources: choices.keys.sorted().map { home + "/" + $0 }, from: .local, to: .sftp(a), destDir: remote)
    job.resolveConflict = { c in (choices[(c.dst as NSString).lastPathComponent]!, false) }
    let p = run(job)
    #expect(p.state == .done && p.errors.isEmpty, "\(p.errors)")
    func text(_ n: String) -> String? { fm.contents(atPath: remote + "/" + n).map { String(decoding: $0, as: UTF8.self) } }
    #expect(text("o") == "new o")
    #expect(text("s") == "old s")
    #expect(text("k") == "old k" && text("k 2") == "new k")
    #expect(text("newer") == "new newer")
    #expect(text("older") == "old older")
    #expect(text("f/x") == "x")   // a file in the way of a folder is replaced
    #expect(p.doneFiles == p.totalFiles && p.doneBytes == p.totalBytes)

    // Cancel in the dialog stops the job.
    let stop = FileJob(.copy, sources: [home + "/o", home + "/s"], from: .local, to: .sftp(a), destDir: remote)
    stop.resolveConflict = { _ in (.cancel, false) }
    #expect(run(stop).state == .cancelled)
}

/// Waits (busy, the transfer is fast) until the job has moved some bytes of its file, then pauses it.
private func pauseMidFile(_ job: FileJob) throws {
    let deadline = Date().addingTimeInterval(20)
    while job.progress.doneBytes == 0 || job.progress.state != .running {
        try #require(Date() < deadline && job.progress.state != .done, "never saw the transfer start")
    }
    job.isPaused = true
}

@Test(arguments: ["up", "down"]) func pauseAndCancelMidFileLeavesNothing(direction: String) throws {
    let a = SFTPTarget.local()
    let from = tempDir(), to = tempDir()
    defer { try? fm.removeItem(atPath: from); try? fm.removeItem(atPath: to) }
    try randomData(50_000_000).write(to: URL(fileURLWithPath: from + "/huge"))
    let job = FileJob(.copy, sources: [from + "/huge"], from: direction == "up" ? .local : .sftp(a),
                      to: direction == "up" ? .sftp(a) : .local, destDir: to)
    let finished = DispatchSemaphore(value: 0)
    job.onFinish = { finished.signal() }
    job.start()
    try pauseMidFile(job)
    usleep(300_000)
    let held = job.progress.doneBytes
    usleep(300_000)
    #expect(job.progress.doneBytes == held && held > 0 && held < 50_000_000)
    #expect(try fm.contentsOfDirectory(atPath: to).contains { $0.hasPrefix(".dfm-partial-") })
    job.cancel()
    #expect(finished.wait(timeout: .now() + 20) == .success)
    #expect(job.progress.state == .cancelled)
    #expect(try fm.contentsOfDirectory(atPath: to) == [])
}

@Test(arguments: ["up", "down"]) func retryAfterALostConnectionResumes(direction: String) throws {
    let name = "sftp-server-resume-" + UUID().uuidString.prefix(8)
    let from = tempDir(), to = tempDir()
    defer { try? fm.removeItem(atPath: from); try? fm.removeItem(atPath: to) }
    let b = otherServer(in: from, String(name))
    let data = randomData(50_000_000)
    try data.write(to: URL(fileURLWithPath: from + "/huge"))
    let job = FileJob(.copy, sources: [from + "/huge"], from: direction == "up" ? .local : .sftp(b),
                      to: direction == "up" ? .sftp(b) : .local, destDir: to)
    nonisolated(unsafe) var errors: [String] = []
    job.resolveError = { _, message in errors.append(message); return (.retry, false) }
    let finished = DispatchSemaphore(value: 0)
    job.onFinish = { finished.signal() }
    job.start()
    try pauseMidFile(job)
    let kill = Process()
    kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    kill.arguments = ["-f", String(name)]
    try kill.run()
    kill.waitUntilExit()
    usleep(200_000)
    job.isPaused = false
    #expect(finished.wait(timeout: .now() + 60) == .success)
    #expect(job.progress.state == .done)
    #expect(errors.count == 1 && errors.first?.contains("lost") == true, "\(errors)")
    #expect(fm.contents(atPath: to + "/huge") == data)
    #expect(try fm.contentsOfDirectory(atPath: to) == ["huge"])
}

@Test func unsafeNamesAreNotEndpointsOfAPath() {
    for bad in ["", ".", "..", "a/b", "../x", "x\0y"] { #expect(!FileJob.isSafeName(bad), "\(bad)") }
    for good in ["..a", "a..", ".hidden", "it's", "line\nbreak", "кирилиця"] { #expect(FileJob.isSafeName(good), "\(good)") }
}

/// A hostile "server" (a small SFTP v3 responder in Python) lists `../escape.txt` and `a/b` next to `ok.txt`.
/// Downloading its folder copies ok.txt only; the other two are errors, and nothing lands outside the target.
@Test func hostileNamesFromAServerAreRefused() throws {
    let dir = tempDir()
    defer { try? fm.removeItem(atPath: dir) }
    let server = dir + "/evil-server"
    try #"""
    #!/usr/bin/python3 -I
    import sys, struct
    inp, out = sys.stdin.buffer, sys.stdout.buffer
    def rd(n):
        b = inp.read(n)
        if len(b) < n: sys.exit(0)
        return b
    def send(t, body):
        out.write(struct.pack(">IB", len(body) + 1, t) + body); out.flush()
    def s(b): return struct.pack(">I", len(b)) + b
    def attrs(mode, size): return struct.pack(">IQI", 1 | 4, size, mode)
    def status(rid, code): send(101, rid + struct.pack(">I", code) + s(b"") + s(b""))
    DIR, FILE = 0o40755, 0o100644
    entries = [b"../escape.txt", b"ok.txt", b"a/b"]
    listed = False
    while True:
        n = struct.unpack(">I", rd(4))[0]; pkt = rd(n); t = pkt[0]
        if t == 1: send(2, struct.pack(">I", 3)); continue
        rid, rest = pkt[1:5], pkt[5:]
        p = rest[4:4 + struct.unpack(">I", rest[:4])[0]]
        if t in (7, 17):
            if p.endswith(b"/evil"): send(105, rid + attrs(DIR, 0))
            elif p.endswith(b"/evil/ok.txt"): send(105, rid + attrs(FILE, 2))
            else: status(rid, 2)
        elif t == 11: listed = False; send(102, rid + s(b"D"))
        elif t == 12:
            if listed: status(rid, 1)
            else:
                listed = True
                send(104, rid + struct.pack(">I", len(entries)) + b"".join(s(e) + s(e) + attrs(FILE, 2) for e in entries))
        elif t == 3: send(102, rid + s(b"F"))
        elif t == 5:
            off = struct.unpack(">Q", rest[4 + len(p):12 + len(p)])[0]
            if off == 0: send(103, rid + s(b"hi"))
            else: status(rid, 1)
        elif t == 4: status(rid, 0)
        else: status(rid, 8)
    """#.write(toFile: server, atomically: true, encoding: .utf8)
    chmod(server, 0o755)
    let to = tempDir()
    defer { try? fm.removeItem(atPath: to) }
    let job = FileJob(.copy, sources: ["/srv/evil"], from: .sftp(.local(server: server)), to: .local, destDir: to)
    nonisolated(unsafe) var refused: [String] = []
    job.resolveError = { path, _ in refused.append((path as NSString).lastPathComponent); return (.skip, false) }
    let p = run(job)
    #expect(Set(refused) == ["escape.txt", "b"], "\(refused) \(p.errors)")
    #expect(fm.contents(atPath: to + "/evil/ok.txt") == Data("hi".utf8))
    #expect(try fm.contentsOfDirectory(atPath: to) == ["evil"])
    #expect(try fm.contentsOfDirectory(atPath: to + "/evil") == ["ok.txt"])
}
