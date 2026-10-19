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
    #expect(SplitParts.parts(of: "big.iso", in: names) == ["big.iso.000", "big.iso.001", "big.iso.002"])
    #expect(SplitParts.parts(of: "x.txt", in: names).isEmpty)
}

/// F-08: every part but the last the size of the first; the last no bigger.
@Test func splitPartSizes() {
    let parts = ["f.000", "f.001", "f.002"]
    #expect(SplitParts.misfit(parts, sizes: ["f.000": 10, "f.001": 10, "f.002": 10]) == nil)
    #expect(SplitParts.misfit(parts, sizes: ["f.000": 10, "f.001": 10, "f.002": 3]) == nil)    // the last one smaller: ok
    #expect(SplitParts.misfit(parts, sizes: ["f.000": 10, "f.001": 7, "f.002": 3]) == "f.001")  // one in the middle
    #expect(SplitParts.misfit(parts, sizes: ["f.000": 10, "f.001": 10, "f.002": 12]) == "f.002") // the last one bigger
    #expect(SplitParts.misfit(["f.000"], sizes: ["f.000": 10]) == nil)
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

/// F-08: split by 1k, .000 gone, split again by 2k — over .000 and .001, leaving .002 of the first split. The parts
/// number on without a gap, so only their sizes tell Combine they don't belong together; and Split sees the old ones.
@Test func twoSplitsOverEachOtherDontCombine() throws {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-split-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: d) }
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    try Data((0..<3000).map { UInt8($0 % 251) }).write(to: URL(fileURLWithPath: d + "/f.bin"))
    func sh(_ c: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", c]
        p.currentDirectoryURL = URL(fileURLWithPath: d)
        try! p.run()
        p.waitUntilExit()
    }
    sh("split -d -a 3 -b 1k -- f.bin f.bin. && rm f.bin.000")
    #expect(SplitParts.parts(of: "f.bin", in: try FileManager.default.contentsOfDirectory(atPath: d)) == ["f.bin.001", "f.bin.002"])
    sh("split -d -a 3 -b 2k -- f.bin f.bin.")
    let items = try DirLister.list(d)
    let seq = try #require(SplitParts.sequence(for: "f.bin.000", in: items.map(\.name)))
    #expect(seq.parts == ["f.bin.000", "f.bin.001", "f.bin.002"])
    #expect(SplitParts.misfit(seq.parts, sizes: Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.size) })) == "f.bin.001")
}
