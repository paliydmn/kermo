import DFMCore
import Foundation
import Testing
@testable import DFileManager

// Task 13 §8.4 item 6: Info's three checksums in one read.

@Test func infoHashesAllThreeInOneRead() throws {
    let d = NSTemporaryDirectory() + "k13info-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: d) }
    try Data("abc".utf8).write(to: URL(fileURLWithPath: d + "/abc"))
    let all = try InfoWindow.digests(d + "/abc", cancel: CancelFlag()).get()
    #expect(all["MD5"] == "900150983cd24fb0d6963f7d28e17f72")
    #expect(all["SHA-1"] == "a9993e364706816aba3e25717850c26c9cd0d89d")
    #expect(all["SHA-256"] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

    var big = Data(repeating: 1, count: (1 << 20) + 3)   // more than one read
    big[big.count - 1] = 2
    try big.write(to: URL(fileURLWithPath: d + "/big"))
    #expect(try InfoWindow.digests(d + "/big", cancel: CancelFlag()).get()["SHA-256"] == SHA256Hex(big))

    func text(_ r: Result<[String: String], InfoWindow.DigestFailure>) -> String? { if case .failure(let f) = r { f.text } else { nil } }
    #expect(text(InfoWindow.digests(d, cancel: CancelFlag())) == "skipped: a folder")
    #expect(text(InfoWindow.digests(d + "/missing", cancel: CancelFlag())) == "can't read (No such file or directory)")
    let stopped = CancelFlag()
    stopped.cancel()
    #expect(text(InfoWindow.digests(d + "/big", cancel: stopped)) == "stopped")
}

private func SHA256Hex(_ data: Data) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    p.arguments = ["-a", "256"]
    let i = Pipe(), o = Pipe()
    p.standardInput = i
    p.standardOutput = o
    try? p.run()
    i.fileHandleForWriting.write(data)
    try? i.fileHandleForWriting.close()
    let out = o.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: out, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
}
