import AppKit
import DFMCore

/// Line-number gutter for a TextKit 1 NSTextView (create the view with `usingTextLayoutManager: false`).
final class LineNumberRuler: NSRulerView {
    private var lineStarts: [Int]?   // UTF-16 offsets of line starts: moved along by edits, built in full when nil
    /// Lines before the text's first (a followed log's that dropped off the top): numbers go on from there.
    var firstLine = 0

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        clipsToBounds = true   // its edge line went on below the text, over a window's status line
        NotificationCenter.default.addObserver(self, selector: #selector(edited), name: NSTextStorage.didProcessEditingNotification,
                                               object: textView.textStorage)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification,
                                               object: textView.enclosingScrollView?.contentView)
    }
    required init(coder: NSCoder) { fatalError() }

    /// A keystroke in a 30 MB log was a count of all its lines again: now only the lines the edit touched.
    @objc private func edited(_ n: Notification) {
        guard let storage = n.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
        if storage.editedRange.length == storage.length { lineStarts = nil }   // all of it replaced: counted when drawn
        else if let old = lineStarts { lineStarts = Self.lineStarts(old, storage.mutableString, edited: storage.editedRange, delta: storage.changeInLength) }
        needsDisplay = true
    }
    @objc private func redraw() { needsDisplay = true }

    /// Lets the owner say the whole text was replaced: counted again in full.
    func invalidate() { lineStarts = nil; needsDisplay = true }

    /// Where `text`'s lines start (a last empty line after a final "\n" too).
    static func lineStarts(_ text: NSString) -> [Int] { scan(text, from: 0, into: [0]) }

    /// `starts` (right for the text before the edit) for `text` after it: `edited` is the changed range in `text`,
    /// `delta` how much longer the text got. The lines from the one before the edit (a "\r" there may now pair with a
    /// "\n") are looked at again until a line start lines up with an old one past the edit: the rest only moves.
    static func lineStarts(_ starts: [Int], _ text: NSString, edited: NSRange, delta: Int) -> [Int] {
        let from = max(0, edited.location - 1)
        var lo = 0, hi = starts.count - 1   // the last start at or before `from`
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= from { lo = mid } else { hi = mid - 1 }
        }
        let oldEnd = NSMaxRange(edited) - delta
        var j = lo + 1
        return scan(text, from: starts[lo], into: Array(starts[...lo])) { i in
            while j < starts.count, starts[j] + delta < i { j += 1 }
            return j < starts.count && starts[j] >= oldEnd && starts[j] + delta == i ? starts[j...].map { $0 + delta } : nil
        }
    }

    /// Line starts from `i` (a line start) on, appended to `s`; `rest` may finish them once a start is known.
    private static func scan(_ text: NSString, from i: Int, into s: [Int], rest: (Int) -> [Int]? = { _ in nil }) -> [Int] {
        var s = s, i = i
        let len = text.length
        while i < len {
            i = NSMaxRange(text.lineRange(for: NSRange(location: i, length: 0)))
            if i < len, let tail = rest(i) { return s + tail }   // the same text from here on: the same lines
            if i < len || text.character(at: len - 1) == 10 && i == len { s.append(i) }
        }
        return s
    }

    private func starts(_ text: NSString) -> [Int] {
        if lineStarts == nil { lineStarts = Self.lineStarts(text) }
        let s = lineStarts!
        // Widen the gutter for files with many lines.
        let digits = max(3, String(s.count).count)
        let width = CGFloat(digits) * 8 + 14
        if abs(ruleThickness - width) > 1 { ruleThickness = width }
        return s
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = clientView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let text = tv.textStorage?.mutableString else { return }   // not `string`: a copy of all of it on every draw
        let lines = starts(text)
        let glyphs = lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // First visible line: binary search in line starts.
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid] <= chars.location { lo = mid } else { hi = mid - 1 }
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        var line = lo
        while line < lines.count, lines[line] <= NSMaxRange(chars) {
            let y: CGFloat
            if lines[line] < text.length {
                let g = lm.glyphIndexForCharacter(at: lines[line])
                y = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY
            } else {
                y = lm.extraLineFragmentRect.minY   // empty last line
            }
            let p = convert(NSPoint(x: 0, y: y + tv.textContainerInset.height), from: tv)
            let label = "\(firstLine + line + 1)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: p.y + 1), withAttributes: attrs)
            line += 1
        }
    }
}

/// Colors for highlighter tokens, shared by the editor and the viewer.
enum SyntaxColors {
    static func color(_ t: Syntax.Token) -> NSColor {
        switch t {
        case .comment: .secondaryLabelColor
        case .string: .systemRed
        case .number: .systemBlue
        case .keyword: .systemPink
        case .key: .systemTeal
        case .tag: .systemPurple
        case .variable: .systemOrange
        }
    }

    /// `region`: only there (what `changed` found); nil: all of the text.
    static func apply(_ tokens: [(range: NSRange, token: Syntax.Token)], to storage: NSTextStorage, in region: NSRange? = nil) {
        let all = NSRange(location: 0, length: storage.length), region = region.map { NSIntersectionRange($0, all) } ?? all
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: region)
        for (range, token) in tokens where NSMaxRange(range) <= storage.length {
            let r = NSIntersectionRange(range, region)
            if r.length > 0 { storage.addAttribute(.foregroundColor, value: color(token), range: r) }
        }
        storage.endEditing()
    }

    /// What a re-tint must paint (nil: nothing): the text edited since the last one (`edited`, in the new text: typed
    /// letters wear their neighbour's color) and wherever the tokens differ. A token before the edit that's the
    /// same, or one after it that's the same moved along by `delta`, keeps its color: re-setting all of them held a
    /// 2 MB file's window for 15 s, setting them over a text's worth of runs being that slow.
    static func changed(_ old: [(range: NSRange, token: Syntax.Token)], _ new: [(range: NSRange, token: Syntax.Token)],
                        edited: NSRange, delta: Int, length: Int) -> NSRange? {
        func same(_ a: (range: NSRange, token: Syntax.Token), _ b: (range: NSRange, token: Syntax.Token), by d: Int) -> Bool {
            a.token == b.token && a.range.length == b.range.length && a.range.location + d == b.range.location
        }
        var k = 0, m = 0
        while k < old.count, k < new.count, NSMaxRange(new[k].range) <= edited.location, same(old[k], new[k], by: 0) { k += 1 }
        while m < old.count - k, m < new.count - k, new[new.count - 1 - m].range.location >= NSMaxRange(edited),
              same(old[old.count - 1 - m], new[new.count - 1 - m], by: delta) { m += 1 }
        var lo = edited.location, hi = NSMaxRange(edited)
        if k < new.count - m { lo = min(lo, new[k].range.location); hi = max(hi, NSMaxRange(new[new.count - 1 - m].range)) }
        if k < old.count - m {   // where the old ones are now: as they were before the edit, moved along after it
            let first = old[k].range.location, last = NSMaxRange(old[old.count - 1 - m].range)
            (lo, hi) = (min(lo, first, first + delta), max(hi, last, last + delta))
        }
        (lo, hi) = (max(0, lo), min(length, hi))
        return hi > lo ? NSRange(location: lo, length: hi - lo) : nil
    }
}

/// Terminal colors (`ANSI`) as this app's, shared by the viewer and the output window: system colors, so each reads
/// in light and dark; black and white are the text's own grays.
enum ANSIColors {
    static func color(_ c: Int) -> NSColor {
        switch c % 8 {
        case 0: .secondaryLabelColor
        case 1: .systemRed
        case 2: .systemGreen
        case 3: c < 8 ? .systemOrange : .systemYellow
        case 4: .systemBlue
        case 5: .systemPink
        case 6: .systemCyan
        default: .textColor
        }
    }

    static func attributes(_ s: ANSI.Style, font: NSFont) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [:]
        if let c = s.color { a[.foregroundColor] = color(c) }
        if s.bold { a[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        return a
    }

    /// `runs` (from `offset` on in `storage`) in their colors.
    static func apply(_ runs: [ANSI.Run], to storage: NSTextStorage, offset: Int = 0, font: NSFont) {
        guard !runs.isEmpty else { return }
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)   // once, not per run
        storage.beginEditing()
        for r in runs where r.range.location + offset + r.range.length <= storage.length {
            var a: [NSAttributedString.Key: Any] = r.style.bold ? [.font: bold] : [:]
            if let c = r.style.color { a[.foregroundColor] = color(c) }
            storage.addAttributes(a, range: NSRange(location: r.range.location + offset, length: r.range.length))
        }
        storage.endEditing()
    }

    /// The level tints (`TextFormat.logLevels`) of lines without a color of their own: a colored line keeps its colors.
    static func uncolored(_ levels: [(range: NSRange, level: TextFormat.Level)], _ runs: [ANSI.Run]) -> [(range: NSRange, level: TextFormat.Level)] {
        let colored = runs.filter { $0.style.color != nil }
        guard !colored.isEmpty else { return levels }
        var j = 0
        return levels.sorted { $0.range.location < $1.range.location }.filter { l in   // both by place: one pass
            while j < colored.count, NSMaxRange(colored[j].range) <= l.range.location { j += 1 }
            return !(j < colored.count && colored[j].range.location < NSMaxRange(l.range))
        }
    }
}
