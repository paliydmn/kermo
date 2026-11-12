import Foundation

/// The editor's Compare: two texts' lines matched (the standard library's `difference(from:)`), the blocks where they
/// differ, and in a changed line the characters that do — in UTF-16 ranges, as NSTextView has them. Lines as the line
/// numbers count them (NSString's line ends; a last empty line after a final "\n").
public enum TextDiff {
    /// Lines `old` of the old text stand where lines `new` of the new one are; either may be empty (added, removed).
    public struct Block: Equatable, Sendable {
        public let old: Range<Int>, new: Range<Int>
        public init(old: Range<Int>, new: Range<Int>) { (self.old, self.new) = (old, new) }
    }

    public struct Result: Sendable {
        public let blocks: [Block]
        /// Each line's text, without its line end.
        public let oldLines: [NSRange], newLines: [NSRange]
        /// The characters that differ in a block's lines paired one to one (its first lines on each side), in the texts.
        public let oldChars: [NSRange], newChars: [NSRange]
    }

    /// About 0.7 s of work on a 2026 Mac: 7 000 lines all different are 2·10⁸ (10 000: 4·10⁸, 1.25 s). The lines' check
    /// and their matching each take up to that; the changed characters what the matching left of it.
    public static let budget = 2 * 100_000_000

    /// `old` against `new`; nil if matching them would cost over `budget` (`cost`). Its changed characters within the
    /// budget too: past it, a changed line is changed all of it.
    public static func compare(_ old: String, _ new: String, budget: Int = budget) -> Result? {
        let a = NSString(string: old), b = NSString(string: new)   // UTF-16 underneath: a line's text by its range at once
        let la = lines(a), lb = lines(b)
        var table: [[UInt16]: Int] = [:]
        let x = ids(a, la, &table), y = ids(b, lb, &table)
        guard let spent = cost(x, y, budget: budget) else { return nil }
        let blocks = blocks(x, y)
        var oc: [NSRange] = [], nc: [NSRange] = [], left = budget - spent
        for k in blocks {
            for (i, j) in zip(k.old, k.new) {
                let (u, v) = (a.substring(with: la[i]), b.substring(with: lb[j]))
                let rest = differing(Array(u.utf16), Array(v.utf16)), work = rest * rest   // (n + m)·D at most, of what differs
                guard work <= left, let d = inline(u, v) else { continue }
                left -= work
                oc += d.old.map { NSRange(location: $0.location + la[i].location, length: $0.length) }
                nc += d.new.map { NSRange(location: $0.location + lb[j].location, length: $0.length) }
            }
        }
        return Result(blocks: blocks, oldLines: la, newLines: lb, oldChars: oc, newChars: nc)
    }

    /// Each line's text range without its line end; a text ending in "\n" (or empty) ends with an empty line.
    public static func lines(_ s: NSString) -> [NSRange] {
        var r: [NSRange] = [], i = 0
        while i < s.length {
            var start = 0, end = 0, contents = 0
            s.getLineStart(&start, end: &end, contentsEnd: &contents, for: NSRange(location: i, length: 0))
            r.append(NSRange(location: start, length: contents - start))
            i = end
        }
        if s.length == 0 || s.character(at: s.length - 1) == 10 { r.append(NSRange(location: s.length, length: 0)) }
        return r
    }

    /// Lines as numbers, the same UTF-16 the same number (`table` shared by both texts): matched as Ints. Not as
    /// Strings: those call "é" and "e" with a combining accent equal, and the bytes differ.
    private static func ids(_ s: NSString, _ lines: [NSRange], _ table: inout [[UInt16]: Int]) -> [Int] {
        lines.map { r in
            var line = [UInt16](repeating: 0, count: r.length)
            s.getCharacters(&line, range: r)
            if let id = table[line] { return id }
            table[line] = table.count
            return table.count - 1
        }
    }

    /// How many lines `a` and `b` share at their start and at their end.
    private static func common(_ a: [Int], _ b: [Int]) -> (head: Int, tail: Int) {
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        return (p, s)
    }

    /// What matching costs, if `budget` at most: (N + M)·D of what's left once the common start and end are set aside,
    /// D the lines either side has that the other hasn't there. The standard library's matching can't be stopped
    /// midway, so it's asked first: at once no when the lines with no equal at all are too many; else D itself, worked
    /// out up to what the budget allows and no further (lines that only moved count too — a sorted file's do).
    /// The work it takes ((N + M)·D), nil over `budget`.
    public static func cost(_ a: [Int], _ b: [Int], budget: Int = budget) -> Int? {
        let (p, s) = common(a, b)
        let x = Array(a[p..<(a.count - s)]), y = Array(b[p..<(b.count - s)]), n = x.count + y.count
        guard n > 0 else { return 0 }
        let inX = Set(x), inY = Set(y), cap = budget / n
        guard x.count(where: { !inY.contains($0) }) + y.count(where: { !inX.contains($0) }) <= cap else { return nil }
        return distance(x, y, cap: cap).map { n * $0 }
    }

    /// The fewest lines removed and added that make `x` into `y` (Myers's forward pass, one diagonal array: no more
    /// memory than the texts'); nil past `cap` — stopped there.
    static func distance(_ x: [Int], _ y: [Int], cap: Int) -> Int? {
        let (n, m) = (x.count, y.count), most = min(cap, n + m), off = most + 1
        var v = [Int](repeating: 0, count: 2 * most + 3)
        for d in 0...most {
            for k in stride(from: -d, through: d, by: 2) {
                var i = k == -d || k != d && v[off + k - 1] < v[off + k + 1] ? v[off + k + 1] : v[off + k - 1] + 1
                var j = i - k
                while i < n, j < m, x[i] == y[j] { (i, j) = (i + 1, j + 1) }
                v[off + k] = i
                if i >= n, j >= m { return d }
            }
        }
        return nil
    }

    /// Where `a` and `b` differ, in order.
    public static func blocks(_ a: [Int], _ b: [Int]) -> [Block] {
        let (p, s) = common(a, b)
        let x = Array(a[p..<(a.count - s)]), y = Array(b[p..<(b.count - s)])
        var gone = [Bool](repeating: false, count: x.count), came = [Bool](repeating: false, count: y.count)
        for c in y.difference(from: x) {
            switch c {
            case .remove(let o, _, _): gone[o] = true
            case .insert(let o, _, _): came[o] = true
            }
        }
        // What's left of each is the same lines: walked side by side, a block is where either has some out.
        var out: [Block] = [], i = 0, j = 0
        while i < x.count || j < y.count {
            guard i < x.count && gone[i] || j < y.count && came[j] else { (i, j) = (i + 1, j + 1); continue }
            let (si, sj) = (i, j)
            while i < x.count, gone[i] { i += 1 }
            while j < y.count, came[j] { j += 1 }
            out.append(Block(old: p + si..<p + i, new: p + sj..<p + j))
        }
        return out
    }

    /// Copy Change: what makes lines `to.range` of the target text read as lines `from.range` of the source — the range to
    /// replace there and the text to put in. Lines as `lines` gives them (without line ends): the source's lines with
    /// what's between them; a block one side lacks goes in (or out) with one line end, at the end of the text before it.
    public static func carry(from: (text: NSString, lines: [NSRange], range: Range<Int>),
                             to: (text: NSString, lines: [NSRange], range: Range<Int>)) -> (range: NSRange, text: String) {
        let (src, dst, r) = (from.lines, to.lines, to.range)
        let text = from.range.isEmpty ? "" : from.text.substring(with: NSRange(location: src[from.range.lowerBound].location,
                                                                                length: NSMaxRange(src[from.range.upperBound - 1]) - src[from.range.lowerBound].location))
        func span(_ a: Int, _ b: Int) -> NSRange { NSRange(location: a, length: b - a) }
        if !r.isEmpty, !from.range.isEmpty {   // changed: the lines' text over the lines' text, their ends as they are
            return (span(dst[r.lowerBound].location, NSMaxRange(dst[r.upperBound - 1])), text)
        }
        if r.isEmpty {   // missing here: in before the line it stands at, or after the last line
            if r.lowerBound < dst.count { return (NSRange(location: dst[r.lowerBound].location, length: 0), text + "\n") }
            return (NSRange(location: to.text.length, length: 0), "\n" + text)
        }
        // Only here: out with the line end after them, or — at the end — the one before them.
        if r.upperBound < dst.count { return (span(dst[r.lowerBound].location, dst[r.upperBound].location), "") }
        return (span(r.lowerBound > 0 ? NSMaxRange(dst[r.lowerBound - 1]) : 0, to.text.length), "")
    }

    /// The characters `a` and `b` don't share — whole Characters: an emoji or a letter with its marks stays one — as
    /// UTF-16 ranges in each; nil for a line over `limit` UTF-16 units (all of it is the change then).
    public static func inline(_ a: String, _ b: String, limit: Int = 1000) -> (old: [NSRange], new: [NSRange])? {
        guard a.utf16.count <= limit, b.utf16.count <= limit else { return nil }
        let x = a.map { Array($0.utf16) }, y = b.map { Array($0.utf16) }   // whole Characters, told apart by their UTF-16
        var gone = [Bool](repeating: false, count: x.count), came = [Bool](repeating: false, count: y.count)
        for c in y.difference(from: x) {
            switch c {
            case .remove(let o, _, _): gone[o] = true
            case .insert(let o, _, _): came[o] = true
            }
        }
        return (runs(gone, x), runs(came, y))
    }

    /// How much of `x` and `y` is left once their common start and end are set aside.
    private static func differing(_ x: [UInt16], _ y: [UInt16]) -> Int {
        var p = 0
        while p < x.count, p < y.count, x[p] == y[p] { p += 1 }
        var s = 0
        while s < x.count - p, s < y.count - p, x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }
        return x.count + y.count - 2 * (p + s)
    }

    /// The marked characters' runs in UTF-16.
    private static func runs(_ marked: [Bool], _ chars: [[UInt16]]) -> [NSRange] {
        var out: [NSRange] = [], u = 0, start: Int?
        for (k, c) in chars.enumerated() {
            if marked[k] { start = start ?? u } else if let s = start { out.append(NSRange(location: s, length: u - s)); start = nil }
            u += c.count
        }
        if let s = start { out.append(NSRange(location: s, length: u - s)) }
        return out
    }
}
