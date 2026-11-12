import Foundation

/// The editor's line commands as text in and one replacement out, in UTF-16 ranges as NSTextView has them: the app
/// applies it as one Undo step. Lines are split at "\n" alone, so a line of a file with mixed line ends keeps its "\r".
public enum LineEdit {
    /// Put `text` in place of `range`, then select `select`.
    public struct Edit: Equatable, Sendable {
        public let range: NSRange, text: String, select: NSRange
    }

    /// Columns a tab takes (the editor's tab stops, its Col and Go to Line's column).
    public static let tabWidth = 4

    /// What Tab puts in: a tab, or spaces to the next stop.
    public enum Indent: Equatable, Sendable {
        case tabs, spaces(Int)
        public var unit: String { if case .spaces(let n) = self { String(repeating: " ", count: n) } else { "\t" } }
        /// Columns an indent takes.
        public var width: Int { if case .spaces(let n) = self { n } else { tabWidth } }
    }

    /// The whole lines `sel` touches, with the last one's "\n"; a selection that ends where a line starts leaves that line out.
    public static func lines(_ t: NSString, _ sel: NSRange) -> NSRange {
        var end = NSMaxRange(sel)
        if sel.length > 0, t.character(at: end - 1) == 10 { end -= 1 }
        return t.lineRange(for: NSRange(location: sel.location, length: end - sel.location))
    }

    /// Whether `r` (whole lines) ends in "\n" — in UTF-16: a Swift String sees "\r\n" as one Character, not ending in "\n".
    private static func endsInNewline(_ t: NSString, _ r: NSRange) -> Bool { r.length > 0 && t.character(at: NSMaxRange(r) - 1) == 10 }

    /// The lines of `r` without their "\n"s, and whether the last one had one.
    private static func split(_ t: NSString, _ r: NSRange) -> (lines: [String], newline: Bool) {
        let newline = endsInNewline(t, r)
        let body = t.substring(with: NSRange(location: r.location, length: r.length - (newline ? 1 : 0))) as NSString
        return (body.components(separatedBy: "\n"), newline)
    }

    /// `out` in place of the lines `r`: the caret at `caret`, else the new lines selected (without their last "\n").
    private static func whole(_ r: NSRange, _ out: [String], _ newline: Bool, caret: Int? = nil) -> Edit {
        let body = out.joined(separator: "\n"), shown = body.utf16.count - (body.utf16.last == 13 ? 1 : 0)   // not a CRLF line's "\r"
        return Edit(range: r, text: body + (newline ? "\n" : ""),
                    select: caret.map { NSRange(location: $0, length: 0) } ?? NSRange(location: r.location, length: shown))
    }

    private static func lead(_ s: String) -> Substring { s.prefix { $0 == " " || $0 == "\t" } }
    private static func blank(_ s: String) -> Bool { s.allSatisfy(\.isWhitespace) }

    /// Tab on a selection of lines: `unit` before each line that isn't empty.
    public static func indent(_ t: NSString, _ sel: NSRange, unit: String) -> Edit {
        let r = lines(t, sel), (ls, nl) = split(t, r)
        return whole(r, ls.map { $0.allSatisfy { $0 == "\r" } ? $0 : unit + $0 }, nl)
    }

    /// ⇧Tab: a tab, or up to `width` spaces, off the start of each line. A caret stays on its text.
    public static func outdent(_ t: NSString, _ sel: NSRange, width: Int) -> Edit? {
        let r = lines(t, sel), (ls, nl) = split(t, r)
        let cut = ls.map { $0.hasPrefix("\t") ? 1 : $0.prefix(width).prefix { $0 == " " }.count }
        guard cut.contains(where: { $0 > 0 }) else { return nil }
        let out = zip(ls, cut).map { String($0.dropFirst($1)) }
        return whole(r, out, nl, caret: sel.length == 0 ? max(r.location, sel.location - cut[0]) : nil)
    }

    /// ⌘/: comments the lines out with `token` ("#", "//") at their least indent, or takes it off when every line that
    /// isn't blank has it. A caret stays on its text.
    public static func toggleComment(_ t: NSString, _ sel: NSRange, token: String) -> Edit {
        let r = lines(t, sel), (ls, nl) = split(t, r)
        let filled = ls.filter { !blank($0) }
        let on = !filled.isEmpty && filled.allSatisfy { $0.dropFirst(lead($0).count).hasPrefix(token) }
        let col = filled.map { lead($0).count }.min() ?? 0
        var change: (at: Int, cut: Int, put: Int) = (0, 0, 0)   // the first line's, for the caret (UTF-16)
        let out = ls.enumerated().map { i, l -> String in
            guard filled.isEmpty || !blank(l) else { return l }
            let pre = on ? lead(l) : l.prefix(col), rest = l.dropFirst(pre.count)
            let after = rest.dropFirst(token.count), space = after.hasPrefix(" ")
            if i == 0 { change = on ? (pre.utf16.count, token.utf16.count + (space ? 1 : 0), 0) : (pre.utf16.count, 0, token.utf16.count + 1) }
            return on ? String(pre + (space ? after.dropFirst() : after)) : pre + token + " " + rest
        }
        let p = sel.location - r.location
        let at = p < change.at ? p : change.at + change.put + max(0, p - change.at - change.cut)
        return whole(r, out, nl, caret: sel.length == 0 ? r.location + at : nil)
    }

    /// ⌘/ in XML: <!-- --> around the lines, or off them — off each line when each is commented on its own. nil: only
    /// blanks, or lines that hold a comment already (XML can't nest one in another).
    public static func toggleComment(_ t: NSString, _ sel: NSRange, open: String, close: String) -> Edit? {
        let r = lines(t, sel), (ls, nl) = split(t, r)
        /// `s` without its outer whitespace, and that whitespace; whether it's one comment, closed only at its end.
        func parts(_ s: String) -> (head: Substring, core: Substring, tail: Substring, commented: Bool) {
            let head = s.prefix { $0.isWhitespace }, rest = s.dropFirst(head.count)
            let tail = Substring(String(rest.reversed().prefix { $0.isWhitespace }.reversed())), core = rest.dropLast(tail.count)
            let inner = core.dropFirst(open.count)
            let commented = core.hasPrefix(open) && core.hasSuffix(close) && inner.count >= close.count && inner.range(of: close)?.upperBound == inner.endIndex
            return (head, core, tail, commented)
        }
        func uncomment(_ p: (head: Substring, core: Substring, tail: Substring, commented: Bool)) -> String {
            var inner = p.core.dropFirst(open.count).dropLast(close.count)
            if inner.hasPrefix(" ") { inner = inner.dropFirst() }
            if inner.hasSuffix(" ") { inner = inner.dropLast() }
            return String(p.head + inner + p.tail)
        }
        let body = parts(ls.joined(separator: "\n"))
        guard !body.core.isEmpty else { return nil }
        if body.commented { return whole(r, uncomment(body).components(separatedBy: "\n"), nl) }
        let each = ls.map(parts)
        if each.allSatisfy({ $0.core.isEmpty || $0.commented }) { return whole(r, zip(ls, each).map { $1.core.isEmpty ? $0 : uncomment($1) }, nl) }
        guard !body.core.contains(open), !body.core.contains(close) else { return nil }
        return whole(r, String(body.head + open + " " + body.core + " " + close + body.tail).components(separatedBy: "\n"), nl)
    }

    /// ⌥↑ / ⌥↓: the lines past the line above or below; nil at the top or bottom.
    public static func move(_ t: NSString, _ sel: NSRange, up: Bool) -> Edit? {
        let r = lines(t, sel)
        guard r.length > 0 else { return nil }   // the empty line after the last "\n"
        if up {
            guard r.location > 0 else { return nil }
            let p = t.lineRange(for: NSRange(location: r.location - 1, length: 0)), region = NSUnionRange(p, r)
            let (ls, nl) = split(t, region)
            let text = (ls.dropFirst() + [ls[0]]).joined(separator: "\n") + (nl ? "\n" : "")
            return Edit(range: region, text: text, select: NSRange(location: sel.location - p.length, length: sel.length))
        }
        guard NSMaxRange(r) < t.length else { return nil }
        let n = t.lineRange(for: NSRange(location: NSMaxRange(r), length: 0)), region = NSUnionRange(r, n)
        let (ls, nl) = split(t, region)
        let text = ([ls[ls.count - 1]] + ls.dropLast()).joined(separator: "\n") + (nl ? "\n" : "")
        let at = sel.location + ls[ls.count - 1].utf16.count + 1, end = region.location + text.utf16.count
        return Edit(range: region, text: text, select: NSRange(location: at, length: min(sel.length, end - at)))   // the last line has no "\n" to select
    }

    /// ⇧⌥↓ / ⇧⌥↑: a copy of the lines under (above) them, the selection on the lower (upper) one.
    public static func duplicate(_ t: NSString, _ sel: NSRange, up: Bool = false) -> Edit {
        let r = lines(t, sel), s = t.substring(with: r)
        let copy = endsInNewline(t, r) ? s : "\n" + s
        if up { return Edit(range: NSRange(location: r.location, length: 0), text: endsInNewline(t, r) ? s : s + "\n", select: sel) }
        return Edit(range: NSRange(location: NSMaxRange(r), length: 0), text: copy,
                    select: NSRange(location: sel.location + copy.utf16.count, length: sel.length))
    }

    /// ⇧⌘K: the lines gone, with their "\n" (the last line takes the one before it); the caret where the next one starts.
    public static func delete(_ t: NSString, _ sel: NSRange) -> Edit? {
        var r = lines(t, sel)
        if NSMaxRange(r) == t.length, !endsInNewline(t, r) {
            guard r.location > 0 else { return r.length > 0 ? Edit(range: r, text: "", select: NSRange(location: 0, length: 0)) : nil }
            r = NSRange(location: r.location - 1, length: r.length + 1)
            let start = t.lineRange(for: NSRange(location: r.location, length: 0)).location
            return Edit(range: r, text: "", select: NSRange(location: start, length: 0))
        }
        return Edit(range: r, text: "", select: NSRange(location: r.location, length: 0))
    }

    /// ↩ over `sel`: a newline with the line's indent, one more after an opening bracket (or ":" where `colon` opens a
    /// block: YAML, Python); between a pair of brackets the closing one goes on a line of its own. `caret`: where it
    /// goes in the text put in.
    public static func newline(_ t: NSString, over sel: NSRange, unit: String, colon: Bool) -> (text: String, caret: Int) {
        let p = sel.location, start = t.lineRange(for: NSRange(location: p, length: 0)).location
        let before = t.substring(with: NSRange(location: start, length: p - start))
        let indent = String(lead(before)), last = before.trimmingCharacters(in: .whitespaces).last
        let comment = before.drop { $0 == " " || $0 == "\t" }.hasPrefix("#")
        guard let last, "{[(".contains(last) || colon && last == ":" && !comment else { return ("\n" + indent, 1 + indent.utf16.count) }
        let inner = "\n" + indent + unit, end = NSMaxRange(sel)
        let pairs: [Character: unichar] = ["{": 125, "[": 93, "(": 41]
        if end < t.length, let close = pairs[last], t.character(at: end) == close { return (inner + "\n" + indent, inner.utf16.count) }
        return (inner, inner.utf16.count)
    }

    /// The columns `prefix` (a line's start to the caret) takes, a tab going to the next multiple of `tab`.
    public static func column(_ prefix: String, tab: Int = tabWidth) -> Int {
        prefix.reduce(0) { c, ch in ch == "\t" ? (c / tab + 1) * tab : c + 1 }
    }

    /// Where in `line` (UTF-16) the column `col` (0 first) starts, as `column` counts; its end if it's shorter.
    public static func offset(ofColumn col: Int, in line: String, tab: Int = tabWidth) -> Int {
        var c = 0, at = 0
        for ch in line where c < col && ch != "\r" {
            c = ch == "\t" ? (c / tab + 1) * tab : c + 1
            at += ch.utf16.count
        }
        return at
    }

    /// How the text indents: tabs, or 2 or 4 spaces, by its indented lines (the first 200,000 characters); nil when none is.
    public static func detect(_ text: String) -> Indent? {
        var tabs = 0, spaces = 0, notFour = 0
        for line in text.prefix(200_000).split(whereSeparator: \.isNewline) {
            if line.first == "\t" { tabs += 1; continue }
            let n = line.prefix { $0 == " " }.count
            guard n >= 2, n < line.count else { continue }   // one space aligns (" * " in a comment); blanks say nothing
            spaces += 1
            if n % 4 != 0 { notFour += 1 }
        }
        guard tabs + spaces > 0 else { return nil }
        if tabs > spaces { return .tabs }
        return .spaces(notFour * 5 > spaces ? 2 : 4)   // ponytail: 3 or 8 read as 2 or 4
    }

    /// What Tab puts in: the text's way, else the language's (YAML takes no tab, ever; a Makefile's recipes need them).
    public static func indent(for language: Syntax.Language?, detected: Indent?) -> Indent {
        if language == .yaml, detected == .tabs || detected == nil { return .spaces(2) }
        if let detected { return detected }
        switch language {
        case .makefile?: return .tabs
        case .json?: return .spaces(2)
        default: return .spaces(4)
        }
    }

    /// The bracket that pairs with the one at `i` ("(", "]", "{"…), counting nesting, at most `limit` characters away.
    public static func matchingBracket(_ t: NSString, at i: Int, limit: Int = 50_000) -> Int? {
        let pairs: [unichar: (unichar, Int)] = [40: (41, 1), 91: (93, 1), 123: (125, 1), 41: (40, -1), 93: (91, -1), 125: (123, -1)]
        guard i >= 0, i < t.length, let (other, step) = pairs[t.character(at: i)] else { return nil }
        let me = t.character(at: i)
        var depth = 0, j = i
        while j >= 0, j < t.length, abs(j - i) <= limit {
            let c = t.character(at: j)
            if c == me { depth += 1 } else if c == other { depth -= 1; if depth == 0 { return j } }
            j += step
        }
        return nil
    }

    /// How a line is commented out in `language` — one mark before it, or XML's two around — by the file's name for a
    /// text of none: "#" for a file without an extension (hosts, crontab, an Untitled), nil (no guess) for one with an
    /// unknown extension. An `.ini` file takes ";" (PHP's refuse "#").
    public static func comment(_ language: Syntax.Language?, fileName: String?) -> (open: String, close: String?)? {
        let ext = fileName.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
        if ext == "ini" { return (";", nil) }
        guard let language else { return ext.isEmpty ? ("#", nil) : nil }
        switch language {
        case .json: return nil
        case .xml: return ("<!--", "-->")
        case .clike: return ("//", nil)
        default: return ("#", nil)
        }
    }
}
