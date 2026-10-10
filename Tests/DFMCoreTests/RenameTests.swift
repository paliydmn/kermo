import Foundation
import Testing
@testable import DFMCore

private func apply(_ p: RenamePattern, _ name: String, _ i: Int = 0) -> String {
    try! p.apply(name, index: i, mtime: 1_700_000_000, parent: "/x/Photos")   // 2023-11-14 local time
}

@Test func renameTokens() {
    var p = RenamePattern()
    #expect(apply(p, "report.final.pdf") == "report.final.pdf")
    #expect(apply(p, ".zshrc") == ".zshrc")
    p.nameMask = "[P]_[C]"
    p.counterStart = 7
    p.counterDigits = 3
    #expect(apply(p, "IMG_1.JPG", 2) == "Photos_009.JPG")
    p = RenamePattern()
    p.nameMask = "[N2-4]-[N6-]"
    #expect(apply(p, "abcdefgh.txt") == "bcd-fgh.txt")
    p.nameMask = "[YMD]-[N]"
    #expect(apply(p, "a.txt").hasPrefix("2023111"))
    p = RenamePattern()
    p.extMask = ""
    #expect(apply(p, "a.txt") == "a")
    p.nameMask = "[Q]"
    #expect(apply(p, "a.txt") == "[Q]")   // unknown tokens stay literal
}

@Test func renameReplaceAndCase() throws {
    var p = RenamePattern()
    p.find = "IMG_(\\d+)"
    p.replace = "photo-$1"
    p.regex = true
    p.caseMode = .lower
    #expect(apply(p, "IMG_0042.JPG") == "photo-0042.jpg")
    p.find = "("
    #expect(throws: (any Error).self) { try p.apply("x", index: 0, mtime: 0, parent: "/") }
}

private func dir(_ files: [String: String]) -> String {
    let d = NSTemporaryDirectory() + "dfm-ren-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    for (name, text) in files { try! Data(text.utf8).write(to: URL(fileURLWithPath: d + "/" + name)) }
    return d
}
private func read(_ path: String) -> String? {
    (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) }
}

@Test func batchRenameSwapsAndChains() throws {
    let d = dir(["a": "A", "b": "B", "c": "C"])
    defer { try? FileManager.default.removeItem(atPath: d) }
    try BatchRename.run([(d + "/a", d + "/b"), (d + "/b", d + "/c"), (d + "/c", d + "/a")])
    #expect(read(d + "/b") == "A" && read(d + "/c") == "B" && read(d + "/a") == "C")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: d).filter { $0.hasPrefix(".dfm-ren") }
    #expect(leftovers.isEmpty)
}

@Test func batchRenameRefusesToClobberAndRollsBack() {
    let d = dir(["a": "A", "b": "B", "keep": "K"])
    defer { try? FileManager.default.removeItem(atPath: d) }
    #expect(BatchRename.conflicts([(d + "/a", d + "/keep")]) == [d + "/a"])
    #expect(BatchRename.conflicts([(d + "/a", d + "/x"), (d + "/b", d + "/x")]).count == 2)
    #expect(throws: BatchRename.Failure.self) { try BatchRename.run([(d + "/a", d + "/x"), (d + "/b", d + "/keep")]) }
    #expect(read(d + "/a") == "A" && read(d + "/b") == "B" && read(d + "/keep") == "K")
    #expect(read(d + "/x") == nil)
}

@Test func batchRenameAllowsCaseOnlyChange() throws {
    let d = dir(["readme.md": "R"])
    defer { try? FileManager.default.removeItem(atPath: d) }
    try BatchRename.run([(d + "/readme.md", d + "/README.md")])
    #expect(try FileManager.default.contentsOfDirectory(atPath: d) == ["README.md"])
}

@Test func renameTokenEdges() {
    var p = RenamePattern()
    p.nameMask = "[N10-]|[N0]|[N3]|[N2-100]|[N"
    #expect(apply(p, "abcdef.txt") == "|[N0]|c|bcdef|[N.txt")   // past the end, invalid, single, clamped, unterminated
    p = RenamePattern()
    #expect(apply(p, "archive.tar.gz") == "archive.tar.gz")      // only the last dot splits the extension
    p.nameMask = "[E]"; p.extMask = "[N]"
    #expect(apply(p, "archive.tar.gz") == "gz.archive.tar")
    p.nameMask = "[N]_[E]"; p.extMask = ""
    #expect(apply(p, "a.txt") == "a_txt" && apply(p, "noext") == "noext_")   // no ext: no trailing dot
    p = RenamePattern()
    p.counterStart = 10; p.counterStep = -2; p.counterDigits = 2
    p.nameMask = "[C]"
    #expect(apply(p, "x.y", 1) == "08.y" && apply(p, "x.y", 6) == "-2.y")
    p = RenamePattern()
    p.caseMode = .title
    #expect(apply(p, "hello world-foo_bar.txt") == "Hello World-Foo_Bar.Txt")
    p.caseMode = .upper
    #expect(apply(p, "a.txt") == "A.TXT")
    p = RenamePattern()
    p.find = "."; p.replace = "_"          // plain mode: a dot is a dot
    #expect(apply(p, "a.b.txt") == "a_b_txt")
    p.find = "(\\w)"; p.replace = "$1$1"; p.regex = true
    #expect(apply(p, "ab.c") == "aabb.cc")
}

@Test func renameDateTokensUseLocalTime() throws {
    let mtime = 1_700_000_000.0
    let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date(timeIntervalSince1970: mtime))
    func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
    var p = RenamePattern()
    p.nameMask = "[Y]-[M]-[D] [h][m][s] [YMD] [hms]"
    p.extMask = ""
    let expected = "\(c.year!)-\(two(c.month))-\(two(c.day)) \(two(c.hour))\(two(c.minute))\(two(c.second)) "
        + "\(c.year!)\(two(c.month))\(two(c.day)) \(two(c.hour))\(two(c.minute))\(two(c.second))"
    #expect(try p.apply("x.txt", index: 0, mtime: mtime, parent: "/") == expected)
}

@Test func batchRenameConflictRules() {
    let d = dir(["a": "A", "b": "B", "keep": "K"])
    defer { try? FileManager.default.removeItem(atPath: d) }
    #expect(BatchRename.conflicts([(d + "/a", d + "/b"), (d + "/b", d + "/a")]).isEmpty)          // swap is fine
    #expect(BatchRename.conflicts([(d + "/a", d + "/a")]).isEmpty)                                 // unchanged is fine
    #expect(BatchRename.conflicts([(d + "/a", d + "/X"), (d + "/b", d + "/x")]) == [d + "/a", d + "/b"])   // case-insensitive clash
    #expect(BatchRename.conflicts([(d + "/a", d + "/KEEP")]) == [d + "/a"])                         // existing, case-insensitively
    #expect(BatchRename.conflicts([(d + "/a", d + "/")]) == [d + "/a"])
    #expect(BatchRename.conflicts([(d + "/a", d + "/.")]) == [d + "/a"])
    #expect(BatchRename.conflicts([(d + "/a", d + "/..")]) == [d + "/a"])
    #expect(BatchRename.conflicts([(d + "/a", d + "/new")]).isEmpty)
    #expect(!BatchRename.isValidName("../x") && !BatchRename.isValidName("a/b") && !BatchRename.isValidName(""))   // F7
    #expect(BatchRename.isValidName("..x") && BatchRename.isValidName(".zshrc"))
}

@Test func batchRenameRollsBackWhenTheFileSystemSaysNo() {
    let d = dir(["a": "A", "b": "B"])
    defer { try? FileManager.default.removeItem(atPath: d) }
    #expect(throws: BatchRename.Failure.self) {
        try BatchRename.run([(d + "/a", d + "/renamed-a"), (d + "/b", d + "/missing-dir/b")])
    }
    #expect(read(d + "/a") == "A" && read(d + "/b") == "B" && read(d + "/renamed-a") == nil)
    #expect(try! FileManager.default.contentsOfDirectory(atPath: d).sorted() == ["a", "b"])   // no temp names left
    #expect(throws: Never.self) { try BatchRename.run([(d + "/a", d + "/a")]) }
    #expect(throws: Never.self) { try BatchRename.run([]) }
    let err = BatchRename.Failure(path: "/x/y.txt", message: "boom")
    #expect(err.errorDescription == "“y.txt”: boom")
}
