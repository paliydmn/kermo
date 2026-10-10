import Foundation
import Testing
@testable import DFMCore

private struct Pair {
    let root: String
    var l: String { root + "/l" }
    var r: String { root + "/r" }
    init() {
        root = NSTemporaryDirectory() + "dfm-sync-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: l, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(atPath: r, withIntermediateDirectories: true)
    }
    func write(_ rel: String, _ text: String, mtime: Double = 1_000_000) {
        let p = root + "/" + rel
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: URL(fileURLWithPath: p))
        try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: p)
    }
    func plan(hidden: Bool = false, byContent: Bool = false) -> [String: DirSync.Item] {
        Dictionary(uniqueKeysWithValues: DirSync.compare(left: l, right: r, byContent: byContent, includeHidden: hidden).map { ($0.path, $0) })
    }
}

@Test func syncHiddenFilesOnlyWhenAsked() {
    let p = Pair()
    defer { try? FileManager.default.removeItem(atPath: p.root) }
    p.write("l/.secret", "s")
    p.write("l/.git/config", "c")
    p.write("r/shown", "x")
    #expect(Set(p.plan().keys) == ["shown"])
    #expect(Set(p.plan(hidden: true).keys) == [".secret", ".git", "shown"])
}

@Test func syncFileVersusFolderIsAConflict() {
    let p = Pair()
    defer { try? FileManager.default.removeItem(atPath: p.root) }
    p.write("l/x", "file")
    p.write("r/x/inner", "folder")
    let item = p.plan()["x"]
    #expect(item?.isConflict == true && item?.action == .skip)
    #expect(item?.left?.kind == .file && item?.right?.kind == .dir)
    #expect(p.plan()["x/inner"] == nil)   // not walked into
}

@Test func syncMissingFolderIsOneRowAndEmptyFoldersAreSilent() {
    let p = Pair()
    defer { try? FileManager.default.removeItem(atPath: p.root) }
    p.write("l/only/deep/er/f.txt", "f")
    try! FileManager.default.createDirectory(atPath: p.l + "/empty", withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(atPath: p.r + "/empty", withIntermediateDirectories: true)
    let plan = p.plan()
    #expect(Set(plan.keys) == ["only"])
    #expect(plan["only"]?.action == .toRight && plan["only"]?.left?.kind == .dir && plan["only"]?.right == nil)
}

@Test func syncMatchesNamesLikeAPFS() {
    let p = Pair()
    defer { try? FileManager.default.removeItem(atPath: p.root) }
    p.write("l/" + "Їжак.txt".decomposedStringWithCanonicalMapping, "same")
    p.write("r/" + "їжак.txt".precomposedStringWithCanonicalMapping, "same")
    let plan = DirSync.compare(left: p.l, right: p.r)
    #expect(plan.count == 1 && plan.first?.action == .equal)
}

@Test func syncStopsWhenCancelled() {
    let p = Pair()
    defer { try? FileManager.default.removeItem(atPath: p.root) }
    for i in 0..<5 { p.write("l/f\(i)", "x") }
    #expect(DirSync.compare(left: p.l, right: p.r, isCancelled: { true }).isEmpty)
    var seen = 0
    let partial = DirSync.compare(left: p.l, right: p.r, isCancelled: { seen += 1; return seen > 2 })
    #expect(partial.count == 2)
}

@Test func syncByContentOnlyMattersForSameSizeAndTime() {
    let p = Pair()
    defer { try? FileManager.default.removeItem(atPath: p.root) }
    p.write("l/a", "abc", mtime: 100); p.write("r/a", "abd", mtime: 100)   // same size & time, different bytes
    p.write("l/b", "abc", mtime: 100); p.write("r/b", "abc", mtime: 100)
    p.write("l/c", "abc", mtime: 200); p.write("r/c", "abd", mtime: 100)   // newer wins even if content is compared
    let plan = p.plan(byContent: true)
    #expect(plan["a"]?.isConflict == true && plan["b"]?.action == .equal && plan["c"]?.action == .toRight)
}

@Test func filesEqualCompares() throws {
    let d = NSTemporaryDirectory() + "dfm-eq-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: d) }
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    let big = Data(repeating: 7, count: (1 << 20) + 5)   // crosses the 1 MB read chunk
    try big.write(to: URL(fileURLWithPath: d + "/a"))
    try big.write(to: URL(fileURLWithPath: d + "/b"))
    try big.dropLast().write(to: URL(fileURLWithPath: d + "/shorter"))
    var flipped = big; flipped[big.count - 1] = 8
    try flipped.write(to: URL(fileURLWithPath: d + "/lastbyte"))
    try Data().write(to: URL(fileURLWithPath: d + "/e1"))
    try Data().write(to: URL(fileURLWithPath: d + "/e2"))
    #expect(DirSync.filesEqual(d + "/a", d + "/b"))
    #expect(DirSync.filesEqual(d + "/e1", d + "/e2"))
    #expect(!DirSync.filesEqual(d + "/a", d + "/shorter"))
    #expect(!DirSync.filesEqual(d + "/a", d + "/lastbyte"))
    #expect(!DirSync.filesEqual(d + "/a", d + "/missing"))
}

@Test func compareFoldersEdgeCases() {
    func f(_ n: String, _ size: Int64 = 1, _ t: Double = 100, dir: Bool = false) -> FileItem {
        FileItem(name: n, kind: dir ? .dir : .file, size: size, mtime: t, mode: 0, flags: 0)
    }
    // Folders are matched by presence only, even against a file of the same name.
    let (l, r) = DirCompare.differences(left: [f("d", dir: true), f("x", dir: true), f("both", 1, 100)],
                                        right: [f("d"), f("x", dir: true), f("both", 2, 100.9)])
    #expect(l == ["both"] && r == ["both"])
    // NFD (as APFS may return it) and NFC spell the same file.
    let nfd = "Їжак.txt".decomposedStringWithCanonicalMapping
    let (l2, r2) = DirCompare.differences(left: [f(nfd, 1, 200)], right: [f("їжак.txt", 1, 100)])
    #expect(l2 == [nfd] && r2.isEmpty)
    let (l3, r3) = DirCompare.differences(left: [], right: [f("only")])
    #expect(l3.isEmpty && r3 == ["only"])
    let (l4, r4) = DirCompare.differences(left: [], right: [])
    #expect(l4.isEmpty && r4.isEmpty)
}

@Test func mirrorMakesTheTargetAnExactCopy() {
    func f(_ n: String, _ t: Double, dir: Bool = false) -> FileItem { FileItem(name: n, kind: dir ? .dir : .file, size: 1, mtime: t, mode: 0, flags: 0) }
    let items = [
        DirSync.Item(path: "only-left", left: f("only-left", 1), right: nil, action: .toRight, isConflict: false),
        DirSync.Item(path: "only-right", left: nil, right: f("only-right", 1), action: .toLeft, isConflict: false),
        DirSync.Item(path: "newer-right", left: f("newer-right", 1), right: f("newer-right", 9), action: .toLeft, isConflict: false),
        DirSync.Item(path: "same", left: f("same", 1), right: f("same", 1), action: .equal, isConflict: false),
        DirSync.Item(path: "clash", left: f("clash", 1), right: f("clash", 1, dir: true), action: .skip, isConflict: true),
    ]
    #expect(DirSync.mirror(items, toRight: true).map(\.action) == [.toRight, .trashRight, .toRight, .equal, .skip])
    #expect(DirSync.mirror(items, toRight: false).map(\.action) == [.trashLeft, .toLeft, .toLeft, .equal, .skip])
    #expect(DirSync.choices(items[0]) == [.toRight, .trashLeft, .skip])
    #expect(DirSync.choices(items[1]) == [.toLeft, .trashRight, .skip])
    #expect(DirSync.choices(items[2]) == [.toRight, .toLeft, .skip])
    #expect(DirSync.choices(items[3]) == [.equal])
}
