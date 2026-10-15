import Foundation

/// Terminal colors in text (`journalctl`, `docker logs`, `ls --color`, a log written with them): the text as printed,
/// and which runs of it are which color. SGR only — the 16 colors, their bright half, bold, resets; a 256-color or
/// RGB one goes to the nearest of the 16, a background is passed over. Every other escape sequence (cursor moves,
/// line clears, window titles) is hidden. Read in pieces (`feed`): a sequence cut at a piece's end waits for the next,
/// and a color goes on into it.
public struct ANSI: Sendable {
    public struct Style: Equatable, Sendable {
        /// 0–7 black, red, green, yellow, blue, magenta, cyan, white; 8–15 their bright ones; nil: the text's own.
        public var color: Int?
        public var bold = false
        public init(color: Int? = nil, bold: Bool = false) { (self.color, self.bold) = (color, bold) }
        public var isPlain: Bool { color == nil && !bold }
    }

    /// A run of styled text, in UTF-16 units of the text `feed` returned.
    public struct Run: Equatable, Sendable {
        public var range: NSRange
        public var style: Style
        public init(_ range: NSRange, _ style: Style) { (self.range, self.style) = (range, style) }
    }

    public private(set) var style = Style()
    private var pending: [Unicode.Scalar] = []

    public init() {}

    /// The whole of `s` at once.
    public static func parse(_ s: String) -> (text: String, runs: [Run]) {
        var a = ANSI()
        return a.feed(s, end: true)
    }

    /// `s` without its escape sequences.
    public static func strip<S: StringProtocol>(_ s: S) -> String {
        s.utf8.contains(0x1B) ? parse(String(s)).text : String(s)
    }

    /// The next piece: its text and its styled runs (their style goes on into the next piece). `end`: no piece follows —
    /// a sequence cut here goes.
    public mutating func feed(_ s: String, end: Bool = false) -> (text: String, runs: [Run]) {
        if pending.isEmpty, !s.utf8.contains(0x1B) {   // the usual case: nothing to take out
            let n = s.utf16.count
            return (s, style.isPlain || n == 0 ? [] : [Run(NSRange(location: 0, length: n), style)])
        }
        let all = pending + Array(s.unicodeScalars)
        pending = []
        var out = String.UnicodeScalarView(), runs: [Run] = [], at = 0, runStart = 0
        func restyle(_ new: Style) {
            guard new != style else { return }
            if !style.isPlain, at > runStart { runs.append(Run(NSRange(location: runStart, length: at - runStart), style)) }
            style = new
            runStart = at
        }
        var i = 0
        while i < all.count {
            let c = all[i]
            guard c == "\u{1B}" else {
                out.append(c)
                at += c.utf16.count
                i += 1
                continue
            }
            guard let length = Self.sequence(all, at: i) else {
                if !end, all.count - i < 256 {   // cut here: the rest waits for the next piece
                    pending = Array(all[i...])
                    break
                }
                i += 1   // never ended (or too long to be one): only the ESC goes, the text stays
                continue
            }
            if all[i + 1] == "[", all[i + length - 1] == "m" {
                let params = String(String.UnicodeScalarView(all[(i + 2)..<(i + length - 1)]))
                if params.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ";" || $0 == ":") }) { restyle(Self.sgr(params, style)) }   // not `ESC[>4;1m`
            }
            i += length
        }
        if !style.isPlain, at > runStart { runs.append(Run(NSRange(location: runStart, length: at - runStart), style)) }
        return (String(out), runs)
    }

    /// The length of the escape sequence at `i` (an ESC), or nil if it's cut off by the end. CSI: ESC [ parameters
    /// final; OSC: ESC ] … BEL or ESC \ (a line end or another control ends a broken one, and stays); a charset
    /// choice: ESC ( B; else ESC and one more printable (anything else stays).
    static func sequence(_ s: [Unicode.Scalar], at i: Int) -> Int? {
        guard i + 1 < s.count else { return nil }
        switch s[i + 1] {
        case "[":
            var j = i + 2
            while j < s.count {
                if (0x40...0x7E).contains(s[j].value) { return j - i + 1 }
                if !(0x20...0x3F).contains(s[j].value) { return j - i }   // broken: the sequence ends before it
                j += 1
            }
            return nil
        case "]":
            var j = i + 2
            while j < s.count {
                if s[j] == "\u{07}" { return j - i + 1 }
                if s[j] == "\u{1B}" { return j + 1 < s.count ? (s[j + 1] == "\\" ? j - i + 2 : j - i) : nil }
                if s[j].value < 0x20 { return j - i }
                j += 1
            }
            return nil
        case "(", ")", "*", "+": return i + 2 < s.count ? 3 : nil
        default: return (0x20...0x7E).contains(s[i + 1].value) ? 2 : 1
        }
    }

    /// `style` after an SGR's parameters ("1;31", "38;5;208", "38:2::255:128:0", "" = reset).
    static func sgr(_ params: String, _ style: Style) -> Style {
        var s = style
        var p: [Int] = []
        for group in params.split(separator: ";", omittingEmptySubsequences: false) {
            // A colon group is one color of its own: 38:5:n, 38:2:r:g:b, or with a color space first 38:2:cs:r:g:b.
            var sub = group.split(separator: ":", omittingEmptySubsequences: false).map { min(Int($0) ?? 0, 1 << 16) }
            if sub.count == 6, sub[1] == 2 { sub.remove(at: 2) }
            p += sub
        }
        var k = 0
        while k < p.count {
            switch p[k] {
            case 0: s = Style()
            case 1: s.bold = true
            case 21, 22: s.bold = false
            case 30...37: s.color = p[k] - 30
            case 90...97: s.color = p[k] - 90 + 8
            case 39: s.color = nil
            case 38, 48:   // 256 colors or RGB; a background's is read past
                if k + 2 < p.count, p[k + 1] == 5 {
                    if p[k] == 38 { s.color = nearest(p[k + 2]) }
                    k += 2
                } else if k + 4 < p.count, p[k + 1] == 2 {
                    if p[k] == 38 { s.color = nearest(p[k + 2], p[k + 3], p[k + 4]) }
                    k += 4
                }
            default: break   // backgrounds, italic, underline, reverse…: as printed
            }
            k += 1
        }
        return s
    }

    /// xterm's 16.
    static let palette: [(Int, Int, Int)] = [(0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0), (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
                                             (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0), (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]

    /// One of the 256 as the nearest of the 16.
    static func nearest(_ n: Int) -> Int? {
        switch n {
        case 0..<16: return n
        case 16..<232:
            let level = [0, 95, 135, 175, 215, 255], c = n - 16
            return nearest(level[c / 36], level[c / 6 % 6], level[c % 6])
        case 232..<256: let g = 8 + 10 * (n - 232); return nearest(g, g, g)
        default: return nil
        }
    }

    static func nearest(_ r: Int, _ g: Int, _ b: Int) -> Int {
        let (r, g, b) = (min(max(r, 0), 255), min(max(g, 0), 255), min(max(b, 0), 255))   // a log's 4000000000 overflows the squares
        return palette.indices.min { a, z in
            let d = { (i: Int) in let (pr, pg, pb) = palette[i]; return (pr - r) * (pr - r) + (pg - g) * (pg - g) + (pb - b) * (pb - b) }
            return d(a) < d(z)
        }!
    }
}
