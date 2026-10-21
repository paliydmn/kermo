import Foundation
import Testing
@testable import DFMCore

// Task 9 QA follow-up, group "viewer2" (V4, V5).

/// V4: one bad byte in a UTF-8 log is one U+FFFD, not the whole chunk turned into Windows-1251 mojibake;
/// real Windows-1251 (even a few words in an ASCII file) still decodes as such.
@Test func decodeKeepsDamagedUTF8AsUTF8() {
    let damaged = Data("Привіт, світ — ".utf8) + [0xff] + Data(" ERROR in модуль\n".utf8)
    #expect(TextFormat.decode(damaged) == ("Привіт, світ — \u{FFFD} ERROR in модуль\n", "UTF-8 (lossy)"))
    #expect(TextFormat.mostlyUTF8(damaged))
    // A short follow chunk: one Cyrillic word and a bad byte.
    #expect(TextFormat.decode(Data("ok ".utf8) + [0xc0] + Data(" привіт\n".utf8)).text == "ok \u{FFFD} привіт\n")

    let cp1251 = "Він пішов додому. Сім ієрогліфів.".data(using: .windowsCP1251)!
    #expect(!TextFormat.mostlyUTF8(cp1251))
    #expect(TextFormat.decode(cp1251) == ("Він пішов додому. Сім ієрогліфів.", "Windows-1251"))
    let config = Data(("# " + String(repeating: "setting = value\n", count: 200)).utf8)
        + "# Коментар\n".data(using: .windowsCP1251)! + Data("end = 1\n".utf8)
    #expect(TextFormat.decode(config).encoding == "Windows-1251")
    #expect(!TextFormat.mostlyUTF8(Data("plain ascii".utf8)))
}

/// V5: a log truncated under its writer (copytruncate) starts with a run of NULs — still text; a few control
/// bytes or ANSI colors are text too; real binaries (Mach-O, UTF-16, random bytes) are binary.
@Test func binaryDetectionIgnoresALeadingNULRun() {
    let log = Data((0..<200).map { "2026-10-07 12:00:00 \u{1b}[31mERROR\u{1b}[0m worker \($0)\tok\r\n" }.joined().utf8)
    #expect(!TextFormat.looksBinary(log))
    #expect(!TextFormat.looksBinary(Data(repeating: 0, count: 64 << 10) + log))
    #expect(!TextFormat.looksBinary(log + [0, 0, 7] + log))   // a stray NUL or bell mid-text
    #expect(!TextFormat.looksBinary(Data()))

    #expect(TextFormat.looksBinary(Data(repeating: 0, count: 4096)))
    #expect(TextFormat.looksBinary(Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1, 0, 0, 0, 0, 2, 0, 0, 0]) + Data(repeating: 0x41, count: 40)))
    #expect(TextFormat.looksBinary("hello world\n".data(using: .utf16LittleEndian)!))
    var rng = SystemRandomNumberGenerator()
    #expect(TextFormat.looksBinary(Data((0..<8192).map { _ in UInt8.random(in: 1...255, using: &rng) })))
}

/// V5 follow-up: the leading-NUL skip stops after 256 MB — an all-NUL file or a disk image is binary after a quick
/// scan instead of one of the whole (possibly many-GB, memory-mapped) file — but a server log fetched with 16 MB of
/// real NULs (a copytruncate hole written out) is still text.
@Test func binaryDetectionCapsTheLeadingNULRun() throws {
    let log = Data((0..<50).map { "2026-10-07 12:00:00 worker \($0) ok\n" }.joined().utf8)
    #expect(!TextFormat.looksBinary(Data(count: 16 << 20) + log))
    #expect(TextFormat.looksBinary(Data(count: 16 << 20)))
    // Past the cap (a sparse file mapped, so no 256 MB in memory): binary.
    let path = NSTemporaryDirectory() + "dfm-r9v2-nul-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: path) }
    FileManager.default.createFile(atPath: path, contents: nil)
    let h = try #require(FileHandle(forWritingAtPath: path))
    try h.seek(toOffset: UInt64(TextFormat.nulRunLimit) + 1)
    try h.write(contentsOf: log)
    try h.close()
    #expect(TextFormat.nulRunLimit == 256 << 20)
    #expect(TextFormat.looksBinary(try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)))
    #expect(!TextFormat.looksBinary((Data(count: 100) + log).dropFirst(50)))   // a slice: offsets from its start
}

/// V6 follow-up: inside one line longer than the window (a minified JSON) the window still centres on the offset —
/// it used to snap back to the line's start within 1 MB, so sliding never moved — and its cuts never split a
/// UTF-8 character.
@Test func windowMovesThroughALongLineAndKeepsCharactersWhole() {
    let d = Data(String(repeating: "{\"name\":\"значення\"},", count: 50_000).utf8)   // 1.5 MB, no newline at all
    for offset in [3000, 10_000, 20_000, 30_001] {
        let w = BigFile.window(d, around: offset, size: 8192)
        #expect(w.contains(offset) && w.lowerBound > offset - 8192 / 2 - 8192 / 4 - 4 && w.upperBound > offset + 8192 / 4, "\(offset): \(w)")
        #expect(d[w.lowerBound] & 0xc0 != 0x80 && (w.upperBound == d.count || d[w.upperBound] & 0xc0 != 0x80), "\(offset): \(w)")
    }
    #expect(BigFile.window(d, around: d.count, size: 8191).lowerBound > 0)
    #expect(d[BigFile.window(d, around: d.count, size: 8191).lowerBound] & 0xc0 != 0x80)
}

/// V6 follow-up: the window always holds the offset it is centred on — short lines before a line longer than half
/// of it (a minified .js with a licence header) used to end it at that long line's start: 0..<38, never sliding.
@Test func windowAlwaysHoldsItsOffset() {
    let size = 256 << 10
    let header = Data("/*! lib v3.7.1 | (c) Someone | MIT */\n".utf8) + Data(repeating: 0x61, count: 5 << 20)
    let short = Data((0..<1000).map { "line \($0)\n" }.joined().utf8)
    let mixed = short + Data(repeating: 0x62, count: 1 << 20) + Data([10]) + short + Data(repeating: 0x63, count: 1 << 20)
    for d in [header, mixed] {
        for o in [1000, 50_000, 120_000] + Array(stride(from: 0, to: d.count, by: 65_537)) {
            let w = BigFile.window(d, around: o, size: size)
            #expect(w.contains(o) && w.count > size / 2, "\(o): \(w)")
        }
    }
}

/// V6 follow-up: how many bytes make so many UTF-16 units of text decoded as the viewer does — a damaged byte is one
/// U+FFFD but one byte (counting the U+FFFD's 3 UTF-8 bytes skipped text on every slide), an emoji is 2 units.
@Test func utf8BytesCountsSourceBytes() {
    let d = Data("aб".utf8) + [0xff] + Data("😀".utf8) + [0xe2, 0x82] + Data("z".utf8)
    #expect(String(decoding: d, as: UTF8.self).utf16.count == 7)
    #expect([0, 1, 2, 3, 5, 6, 7].map { ANSI.bytes(d, units: $0, singleByte: false) } == [0, 1, 3, 4, 8, 10, 11])
    #expect(ANSI.bytes(d.subdata(in: 3..<d.count), units: 2, singleByte: false) == 5)   // from the bad byte: it and the emoji
    #expect(ANSI.bytes(d, units: 100, singleByte: false) == d.count)
    #expect(ANSI.units(d, singleByte: false) == 7)
}

/// D-069: a big file's window shows colors, not escape codes — and a place in a line maps back to the file's bytes
/// past them, both ways: where the top line is kept while sliding. A sequence cut by the window's end shows as the
/// rest of `parse` does (only its ESC goes). A charset choice followed by a line end keeps the line end.
@Test func aWindowsPlacesMapPastEscapeCodes() {
    let line = Data("\u{1B}[31mERROR\u{1B}[0m: x".utf8)   // shows "ERROR: x"
    #expect(ANSI.parse(String(decoding: line, as: UTF8.self)).text == "ERROR: x")
    #expect([0, 1, 5, 6, 8].map { ANSI.bytes(line, units: $0, singleByte: false) } == [0, 6, 10, 15, 17])
    #expect([0, 6, 10, 15, 17].map { ANSI.units(line.prefix($0), singleByte: false) } == [0, 1, 5, 6, 8])
    let cut = Data("ok \u{1B}[3".utf8)   // a sequence cut: only its ESC goes
    #expect(ANSI.units(cut, singleByte: false) == ANSI.parse(String(decoding: cut, as: UTF8.self)).text.utf16.count)
    let cp1251 = Data([0x1B, 0x5B, 0x31, 0x6D, 0xCF, 0xF0, 0x1B, 0x5B, 0x30, 0x6D, 0xE8])   // bold "Пр", plain "и"
    #expect(ANSI.bytes(cp1251, units: 2, singleByte: true) == 6 && ANSI.units(cp1251, singleByte: true) == 3)
    #expect(ANSI.parse("a\u{1B}(\nb").text == "a\nb", "the line count after it stays right")
}
