import Foundation
import Testing
@testable import DFMCore

private func shown(_ r: (text: String, runs: [ANSI.Run])) -> String {
    let ns = r.text as NSString
    return r.runs.map { "\(ns.substring(with: $0.range))=\($0.style.color.map(String.init) ?? "-")\($0.style.bold ? "b" : "")" }.joined(separator: " ")
}

/// Colors come out as runs over the text the sequences leave; resets — whole, of the color, of bold — end them, nested
/// or not; bright, 256-color and RGB ones go to the 16; everything else that starts with ESC is hidden.
@Test func ansiColorsBecomeRuns() {
    let a = ANSI.parse("plain \u{1B}[31mred\u{1B}[0m and \u{1B}[1;32mbold green\u{1B}[39m bold\u{1B}[22m end")
    #expect(a.text == "plain red and bold green bold end")
    #expect(shown(a) == "red=1 bold green=2b  bold=-b")
    #expect(shown(ANSI.parse("\u{1B}[91mA\u{1B}[mB\u{1B}[1mC\u{1B}[0;34mD")) == "A=9 C=-b D=4", "an empty SGR resets")
    #expect(shown(ANSI.parse("\u{1B}[38;5;196mX\u{1B}[38;5;4mY\u{1B}[38;5;244mZ\u{1B}[38;2;0;200;0mG\u{1B}[38:2:250:250:250mW")) == "X=9 Y=4 Z=8 G=2 W=15")
    #expect(shown(ANSI.parse("\u{1B}[48;5;196;33mY\u{1B}[41mstill\u{1B}[49m")) == "Ystill=3", "a background is read past")
    let hidden = ANSI.parse("\u{1B}[2K\u{1B}[1Gline\u{1B}]0;title\u{07}\u{1B}(B ok\u{1B}]8;;http://x\u{1B}\\link\u{1B}=")
    #expect(hidden.text == "line oklink" && hidden.runs.isEmpty)
    #expect(ANSI.parse("no colors\n").text == "no colors\n" && ANSI.parse("no colors\n").runs.isEmpty)
    #expect(ANSI.strip("\u{1B}[31mERROR\u{1B}[0m x") == "ERROR x")
}

/// Line ends stay as they are (CRLF too) and runs count UTF-16: an emoji or Cyrillic before a color doesn't shift it.
@Test func ansiKeepsLineEndsAndCountsUTF16() {
    let a = ANSI.parse("\u{1B}[32mok\u{1B}[0m\r\n😀 \u{1B}[33mпопередження\u{1B}[0m\r\n")
    #expect(a.text == "ok\r\n😀 попередження\r\n")
    #expect(shown(a) == "ok=2 попередження=3")
}

/// Read in pieces: a sequence cut at a piece's end waits for the next one; a color goes on across pieces; at the very
/// end a cut one goes.
@Test func ansiReadInPieces() {
    var a = ANSI()
    let one = a.feed("before \u{1B}[3")
    #expect(one.text == "before " && one.runs.isEmpty)
    let two = a.feed("1mred, still")
    #expect(two.text == "red, still" && shown(two) == "red, still=1")
    let three = a.feed(" red\u{1B}")
    #expect(three.text == " red" && shown(three) == " red=1")
    let four = a.feed("[0m plain")
    #expect(four.text == " plain" && four.runs.isEmpty && a.style.isPlain)
    var b = ANSI()
    _ = b.feed("x\u{1B}]0;never ends")
    #expect(b.feed(" more", end: true).text == "", "an unended title at the very end goes")
    var c = ANSI()
    #expect(c.feed("\u{1B}[1;3", end: true).text == "")
}

/// `e`: errors only, or errors and warnings — by the words the tints go by, a line's colors aside — alone or with an
/// `&` text, in the text and over a mapped file's bytes alike.
@Test func lineFiltersKeepLevels() throws {
    let text = "1 started\n2 warning: disk\n3 ERROR: down\n\u{1B}[31m4 fatal\u{1B}[0m crash\n5 deprecated error\n6 ok"
    #expect(LineFilter(level: .error).apply(text) == "3 ERROR: down\n\u{1B}[31m4 fatal\u{1B}[0m crash\n5 deprecated error\n")
    #expect(LineFilter(level: .warning).apply(text) == "2 warning: disk\n3 ERROR: down\n\u{1B}[31m4 fatal\u{1B}[0m crash\n5 deprecated error\n")
    var down = try #require(LineFilter("!down"))
    down.level = .error
    #expect(down.apply(text) == "\u{1B}[31m4 fatal\u{1B}[0m crash\n5 deprecated error\n" && down.spec == "!down")
    #expect(LineFilter(level: .warning).spec == "" && LineFilter(level: .error) != LineFilter(level: .warning))
    let (kept, more) = LineFilter(level: .error).apply(Data(text.utf8), limit: 1 << 20)
    #expect(String(decoding: kept, as: UTF8.self) == LineFilter(level: .error).apply(text) && !more)
    #expect(String(decoding: down.apply(Data(text.utf8), limit: 1 << 20).0, as: UTF8.self) == down.apply(text))
    #expect(TextFormat.level(of: "x error") == .error && TextFormat.level(of: "a warning") == .warning && TextFormat.level(of: "fine") == nil)
}
