import Foundation

/// A change the model proposes to a text file (task 23 PR 7, `propose_edit`): its edits made in order on the text as
/// the editor holds it, never on, beside or uncovering a value Kermo hid (•••); then the parts the user keeps, as one
/// change of that text.
public enum AIEdit {
    public struct Refused: Error, Equatable { public let words: String }

    /// What the card shows and Apply takes: the text it was made on, the text proposed, where they differ — nil when
    /// the card can't show it (too different to compare here, or line ends its blocks can't carry: Compare only) —
    /// and what is hidden in each: the base's values, and where those stand in the proposed text (not what the model
    /// wrote: the user sees that).
    public struct Proposal: Sendable {
        public let base: String, proposed: String
        public let diff: TextDiff.Result?
        public let hiddenOld: [NSRange], hiddenNew: [NSRange]

        public init(base: String, proposed: String, hiddenOld: [NSRange], hiddenNew: [NSRange]) {
            (self.base, self.proposed, self.hiddenOld, self.hiddenNew) = (base, proposed, hiddenOld, hiddenNew)
            // A block's lines put back must give the proposed text: past a lone CR or U+2028 at a block's edge they don't.
            diff = TextDiff.compare(base, proposed).flatMap { d in
                !d.blocks.isEmpty && (AIEdit.carry(base, proposed, d, d.blocks.map { _ in true }) as NSString).isEqual(to: proposed) ? d : nil
            }
        }
        /// Tests: a text's hidden values found in each.
        public init(base: String, proposed: String) {
            self.init(base: base, proposed: proposed, hiddenOld: AISecrets.ranges(base), hiddenNew: AISecrets.ranges(proposed))
        }

        /// Lines removed and added, all blocks; past the card, `Int.max`.
        public var changedLines: Int { diff?.blocks.reduce(0) { $0 + $1.old.count + $1.new.count } ?? Int.max }
    }

    /// The card shows its blocks up to this many changed lines; past it, only Open in Compare.
    public static let cardLines = 200

    /// A file's text as the editor reads it (`Editor.load`): no byte order mark; LF where every line ends in CRLF.
    public static func editorText(_ s: String) -> String {
        let s = s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        return TextFormat.isCRLF(Data(s.utf8)) ? s.replacingOccurrences(of: "\r\n", with: "\n") : s
    }

    /// `edits` made in order on `text` (`name` says which file), and the proposal. Each `old` is found as the model saw
    /// the file: a match inside a hidden value isn't one — so the words never tell a guessed secret right — and the
    /// one match mustn't touch a hidden value either (`password=` → `password=x` would change it unseen). The base's
    /// hidden values are found once and followed through each edit: one whose name the edits change so that it
    /// wouldn't be hidden any more is refused too. Its work (a diff, the patterns) is for a thread of its own.
    public static func propose(_ edits: [(old: String, new: String)], to text: String, in name: String) -> Result<Proposal, Refused> {
        guard !edits.isEmpty else { return .failure(Refused(words: "propose_edit needs at least one edit.")) }
        let base = AISecrets.ranges(text)
        var out = text, hidden = base
        let lf = !(text as NSString).contains("\r\n")   // the model read the file's CRLF; the editor's text has LF then
        for (i, e) in edits.enumerated() {
            let which = edits.count > 1 ? "Edit \(i + 1): " : ""
            let old = lf ? e.old.replacingOccurrences(of: "\r\n", with: "\n") : e.old, new = lf ? e.new.replacingOccurrences(of: "\r\n", with: "\n") : e.new
            func no(_ words: String) -> Result<Proposal, Refused> { .failure(Refused(words: which + words)) }
            guard !(old as NSString).isEqual(to: new) else { return no("new_text has to differ from old_text.") }
            guard !old.contains("•••"), !new.contains("•••") else {
                return no("Kermo hid a value there (•••): the assistant can't change it or write it back. Edit around it.")
            }
            let s = out as NSString
            if old.isEmpty {   // an empty file's first text
                guard s.length == 0 else { return no("old_text has to be there: the text to replace, exactly as it is in the file.") }
                out = new
                continue
            }
            var found: [NSRange] = [], from = 0
            while from < s.length {
                let r = s.range(of: old, options: .literal, range: NSRange(location: from, length: s.length - from))
                guard r.location != NSNotFound else { break }
                if !hidden.contains(where: { NSIntersectionRange($0, r).length > 0 }) { found.append(r) }
                from = r.location + 1   // overlapping ones count too: "aa" is in "aaa" twice
            }
            guard found.count == 1 else {
                return no(found.isEmpty ? "old_text isn't in \(name). It has to match exactly: spaces and line ends too."
                          : "old_text is in \(name) \(found.count) times. Give more of the text around it, so that it is there once.")
            }
            let r = found[0], shift = (new as NSString).length - r.length
            guard !hidden.contains(where: { $0.location <= NSMaxRange(r) && r.location <= NSMaxRange($0) }) else {
                return no("old_text ends or starts right at a value Kermo hid (•••): the change would run into it. Edit around it — whole lines before or after.")
            }
            out = s.replacingCharacters(in: r, with: new)
            hidden = hidden.map { $0.location >= NSMaxRange(r) ? NSRange(location: $0.location + shift, length: $0.length) : $0 }   // none overlaps r
        }
        guard !(out as NSString).isEqual(to: text) else { return .failure(Refused(words: "The edits change nothing.")) }
        let now = AISecrets.ranges(out)
        guard hidden.allSatisfy({ h in now.contains { $0.location <= h.location && NSMaxRange(h) <= NSMaxRange($0) } }) else {
            return .failure(Refused(words: "The change would show a value Kermo hid (•••): leave the name in front of it as it is."))
        }
        return .success(Proposal(base: text, proposed: out, hiddenOld: base, hiddenNew: hidden))
    }

    /// The base with the blocks `keep` says (in the diff's order) as proposed, the rest as they are. All kept: the
    /// proposed text; none: the base.
    public static func kept(_ p: Proposal, _ keep: [Bool]) -> String {
        guard let d = p.diff else { return p.base }
        return keep.allSatisfy({ $0 }) ? p.proposed : carry(p.base, p.proposed, d, keep)
    }

    private static func carry(_ base: String, _ proposed: String, _ d: TextDiff.Result, _ keep: [Bool]) -> String {
        let out = NSMutableString(string: base), old = base as NSString, new = proposed as NSString
        for (k, b) in zip(keep, d.blocks).reversed() where k {   // from the end: what is before stays where it was
            let c = TextDiff.carry(from: (new, d.newLines, b.new), to: (old, d.oldLines, b.old))
            out.replaceCharacters(in: c.range, with: c.text)
        }
        return out as String
    }

    /// The one range of `a` to replace, and with what, to make it `b` — whole lines, so a cut never falls inside a
    /// character. nil: they're the same.
    public static func span(_ a: String, _ b: String) -> (range: NSRange, text: String)? {
        let x = a as NSString, y = b as NSString
        guard !x.isEqual(to: b) else { return nil }
        var p = 0, s = 0
        while p < x.length, p < y.length, x.character(at: p) == y.character(at: p) { p += 1 }
        while s < x.length - p, s < y.length - p, x.character(at: x.length - 1 - s) == y.character(at: y.length - 1 - s) { s += 1 }
        p = x.lineRange(for: NSRange(location: p, length: 0)).location   // the text before it is the same in both
        s -= NSMaxRange(x.lineRange(for: NSRange(location: x.length - s, length: 0))) - (x.length - s)   // and after it
        return (NSRange(location: p, length: x.length - s - p), y.substring(with: NSRange(location: p, length: y.length - s - p)))
    }
}
