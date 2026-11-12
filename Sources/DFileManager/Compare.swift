import AppKit
import DFMCore

/// Compare: two views of the editor window side by side — a document as it is, live, or a read-only copy
/// (`Editor.snapshot`) — their differences painted on the views alone, never in the text's storage (a clone elsewhere
/// shows none; nothing is changed, drafted or saved by it). Across from what one side lacks its layout leaves blank
/// space, so equal lines stay level; the scroll follows line by line; ⌥⌘↓ ⌥⌘↑ go from change to change. Worked out off
/// the main thread once typing pauses, the latest only. Another tab in either pane pauses it; closing or moving a side,
/// Join Panes or Stop Comparing ends it, and closes the copies made for it.
@MainActor
final class Comparison: NSObject {
    enum Kind { case removed, added, changed }

    /// What one side's view draws (`EditorTextView`, `LineNumberRuler`) and the space its layout leaves.
    @MainActor final class Side: NSObject, NSLayoutManagerDelegate {
        weak var view: DocView?
        let old: Bool
        /// Its changed lines (text ranges, in order) with their block's index; the characters that differ in them.
        fileprivate(set) var lines: [(range: NSRange, kind: Kind, block: Int)] = []
        fileprivate(set) var chars: [NSRange] = []
        /// Blank space after a line, by where the line starts; and before the first line (the text's top inset).
        fileprivate(set) var gaps: [Int: CGFloat] = [:]
        fileprivate(set) var top: CGFloat = 0
        /// The block the caret is in, either side's: its lines are marked in the line numbers.
        var current: Int?

        init(_ v: DocView, old: Bool) { (view, self.old) = (v, old) }

        // Asked once per line, with its line end's glyph (spike: never per wrapped fragment); a last line without a line
        // end isn't asked — space after it would be below everything anyway.
        nonisolated func layoutManager(_ lm: NSLayoutManager, paragraphSpacingAfterGlyphAt g: Int, withProposedLineFragmentRect r: NSRect) -> CGFloat {
            guard let text = lm.textStorage?.mutableString, g < lm.numberOfGlyphs else { return 0 }
            let start = text.lineRange(for: NSRange(location: lm.characterIndexForGlyph(at: g), length: 0)).location
            return MainActor.assumeIsolated { gaps[start] ?? 0 }
        }

        /// The kind and block of the line starting at `start`, if it changed.
        func mark(at start: Int) -> (kind: Kind, block: Int)? {
            let i = lines.partitioningIndex { $0.range.location >= start }
            return i < lines.count && lines[i].range.location == start ? (lines[i].kind, lines[i].block) : nil
        }

        /// A typed change moves what's after it along (the text's edited range, its change in length) till it's worked out anew.
        fileprivate func shift(_ edited: NSRange, by delta: Int) {
            let from = NSMaxRange(edited) - delta   // where the old text resumes
            func moved(_ r: NSRange) -> NSRange? {
                r.location >= from ? NSRange(location: r.location + delta, length: r.length) : NSMaxRange(r) <= edited.location ? r : nil
            }
            lines = lines.compactMap { l in moved(l.range).map { ($0, l.kind, l.block) } }
            chars = chars.compactMap(moved)
            gaps = Dictionary(gaps.compactMap { k, v in k >= from ? (k + delta, v) : k < edited.location ? (k, v) : nil }, uniquingKeysWith: max)
        }

        /// The view's colors: a band under each changed line, its changed characters stronger, the blank space hatched.
        /// Old and new pick the colors, not left and right: removed gray, added green, changed amber (red means failed).
        func draw(in tv: NSTextView, _ rect: NSRect) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer, let text = tv.textStorage?.mutableString else { return }
            let o = tv.textContainerOrigin, w = tv.bounds.width
            let shown = lm.characterRange(forGlyphRange: lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -o.x, dy: -o.y), in: tc), actualGlyphRange: nil)
            let hatch = NSColor.labelColor.withAlphaComponent(0.07)
            func band(_ r: NSRect, _ c: NSColor) { c.setFill(); NSRect(x: 0, y: r.minY + o.y, width: w, height: r.height).fill(using: .sourceOver) }
            func hatched(_ r: NSRect) {
                guard r.height > 0, r.intersects(rect) else { return }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: r).addClip()
                hatch.setStroke()
                let p = NSBezierPath()
                var x = r.minX - r.height
                while x < r.maxX { p.move(to: NSPoint(x: x, y: r.maxY)); p.line(to: NSPoint(x: x + r.height, y: r.minY)); x += 7 }
                p.lineWidth = 1.5
                p.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            let from = lines.partitioningIndex { NSMaxRange($0.range) >= shown.location }
            for l in lines[from...] {
                if l.range.location > NSMaxRange(shown) { break }
                let whole = text.lineRange(for: NSRange(location: l.range.location, length: 0))
                lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forCharacterRange: whole, actualCharacterRange: nil)) { _, used, _, _, _ in
                    band(used, Self.color(l.kind, old: self.old, strong: false))
                }
            }
            let strong = Self.color(.changed, old: old, strong: true)
            strong.setFill()
            let c0 = chars.partitioningIndex { NSMaxRange($0) >= shown.location }
            for c in chars[c0...] {
                if c.location > NSMaxRange(shown) { break }
                lm.enumerateEnclosingRects(forGlyphRange: lm.glyphRange(forCharacterRange: c, actualCharacterRange: nil), withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { r, _ in
                    NSBezierPath(roundedRect: r.offsetBy(dx: o.x, dy: o.y), xRadius: 2, yRadius: 2).fill()
                }
            }
            for start in gaps.keys where start <= NSMaxRange(shown) && start < text.length {
                let end = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0))) - 1
                guard end >= shown.location else { continue }   // its line above what's drawn (its space may still show)
                let f = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: end), effectiveRange: nil)
                let u = lm.lineFragmentUsedRect(forGlyphAt: lm.glyphIndexForCharacter(at: end), effectiveRange: nil)
                hatched(NSRect(x: 0, y: u.maxY + o.y, width: w, height: f.maxY - u.maxY))
            }
            if top > 0 { hatched(NSRect(x: 0, y: o.y - top, width: w, height: top)) }
        }

        static func color(_ k: Kind, old: Bool, strong: Bool) -> NSColor {
            switch (k, strong) {
            case (.removed, _): .systemGray.withAlphaComponent(0.22)
            case (.added, _): .systemGreen.withAlphaComponent(0.16)
            case (.changed, false): .systemOrange.withAlphaComponent(0.13)
            case (.changed, true): old ? .systemGray.withAlphaComponent(0.38) : .systemGreen.withAlphaComponent(0.34)
            }
        }
        /// Its mark beside the line number: − removed, + added, ~ changed — not color alone.
        static func symbol(_ k: Kind) -> (String, NSColor) {
            switch k {
            case .removed: ("−", .systemGray)
            case .added: ("+", .systemGreen)
            case .changed: ("~", .systemOrange)
            }
        }
    }

    let old: Side, new: Side
    /// The copies made for it: closed with it (nothing in them to lose).
    var snapshots: [Editor]
    private(set) var blocks: [TextDiff.Block] = []
    private(set) var paused = false
    /// The last result, for the blank space again (Wrap, a new width, the text size), and the texts' edits it was of.
    private var last: TextDiff.Result?
    private var lastEdits = (0, 0)
    /// Over the budget (`TextDiff.cost`): no colors, its status lines say so and offer `diff -u`.
    private(set) var tooBig = false
    private var running = false, again = false, syncing = false, due = 0
    private var observers: [NSObjectProtocol] = []
    private var widths: [CGFloat] = [0, 0]
    private weak var host: EditorHost?   // a late result after the window's gone: nothing to do

    init(old: DocView, new: DocView, snapshots: [Editor], host: EditorHost) {
        (self.old, self.new, self.snapshots) = (Side(old, old: true), Side(new, old: false), snapshots)
        self.host = host
    }

    private var sides: [Side] { [old, new] }

    // MARK: On and off

    /// Its colors, space and scroll on the two views; worked out now.
    func start() {
        attach()
        recompute()
    }

    private func attach() {
        let nc = NotificationCenter.default
        for (i, s) in sides.enumerated() {
            guard let v = s.view else { continue }
            v.text.compared = s
            v.ruler.compared = s
            v.text.layoutManager?.delegate = s
            v.frame.scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: v.frame.scroll.contentView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrolled(i) }
            })
            observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: v.text, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.resized(i) }
            })
            if i == 0 || old.view?.doc !== v.doc {   // one storage, one look
                nc.addObserver(self, selector: #selector(edited), name: NSTextStorage.didProcessEditingNotification, object: v.doc.storage)
            }
        }
        widths = sides.map { $0.view?.text.bounds.width ?? 0 }
        paused = false
        keys()
    }

    /// The key bars say ⌥⌘↓ ⌥⌘↑ while it compares (`Editor.keys`).
    private func keys() { sides.forEach { $0.view?.frame.showKeys() } }

    /// Back to plain views: no delegate, no observer, no colors — nothing costs anything once it's off.
    private func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        NotificationCenter.default.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: nil)
        for s in sides {
            s.view?.text.compared = nil
            s.view?.ruler.compared = nil
            s.view?.text.layoutManager?.delegate = nil
            set(s, lines: [], chars: [], gaps: [:], top: 0)
            s.view?.frame.actions = []
        }
        (blocks, last, tooBig, running, again) = ([], nil, false, false, false)
        say()
        keys()
    }

    /// The panes as they are now (`EditorHost.showTabs`): another tab in either pauses it, back again goes on; a side
    /// closed, moved to the other's pane, or a pane gone ends it.
    func check() {
        guard let host else { return }
        guard let a = old.view, let b = new.view, let pa = a.pane, let pb = b.pane, pa !== pb, host.panes.contains(where: { $0 === pa }),
              host.panes.contains(where: { $0 === pb }), pa.docs.contains(where: { $0 === a.doc }), pb.docs.contains(where: { $0 === b.doc }) else {
            return host.stopComparing()
        }
        let shown = pa.active === a.doc && pb.active === b.doc
        if shown, paused { start() }
        if !shown, !paused { detach(); paused = true; say(); keys() }
    }

    /// Stop Comparing: views plain again, the copies made for it closed.
    func stop() {
        detach()
        snapshots.filter { $0.snapshot != nil }.forEach { host?.remove($0) }
    }

    /// A read-only copy's tab went to a document (Edit, its file open in another tab already): that side is its view.
    func replace(_ e: Editor, with doc: Editor, in p: EditorHost.Pane) {
        guard let s = sides.first(where: { $0.view?.doc === e }) else { return }
        detach()
        s.view = doc.view(in: p)
        snapshots.removeAll { $0 === e }
    }

    // MARK: Working it out

    @objc private func edited(_ n: Notification) {
        guard let storage = n.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
        for s in sides where s.view?.doc.storage === storage { s.shift(storage.editedRange, by: storage.changeInLength) }
        due += 1
        let mine = due
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in   // as the colors wait for a pause in typing
            MainActor.assumeIsolated { if let self, self.due == mine { self.recompute() } }
        }
    }

    /// Both texts matched off the main thread; one at a time, and if either changed meanwhile, again (the latest only).
    func recompute() {
        guard !paused, let a = old.view?.doc, let b = new.view?.doc else { return }
        guard a.cover == nil, b.cover == nil else { return show(nil, empty: true) }   // a text being read: nothing yet
        if running { again = true; return }
        running = true
        let (x, y, ea, eb) = (a.storage.string, b.storage.string, a.edits, b.edits)
        Task {
            let r = await Task.detached(priority: .userInitiated) { TextDiff.compare(x, y) }.value
            running = false
            guard host?.comparison === self, !paused, old.view?.doc === a, new.view?.doc === b else { return }
            if again || a.edits != ea || b.edits != eb { again = false; return recompute() }
            lastEdits = (ea, eb)
            show(r)
        }
    }

    /// A result on the views; nil: over the budget (or `empty`: no text to compare yet).
    private func show(_ r: TextDiff.Result?, empty: Bool = false) {
        last = r
        blocks = r?.blocks ?? []
        tooBig = r == nil && !empty
        regap()
        for s in sides {
            var actions: [(String, @MainActor () -> Void)] = []
            if s.view?.doc.snapshot?.source != nil { actions.append(("Edit", { @MainActor [weak s] in s?.view?.doc.edit() })) }
            if tooBig { actions.append(("Show as diff -u", { @MainActor [weak self] in self?.showPlain() })) }
            s.view?.frame.actions = actions
        }
        caretMoved(nil)
    }

    /// Lines, characters and blank space on both views from the last result.
    func regap() {
        guard let r = last, let va = old.view, let vb = new.view else { return sides.forEach { set($0, lines: [], chars: [], gaps: [:], top: 0) } }
        guard (va.doc.edits, vb.doc.edits) == lastEdits else { return }   // typed since: what shows was moved along (`shift`), the next result regaps
        var gaps: [[Int: CGFloat]] = [[:], [:]], tops: [CGFloat] = [0, 0], lines: [[(NSRange, Kind, Int)]] = [[], []]
        for (k, b) in r.blocks.enumerated() {
            let pairs = min(b.old.count, b.new.count)
            for (n, i) in b.old.enumerated() { lines[0].append((r.oldLines[i], n < pairs ? .changed : .removed, k)) }
            for (n, j) in b.new.enumerated() { lines[1].append((r.newLines[j], n < pairs ? .changed : .added, k)) }
            let h = [height(va, r.oldLines, b.old), height(vb, r.newLines, b.new)]
            for (s, (ls, range)) in [(r.oldLines, b.old), (r.newLines, b.new)].enumerated() {
                let gap = h[1 - s] - h[s]
                guard gap > 0.5 else { continue }
                // After the block's last line here, else after the line before it, else before the first line.
                if let last = range.last ?? (range.lowerBound > 0 ? range.lowerBound - 1 : nil) { gaps[s][ls[last].location, default: 0] += gap } else { tops[s] += gap }
            }
        }
        set(old, lines: lines[0], chars: r.oldChars, gaps: gaps[0], top: tops[0])
        set(new, lines: lines[1], chars: r.newChars, gaps: gaps[1], top: tops[1])
    }

    /// How tall `range`'s lines are in `v`: rows of the text's line height, or — wrapped — as its layout has them.
    private func height(_ v: DocView, _ lines: [NSRange], _ range: Range<Int>) -> CGFloat {
        guard !range.isEmpty, let lm = v.text.layoutManager else { return 0 }
        guard Editor.wraps else { return CGFloat(range.count) * lm.defaultLineHeight(for: v.text.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)) }
        let from = lines[range.lowerBound].location, to = range.upperBound < lines.count ? lines[range.upperBound].location : v.doc.storage.length
        var h: CGFloat = 0
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forCharacterRange: NSRange(location: from, length: max(1, to - from)), actualCharacterRange: nil)) { _, used, _, _, _ in h += used.height }
        return h
    }

    /// A side's marks and space set — its layout laid out again only where the space changed.
    private func set(_ s: Side, lines: [(NSRange, Kind, Int)], chars: [NSRange], gaps: [Int: CGFloat], top: CGFloat) {
        let changed = Set(s.gaps.keys).union(gaps.keys).filter { s.gaps[$0] != gaps[$0] }
        (s.lines, s.chars, s.gaps) = (lines.map { ($0.0, $0.1, $0.2) }, chars, gaps)
        guard let v = s.view, let lm = v.text.layoutManager else { return }
        let text = v.doc.storage.mutableString
        for k in changed where k < text.length { lm.invalidateLayout(forCharacterRange: text.lineRange(for: NSRange(location: k, length: 0)), actualCharacterRange: nil) }
        if top != s.top {
            s.top = top
            v.text.textContainerInset = NSSize(width: 4, height: 4 + top)   // its top only matters; the bottom's the same, unseen
        }
        v.text.needsDisplay = true
        v.ruler.needsDisplay = true
    }

    /// The width changed (the window, the divider, Wrap): wrapped lines' blank space measured again.
    private func resized(_ i: Int) {
        let w = sides[i].view?.text.bounds.width ?? 0
        guard w != widths[i] else { return }
        widths[i] = w
        if Editor.wraps { regap() }
    }

    // MARK: Scrolling together

    /// The other side scrolled to the same place: the line at this one's top — or its block's top, inside a change —
    /// and as far into it. Line by line, not by the same offset: a long text's layout is laid out only where it shows,
    /// so where its far lines are is a guess (spike: 100 000 lines, two thirds off).
    private func scrolled(_ i: Int) {
        guard !syncing, !paused, let from = sides[i].view, let to = sides[1 - i].view else { return }
        syncing = true
        defer { syncing = false }
        let clip = from.frame.scroll.contentView, there = to.frame.scroll.contentView
        let top = clip.bounds.minY, line = self.line(at: top, in: from), fromOld = i == 0
        var y: CGFloat
        if let b = block(holding: line, old: fromOld) {
            y = blockTop(b, old: !fromOld, in: to) + top - blockTop(b, old: fromOld, in: from)
        } else {
            y = self.y(ofLine: map(line, old: fromOld), in: to) + top - self.y(ofLine: line, in: from)
        }
        y = min(max(y, 0), max(0, to.text.frame.height - there.bounds.height))
        guard abs(there.bounds.minY - y) > 0.5 else { return }
        there.scroll(to: NSPoint(x: there.bounds.minX, y: y))
        to.frame.scroll.reflectScrolledClipView(there)
    }

    /// The line at `y` (the text view's), by its line numbers' starts.
    private func line(at y: CGFloat, in v: DocView) -> Int {
        guard let lm = v.text.layoutManager, let tc = v.text.textContainer, v.doc.storage.length > 0 else { return 0 }
        let g = lm.glyphIndex(for: NSPoint(x: 0, y: max(0, y - v.text.textContainerOrigin.y)), in: tc)
        return LineNumberRuler.line(of: lm.characterIndexForGlyph(at: g), in: v.ruler.starts)
    }

    /// Where line `n` starts in `v` (the text view's y); past its last, where the text ends.
    private func y(ofLine n: Int, in v: DocView) -> CGFloat {
        guard let lm = v.text.layoutManager else { return 0 }
        let starts = v.ruler.starts, length = v.doc.storage.length
        let o = v.text.textContainerOrigin.y
        guard n < starts.count, starts[n] < length else { return o + lm.extraLineFragmentRect.minY }
        return o + lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: starts[n]), effectiveRange: nil).minY
    }

    /// Where a block starts on a side: its first line, else (none there) the blank space across from it.
    private func blockTop(_ b: TextDiff.Block, old isOld: Bool, in v: DocView) -> CGFloat {
        let r = isOld ? b.old : b.new, s = isOld ? old : new
        if !r.isEmpty { return y(ofLine: r.lowerBound, in: v) }
        let next = y(ofLine: r.lowerBound, in: v)
        guard r.lowerBound > 0 else { return next - s.top }
        let starts = v.ruler.starts   // a block from before the latest typing may be past the text's end now
        return next - (starts.indices.contains(r.lowerBound - 1) ? s.gaps[starts[r.lowerBound - 1]] ?? 0 : 0)
    }

    /// The block whose lines on that side hold `line` (a block with none there: at the line after its space).
    private func block(holding line: Int, old isOld: Bool) -> TextDiff.Block? {
        let i = blocks.partitioningIndex { (isOld ? $0.old : $0.new).lowerBound > line } - 1
        guard i >= 0 else { return nil }
        let r = isOld ? blocks[i].old : blocks[i].new
        return r.contains(line) ? blocks[i] : nil
    }

    /// The line across from `line` (not in a block).
    private func map(_ line: Int, old isOld: Bool) -> Int {
        let i = blocks.partitioningIndex { (isOld ? $0.old : $0.new).lowerBound > line } - 1
        guard i >= 0 else { return line }
        let (mine, theirs) = isOld ? (blocks[i].old, blocks[i].new) : (blocks[i].new, blocks[i].old)
        return line - mine.upperBound + theirs.upperBound
    }

    // MARK: Changes

    /// ⌥⌘↓ ⌥⌘↑: the caret, on the side with the keys, to the next or previous change's first line — the other side
    /// alongside — round from the last to the first.
    func step(_ d: Int, from v: DocView?) {
        guard !paused, !blocks.isEmpty, let s = sides.first(where: { $0.view === v }) ?? sides.first(where: { $0.view != nil }), let v = s.view else { return NSSound.beep() }
        let starts = blocks.map { (s.old ? $0.old : $0.new).lowerBound }, here = caretLine(v)
        let i = d > 0 ? starts.firstIndex { $0 > here } ?? 0 : starts.lastIndex { $0 < here } ?? starts.count - 1
        let line = min(starts[i], v.ruler.starts.count - 1), at = v.ruler.starts[line]
        v.text.setSelectedRange(NSRange(location: at, length: 0))
        let clip = v.frame.scroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, blockTop(blocks[i], old: s.old, in: v) - clip.bounds.height / 3)))
        v.frame.scroll.reflectScrolledClipView(clip)
        caretMoved(v)
    }

    private func caretLine(_ v: DocView) -> Int { LineNumberRuler.line(of: v.text.selectedRange().location, in: v.ruler.starts) }

    /// The caret moved in `v` (nil: the result changed): the block it's in is marked on both sides, and said.
    func caretMoved(_ v: DocView?) {
        guard let v = v ?? host?.active.flatMap({ e in sides.first { $0.view?.doc === e }?.view }) ?? new.view,
              let s = sides.first(where: { $0.view === v }) else { return }
        let line = caretLine(v)
        let b = blocks.firstIndex { r in let x = s.old ? r.old : r.new; return x.contains(line) || x.isEmpty && x.lowerBound == line }
        if b != old.current || b != new.current {
            (old.current, new.current) = (b, b)
            sides.forEach { $0.view?.ruler.needsDisplay = true }
        }
        say()
    }

    /// Its words for `v`'s status line, before Ln and Col; nil: `v` isn't a side.
    func words(for v: DocView) -> String? {
        guard sides.contains(where: { $0.view === v }) else { return nil }
        if paused { return "Compare paused" }
        if tooBig { return "Too different to compare here" }
        guard let a = old.view?.doc, let b = new.view?.doc, a.cover == nil, b.cover == nil, last != nil else { return "Comparing…" }
        if blocks.isEmpty {
            let (f, g) = (a.format, b.format)
            if f.crlf != g.crlf { return "Same text — line endings differ (\(f.crlf ? "CRLF" : "LF") / \(g.crlf ? "CRLF" : "LF"))" }
            if f.bom != g.bom { return "Same text — one has a byte order mark" }
            return f.encoding == g.encoding ? "No differences" : "Same text — encodings differ"
        }
        if let k = old.current { return "Change \(k + 1) of \(blocks.count)" }
        return blocks.count == 1 ? "1 change" : "\(blocks.count) changes"
    }

    private func say() { sides.forEach { $0.view.map { $0.doc.sayPosition($0) } } }

    /// Show as diff -u (over the budget): both texts as they are now in 0600 files of ours, gone at quit (as a draft's
    /// for Compare were), shown by `diff -u` under their tabs' names.
    func showPlain() {
        guard let a = old.view?.doc, let b = new.view?.doc else { return }
        let dir = NSTemporaryDirectory() + "dfm-text-compare-" + UUID().uuidString
        guard mkdir(dir, 0o700) == 0 else { return }
        Editor.comparisons.append(dir)
        let (pa, pb) = (dir + "/old", dir + "/new"), fm = FileManager.default
        guard fm.createFile(atPath: pa, contents: Data(a.storage.string.utf8), attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: pb, contents: Data(b.storage.string.utf8), attributes: [.posixPermissions: 0o600]) else { return }
        AppDelegate.runDiff(AppDelegate.diffCommand(pa, pb, labels: (a.name, b.name)), dir, false, "diff \(a.name) ↔ \(b.name)")
    }
}

extension RandomAccessCollection {
    /// The first index whose element is `true` for `belongs` — every element before it `false` (a sorted collection).
    func partitioningIndex(where belongs: (Element) -> Bool) -> Index {
        var lo = startIndex, n = count
        while n > 0 {
            let half = n / 2, mid = index(lo, offsetBy: half)
            if belongs(self[mid]) { n = half } else { lo = index(after: mid); n -= half + 1 }
        }
        return lo
    }
}
