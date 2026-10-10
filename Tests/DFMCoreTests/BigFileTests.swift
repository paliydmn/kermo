import Foundation
import Testing
@testable import DFMCore

private let text = Data("one\ntwo\nthree\n\nfive".utf8)   // lines start at 0, 4, 8, 14, 15

@Test func bigFileLineBoundaries() {
    #expect([0, 2, 3, 4, 7, 8, 14, 15, 17, 19].map { BigFile.lineStart(text, at: $0) } == [0, 0, 0, 4, 4, 8, 14, 15, 15, 15])
    #expect([0, 3, 4, 13, 14, 15, 19].map { BigFile.nextLine(text, after: $0) } == [4, 4, 8, 14, 15, 19, 19])
    #expect(BigFile.newlines(text, 0..<text.count) == 4 && BigFile.newlines(text, 4..<14) == 2 && BigFile.newlines(text, 0..<3) == 0)
    #expect((0...5).map { BigFile.lineOffset(text, from: 0, line: $0) } == [0, 4, 8, 14, 15, 19])
    #expect(BigFile.lineOffset(text, from: 4, line: 2) == 14)
    // A line longer than the look-back limit is cut at the limit instead of scanning gigabytes.
    let long = Data(repeating: 65, count: 100) + Data("\nx".utf8)
    #expect(BigFile.lineStart(long, at: 90, limit: 10) == 90)
    #expect(BigFile.lineStart(long, at: 101, limit: 10) == 101)
}

@Test func bigFileWindows() {
    let lines = (0..<1000).map { String(format: "line %04d\n", $0) }.joined()   // 10 bytes per line
    let d = Data(lines.utf8)
    let w = BigFile.window(d, around: 5000, size: 1000)
    #expect(w == 4500..<5500)
    #expect(BigFile.window(d, around: 5003, size: 1000) == 4500..<5500)   // aligned to whole lines
    #expect(BigFile.window(d, around: 0, size: 1000) == 0..<1000)
    #expect(BigFile.window(d, around: d.count, size: 1000) == 9000..<10000)   // the end: full last page
    #expect(BigFile.window(d, around: 0, size: 50_000) == 0..<10000)
    let oneLine = Data(repeating: 66, count: 5000)
    #expect(BigFile.window(oneLine, around: 2500, size: 1000).count == 1000)   // no newline at all: cut, not empty
}

@Test func bigFileSearchAcrossChunks() {
    var d = Data(repeating: 46, count: 10_000)
    d.replaceSubrange(4094..<4101, with: Data("NeeDLE!".utf8))   // straddles the 4096-byte chunk edge
    d.replaceSubrange(9000..<9006, with: Data("needle".utf8))
    let needle = Array("needle".utf8)
    #expect(BigFile.find(needle, in: d, from: 0, caseSensitive: false, chunk: 4096) == 4094)
    #expect(BigFile.find(needle, in: d, from: 4095, caseSensitive: false, chunk: 4096) == 9000)
    #expect(BigFile.find(needle, in: d, from: 0, caseSensitive: true, chunk: 4096) == 9000)
    #expect(BigFile.find(needle, in: d, from: 9001, caseSensitive: false, chunk: 4096) == nil)
    #expect(BigFile.find(Array("x".utf8), in: Data(), from: 0, caseSensitive: true) == nil)
}

@Test func bigFilePositions() {
    let size = 10 << 30
    #expect(BigFile.position("50%", size: size) == 5 << 30)
    #expect(BigFile.position(" 1.5G ", size: size) == 3 << 29)
    #expect(BigFile.position("200m", size: size) == 200 << 20)
    #expect(BigFile.position("4096", size: size) == 4096)
    #expect(BigFile.position("end", size: size) == size && BigFile.position("$", size: size) == size)
    #expect(BigFile.position("99T", size: size) == size)   // clamped
    #expect(BigFile.position("150%", size: size) == nil && BigFile.position("abc", size: size) == nil)
    #expect(BigFile.position("-5", size: size) == nil)
    #expect(BigFile.position("inf", size: size) == size && BigFile.position("1e300g", size: size) == size)   // F6: used to trap
    #expect(BigFile.position("nan", size: size) == nil)
}
