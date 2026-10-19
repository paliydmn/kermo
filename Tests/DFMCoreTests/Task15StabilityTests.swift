import Foundation
@testable import DFMCore
import Testing

/// Task 15 sss-6: small stability holes — hostile servers, leftovers.

nonisolated(unsafe) private let fm = FileManager.default

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-sss6-" + UUID().uuidString
    try! fm.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

/// T-04: sizes added up stay at `Int64.max` instead of trapping past it.
@Test func sizesSaturate() {
    #expect(Int64.max.saturatingAdd(1) == .max)
    #expect(Int64.max.saturatingAdd(.max) == .max)
    #expect(Int64(2).saturatingAdd(3) == 5)
    #expect(Int64.min.saturatingAdd(-1) == .min)
}

/// A server that says every file is `Int64.max` bytes (a hostile or broken sftp-server: `Reader.attrs` clamps each).
private final class HugeSizes: TransferFS, @unchecked Sendable {
    let fs = LocalFS()
    func huge(_ a: SFTPClient.Attrs) -> SFTPClient.Attrs { var a = a; if a.kind == .file { a.size = .max }; return a }
    func lstat(_ path: String) throws -> SFTPClient.Attrs? { try fs.lstat(path).map(huge) }
    func list(_ dir: String) throws -> [(name: String, attrs: SFTPClient.Attrs)] { try fs.list(dir).map { ($0.name, huge($0.attrs)) } }
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

/// T-04: ⌥Space on a server folder, or the "Scanning…" of a copy from it, added such sizes with `+=`: a trap. Two
/// files in a folder, a folder below it with one more, two of them copied: each sum stays at `Int64.max`.
@Test func hugeServerSizesDontOverflowAMeasure() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    for t in ["a", "b"] {
        try fm.createDirectory(atPath: d + "/\(t)/sub", withIntermediateDirectories: true)
        for f in ["/x", "/y", "/sub/z"] { fm.createFile(atPath: d + "/\(t)" + f, contents: Data("1".utf8)) }
    }
    let m = FileJob(.copy, sources: []).measure(HugeSizes(), d + "/a")
    #expect(m.files == 3 && m.bytes == .max)

    try fm.createDirectory(atPath: d + "/to", withIntermediateDirectories: true)
    let job = FileJob(.copy, sources: [d + "/a", d + "/b"], from: .sftp(.local()), to: .local, destDir: d + "/to")
    job.runAcross(HugeSizes())
    #expect(job.progress.totalFiles == 6 && job.progress.totalBytes == .max)
    #expect(job.progress.doneBytes == .max, "\(job.progress.errors)")
}
