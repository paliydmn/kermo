import Foundation
import Testing
@testable import DFMCore

@Test func hexDumpLayout() {
    let dump = TextFormat.hexDump(Data("Hello, world!\n\u{0}\u{1}xyz".utf8), base: 0x100)
    let lines = dump.split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[0] == "00000100  48 65 6c 6c 6f 2c 20 77  6f 72 6c 64 21 0a 00 01  |Hello, world!...|")
    #expect(lines[1].hasPrefix("00000110  78 79 7a "))
    #expect(lines[1].hasSuffix("|xyz|"))
    func column(_ l: Substring) -> Int { l.distance(from: l.startIndex, to: l.firstIndex(of: "|")!) }
    #expect(column(lines[0]) == column(lines[1]))   // ASCII column stays aligned on a short last line
}

@Test func binaryPlistBecomesReadable() throws {
    let bin = try PropertyListSerialization.data(fromPropertyList: ["Label": "com.example.agent", "RunAtLoad": true],
                                                 format: .binary, options: 0)
    let text = try #require(TextFormat.prettyPlist(bin))
    #expect(text.contains("<key>Label</key>") && text.contains("com.example.agent"))
    #expect(TextFormat.prettyPlist(Data("not a plist {".utf8)) == nil)
}

@Test func jsonPrettyPrint() throws {
    let text = try #require(TextFormat.prettyJSON(Data(#"{"b":1,"a":{"url":"http://x/y"}}"#.utf8)))
    #expect(text.contains("\"a\" : {"))
    #expect(text.firstRange(of: "\"a\"")!.lowerBound < text.firstRange(of: "\"b\"")!.lowerBound)   // sorted keys
    #expect(text.contains("http://x/y"))   // slashes not escaped
    #expect(TextFormat.prettyJSON(Data("{oops".utf8)) == nil)
}

@Test func logLineLevels() {
    let log = "boot ok\nWARNING: disk 90%\nkernel: Error -36 reading\nwarn and error together\nterror is not an error word? yes it is\nall fine\n"
    let levels = TextFormat.logLevels(in: log)
    let ns = log as NSString
    let byLine = Dictionary(uniqueKeysWithValues: levels.map { (ns.substring(with: $0.range), $0.level) })
    #expect(byLine["WARNING: disk 90%"] == .warning)
    #expect(byLine["kernel: Error -36 reading"] == .error)
    #expect(byLine["warn and error together"] == .error)
    #expect(byLine["boot ok"] == nil && byLine["all fine"] == nil)
    #expect(levels.count == 4)
}

@Test func decodeFallsBackToCP1251() {
    let cp1251 = "Привіт".data(using: .windowsCP1251)!
    #expect(TextFormat.decode(cp1251) == ("Привіт", "Windows-1251"))
    #expect(TextFormat.decode(Data("Привіт".utf8)).encoding == "UTF-8")
    #expect(TextFormat.decode(Data()).text == "")
}

@Test func decodeToleratesCutMultibyteCharacters() {
    let utf8 = Data("Привіт".utf8)   // 12 bytes, 2 per letter
    #expect(TextFormat.decode(utf8.dropLast()) == ("Приві", "UTF-8"))       // cut at the end
    #expect(TextFormat.decode(utf8.dropFirst()) == ("ривіт", "UTF-8"))      // cut at the start
    #expect(TextFormat.decode(utf8.dropFirst().dropLast()) == ("риві", "UTF-8"))
    #expect(TextFormat.decode(Data([0x41, 0x98, 0x42])).text == "A")        // up to 3 bytes per edge are trimmed as "cut"
    let bad = TextFormat.decode(Data(Array("AAAAAAAA".utf8) + [0x98] + Array("BBBBBBBB".utf8)))   // 0x98 is undefined in CP1251 too
    #expect(bad.encoding == "UTF-8 (lossy)" && bad.text == "AAAAAAAA\u{FFFD}BBBBBBBB")
    #expect(TextFormat.decode(Data([0x98])).encoding == "UTF-8 (lossy)")
}

@Test func hexDumpAlignmentAtEveryLength() {
    #expect(TextFormat.hexDump(Data()) == "")
    func pipe(_ s: String) -> Int { Array(s).firstIndex(of: "|")! }
    let full = TextFormat.hexDump(Data(0..<16))
    #expect(full == "00000000  00 01 02 03 04 05 06 07  08 09 0a 0b 0c 0d 0e 0f  |................|\n")
    for n in 1...17 {
        let dump = TextFormat.hexDump(Data(repeating: 0x41, count: n))
        let lines = dump.split(separator: "\n")
        #expect(lines.count == (n + 15) / 16, "\(n)")
        #expect(pipe(String(lines.last!)) == pipe(full), "\(n) bytes: ASCII column aligned")
        #expect(lines.last!.hasSuffix("|" + String(repeating: "A", count: n % 16 == 0 ? 16 : n % 16) + "|"), "\(n)")
    }
    let printable = TextFormat.hexDump(Data([0x1f, 0x20, 0x7e, 0x7f, 0x80, 0xff]))
    #expect(printable.hasSuffix("|. ~...|\n"))
    #expect(TextFormat.hexDump(Data([1]), base: 0xdead_beef).hasPrefix("deadbeef  01"))
}

@Test func prettyPrintersAcceptFragmentsAndOpenStep() throws {
    #expect(TextFormat.prettyJSON(Data("42".utf8)) == "42")
    #expect(TextFormat.prettyJSON(Data("[1,2]".utf8)) == "[\n  1,\n  2\n]")
    #expect(TextFormat.prettyJSON(Data("{\"ключ\":\"значення\"}".utf8))?.contains("\"ключ\" : \"значення\"") == true)
    #expect(TextFormat.prettyJSON(Data()) == nil)
    let openStep = try #require(TextFormat.prettyPlist(Data("{ Label = \"com.x\"; Count = 3; }".utf8)))
    #expect(openStep.contains("<key>Label</key>") && openStep.contains("<string>com.x</string>"))
    #expect(TextFormat.prettyPlist(Data()) == nil)
}

@Test func logLevelKeywords() {
    let text = "a: deprecated api\nb: PANIC now\nc: access denied\nd: critical\ne: FATAL\nf: errors found\ng: Err 5\n"
    let ns = text as NSString
    let by = Dictionary(uniqueKeysWithValues: TextFormat.logLevels(in: text).map { (ns.substring(with: $0.range), $0.level) })
    #expect(by["a: deprecated api"] == .warning)
    #expect(by["b: PANIC now"] == .error && by["c: access denied"] == .error && by["d: critical"] == .error && by["e: FATAL"] == .error)
    #expect(by["g: Err 5"] == .error)
    #expect(by["f: errors found"] == nil)   // whole-word match only: plurals are not highlighted
    #expect(TextFormat.logLevels(in: "").isEmpty)
}
