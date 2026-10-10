import Foundation
import Testing
@testable import DFMCore

private func item(_ n: String, kind: FileItem.Kind = .file, size: Int64 = 0, mtime: Double = 0, flags: UInt32 = 0) -> FileItem {
    FileItem(name: n, kind: kind, size: size, mtime: mtime, mode: 0, flags: flags)
}
private func sorted(_ names: [String], by key: SortKey = .name, ascending: Bool = true) -> [String] {
    names.map { item($0) }.sortedForPanel(by: key, ascending: ascending).map(\.name)
}
/// What Finder shows (ICU collation via localizedStandardCompare) — the oracle for the fast ASCII path.
private func finder(_ names: [String]) -> [String] { names.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

/// Deterministic generator so a fuzz failure can be reproduced from its seed.
private struct LCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

@Test func naturalOrderNumbersLikeFinder() {
    #expect(sorted(["file10.txt", "file2.txt", "file1.txt"]) == ["file1.txt", "file2.txt", "file10.txt"])
    #expect(sorted(["v1.10", "v1.9", "v1.2"]) == ["v1.2", "v1.9", "v1.10"])
    #expect(sorted(["x10", "x9", "x007", "x08"]) == ["x007", "x08", "x9", "x10"])
    let tricky = ["a", "A", "07", "7", "a b", "a_b", "a-b", "a.b", "a(1)", "a[1]", "~a", "#a", "README", "readme.md", "Readme",
                  "IMG_0010.jpg", "IMG_0009.jpg", "img_0011.JPG", "1.5", "1.10", "10", "2", "", " "]
    #expect(sorted(tricky) == finder(tricky))
}

@Test func nonASCIINamesFallBackToFinderOrder() {
    let names = ["яблуко", "єнот", "Ünïcode", "apple", "Zebra", "ёж", "Їжак", "ñandú", "zebra2", "zebra10"]
    #expect(sorted(names) == finder(names))
    // NFD on disk vs NFC in the other name: still one consistent order.
    let mixed = ["Їжак.txt".decomposedStringWithCanonicalMapping, "їжа.txt", "Їжа.txt"]
    #expect(sorted(mixed) == finder(mixed))
}

@Test func fuzzNaturalSortAgreesWithFinder() {
    var rng = LCG(state: 42)
    let alphabet = Array("abcXYZ0123456789_-. ~()[]")
    let names = (0..<2000).map { _ in String((0..<Int.random(in: 1...7, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }) }
    let ours = sorted(names)
    for (a, b) in zip(ours, ours.dropFirst()) {
        #expect(b.localizedStandardCompare(a) != .orderedAscending, "\(a.debugDescription) must not come after \(b.debugDescription)")
    }
    #expect(NameKey.natural(Array("a10".utf8), Array("a9".utf8)) > 0)
    #expect(NameKey.natural(Array("a".utf8), Array("a".utf8)) == 0)
    #expect(NameKey.natural(Array("ab".utf8), Array("abc".utf8)) < 0)   // prefix comes first
}

@Test func foldersFirstInBothDirections() {
    let items = [item("b.txt"), item("A", kind: .dir), item("a.txt"), item("z", kind: .dir), item("link", kind: .link)]
    let up = items.sortedForPanel(by: .name, ascending: true).map(\.name)
    #expect(up == ["A", "z", "a.txt", "b.txt", "link"])
    let down = items.sortedForPanel(by: .name, ascending: false).map(\.name)
    #expect(down == ["z", "A", "link", "b.txt", "a.txt"])   // folders still first, each group reversed
    #expect(items.sortedForPanel(by: .size, ascending: false).prefix(2).map(\.name) == ["z", "A"])
}

@Test func sizeAndDateKeysBreakTiesByName() {
    let items = [item("b", size: 5, mtime: 2), item("a", size: 5, mtime: 1), item("c10", size: 1, mtime: 3), item("c9", size: 1, mtime: 3)]
    #expect(items.sortedForPanel(by: .size, ascending: true).map(\.name) == ["c9", "c10", "a", "b"])
    #expect(items.sortedForPanel(by: .size, ascending: false).map(\.name) == ["b", "a", "c10", "c9"])
    #expect(items.sortedForPanel(by: .mtime, ascending: true).map(\.name) == ["a", "b", "c9", "c10"])
    #expect(items.sortedForPanel(by: .mtime, ascending: false).map(\.name) == ["c10", "c9", "b", "a"])
    #expect([FileItem]().sortedForPanel(by: .name, ascending: true).isEmpty)
}

@Test func hiddenByDotOrFlag() {
    #expect(item(".DS_Store").isHidden)
    #expect(item("Library", flags: UInt32(UF_HIDDEN)).isHidden)
    #expect(!item("Documents").isHidden)
    #expect(!item("a.b", flags: UInt32(UF_IMMUTABLE)).isHidden)
}
