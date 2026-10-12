import Foundation
import Testing
@testable import DFMCore

// Task 8 admin review: one test per fixed finding, named by its ID.

/// S1: a pasteboard item (any app can write one) must not name a local program for the transfer to run.
@Test func pastedServerItemCannotPickALocalProgram() throws {
    let json = #"{"host":"anything","localServer":"/tmp/evil"}"#
    let t = try JSONDecoder().decode(SFTPTarget.self, from: Data(json.utf8))
    #expect(t.localServer == nil)
    #expect(t == SFTPTarget(host: "anything"))
    let encoded = String(decoding: try JSONEncoder().encode(SFTPTarget.local()), as: UTF8.self)
    #expect(!encoded.contains("localServer"))
}

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r8-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

/// R4: rename on a server (F6 in place) must never replace what's already there.
@Test func remoteRenameRefusesAnExistingTarget() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try Data("new".utf8).write(to: URL(fileURLWithPath: d + "/nginx.conf.new"))
    try Data("live".utf8).write(to: URL(fileURLWithPath: d + "/nginx.conf"))
    try FileManager.default.createDirectory(atPath: d + "/dir", withIntermediateDirectories: false)
    let c = try SFTPClient(.local())
    defer { c.close() }
    #expect(throws: SFTPError.self) { try c.rename(d + "/nginx.conf.new", d + "/nginx.conf", replace: false) }
    #expect(throws: SFTPError.self) { try c.rename(d + "/nginx.conf.new", d + "/dir", replace: false) }
    #expect(try String(contentsOfFile: d + "/nginx.conf", encoding: .utf8) == "live")
    #expect(try String(contentsOfFile: d + "/nginx.conf.new", encoding: .utf8) == "new")
    try c.rename(d + "/nginx.conf.new", d + "/nginx.conf.bak", replace: false)
    #expect(FileManager.default.fileExists(atPath: d + "/nginx.conf.bak"))
}

/// R5/R6/R12: deleting a big tree on a server is a queued job over one connection; what can't go is reported
/// per path and the rest still goes.
@Test func remoteDeleteJobRemovesATreeAndReportsWhatItCouldNot() throws {
    let d = tempDir()
    defer { chmod(d + "/tree/locked", 0o755); try? FileManager.default.removeItem(atPath: d) }
    for i in 0..<300 {
        let sub = d + "/tree/node_modules/p\(i % 30)"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sub + "/f\(i).js", contents: Data("x".utf8))
    }
    try FileManager.default.createDirectory(atPath: d + "/tree/locked", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: d + "/tree/locked/keep", contents: nil)
    chmod(d + "/tree/locked", 0o555)
    try FileManager.default.createSymbolicLink(atPath: d + "/tree/link", withDestinationPath: d + "/outside")
    try FileManager.default.createDirectory(atPath: d + "/outside", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: d + "/outside/safe", contents: nil)

    let job = FileJob(.delete, sources: [d + "/tree"], from: .sftp(.local()), to: .sftp(.local()), destDir: nil)
    job.run()
    #expect(job.progress.state == .done)
    #expect(job.progress.errors.count == 1, "\(job.progress.errors)")   // locked/keep; its folders stay, not reported twice
    #expect(FileManager.default.fileExists(atPath: d + "/tree/locked/keep"))
    #expect(!FileManager.default.fileExists(atPath: d + "/tree/node_modules"))
    #expect(FileManager.default.fileExists(atPath: d + "/outside/safe"))   // the link went, not what it points to
}

/// L2: merging a folder into an existing one keeps the existing folder's mode and dates.
@Test func mergeKeepsTheTargetFoldersPermissions() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let fm = FileManager.default
    try fm.createDirectory(atPath: d + "/src/.ssh", withIntermediateDirectories: true)
    fm.createFile(atPath: d + "/src/.ssh/new_key", contents: nil)
    chmod(d + "/src/.ssh", 0o777)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 946_684_800)], ofItemAtPath: d + "/src/.ssh")
    try fm.createDirectory(atPath: d + "/dst/.ssh", withIntermediateDirectories: true)
    chmod(d + "/dst/.ssh", 0o700)
    let before = try fm.attributesOfItem(atPath: d + "/dst/.ssh")[.modificationDate] as? Date
    let job = FileJob(.copy, sources: [d + "/src/.ssh"], destDir: d + "/dst")
    job.resolveConflict = { _ in (.overwrite, false) }
    job.run()
    #expect(fm.fileExists(atPath: d + "/dst/.ssh/new_key"))
    #expect(FileJob.lstat(d + "/dst/.ssh").map { $0.st_mode & 0o777 } == 0o700)
    let after = try fm.attributesOfItem(atPath: d + "/dst/.ssh")[.modificationDate] as? Date
    #expect(after != Date(timeIntervalSince1970: 946_684_800) && after! >= before!)
}

/// L4: "apply to all" never covers replacing a folder with a file; that one is always asked.
@Test func replacingAFolderWithAFileIsAlwaysAsked() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let fm = FileManager.default
    for p in ["src/a.txt", "src/build", "dst/a.txt", "dst/build/keep.o"] {
        try fm.createDirectory(atPath: (d + "/" + p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: d + "/" + p, contents: Data("x".utf8))
    }
    let asked = QAFlagCounter()
    let job = FileJob(.copy, sources: [d + "/src/a.txt", d + "/src/build"], destDir: d + "/dst")
    job.resolveConflict = { c in
        asked.add()
        return c.replacesFolder ? (.skip, false) : (.overwrite, true)   // "Overwrite all" on the first one
    }
    job.run()
    #expect(asked.count == 2)
    #expect(fm.fileExists(atPath: d + "/dst/build/keep.o"))
}

/// L5: a folder that can't be read is an error, not silently an empty copy.
@Test func copyingAnUnreadableFolderIsAnError() throws {
    let d = tempDir()
    defer { chmod(d + "/src/secret", 0o755); try? FileManager.default.removeItem(atPath: d) }
    let fm = FileManager.default
    try fm.createDirectory(atPath: d + "/src/secret", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: d + "/dst", withIntermediateDirectories: true)
    fm.createFile(atPath: d + "/src/secret/data", contents: nil)
    chmod(d + "/src/secret", 0o000)
    let job = FileJob(.copy, sources: [d + "/src/secret"], destDir: d + "/dst")
    job.run()
    #expect(job.progress.errors.count == 1, "\(job.progress.errors)")
    #expect(job.results.isEmpty)   // nothing to undo as if it were a full copy
}

final class QAFlagCounter: @unchecked Sendable {
    private let l = NSLock(); private var n = 0
    var count: Int { l.withLock { n } }
    func add() { l.withLock { n += 1 } }
}

/// L3: a folder that can't be read on the source side is not "empty": mirror must not trash its twin.
@Test func mirrorNeverTrashesUnderAnUnreadableFolder() throws {
    let d = tempDir()
    defer { chmod(d + "/L/photos", 0o755); try? FileManager.default.removeItem(atPath: d) }
    let fm = FileManager.default
    for p in ["L/photos/1.jpg", "R/photos/1.jpg", "R/photos/2.jpg", "L/same.txt", "R/same.txt"] {
        try fm.createDirectory(atPath: (d + "/" + p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: d + "/" + p, contents: nil)
    }
    chmod(d + "/L/photos", 0o000)
    let items = DirSync.mirror(DirSync.compare(left: d + "/L", right: d + "/R"), toRight: true)
    #expect(!items.contains { $0.action == .trashRight || $0.action == .trashLeft }, "\(items.map { ($0.path, $0.action) })")
    let bad = items.first { $0.path == "photos" }
    #expect(bad?.unreadable != nil && bad?.action == .skip)
    #expect(bad.map(DirSync.choices) == [.skip])

    chmod(d + "/L", 0o000)   // the root itself: nothing at all to do
    defer { chmod(d + "/L", 0o755) }
    let root = DirSync.mirror(DirSync.compare(left: d + "/L", right: d + "/R"), toRight: true)
    #expect(root.count == 1 && root[0].unreadable != nil && root[0].action == .skip)
}

/// V1: in a file too big to load whole, the window at the end must hold the last line — whatever the line lengths.
@Test func bigFileWindowAtTheEndReachesTheLastLine() {
    var text = ""
    for i in 0..<5000 { text += "LIVE \(i) " + String(repeating: "x", count: i % 37) + "\n" }
    text += "NEEDLE-AT-END ERROR\n"
    let d = Data(text.utf8)
    for size in [1000, 4096, 65_536] {
        let w = BigFile.window(d, around: d.count, size: size)
        #expect(w.upperBound == d.count, "size \(size)")
        #expect(String(decoding: d[w], as: UTF8.self).hasSuffix("NEEDLE-AT-END ERROR\n"))
        // Sliding down from the line before the end (what scrolling does) must reach it too.
        let near = BigFile.window(d, around: BigFile.lineStart(d, at: d.count - 30), size: size)
        #expect(near.upperBound == d.count, "size \(size)")
    }
}

/// R3: F4 on a server file. Saving never silently overwrites a change made on the server meanwhile, never leaves
/// a half-written file there, keeps the mode, and writes through a symlink instead of replacing it.
@Test func remoteEditSaveChecksForChangesAndReplacesSafely() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let fm = FileManager.default
    let conf = d + "/srv/nginx.conf", local = d + "/local.conf"
    try fm.createDirectory(atPath: d + "/srv", withIntermediateDirectories: true)
    try Data("server v1\n".utf8).write(to: URL(fileURLWithPath: conf))
    chmod(conf, 0o640)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: conf)
    let c = try SFTPClient(.local())
    defer { c.close() }

    var base = try c.download(conf, to: local)
    #expect(fm.contents(atPath: local) == Data("server v1\n".utf8))
    #expect(FileJob.lstat(local).map { $0.st_mode & 0o777 } == 0o600)

    try Data("mine\n".utf8).write(to: URL(fileURLWithPath: local))
    base = try c.upload(local, to: conf, baseline: base)
    #expect(fm.contents(atPath: conf) == Data("mine\n".utf8))
    #expect(FileJob.lstat(conf).map { $0.st_mode & 0o777 } == 0o640)

    // A colleague edits it on the server; our next save must stop and say so.
    try Data("mine\n# changed-on-server-by-colleague\n".utf8).write(to: URL(fileURLWithPath: conf))
    try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: conf)
    try Data("mine v2\n".utf8).write(to: URL(fileURLWithPath: local))
    #expect(throws: SFTPClient.ChangedOnServer.self) { try c.upload(local, to: conf, baseline: base) }
    #expect(fm.contents(atPath: conf) == Data("mine\n# changed-on-server-by-colleague\n".utf8))
    try c.upload(local, to: conf, baseline: base, force: true)   // "Overwrite"
    #expect(fm.contents(atPath: conf) == Data("mine v2\n".utf8))

    // Through a symlink: the link stays, its target gets the text.
    try fm.createSymbolicLink(atPath: d + "/srv/current.conf", withDestinationPath: "nginx.conf")
    let lb = try c.download(d + "/srv/current.conf", to: local)
    try Data("via link\n".utf8).write(to: URL(fileURLWithPath: local))
    try c.upload(local, to: d + "/srv/current.conf", baseline: lb)
    #expect(try fm.destinationOfSymbolicLink(atPath: d + "/srv/current.conf") == "nginx.conf")
    #expect(fm.contents(atPath: conf) == Data("via link\n".utf8))

    #expect(try fm.contentsOfDirectory(atPath: d + "/srv").sorted() == ["current.conf", "nginx.conf"])   // no partials left
}

/// R10: the app keeps track of shared connections so it can end them; stopping one forgets it (and a target
/// without ssh — the local test server — is never stopped through ssh).
@Test func sharedConnectionsAreTrackedAndReleased() {
    let t = SFTPTarget(host: "dfm-r10-\(UUID().uuidString.prefix(8)).invalid")
    SFTP.noteMaster(t)
    #expect(SFTP.masterTargets.contains(t))
    SFTP.stopMaster(t, now: false)   // nothing is listening: ssh -O stop just fails, quickly
    #expect(!SFTP.masterTargets.contains(t))
    SFTP.noteMaster(.local())
    SFTP.stopMaster(.local(), now: true)
}
