import Foundation
import Testing
@testable import DFMCore

private func tree() -> String {
    let root = NSTemporaryDirectory() + "dfm-search-" + UUID().uuidString
    let files = [
        "a/server.log": "ok\nERROR disk full\n",
        "a/b/app.log": "all good",
        "a/b/notes.txt": "error in lowercase",
        "c/readme.md": "nothing",
        ".hidden/secret.log": "ERROR hidden",
    ]
    for (rel, text) in files {
        let p = root + "/" + rel
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: URL(fileURLWithPath: p))
    }
    return root
}

private func find(_ q: SearchQuery) -> [String] {
    var hits: [String] = []
    FileSearch.run(q, isCancelled: { false }) { hits.append($0.name) }
    return hits.sorted()
}

@Test func searchByName() {
    let root = tree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    var q = SearchQuery(root: root)
    q.name = "*.log"
    #expect(find(q) == ["a/b/app.log", "a/server.log"])
    q.includeHidden = true
    #expect(find(q) == [".hidden/secret.log", "a/b/app.log", "a/server.log"])
    q.name = "b"                         // plain text = substring of the name
    q.includeHidden = false
    #expect(find(q) == ["a/b"])
}

@Test func searchByContent() {
    let root = tree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    var q = SearchQuery(root: root)
    q.contains = "ERROR"
    #expect(find(q) == ["a/b/notes.txt", "a/server.log"])   // case-insensitive by default
    q.caseSensitive = true
    #expect(find(q) == ["a/server.log"])
    q.name = "*.txt"
    q.caseSensitive = false
    #expect(find(q) == ["a/b/notes.txt"])
}

@Test func contentMatchAcrossChunkBoundary() throws {
    let p = NSTemporaryDirectory() + "dfm-chunk-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: p) }
    var data = Data(repeating: UInt8(ascii: "x"), count: (1 << 20) - 3)
    data.append(contentsOf: Array("NEEDLE".utf8))   // straddles the 1 MB edge
    try data.write(to: URL(fileURLWithPath: p))
    #expect(FileSearch.fileContains(p, Array("needle".utf8), caseSensitive: false))
    #expect(!FileSearch.fileContains(p, Array("needle".utf8), caseSensitive: true))
}

@Test func searchStopsWhenCancelled() {
    let root = tree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    var q = SearchQuery(root: root)
    q.name = "*"
    var count = 0
    FileSearch.run(q, isCancelled: { count >= 2 }) { _ in count += 1 }
    #expect(count == 2)
}

@Test func compareFoldersMarksNewerAndMissing() {
    func f(_ n: String, _ size: Int64, _ t: Double, dir: Bool = false) -> FileItem {
        FileItem(name: n, kind: dir ? .dir : .file, size: size, mtime: t, mode: 0, flags: 0)
    }
    let left = [f("same", 1, 100), f("newer-left", 1, 200), f("older-left", 1, 100), f("only-left", 1, 1),
                f("clash", 1, 100), f("Case.TXT", 1, 100), f("sub", 0, 5, dir: true)]
    let right = [f("same", 1, 100.5), f("newer-left", 1, 100), f("older-left", 1, 300), f("only-right", 1, 1),
                 f("clash", 2, 100), f("case.txt", 1, 100), f("sub", 0, 999, dir: true)]
    let (l, r) = DirCompare.differences(left: left, right: right)
    #expect(l == ["newer-left", "only-left", "clash"])
    #expect(r == ["older-left", "only-right", "clash"])
}

@Test func searchRegexNamesAndOddRoots() throws {
    let root = tree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    var q = SearchQuery(root: root)
    q.name = "re:^server\\.log$"
    #expect(find(q) == ["a/server.log"])
    q.name = "re:("          // invalid regex: Mask is nil, so the name doesn't filter
    #expect(find(q).count == find(SearchQuery(root: root)).count)
    #expect(find(SearchQuery(root: root + "/missing")).isEmpty)
    var one = SearchQuery(root: root + "/a/server.log")   // a file as root: nothing to walk
    one.name = "*"
    #expect(find(one).isEmpty)
}

@Test func searchDoesNotFollowLinkedFoldersOrLookInsideNonFiles() throws {
    let root = tree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createSymbolicLink(atPath: root + "/linkdir", withDestinationPath: "a")
    var q = SearchQuery(root: root)
    q.name = "*.log"
    #expect(!find(q).contains { $0.hasPrefix("linkdir/") })
    q.name = "linkdir"
    #expect(find(q) == ["linkdir"])   // the link itself is listed
    q.name = ""
    q.contains = "ok"
    #expect(find(q) == ["a/server.log"])   // folders and links are never content matches
}

@Test func fileContainsEdgeCases() throws {
    let d = NSTemporaryDirectory() + "dfm-contains-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: d) }
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    try Data("abc".utf8).write(to: URL(fileURLWithPath: d + "/abc"))
    var exact = Data(repeating: UInt8(ascii: "x"), count: (1 << 20) - 6)
    exact.append(contentsOf: Array("NEEDLE".utf8))   // ends exactly on the chunk edge
    try exact.write(to: URL(fileURLWithPath: d + "/edge"))
    try Data("Привіт".utf8).write(to: URL(fileURLWithPath: d + "/cyr"))

    #expect(FileSearch.fileContains(d + "/abc", Array("abc".utf8), caseSensitive: true))
    #expect(!FileSearch.fileContains(d + "/abc", Array("abcd".utf8), caseSensitive: true))
    #expect(!FileSearch.fileContains(d + "/abc", [], caseSensitive: true))
    #expect(!FileSearch.fileContains(d + "/missing", Array("a".utf8), caseSensitive: true))
    #expect(FileSearch.fileContains(d + "/edge", Array("needle".utf8), caseSensitive: false))
    #expect(FileSearch.fileContains(d + "/cyr", Array("Привіт".utf8), caseSensitive: false))
    #expect(FileSearch.fileContains(d + "/cyr", Array("ПРИВІТ".utf8), caseSensitive: false))
}

@Test func cancelFlag() {
    let f = CancelFlag()
    #expect(!f.isCancelled)
    f.cancel()
    #expect(f.isCancelled)
}
