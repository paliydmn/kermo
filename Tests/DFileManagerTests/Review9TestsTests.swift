import Foundation
import Testing
@testable import DFileManager

// Task 9 QA follow-up, group "tests" (Q1, V2).

/// V2: F3 on a rotated app.log.1.gz shows the log as text and says it was unpacked; binary content inside stays hex.
@Test func viewerShowsGzippedLogAsText() throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r9t-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    func gzip(_ name: String, _ content: Data) throws -> URL {
        try content.write(to: URL(fileURLWithPath: dir + "/" + name))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = [dir + "/" + name]
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        return URL(fileURLWithPath: dir + "/" + name + ".gz")
    }
    let log = (0..<500).map { "2026-10-07 12:00:\($0 % 60) worker \($0) ok\n" }.joined()
    let (text, info, _, _) = Viewer.read(try gzip("app.log.1", Data(log.utf8)), .text)
    #expect(text == log)
    #expect(info.contains("gzip") && info.contains("unpacked") && info.hasSuffix("UTF-8"))

    let (hex, binInfo, _, _) = Viewer.read(try gzip("core.bin", Data([0x7f, 0x45, 0x4c, 0x46, 0, 0, 0, 1])), .text)
    #expect(hex.hasPrefix("00000000  7f 45 4c 46 00 00 00 01") && binInfo.contains("gzip") && binInfo.contains("hex"))
}

/// V2 review: a cut-off gzip log says "damaged after …" in the subtitle; an empty one is empty text marked gzip;
/// a file over 32 MB only named .gz (not compressed) still goes the huge-file way (mmap window, hex with go-to).
@Test func viewerDamagedEmptyAndHugeCompressedNames() throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r9t-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    func gzip(_ name: String, _ content: Data) throws -> URL {
        try content.write(to: URL(fileURLWithPath: dir + "/" + name))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = [dir + "/" + name]
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        return URL(fileURLWithPath: dir + "/" + name + ".gz")
    }
    let log = (0..<200_000).map { "line \($0)\n" }.joined()
    let whole = try Data(contentsOf: try gzip("app.log.1", Data(log.utf8)))
    let half = URL(fileURLWithPath: dir + "/half.log.gz")
    try whole.prefix(whole.count / 2).write(to: half)
    let (text, info, _, _) = Viewer.read(half, .text)
    #expect(log.hasPrefix(text) && !text.isEmpty && info.contains("gzip, damaged after"), "\(info)")

    let (emptyText, emptyInfo, _, _) = Viewer.read(try gzip("app.log.2", Data()), .text)
    #expect(emptyText.isEmpty && emptyInfo.contains("gzip") && !emptyInfo.contains("hex"), "\(emptyInfo)")

    let fake = dir + "/plain.log.gz"
    #expect(FileManager.default.createFile(atPath: fake, contents: nil))
    let h = try FileHandle(forWritingTo: URL(fileURLWithPath: fake))
    try h.truncate(atOffset: 40 << 20)
    try h.close()
    #expect(Viewer.isHuge(fake))
}
