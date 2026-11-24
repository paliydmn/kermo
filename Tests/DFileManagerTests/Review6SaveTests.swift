import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Review 6, PR 6: what's written — Compress, the editor's save, the askpass helper, names tar reads as more.

private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r6s-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// `/usr/bin/tar` with `args`: its exit status.
private func tar(_ args: [String], in dir: String) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    p.arguments = args
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

/// В13: tar reads a leading "@" as "the entries of that archive": Compress on Synology's @eaDir failed ("can't open").
/// "./" goes in front of it, as of a "-" — by the first scalar, so a "-" with a mark joined is one too.
@Test func aNameStartingWithAtIsPackedAsItself() throws {
    #expect(ArchiveIndex.createArguments("/o.zip", names: ["@eaDir", "-x", "-\u{301}y", "a@b"], in: "/d").suffix(4)
            == ["./@eaDir", "./-x", "./-\u{301}y", "a@b"])
    #expect(ShellContext.quoteName("@x") == "./@x" && ShellContext.quoteName("a@x") == "a@x")
    #expect(ShellContext(dir: "/d", otherDir: nil, cursor: nil, targets: ["@eaDir"]).expand("tar -cf x.tar %s") == "tar -cf x.tar ./@eaDir")

    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(atPath: dir + "/@eaDir", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dir + "/@eaDir/thumb", contents: Data("t".utf8))
    #expect(try tar(ArchiveIndex.createArguments(dir + "/o.tar", names: ["@eaDir"], in: dir), in: dir) == 0)
    let index = try ArchiveIndex.read(dir + "/o.tar")
    #expect(index.list("@eaDir")?.map(\.name) == ["thumb"])
}
