import Foundation
import Testing
@testable import DFMCore

private func tempFile(_ name: String) -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-tags-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    let p = d + "/" + name
    FileManager.default.createFile(atPath: p, contents: Data("x".utf8))
    return p
}

@Test func tagsRoundTripAndShowInListing() throws {
    let p = tempFile("a.txt")
    let dir = (p as NSString).deletingLastPathComponent
    defer { try? FileManager.default.removeItem(atPath: dir) }
    #expect(FinderTags.read(p).isEmpty)

    try FinderTags.write(p, [.init(name: "work"), .init(name: "Red", color: 6), .init(name: "Blue", color: 4)])
    #expect(FinderTags.read(p) == [.init(name: "work"), .init(name: "Red", color: 6), .init(name: "Blue", color: 4)])
    #expect(try DirLister.list(dir).first?.label == 4)   // last colored tag, mirrored into FinderInfo
    let names = try URL(fileURLWithPath: p).resourceValues(forKeys: [.tagNamesKey]).tagNames
    #expect(names == ["work", "Red", "Blue"])            // what Finder sees

    try FinderTags.write(p, [])
    #expect(FinderTags.read(p).isEmpty)
    #expect(try DirLister.list(dir).first?.label == 0)
    try FinderTags.write(p, [])   // removing twice is fine
}

@Test func tagParse() {
    let colors = ["", "Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]
    let parsed = FinderTags.parse(" work, green ,, Work, Projects ", existing: [.init(name: "Projects", color: 3)], colorNames: colors)
    #expect(parsed == [.init(name: "work"), .init(name: "green", color: 2), .init(name: "Projects", color: 3)])
}

@Test func searchByTagWalk() throws {
    let p = tempFile("tagged.log")
    let dir = (p as NSString).deletingLastPathComponent
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: dir + "/plain.log", contents: nil)
    try FinderTags.write(p, [.init(name: "Важливе")])
    var q = SearchQuery(root: dir)
    q.tag = "важливе"
    var found: [String] = []
    FileSearch.run(q, isCancelled: { false }) { found.append($0.name) }
    #expect(found == ["tagged.log"])
}
