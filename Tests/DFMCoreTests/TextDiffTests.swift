import Foundation
import Testing
@testable import DFMCore

/// Blocks as "old-lines→new-lines", e.g. "1..<2→1..<3".
private func blocks(_ a: String, _ b: String) -> [String] {
    TextDiff.compare(a, b)!.blocks.map { "\($0.old)→\($0.new)" }
}

@Test func blocksAtTheStartInsideAndAtTheEnd() {
    #expect(blocks("a\nb\nc", "a\nb\nc") == [])
    #expect(blocks("a\nb\nc", "x\na\nb\nc") == ["0..<0→0..<1"])   // added before the first line
    #expect(blocks("a\nb\nc", "b\nc") == ["0..<1→0..<0"])          // the first line removed
    #expect(blocks("a\nb\nc", "a\nB\nc") == ["1..<2→1..<2"])       // changed inside
    #expect(blocks("a\nb\nc", "a\nb\nc\nd") == ["3..<3→3..<4"])    // lines by their text: "c" is "c" with a line end or without
    #expect(blocks("a\nb", "a\nb\n") == ["2..<2→2..<3"])            // a final line end: an empty last line, as the numbers show it
    #expect(blocks("a\nb\nc\n", "a\nb\nc\nd\n") == ["3..<3→3..<4"])
    #expect(blocks("a\nb\nc\nd", "a\nd") == ["1..<3→1..<1"])
    #expect(blocks("a\nb\nc\nd", "a\nX\nY\nZ\nd") == ["1..<3→1..<4"])   // two lines in place of three: one block
    #expect(blocks("a\nb\nc\nd\ne", "a\nB\nc\nD\ne") == ["1..<2→1..<2", "3..<4→3..<4"])
}

@Test func anEmptySide() {
    #expect(blocks("", "a\nb") == ["0..<1→0..<2"])   // an empty text is one empty line, as the line numbers count it
    #expect(blocks("a\n", "") == ["0..<1→0..<0"])
    #expect(blocks("", "") == [])
}

@Test func linesAsTheLineNumbersCountThem() {
    let r = TextDiff.lines("a\r\nb\rc\u{2028}d\n" as NSString)
    #expect(r.map(\.location) == [0, 3, 5, 7, 9])   // CRLF, CR and U+2028 end a line; a last empty one after "\n"
    #expect(r.map(\.length) == [1, 1, 1, 1, 0])
    #expect(TextDiff.lines("" as NSString) == [NSRange(location: 0, length: 0)])
    #expect(TextDiff.lines("x" as NSString) == [NSRange(location: 0, length: 1)])
}

@Test func changedCharactersInUTF16() {
    let r = TextDiff.compare("worker_processes auto;\nx", "worker_processes 4;\nx")!
    #expect(r.oldChars == [NSRange(location: 17, length: 4)])   // "auto"
    #expect(r.newChars == [NSRange(location: 17, length: 1)])   // "4"
    // In a later line: in the text, not the line.
    let s = TextDiff.compare("a\nb\nlisten 443;", "a\nb\nlisten 443 ssl;")!
    #expect(s.newChars == [NSRange(location: 14, length: 4)] && s.oldChars.isEmpty)
    // An emoji (two UTF-16 units) and an "й" made of a letter and its mark stay whole.
    let e = TextDiff.inline("ok 👍 ok", "ok 👎 ok")!
    #expect(e.old == [NSRange(location: 3, length: 2)] && e.new == [NSRange(location: 3, length: 2)])
    let m = TextDiff.inline("ми", "мий\u{0306}")!   // и + combining breve
    #expect(m.old.isEmpty && m.new == [NSRange(location: 2, length: 2)])
    #expect(TextDiff.inline(String(repeating: "a", count: 1001), "b") == nil)   // too long: the whole line is the change
}

@Test func onlyPairedLinesGetCharacters() {
    let r = TextDiff.compare("a\nold one\nz", "a\nnew one\nadded\nz")!
    #expect(r.blocks == [TextDiff.Block(old: 1..<2, new: 1..<3)])
    #expect(r.oldChars == [NSRange(location: 2, length: 3)])   // "old" against "new"; "added" is added, not changed
    #expect(r.newChars == [NSRange(location: 2, length: 3)])
}

@Test func theBudgetTurnsDownAllDifferentButNotAFewChanges() {
    let all = (0..<10_000).map { "left \($0)" }.joined(separator: "\n"), other = (0..<10_000).map { "right \($0)" }.joined(separator: "\n")
    #expect(TextDiff.compare(all, other) == nil)
    var lines = (0..<100_000).map { "line \($0) of a big file" }
    for i in stride(from: 500, to: 100_000, by: 1000) { lines[i] = "changed \(i)" }
    let start = Date()
    let r = TextDiff.compare((0..<100_000).map { "line \($0) of a big file" }.joined(separator: "\n"), lines.joined(separator: "\n"))
    #expect(r?.blocks.count == 100)
    #expect(Date().timeIntervalSince(start) < 5)   // ~0.2 s here; slack for a busy test run
}
