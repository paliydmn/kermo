import Foundation
import Testing
@testable import DFMCore

// Task 9 QA follow-up, group "tests" (Q1, V2).

/// `name` compressed with bsdtar's raw format (one bare stream, like gzip/bzip2/xz would write) — the tools
/// themselves aren't all on a stock Mac.
private func compressedFixture(_ dir: String, _ name: String, _ content: Data) throws -> String {
    let plain = dir + "/" + (name as NSString).deletingPathExtension
    try content.write(to: URL(fileURLWithPath: plain))
    let filter = ["gz": "--gzip", "bz2": "--bzip2", "xz": "--xz"][(name as NSString).pathExtension]!
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    p.arguments = ["-c", "--format", "raw", filter, "-f", dir + "/" + name, "-C", dir, (plain as NSString).lastPathComponent]
    try p.run()
    p.waitUntilExit()
    try #require(p.terminationStatus == 0)
    return dir + "/" + name
}

/// V2: rotated logs (.gz, .bz2, .xz) unpack as a stream, capped; archives and uncompressed files are left alone.
@Test func compressedLogsUnpackAsAStream() throws {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r9t-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: d) }
    let log = Data((0..<2000).map { "line \($0) error maybe\n" }.joined().utf8)
    for (name, compression) in [("app.log.1.gz", "gzip"), ("app.log.2.bz2", "bzip2"), ("app.log.3.xz", "xz")] {
        let f = try compressedFixture(d, name, log)
        #expect(CompressedFile.matches(f))
        let z = try #require(CompressedFile.read(f, limit: 1 << 20), "\(name)")
        #expect(z.data == log && z.compression == compression && !z.truncated)
        let capped = try #require(CompressedFile.read(f, limit: 100))
        #expect(capped.data == log.prefix(100) && capped.truncated)
    }
    #expect(!CompressedFile.matches("site.tar.gz") && !CompressedFile.matches("site.tgz") && !CompressedFile.matches("a.log"))
    try Data("not compressed at all\n".utf8).write(to: URL(fileURLWithPath: d + "/fake.gz"))
    #expect(CompressedFile.read(d + "/fake.gz", limit: 1 << 20) == nil)
}

/// V2 review: a log cut off (an interrupted download, logrotate killed mid-compress) says it's damaged and keeps
/// what came before the cut; one cut before the first 64 KB unpack still says it's gzip; an empty rotated log
/// (`: | gzip`, logrotate's default `ifempty`) is an empty text, not hex of the gzip header.
@Test func damagedAndEmptyCompressedLogs() throws {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r9t-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: d) }
    let log = Data((0..<200_000).map { "line \($0)\n" }.joined().utf8)
    for (name, compression) in [("big.log.gz", "gzip"), ("big.log.bz2", "bzip2"), ("big.log.xz", "xz")] {
        let whole = try Data(contentsOf: URL(fileURLWithPath: try compressedFixture(d, name, log)))
        let ok = try #require(CompressedFile.read(d + "/" + name, limit: 32 << 20))
        #expect(ok.data == log && !ok.damaged, "\(name)")
        for (cut, size) in [("half", whole.count / 2), ("early", 40)] {
            let f = d + "/\(cut)-" + name
            try whole.prefix(size).write(to: URL(fileURLWithPath: f))
            let z = try #require(CompressedFile.read(f, limit: 32 << 20), "\(cut) \(name)")
            #expect(z.damaged && !z.truncated && z.compression == compression && z.data.count < log.count, "\(cut) \(name)")
            #expect(log.starts(with: z.data), "\(cut) \(name)")
        }
        let empty = try #require(CompressedFile.read(try compressedFixture(d, "empty." + name, Data()), limit: 32 << 20), "empty \(name)")
        #expect(empty.data.isEmpty && empty.compression == compression && !empty.damaged && !empty.truncated, "empty \(name)")
    }
}
