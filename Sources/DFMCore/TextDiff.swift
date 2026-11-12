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

    /// Under a second of `cost` on a 2026 Mac: 7 000 lines all different are 2·10⁸, 0.7 s (10 000: 4·10⁸, 1.25 s).
    public static let budget = 2 * 100_000_000

    /// `old` against `new`; nil if matching them would cost over `budget` (`cost`).
    public static func compare(_ old: String, _ new: String, budget: Int = budget) -> Result? {
        let a = NSString(string: old), b = NSString(string: new)   // UTF-16 underneath: a line's text by its range at once
        let la = lines(a), lb = lines(b)
        var table: [String: Int] = [:]
        let x = ids(a, la, &table), y = ids(b, lb, &table)
        guard cost(x, y) <= budget else { return nil }
        let blocks = blocks(x, y)
        var oc: [NSRange] = [], nc: [NSRange] = []
        for k in blocks {
            for (i, j) in zip(k.old, k.new) {
                guard let d = inline(a.substring(with: la[i]), b.substring(with: lb[j])) else { continue }
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

    /// Lines as numbers, the same text the same number (`table` shared by both texts): matched as Ints, not Strings.
    private static func ids(_ s: NSString, _ lines: [NSRange], _ table: inout [String: Int]) -> [Int] {
        lines.map { r in
            let line = s.substring(with: r)
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

    /// What matching costs, about: (N + M)·D of what's left once the common start and end are set aside, D counted as
    /// the lines with no equal on the other side. Can't be stopped midway, so it's asked first; lines that only moved
    /// aren't counted (a reversed file costs more than this says).
    public static func cost(_ a: [Int], _ b: [Int]) -> Int {
        let (p, s) = common(a, b)
        let x = a[p..<(a.count - s)], y = b[p..<(b.count - s)]
        let inX = Set(x), inY = Set(y)
        return (x.count + y.count) * (x.count(where: { !inY.contains($0) }) + y.count(where: { !inX.contains($0) }))
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

    /// The characters `a` and `b` don't share — whole Characters: an emoji or a letter with its marks stays one — as
    /// UTF-16 ranges in each; nil for a line over `limit` UTF-16 units (all of it is the change then).
    public static func inline(_ a: String, _ b: String, limit: Int = 1000) -> (old: [NSRange], new: [NSRange])? {
        guard a.utf16.count <= limit, b.utf16.count <= limit else { return nil }
        let x = Array(a), y = Array(b)
        var gone = [Bool](repeating: false, count: x.count), came = [Bool](repeating: false, count: y.count)
        for c in y.difference(from: x) {
            switch c {
            case .remove(let o, _, _): gone[o] = true
            case .insert(let o, _, _): came[o] = true
            }
        }
        return (runs(gone, x), runs(came, y))
    }

    /// The marked characters' runs in UTF-16.
    private static func runs(_ marked: [Bool], _ chars: [Character]) -> [NSRange] {
        var out: [NSRange] = [], u = 0, start: Int?
        for (k, c) in chars.enumerated() {
            if marked[k] { start = start ?? u } else if let s = start { out.append(NSRange(location: s, length: u - s)); start = nil }
            u += c.utf16.count
        }
        if let s = start { out.append(NSRange(location: s, length: u - s)) }
        return out
    }
}
