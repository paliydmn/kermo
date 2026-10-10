import Foundation
import Testing
@testable import DFMCore

// Task 9 QA follow-up (tasks/task9_qa_followup/README.md): one test per fixed finding, named by its ID.

/// A4: Multi-Rename runs every keystroke through the live preview, so half-typed masks and counters must
/// come back as an error the sheet can show — never trap the process.
@Test func renameMaskInputNeverTraps() throws {
    func apply(_ p: RenamePattern, _ name: String = "example.txt", _ i: Int = 1) throws -> String {
        try p.apply(name, index: i, mtime: 0, parent: "/tmp")
    }
    var p = RenamePattern()
    p.nameMask = "[N2-5]"
    #expect(try apply(p) == "xamp.txt")
    p.nameMask = "[N5-1]"   // reversed range
    #expect(throws: RenamePattern.Invalid.self) { try apply(p) }
    p.nameMask = "[N3-2]"   // empty range is fine
    #expect(try apply(p) == ".txt")
    p.nameMask = "[N5-100]"   // past the end: clamped, names differ in length
    #expect(try apply(p) == "ple.txt")
    p.nameMask = "[N100-200]"
    #expect(try apply(p) == ".txt")
    p.nameMask = "[N9223372036854775807-]"
    #expect(try apply(p) == ".txt")

    p = RenamePattern()
    p.nameMask = "[C]"
    p.counterStart = Int.max
    #expect(throws: RenamePattern.Invalid.self) { try apply(p) }
    #expect(try apply(p, "a.txt", 0) == "\(Int.max).txt")
    p.counterStart = 1
    p.counterStep = Int.max
    #expect(throws: RenamePattern.Invalid.self) { try apply(p, "a.txt", 2) }
    p.counterStep = Int.min
    #expect(throws: RenamePattern.Invalid.self) { try apply(p, "a.txt", 2) }
    p.counterStep = 1
    p.counterDigits = Int.max
    #expect(throws: RenamePattern.Invalid.self) { try apply(p) }
    p.counterDigits = 255
    #expect(try apply(p, "a.txt", 0).count == 255 + 4)

    p.nameMask = "[N]"   // counter not used: its inputs don't matter
    p.counterStart = Int.max
    p.counterDigits = Int.max
    #expect(try apply(p) == "example.txt")
}

nonisolated(unsafe) private let fm = FileManager.default

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r9-" + UUID().uuidString
    try! fm.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

/// The same sftp-server under another program name: another "alias" of this Mac's disk.
private func otherServer(in dir: String) -> SFTPTarget {
    let link = dir + "/sftp-server-" + UUID().uuidString
    try! fm.createSymbolicLink(atPath: link, withDestinationPath: "/usr/libexec/sftp-server")
    return .local(server: link)
}

private func mode(_ p: String) -> Int { (try? fm.attributesOfItem(atPath: p)[.posixPermissions] as? Int) ?? 0 }

private func randomData(_ n: Int) -> Data {
    var d = Data(count: n)
    d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }
    return d
}

/// A1: one server described twice (only how long the login lingers differs) is one disk: moving a file onto
/// its own place must not copy it over itself and then delete it.
@Test func moveBetweenTwoDescriptionsOfOneServerKeepsTheFile() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let bytes = randomData(8)
    try bytes.write(to: URL(fileURLWithPath: d + "/item"))
    let a = SFTPTarget.local(), b = SFTPTarget.local(persist: 1)
    #expect(a != b)
    #expect(Endpoint.sftp(a).isSameFilesystem(as: .sftp(b)))
    #expect(!Endpoint.sftp(a).isSameFilesystem(as: .sftp(otherServer(in: d))))
    #expect(!Endpoint.local.isSameFilesystem(as: .sftp(a)))

    let job = FileJob(.move, sources: [d + "/item"], from: .sftp(a), to: .sftp(b), destDir: d)
    job.resolveConflict = { _ in (.overwrite, false) }
    job.run()
    #expect(fm.contents(atPath: d + "/item") == bytes)

    // And a real move between them is still a move (a rename on the server).
    try fm.createDirectory(atPath: d + "/sub", withIntermediateDirectories: false)
    let move = FileJob(.move, sources: [d + "/item"], from: .sftp(a), to: .sftp(b), destDir: d + "/sub")
    move.run()
    #expect(move.progress.state == .done && move.progress.errors.isEmpty, "\(move.progress.errors)")
    #expect(fm.contents(atPath: d + "/sub/item") == bytes)
    #expect(!fm.fileExists(atPath: d + "/item"))
}

/// A1: no port means "whatever ~/.ssh/config says", not 22 — that is not provably the same server.
@Test func aServerWithoutAPortIsNotTheOneOnPort22() {
    #expect(!SFTPTarget(host: "h").isSameServer(as: SFTPTarget(host: "h", port: 22)))
    #expect(SFTPTarget(host: "h", port: 22).isSameServer(as: SFTPTarget(host: "h", port: 22, identity: "k")))
}

/// A1 / R16 / R18: two connections no comparison can tell apart (another alias of the server; this Mac and a
/// server that is this Mac), or a name in another case: a move onto the source itself is refused, never a loss.
@Test(arguments: ["alias", "local", "case"]) func moveOntoItselfThroughAnotherConnectionIsRefused(_ how: String) throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let bytes = randomData(8)
    try bytes.write(to: URL(fileURLWithPath: d + "/item"))
    try fm.createSymbolicLink(atPath: d + "/link", withDestinationPath: "item")
    if how == "case" && !fm.fileExists(atPath: d + "/ITEM") { return }   // a case-sensitive volume: two names, two files
    let a = SFTPTarget.local()
    let from: Endpoint = how == "alias" ? .sftp(a) : .local
    let to: Endpoint = how == "alias" ? .sftp(otherServer(in: d)) : .sftp(a)
    for name in ["item", "link"] {
        let job = FileJob(.move, sources: [d + "/" + name], from: from, to: to, destDir: d,
                          targetName: how == "case" ? name.uppercased() : nil)
        job.resolveConflict = { _ in (.overwrite, false) }
        job.run()
        #expect(job.progress.errors.count == 1, "\(name): \(job.progress.errors)")
    }
    #expect(fm.contents(atPath: d + "/item") == bytes)
    #expect((try? fm.destinationOfSymbolicLink(atPath: d + "/link")) == "item")
    #expect(try fm.contentsOfDirectory(atPath: d).filter { $0.hasPrefix(".dfm-") }.isEmpty)
}

/// A1 for folders: a folder merged onto itself through another connection (another alias, this Mac and
/// localhost, a name in another case) is refused — not emptied and then deleted as moved.
@Test(arguments: ["alias", "local", "case"]) func folderMergedOntoItselfThroughAnotherConnectionIsRefused(_ how: String) throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    try fm.createDirectory(atPath: d + "/keep/empty", withIntermediateDirectories: true)
    fm.createFile(atPath: d + "/keep/f", contents: Data("x".utf8))
    if how == "case" && !fm.fileExists(atPath: d + "/KEEP") { return }
    let a = SFTPTarget.local()
    let (from, to): (Endpoint, Endpoint) = switch how {
    case "alias": (.sftp(a), .sftp(otherServer(in: d)))
    case "local": (.local, .sftp(a))
    default: (.sftp(a), .sftp(a))
    }
    for kind in [FileJob.Kind.move, .copy] {
        let job = FileJob(kind, sources: [d + "/keep"], from: from, to: to, destDir: d, targetName: how == "case" ? "KEEP" : nil)
        job.resolveConflict = { _ in (.overwrite, false) }
        job.run()
        #expect(job.progress.errors.count == 1, "\(how) \(kind): \(job.progress.errors)")
    }
    #expect(try Set(fm.contentsOfDirectory(atPath: d + "/keep")) == ["empty", "f"])
    #expect(fm.contents(atPath: d + "/keep/f") == Data("x".utf8))
}

/// R18: a folder copied into its own subfolder through another connection, or a name in another case, stops
/// where it meets the copy — no recursion until the stack runs out.
@Test(arguments: ["alias", "local", "case"]) func copyIntoItselfThroughAnotherConnectionStops(_ how: String) throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    try fm.createDirectory(atPath: d + "/tree/sub", withIntermediateDirectories: true)
    fm.createFile(atPath: d + "/tree/sub/f", contents: Data("x".utf8))
    if how == "case" && !fm.fileExists(atPath: d + "/TREE") { return }
    let a = SFTPTarget.local()
    let (from, to): (Endpoint, Endpoint) = switch how {
    case "alias": (.sftp(a), .sftp(otherServer(in: d)))
    case "local": (.local, .sftp(a))
    default: (.sftp(a), .sftp(a))
    }
    let job = FileJob(.copy, sources: [d + "/tree"], from: from, to: to, destDir: d + (how == "case" ? "/TREE/sub" : "/tree/sub"))
    job.run()
    #expect(job.progress.errors.count == 1, "\(job.progress.errors)")
    #expect(fm.contents(atPath: d + "/tree/sub/f") == Data("x".utf8))
    #expect(!fm.fileExists(atPath: d + "/tree/sub/tree/sub/tree"))
}

/// A1 / R18: merging into an existing writable folder whose parent is read-only (a site into a root-owned
/// /var/www) works — the identity marker goes inside the folders, never next to them. With a subfolder named as
/// the top one (mysite/mysite), so the per-child check meets the read-only parent too.
@Test(arguments: ["local", "sftp"]) func mergeIntoAFolderWhoseParentIsReadOnly(_ side: String) throws {
    let d = tempDir()
    defer { chmod(d + "/ro", 0o755); try? fm.removeItem(atPath: d) }
    try fm.createDirectory(atPath: d + "/src/site/site", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: d + "/ro/site", withIntermediateDirectories: true)
    let from: Endpoint = side == "local" ? .local : .sftp(.local())
    for kind in [FileJob.Kind.copy, .move] {
        fm.createFile(atPath: d + "/src/site/new.txt", contents: Data("\(kind)".utf8))
        fm.createFile(atPath: d + "/src/site/site/deep.txt", contents: Data("\(kind)".utf8))
        chmod(d + "/ro", 0o555)
        let job = FileJob(kind, sources: [d + "/src/site"], from: from, to: .sftp(.local()), destDir: d + "/ro")
        job.resolveConflict = { _ in (.overwrite, false) }
        job.run()
        chmod(d + "/ro", 0o755)
        #expect(job.progress.errors == [], "\(side) \(kind)")
        #expect(fm.contents(atPath: d + "/ro/site/new.txt") == Data("\(kind)".utf8), "\(side) \(kind)")
        #expect(fm.contents(atPath: d + "/ro/site/site/deep.txt") == Data("\(kind)".utf8), "\(side) \(kind)")
        #expect(fm.fileExists(atPath: d + "/src/site") == (kind == .copy), "\(side) \(kind)")
    }
    #expect(try fm.contentsOfDirectory(atPath: d + "/ro").filter { $0.hasPrefix(".dfm-") }.isEmpty)
    #expect(try Set(fm.contentsOfDirectory(atPath: d + "/ro/site")) == ["new.txt", "site"])
}

/// Same server, a folder moved into its own subfolder through a name in another case: the rename fails, and the
/// error says why (not "Bad message").
@Test func moveIntoItselfThroughAnotherCaseSaysSo() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    try fm.createDirectory(atPath: d + "/tree/A/b", withIntermediateDirectories: true)
    if !fm.fileExists(atPath: d + "/TREE") { return }
    let job = FileJob(.move, sources: [d + "/tree"], from: .sftp(.local()), to: .sftp(.local()), destDir: d + "/TREE/A/b", targetName: "copy")
    job.run()
    #expect(job.progress.errors.count == 1 && job.progress.errors[0].contains("into itself"), "\(job.progress.errors)")
    #expect(fm.fileExists(atPath: d + "/tree/A/b"))
    #expect(try fm.contentsOfDirectory(atPath: d + "/tree").filter { $0.hasPrefix(".dfm-") }.isEmpty)
}

/// A1: a folder merged into one where no marker may be made can't be told apart from itself: a move is refused
/// and keeps its source.
@Test func moveIntoAFolderThatCantBeMarkedKeepsItsSource() throws {
    let d = tempDir()
    defer { chmod(d + "/ro/site", 0o755); try? fm.removeItem(atPath: d) }
    try fm.createDirectory(atPath: d + "/src/site", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: d + "/ro/site", withIntermediateDirectories: true)
    fm.createFile(atPath: d + "/src/site/new.txt", contents: Data("x".utf8))
    chmod(d + "/ro/site", 0o555)
    let job = FileJob(.move, sources: [d + "/src/site"], from: .local, to: .sftp(.local()), destDir: d + "/ro")
    job.resolveConflict = { _ in (.overwrite, false) }
    job.run()
    #expect(job.progress.errors.count == 1 && job.progress.errors[0].contains("Can't tell"), "\(job.progress.errors)")
    #expect(fm.contents(atPath: d + "/src/site/new.txt") == Data("x".utf8))
}

/// R18: a folder copied into itself on a server through a symlink is refused, and nothing is created first.
@Test func copyIntoItselfThroughASymlinkOnAServerIsRefused() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    try fm.createDirectory(atPath: d + "/tree/sub", withIntermediateDirectories: true)
    fm.createFile(atPath: d + "/tree/sub/f", contents: Data("x".utf8))
    try fm.createSymbolicLink(atPath: d + "/alias", withDestinationPath: d + "/tree/sub")
    let a = SFTPTarget.local()
    for kind in [FileJob.Kind.copy, .move] {
        let job = FileJob(kind, sources: [d + "/tree"], from: .sftp(a), to: .sftp(a), destDir: d + "/alias")
        job.run()
        #expect(job.progress.errors.count == 1, "\(kind): \(job.progress.errors)")
    }
    #expect(try fm.contentsOfDirectory(atPath: d + "/tree/sub") == ["f"])
}

/// A2: merging into a folder that is already on the other side keeps that folder's mode, as L2 does locally.
@Test(arguments: ["up", "down", "across"]) func remoteMergeKeepsTheTargetFoldersPermissions(_ direction: String) throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    try fm.createDirectory(atPath: d + "/src/merge", withIntermediateDirectories: true)
    fm.createFile(atPath: d + "/src/merge/item", contents: Data("private\n".utf8))
    chmod(d + "/src/merge", 0o777)
    try fm.createDirectory(atPath: d + "/dst/merge", withIntermediateDirectories: true)
    chmod(d + "/dst/merge", 0o700)
    let (from, to): (Endpoint, Endpoint) = switch direction {
    case "up": (.local, .sftp(.local()))
    case "down": (.sftp(.local()), .local)
    default: (.sftp(.local()), .sftp(otherServer(in: d)))
    }
    let job = FileJob(.copy, sources: [d + "/src/merge"], from: from, to: to, destDir: d + "/dst")
    job.resolveConflict = { _ in (.overwrite, false) }
    job.run()
    #expect(job.progress.state == .done && job.progress.errors.isEmpty, "\(job.progress.errors)")
    #expect(fm.contents(atPath: d + "/dst/merge/item") == Data("private\n".utf8))
    #expect(mode(d + "/dst/merge") == 0o700)
    // A folder the job creates still gets the source's mode.
    let fresh = FileJob(.copy, sources: [d + "/src/merge"], from: from, to: to, destDir: d + "/dst/merge")
    fresh.run()
    #expect(mode(d + "/dst/merge/merge") == 0o777)
}

/// R14: a server that refuses to set a file's mode and date (vfat / exFAT on Linux) still gets the file — the
/// refusal is reported, not swallowed, and a move whose data arrived drops its source.
@Test func failedAttributesOnAServerAreReported() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let script = d + "/no-setstat-sftp-server"
    try "#!/bin/sh\nexec /usr/libexec/sftp-server -P setstat,fsetstat,lsetstat \"$@\"\n".write(toFile: script, atomically: true, encoding: .utf8)
    chmod(script, 0o755)
    try fm.createDirectory(atPath: d + "/up", withIntermediateDirectories: false)
    try Data("key".utf8).write(to: URL(fileURLWithPath: d + "/id_ed25519"))
    let job = FileJob(.move, sources: [d + "/id_ed25519"], from: .local, to: .sftp(.local(server: script)), destDir: d + "/up")
    job.run()
    #expect(job.progress.errors.count == 1, "\(job.progress.errors)")
    #expect(fm.contents(atPath: d + "/up/id_ed25519") == Data("key".utf8))
    #expect(!fm.fileExists(atPath: d + "/id_ed25519"))
    #expect(try fm.contentsOfDirectory(atPath: d + "/up") == ["id_ed25519"])
}

/// R14: a same-server copy's partial file is owner-only while it fills, like an upload's.
@Test func serverSideCopyCreatesAnOwnerOnlyFile() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    try Data(".env".utf8).write(to: URL(fileURLWithPath: d + "/src"))
    let c = try SFTPClient(.local())
    defer { c.close() }
    guard c.canCopyData else { return }
    try c.copyData(d + "/src", to: d + "/partial", offset: 0, length: 0)
    #expect(mode(d + "/partial") == 0o600)
}

/// R18: a copy into its own subfolder where the top folder copied into can't be marked (read-only), nor its parent:
/// the copy stops instead of recursing through the writable folders below until the process dies.
@Test(arguments: ["local", "alias", "case"], ["root", "parent"]) func copyIntoItselfThroughAReadOnlyFolderStops(_ how: String, _ readOnly: String) throws {
    let d = tempDir()
    defer {
        let all = (fm.enumerator(atPath: d)?.allObjects as? [String] ?? []).map { d + "/" + $0 }
        for p in all + [d] { chmod(p, 0o755) }
        try? fm.removeItem(atPath: d)
    }
    try fm.createDirectory(atPath: d + "/tree/sub/tree/sub", withIntermediateDirectories: true)
    fm.createFile(atPath: d + "/tree/sub/f", contents: Data("x".utf8))
    if how == "case" && !fm.fileExists(atPath: d + "/TREE") { return }
    chmod(d + "/tree/sub/tree", 0o555)
    if readOnly == "parent" { chmod(d + "/tree/sub", 0o555) }
    let a = SFTPTarget.local()
    let (from, to): (Endpoint, Endpoint) = switch how {
    case "alias": (.sftp(a), .sftp(otherServer(in: d)))
    case "local": (.local, .sftp(a))
    default: (.sftp(a), .sftp(a))
    }
    for kind in [FileJob.Kind.copy, .move] {
        let job = FileJob(kind, sources: [d + "/tree"], from: from, to: to, destDir: d + (how == "case" ? "/TREE/sub" : "/tree/sub"))
        job.resolveConflict = { _ in (.overwrite, false) }
        job.run()
        #expect(job.progress.errors.count == 1, "\(how) \(readOnly) \(kind): \(job.progress.errors)")
        #expect(fm.contents(atPath: d + "/tree/sub/f") == Data("x".utf8), "\(how) \(readOnly) \(kind)")
        #expect(!fm.fileExists(atPath: d + "/tree/sub/tree/sub/tree/sub/tree/sub"), "\(how) \(readOnly) \(kind)")
    }
    // Only the top can't be marked: the marker beside it tells, and nothing is written before the refusal.
    if readOnly == "root" { #expect(try fm.contentsOfDirectory(atPath: d + "/tree/sub/tree/sub").isEmpty, "\(how)") }
}

/// A server may leave the mode out of READDIR (SFTP v3 allows it), so a listed folder looks like a file. The depth
/// the copy is held to must still count it, or every nested folder is refused as "into itself".
@Test func depthCountsFoldersListedWithoutAMode() throws {
    final class NoModeListing: TransferFS, @unchecked Sendable {
        let fs = LocalFS()
        func lstat(_ path: String) throws -> SFTPClient.Attrs? { try fs.lstat(path) }
        func list(_ dir: String) throws -> [(name: String, attrs: SFTPClient.Attrs)] {
            try fs.list(dir).map { ($0.name, SFTPClient.Attrs(kind: .file, size: 0, mtime: $0.attrs.mtime, mode: nil)) }
        }
        func mkdir(_ path: String) throws { try fs.mkdir(path) }
        func remove(_ path: String) throws { try fs.remove(path) }
        func rmdir(_ path: String) throws { try fs.rmdir(path) }
        func rename(_ from: String, _ to: String, replace: Bool) throws { try fs.rename(from, to, replace: replace) }
        func readlink(_ path: String) throws -> String { try fs.readlink(path) }
        func realpath(_ path: String) throws -> String { try fs.realpath(path) }
        func symlink(_ destination: String, at link: String) throws { try fs.symlink(destination, at: link) }
        func setAttrs(_ path: String, mtime: Double?, mode: UInt32?) throws { try fs.setAttrs(path, mtime: mtime, mode: mode) }
        func reader(_ path: String, offset: Int64, size: Int64) throws -> PieceReader { try fs.reader(path, offset: offset, size: size) }
        func writer(_ path: String, offset: Int64) throws -> PieceWriter { try fs.writer(path, offset: offset) }
        func close() {}
    }
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    try fm.createDirectory(atPath: d + "/tree/a/b", withIntermediateDirectories: true)
    fm.createFile(atPath: d + "/tree/a/b/f", contents: Data("x".utf8))
    let m = FileJob(.copy, sources: []).measure(NoModeListing(), d + "/tree")
    #expect(m.files == 1 && m.bytes == 1 && m.depth == 2)
}
