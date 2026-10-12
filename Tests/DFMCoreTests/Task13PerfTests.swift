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
    #expect(try trips { try readAll(d + "/small", 2048) } == 4, "open, read, end of file, close")
    #expect(try trips { try readAll(d + "/big", Int64(128 * SFTPClient.chunk)) } == 5, "open, 2 waves of 64 reads, end of file, close")
    #expect(try trips {
        let w = try c.openWrite(d + "/out")
        try w.write(Data(repeating: 3, count: 128 * SFTPClient.chunk))
        try w.finish()
    } == 4, "open, 2 waves of 64 writes, close")
    var listed = 0
    #expect(trips { listed = c.list((0..<3).map { d + "/dirs/\($0)" }).count } == 4, "open, read, end of file, close: each for all 3 at once")
    #expect(listed == 3)
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
