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
