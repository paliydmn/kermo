import Foundation
import Testing
@testable import DFMCore

// The native SFTP client against the real /usr/libexec/sftp-server on pipes (no ssh, no network).

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-sftpc-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private func randomData(_ n: Int) -> Data {
    var d = Data(count: n)
    d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }
    return d
}

@Test func clientBasicOperationsWithTrickyNames() throws {
    let c = try SFTPClient(.local())
    defer { c.close() }
    #expect(c.extensions["posix-rename@openssh.com"] != nil)
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let names = ["plain.txt", "with space.txt", "it's [1] *star?.txt", "кирилиця.txt", "\"quoted\".txt", "line\nbreak.txt", "back\\slash"]
    for n in names { try Data(n.utf8).write(to: URL(fileURLWithPath: d + "/" + n)) }
    try c.mkdir(d + "/sub dir", mode: 0o750)
    try c.symlink("plain.txt", at: d + "/link")

    let items = Dictionary(uniqueKeysWithValues: try c.list(d).map { ($0.name.precomposedStringWithCanonicalMapping, $0.attrs) })
    #expect(items.count == names.count + 2)
    for n in names {
        #expect(items[n.precomposedStringWithCanonicalMapping]?.kind == .file, "\(n)")
        #expect(items[n.precomposedStringWithCanonicalMapping]?.size == Int64(n.utf8.count))
    }
    #expect(items["sub dir"]?.kind == .dir)
    #expect(items["sub dir"]?.mode == 0o750)
    #expect(items["link"]?.kind == .link)
    #expect(try c.readlink(d + "/link") == "plain.txt")
    #expect(try c.lstat(d + "/missing") == nil)

    try c.setAttrs(d + "/plain.txt", mtime: 1_000_000_000, mode: 0o600)
    let a = try #require(try c.lstat(d + "/plain.txt"))
    #expect(a.mtime == 1_000_000_000 && a.mode == 0o600)

    // Plain rename refuses to replace; replace: true goes over the top.
    #expect(throws: SFTPError.self) { try c.rename(d + "/plain.txt", d + "/with space.txt") }
    try c.rename(d + "/plain.txt", d + "/with space.txt", replace: true)
    #expect(try String(contentsOfFile: d + "/with space.txt", encoding: .utf8) == "plain.txt")
    try c.remove(d + "/line\nbreak.txt")
    try c.rmdir(d + "/sub dir")
    #expect(try c.lstat(d + "/line\nbreak.txt") == nil && c.lstat(d + "/sub dir") == nil)

    let e = try #require(throws: SFTPError.self) { try c.list(d + "/missing") }
    #expect(e.code == SFTPClient.NO_SUCH_FILE && !e.connection)
}

@Test func clientStreamsLargeFilesBothWaysAndResumes() throws {
    let c = try SFTPClient(.local())
    defer { c.close() }
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    // Several times the pipeline window (64 × 32 KB), and not a multiple of the chunk.
    let data = randomData(SFTPClient.window * SFTPClient.chunk * 3 + 12_345)
    try data.write(to: URL(fileURLWithPath: d + "/big"))

    var got = Data()
    let r = try c.openRead(d + "/big", sizeHint: Int64(data.count))
    while let piece = try r.read() { got.append(piece) }
    r.close()
    #expect(got == data)

    // A wrong (small) hint still reads to the end; reading from an offset gets the tail.
    var tail = Data()
    let r2 = try c.openRead(d + "/big", offset: 1_000_000, sizeHint: 10)
    while let piece = try r2.read() { tail.append(piece) }
    r2.close()
    #expect(tail == data.subdata(in: 1_000_000..<data.count))

    let w = try c.openWrite(d + "/up", exclusive: true)
    try w.write(data.subdata(in: 0..<700_001))
    try w.finish()
    // Continue where it stopped (Retry after a broken connection).
    let w2 = try c.openWrite(d + "/up", offset: 700_001)
    try w2.write(data.subdata(in: 700_001..<data.count))
    try w2.finish()
    #expect(FileManager.default.contents(atPath: d + "/up") == data)

    #expect(throws: SFTPError.self) { try c.openWrite(d + "/up", exclusive: true) }

    // Empty file: read gives nothing at all.
    FileManager.default.createFile(atPath: d + "/empty", contents: Data())
    let r3 = try c.openRead(d + "/empty")
    #expect(try r3.read() == nil)
    r3.close()
}

@Test func clientCopiesOnTheServer() throws {
    let c = try SFTPClient(.local())
    defer { c.close() }
    try #require(c.canCopyData)
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let data = randomData(3_000_000)
    try data.write(to: URL(fileURLWithPath: d + "/src"))
    try c.copyData(d + "/src", to: d + "/dst", offset: 0, length: 1_000_000)
    try c.copyData(d + "/src", to: d + "/dst", offset: 1_000_000, length: 0)
    #expect(FileManager.default.contents(atPath: d + "/dst") == data)
}

@Test func clientReportsALostConnection() throws {
    let c = try SFTPClient(.local())
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try randomData(5_000_000).write(to: URL(fileURLWithPath: d + "/big"))
    let r = try c.openRead(d + "/big")
    _ = try r.read()
    c.close()
    let e = try #require(throws: SFTPError.self) { while try r.read() != nil {} }
    #expect(e.connection)
    #expect(throws: SFTPError.self) { try c.lstat(d) }
    #expect(!c.isConnected)
}

@Test func clientStartsAgainstAMissingServer() {
    #expect(throws: (any Error).self) { try SFTPClient(.local(server: "/nonexistent/sftp-server")) }
}

/// ⌥Space on a server: a folder's bytes as a copy counts them, a link as itself (not what it points to); no size
/// once cancelled or the connection is gone.
@Test func clientMeasuresAFolder() throws {
    let c = try SFTPClient(.local())
    defer { c.close() }
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try FileManager.default.createDirectory(atPath: d + "/sub/deep", withIntermediateDirectories: true)
    try Data("abc".utf8).write(to: URL(fileURLWithPath: d + "/a"))
    try Data("defg".utf8).write(to: URL(fileURLWithPath: d + "/sub/deep/b"))
    try FileManager.default.createSymbolicLink(atPath: d + "/sub/usr", withDestinationPath: "/usr")
    #expect(try c.measure(d) == 3 + 4 + 4)   // the link: its own 4 bytes ("/usr")
    #expect(try c.measure(d + "/a") == 3)
    #expect(try c.measure(d + "/missing") == 0)

    // Over `window` folders on a level, and a folder too big for one READDIR answer: all counted, in a few round trips.
    for i in 0..<70 {
        try FileManager.default.createDirectory(atPath: d + "/many/\(i)", withIntermediateDirectories: true)
        try Data([1]).write(to: URL(fileURLWithPath: d + "/many/\(i)/f"))
    }
    for i in 0..<250 { try Data([1, 2]).write(to: URL(fileURLWithPath: d + "/many/0/g\(i)")) }
    let before = c.roundTrips
    #expect(try c.measure(d + "/many") == 70 + 500)
    #expect(c.roundTrips - before < 20)   // one by one: over 200
    #expect(try c.measure(d) == 3 + 4 + 4 + 70 + 500)

    let flag = CancelFlag()
    flag.cancel()
    #expect(throws: CancellationError.self) { try c.measure(d, cancel: flag) }
    c.close()
    #expect(throws: SFTPError.self) { try c.measure(d) }
}
