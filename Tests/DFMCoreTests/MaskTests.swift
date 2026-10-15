import Foundation
import Testing
@testable import DFMCore

@Test func globMasks() {
    let m = Mask("*.log; *.TXT")!
    #expect(m.matches("system.log"))
    #expect(m.matches("Notes.txt"))
    #expect(!m.matches("log.swift"))
    #expect(Mask("file?.c")!.matches("file1.c"))
    #expect(!Mask("file?.c")!.matches("file10.c"))
    #expect(Mask("*")!.matches(".zshrc"))     // dotfiles are not special
}

@Test func cyrillicAndNormalization() {
    let nfd = "Їжак.txt".decomposedStringWithCanonicalMapping   // how APFS may hand names back
    #expect(Mask("ї*")!.matches(nfd))
    #expect(Mask(filter: "жак")!.matches(nfd))
}

@Test func regexAndFilterSemantics() {
    #expect(Mask("re:^v\\d+\\.\\d+$")!.matches("V1.10"))
    #expect(Mask("re:(") == nil)
    #expect(Mask("  ") == nil)
    #expect(Mask(filter: "port")!.matches("report.pdf"))   // plain text = substring
    #expect(!Mask(filter: "port*")!.matches("report.pdf")) // wildcard = glob
}

@Test func measureCountsTreeWithoutFollowingLinks() throws {
    let root = NSTemporaryDirectory() + "dfm-measure-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(atPath: root + "/a/b", withIntermediateDirectories: true)
    try Data(count: 10).write(to: URL(fileURLWithPath: root + "/a/x"))
    try Data(count: 5).write(to: URL(fileURLWithPath: root + "/a/b/y"))
    try FileManager.default.createSymbolicLink(atPath: root + "/a/loop", withDestinationPath: root)
    let (files, bytes) = DirLister.measure(root)
    #expect(files == 3)   // x, y, and the link itself
    #expect(bytes >= 15)
}

@Test func maskClassesSeparatorsAndWhitespace() {
    #expect(Mask("[abc]*.txt")!.matches("b1.txt") && !Mask("[abc]*.txt")!.matches("d1.txt"))
    #expect(Mask("[!a]*.txt")!.matches("b.txt") && !Mask("[!a]*.txt")!.matches("a.txt"))
    let m = Mask(" *.log , *.txt ;; ")!
    #expect(m.matches("x.log") && m.matches("x.txt") && !m.matches("x.md"))
    #expect(Mask("*.LOG")!.matches("x.log"))
    #expect(Mask("*.log")!.matches("dir/x.log"))     // search results carry a relative path as the name
    #expect(Mask(filter: "")!.matches("anything"))
    #expect(Mask(filter: "[ab]*")!.matches("alpha") && !Mask(filter: "[ab]*")!.matches("x[ab]y"))
    #expect(Mask(filter: "re:^a")!.matches("abc") && !Mask(filter: "re:^a")!.matches("bac"))
    #expect(Mask(filter: "a.b")!.matches("xa.by") && !Mask(filter: "a.b")!.matches("axb"))   // dot is literal
    #expect(Mask("") == nil && Mask(";,") == nil)
}

/// Names folded once match as each name folded on every call: NFD and Cyrillic, case, globs, plain text, regex.
@Test func foldedNamesMatchAsNamesDo() {
    let names = ["Їжак.txt".decomposedStringWithCanonicalMapping, "ЇЖАК.TXT", "café.LOG", "cafe\u{301}.log", "report.pdf",
                 "a[b]c", "x?y", "dir/x.log", ".zshrc", "Straße", "K\u{212A}elvin", "", "v1.10", "notes"]
    let folded = Mask.Folded(names)
    let masks = ["жак", "ЖАК.t", "café", "CAFÉ.log", "*.log", "*.LOG; *.txt", "[ab]*", "x?y", "re:^v\\d", "re:CAF", "port",
                 "a[b]c", "e", "ss", "k", "*", "?", "a,b"]
    for spec in masks {
        guard let m = Mask(filter: spec) else { continue }
        for (i, n) in names.enumerated() { #expect(m.matches(i, of: folded, name: n) == m.matches(n), "\(spec) on \(n)") }
    }
    var more = Mask.Folded(names.prefix(3))
    more.append(names.dropFirst(3))
    #expect(more.count == names.count)
    #expect(names.indices.allSatisfy { Mask(filter: "log")!.matches($0, of: more, name: names[$0]) == Mask(filter: "log")!.matches(names[$0]) })
}
