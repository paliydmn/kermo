import Foundation
import Testing
@testable import DFMCore

@Test func splitPartSequences() {
    let names = ["big.iso.000", "big.iso.001", "big.iso.002", "big.iso", "other.001", "x.txt"]
    #expect(SplitParts.sequence(for: "big.iso.001", in: names)! == ("big.iso", ["big.iso.000", "big.iso.001", "big.iso.002"]))
    #expect(SplitParts.sequence(for: "other.001", in: names)! == ("other", ["other.001"]))
    #expect(SplitParts.sequence(for: "big.iso.001", in: ["big.iso.000", "big.iso.002"]) == nil)   // .001 missing
    #expect(SplitParts.sequence(for: "a.002", in: ["a.002", "a.003"]) == nil)                      // no first part
    #expect(SplitParts.sequence(for: "x.txt", in: names) == nil)
    #expect(SplitParts.sequence(for: ".001", in: [".001"]) == nil)
}

/// The same commands the app runs: split, then cat the parts back.
@Test func splitAndCombineRoundTrip() throws {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-split-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: d) }
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    let data = Data((0..<2500).map { UInt8($0 % 251) })
    try data.write(to: URL(fileURLWithPath: d + "/f.bin"))
    func sh(_ c: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", c]
        p.currentDirectoryURL = URL(fileURLWithPath: d)
        try! p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
    #expect(sh("split -d -a 3 -b 1k -- f.bin f.bin.") == 0)
    let seq = try #require(SplitParts.sequence(for: "f.bin.001", in: FileManager.default.contentsOfDirectory(atPath: d)))
    #expect(seq.parts == ["f.bin.000", "f.bin.001", "f.bin.002"])
    #expect(sh("set -C; cat " + seq.parts.joined(separator: " ") + " > joined") == 0)
    #expect(try Data(contentsOf: URL(fileURLWithPath: d + "/joined")) == data)
    #expect(sh("set -C; cat f.bin.000 > joined") != 0)   // never overwrites
}
