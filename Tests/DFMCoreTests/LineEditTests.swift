import Foundation
import Testing
@testable import DFMCore

/// `s` with its selection written in it: "|" a caret, "«…»" a selection. Runs `f` and writes the result back the same way.
private func run(_ s: String, _ f: (NSString, NSRange) -> LineEdit.Edit?) -> String? {
    var t = s, sel: NSRange
    if let c = t.range(of: "|") {
        sel = NSRange(location: t[..<c.lowerBound].utf16.count, length: 0)
        t.removeSubrange(c)
    } else {
        let a = t.range(of: "«")!
        t.removeSubrange(a)
        let b = t.range(of: "»")!
        let from = t[..<a.lowerBound].utf16.count
        sel = NSRange(location: from, length: t[..<b.lowerBound].utf16.count - from)
        t.removeSubrange(b)
    }
    guard let e = f(t as NSString, sel) else { return nil }
    let out = (t as NSString).replacingCharacters(in: e.range, with: e.text) as NSString
    if e.select.length == 0 { return out.replacingCharacters(in: e.select, with: "|") }
    let closed = out.replacingCharacters(in: NSRange(location: NSMaxRange(e.select), length: 0), with: "»") as NSString
    return closed.replacingCharacters(in: NSRange(location: e.select.location, length: 0), with: "«")
}

@Test func linesTouchedLeaveOutTheLineASelectionEndsAt() {
    let t = "a\nb\nc" as NSString
    #expect(LineEdit.lines(t, NSRange(location: 0, length: 2)) == NSRange(location: 0, length: 2))   // "a\n" selected: b isn't
    #expect(LineEdit.lines(t, NSRange(location: 1, length: 2)) == NSRange(location: 0, length: 4))
    #expect(LineEdit.lines(t, NSRange(location: 5, length: 0)) == NSRange(location: 4, length: 1))
}

@Test func tabAndShiftTabOnLines() {
    #expect(run("«a\n\nb»\nc", { LineEdit.indent($0, $1, unit: "  ") }) == "«  a\n\n  b»\nc")   // the empty line stays empty
    #expect(run("«\ta\n   b\n      c»", { LineEdit.outdent($0, $1, width: 4) }) == "«a\nb\n  c»")
    #expect(run("    ab|c", { LineEdit.outdent($0, $1, width: 4) }) == "ab|c")
    #expect(run("  |abc", { LineEdit.outdent($0, $1, width: 4) }) == "|abc")
    #expect(run("ab|c", { LineEdit.outdent($0, $1, width: 4) }) == nil)
}

@Test func toggleCommentAtTheLeastIndentAndBack() {
    let hash = { (t: NSString, r: NSRange) in LineEdit.toggleComment(t, r, token: "#") }
    #expect(run("«  a:\n\n    b: 1»\nc", hash) == "«  # a:\n\n  #   b: 1»\nc")
    #expect(run("«  # a:\n\n  #   b: 1»\nc", hash) == "«  a:\n\n    b: 1»\nc")
    #expect(run("  ab|c", hash) == "  # ab|c")
    #expect(run("  # ab|c", hash) == "  ab|c")
    #expect(run("  |#abc", hash) == "  |abc")   // no space after it: the mark alone goes
    #expect(run("«a\n# b»", hash) == "«# a\n# # b»")   // not all commented: all get one more
    #expect(run("|", hash) == "# |")
    let slash = { (t: NSString, r: NSRange) in LineEdit.toggleComment(t, r, token: "//") }
    #expect(run("x = 1;|", slash) == "// x = 1;|")
    let xml = { (t: NSString, r: NSRange) in LineEdit.toggleComment(t, r, open: "<!--", close: "-->") }
    #expect(run("«  <a/>\n  <b/>»", xml) == "«  <!-- <a/>\n  <b/> -->»")
    #expect(run("«  <!-- <a/>\n  <b/> -->»", xml) == "«  <a/>\n  <b/>»")
    #expect(run("  |", xml) == nil)
}

@Test func moveDuplicateAndDeleteLines() {
    #expect(run("a\nb|\nc", { LineEdit.move($0, $1, up: true) }) == "b|\na\nc")
    #expect(run("a\nb\nc|", { LineEdit.move($0, $1, up: true) }) == "a\nc|\nb")   // the last line has no "\n"
    #expect(run("a|\nb\nc", { LineEdit.move($0, $1, up: false) }) == "b\na|\nc")
    #expect(run("a\nb|\nc", { LineEdit.move($0, $1, up: false) }) == "a\nc\nb|")
    #expect(run("«a\nb»\nc", { LineEdit.move($0, $1, up: false) }) == "c\n«a\nb»")
    #expect(run("a|\nb", { LineEdit.move($0, $1, up: true) }) == nil)
    #expect(run("a\nb|", { LineEdit.move($0, $1, up: false) }) == nil)
    #expect(run("a\n|", { LineEdit.move($0, $1, up: true) }) == nil)   // the empty line after the last "\n"
    #expect(run("a|b\nc", { LineEdit.duplicate($0, $1) }) == "ab\na|b\nc")
    #expect(run("a\nb|", { LineEdit.duplicate($0, $1) }) == "a\nb\nb|")
    #expect(run("a\nb|\nc", { LineEdit.delete($0, $1) }) == "a\n|c")
    #expect(run("a\nb|", { LineEdit.delete($0, $1) }) == "|a")
    #expect(run("a|", { LineEdit.delete($0, $1) }) == "|")
    #expect(run("a\n|", { LineEdit.delete($0, $1) }) == "|a")
    #expect(run("|", { LineEdit.delete($0, $1) }) == nil)
}

@Test func newlineKeepsTheIndentAndOpensBlocks() {
    func nl(_ s: String, colon: Bool = false) -> String {
        let t = s.replacingOccurrences(of: "|", with: "") as NSString, p = (s as NSString).range(of: "|").location
        let (ins, caret) = LineEdit.newline(t, at: p, unit: "  ", colon: colon)
        return (t.replacingCharacters(in: NSRange(location: p, length: 0), with: ins) as NSString)
            .replacingCharacters(in: NSRange(location: p + caret, length: 0), with: "|")
    }
    #expect(nl("    a|") == "    a\n    |")
    #expect(nl("  |  a") == "  \n  |  a")   // in the indent: as far as the caret
    #expect(nl("  f {|") == "  f {\n    |")
    #expect(nl("  f {|}") == "  f {\n    |\n  }")
    #expect(nl("  key:|", colon: true) == "  key:\n    |")
    #expect(nl("  key:|") == "  key:\n  |")
    #expect(nl("  # note:|", colon: true) == "  # note:\n  |")
}

@Test func indentationIsReadFromTheText() {
    #expect(LineEdit.detect("a\n\tb\n\tc\n  d") == .tabs)
    #expect(LineEdit.detect("a:\n  b:\n    c: 1\n  d: 2") == .spaces(2))
    #expect(LineEdit.detect("def f():\n    return 1\n        x\n") == .spaces(4))
    #expect(LineEdit.detect("/*\n * one space aligns\n */") == nil)
    #expect(LineEdit.indent(for: .yaml, detected: .tabs) == .spaces(2))
    #expect(LineEdit.indent(for: .makefile, detected: nil) == .tabs)
    #expect(LineEdit.indent(for: .python, detected: .spaces(2)) == .spaces(2))
    #expect(LineEdit.indent(for: nil, detected: nil) == .spaces(4))
    #expect(LineEdit.column("\tab", tab: 4) == 6)
}

@Test func bracketsPairAcrossNesting() {
    let t = "f(a[1], {b: (c)})" as NSString
    #expect(LineEdit.matchingBracket(t, at: 1) == 16)
    #expect(LineEdit.matchingBracket(t, at: 16) == 1)
    #expect(LineEdit.matchingBracket(t, at: 8) == 15)
    #expect(LineEdit.matchingBracket(t, at: 0) == nil)
    #expect(LineEdit.matchingBracket("((" as NSString, at: 0) == nil)
    #expect(Syntax.Language.xml.comment?.close == "-->" && Syntax.Language.json.comment == nil && Syntax.Language.ini.comment?.open == "#")
}
