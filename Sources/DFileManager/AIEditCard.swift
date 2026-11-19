import AppKit
import DFMCore

/// `propose_edit`'s diff in the chat (task 23 PR 7): the file and where it is — production in its purple — then each
/// change with Keep / Drop, Apply to Editor and Open in Compare. Apply puts what is kept into the file's editor tab as
/// one ⌘Z step, the tab opened first if it isn't (a server's through its gate); nothing is written anywhere — ⌘S does
/// that, as after typing. Only on the text the change was made on: a tab that changed since refuses it. Past
/// `AIEdit.cardLines`, or too different to compare here: only Open in Compare. Hidden values show as •••.
@MainActor
final class EditCard: NSStackView {
    private unowned let app: AppDelegate
    private let p: AIEdit.Proposal
    private let server: SFTPTarget?, path: String
    private var keep: [Bool]
    private var toggles: [NSSegmentedControl] = []
    private var buttons: [NSButton] = []
    private let said = NSTextField(wrappingLabelWithString: "")
    private var name: String { (path as NSString).lastPathComponent }

    init(_ p: AIEdit.Proposal, on server: SFTPTarget?, path: String, app: AppDelegate) {
        (self.p, self.server, self.path, self.app) = (p, server, path, app)
        let blocks = p.diff?.blocks ?? []
        keep = blocks.map { _ in true }
        super.init(frame: .zero)
        (orientation, alignment, spacing, edgeInsets) = (.vertical, .centerX, 6, NSEdgeInsets(top: 1, left: 0, bottom: 8, right: 0))
        let prod = server.map(SavedServer.isProd) ?? false, small = p.changedLines <= AIEdit.cardLines
        var views: [NSView] = [strip(prod: prod, changes: blocks.count)]
        if small {
            for (i, b) in blocks.enumerated() { views += hunk(i, b) }
        } else {
            views.append(Self.line(p.diff == nil ? "Too different to show here." : "\(p.changedLines) changed lines — too many to show here.", .secondaryLabelColor))
        }
        let compare = AIPanel.button("Open in Compare") { [weak self] in self?.document { self?.compare($0) } }
        compare.toolTip = "The proposal beside the file: Copy Change takes the parts you want"
        buttons = [compare]
        if small {
            let apply = AIPanel.button("Apply to Editor") { [weak self] in
                guard let self else { return }
                let keep = keep
                document { [weak self] e in self?.apply(e, keep) }
            }
            apply.bezelColor = .controlAccentColor
            buttons.append(apply)
        }
        said.stringValue = small ? "Into the editor as one step — ⌘Z undoes it. Saving is yours: ⌘S." : "Copy Change brings each part into the file. Saving is yours: ⌘S."
        (said.font, said.textColor) = (.systemFont(ofSize: 11), .secondaryLabelColor)
        said.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let foot = NSStackView(views: [said] + buttons)
        (foot.alignment, foot.spacing) = (.centerY, 6)
        views.append(foot)
        setViews(views, in: .top)
        for v in views { v.widthAnchor.constraint(equalTo: widthAnchor, constant: v === views[0] ? 0 : -20).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ r: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    /// The file, where it is, how many changes; production in its colour, and said.
    private func strip(prod: Bool, changes: Int) -> NSView {
        let s = NSMutableAttributedString()
        if prod { s.append(Chip.prod.text); s.append(NSAttributedString(string: " ")) }
        let place = server.map(AISession.label) ?? "this Mac"
        s.append(NSAttributedString(string: "\(name) · \(place)".bidiVisible + (prod ? " · production" : ""),
                                    attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: prod ? Palette.prod : NSColor.labelColor]))
        let count = Answer.small(changes == 1 ? "1 change" : "\(changes) changes")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let text = ChatText(s)
        let row = NSStackView(views: [text, spacer, count])
        row.spacing = 6
        return TintBox(row, fill: prod ? Palette.prod.withAlphaComponent(0.12) : NSColor.quaternaryLabelColor.withAlphaComponent(0.5), inset: NSSize(width: 10, height: 5))
    }

    /// One change: "Line N", Keep / Drop, two lines around it, what goes (−) and what comes (+).
    private func hunk(_ i: Int, _ b: TextDiff.Block) -> [NSView] {
        guard let d = p.diff else { return [] }
        let old = p.base as NSString, new = p.proposed as NSString
        let hiddenOld = AISecrets.ranges(p.base), hiddenNew = AISecrets.ranges(p.proposed)
        let toggle = NSSegmentedControl(labels: ["Keep", "Drop"], trackingMode: .selectOne, target: self, action: #selector(toggled(_:)))
        (toggle.selectedSegment, toggle.tag, toggle.controlSize) = (0, i, .small)
        toggle.setAccessibilityLabel("Change \(i + 1)")
        toggles.append(toggle)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let head = NSStackView(views: [Answer.small("Line \(b.old.lowerBound + 1)"), spacer, toggle])
        head.alignment = .centerY

        let text = NSMutableAttributedString(), mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        func row(_ n: Int?, _ mark: String, _ r: NSRange, _ s: NSString, _ hidden: [NSRange], _ kind: Kind) {
            let number = n.map { String($0 + 1) } ?? ""
            let t = String(repeating: " ", count: max(0, 4 - number.count)) + number + " \(mark) " + Self.shown(r, s, hidden).bidiVisible
            text.append(NSAttributedString(string: (text.length == 0 ? "" : "\n") + t, attributes: [.font: mono, .foregroundColor: kind == .same ? NSColor.secondaryLabelColor : NSColor.labelColor,
                                                                                                    .backgroundColor: kind.fill, Self.kind: kind.rawValue]))
        }
        for n in max(0, b.old.lowerBound - 2)..<b.old.lowerBound { row(n, " ", d.oldLines[n], old, hiddenOld, .same) }
        for n in b.old { row(n, "−", d.oldLines[n], old, hiddenOld, .gone) }
        for n in b.new { row(nil, "+", d.newLines[n], new, hiddenNew, .came) }
        for n in b.old.upperBound..<min(d.oldLines.count, b.old.upperBound + 2) { row(n, " ", d.oldLines[n], old, hiddenOld, .same) }
        let lines = ChatText(text)
        lines.setAccessibilityLabel("Change \(i + 1) at line \(b.old.lowerBound + 1)")
        texts.append(lines)
        return [head, lines]
    }
    private var texts: [ChatText] = []

    private enum Kind: Int {
        case same, gone, came
        var fill: NSColor { [.clear, Palette.fail.withAlphaComponent(0.13), Palette.ok.withAlphaComponent(0.15)][rawValue] }
    }
    private static let kind = NSAttributedString.Key("kermo.diffLine")

    /// A line of `s` as the chat shows it: what is hidden in it (`AISecrets.ranges`) as •••.
    static func shown(_ r: NSRange, _ s: NSString, _ hidden: [NSRange]) -> String {
        var out = "", at = r.location
        for c in hidden.map({ NSIntersectionRange($0, r) }).filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if c.location >= at { out += s.substring(with: NSRange(location: at, length: c.location - at)) + "•••" }
            at = max(at, NSMaxRange(c))
        }
        return out + s.substring(with: NSRange(location: at, length: NSMaxRange(r) - at))
    }

    /// Keep or Drop: a dropped change's new lines struck through and faint, its old ones as they are.
    @objc private func toggled(_ c: NSSegmentedControl) {
        keep[c.tag] = c.selectedSegment == 0
        let t = texts[c.tag], kept = keep[c.tag]
        guard let s = t.textStorage else { return }
        s.enumerateAttribute(Self.kind, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            guard let k = (v as? Int).flatMap(Kind.init) else { return }
            if k == .came {
                s.addAttributes([.strikethroughStyle: kept ? 0 : NSUnderlineStyle.single.rawValue, .foregroundColor: kept ? NSColor.labelColor : NSColor.tertiaryLabelColor,
                                 .backgroundColor: kept ? k.fill : NSColor.clear], range: r)
            } else if k == .gone {
                s.addAttribute(.backgroundColor, value: kept ? k.fill : NSColor.clear, range: r)
            }
        }
        buttons.last?.isEnabled = keep.contains(true) || buttons.count == 1
    }

    // MARK: - Into the editor

    /// The file's tab: open already, or opened now — a server's after its gate (Touch ID for a locked one).
    private func document(_ then: @escaping @MainActor (Editor) -> Void) {
        if let e = server.map({ Editor.tab(onServer: $0, path) }) ?? Editor.document(at: path) { return then(e) }
        guard let t = server else { return Editor.open(URL(fileURLWithPath: path), then: then) }
        Task {
            guard case .pass = await app.gate([t], to: "open a file on") else { return say("\(AISession.label(t)) stays locked: nothing was opened.", error: true) }
            app.remoteOpen(.edit, t, path, in: app.panels.first { $0.remote?.target.asUser == t } ?? app.active, then: then)
        }
    }

    /// Why `e` can't take the change now, in words; nil: it can. Only the text the change was made on.
    private func refusal(_ e: Editor) -> String? {
        if e.cover != nil { return "“\(name)” isn't open yet — try again once it shows." }
        if e.snapshot != nil || e.saving || !e.textView.isEditable { return "“\(name)” can't be changed now." }
        if !(e.storage.string as NSString).isEqual(to: p.base) { return "“\(name)” changed since this was proposed — ask again." }
        return nil
    }

    private func apply(_ e: Editor, _ keep: [Bool]) {
        if let why = refusal(e) { return say(why, error: true) }
        guard let s = AIEdit.span(p.base, AIEdit.kept(p, keep)) else { return say("Nothing kept: nothing to apply.", error: true) }
        guard e.apply(s.text, over: s.range, in: e.current, named: "AI Change") else { return say("“\(name)” didn't take the change.", error: true) }
        e.revealed()
        e.window?.makeFirstResponder(e.textView)
        let at = NSRange(location: s.range.location, length: 0)
        e.textView.setSelectedRange(at)
        e.textView.scrollRangeToVisible(at)
        toggles.forEach { $0.isEnabled = false }
        buttons.forEach { $0.isEnabled = false }
        say("✓ Applied to the editor — ⌘Z undoes it; ⌘S saves.", error: false)
    }

    /// The proposal as a read-only copy beside the file, in the built-in Compare (a program of the user's has no Copy
    /// Change): what is kept goes over by Copy Change, one ⌘Z each.
    private func compare(_ e: Editor) {
        if let why = refusal(e) { return say(why, error: true) }
        let copy = Editor.snapshot((p.proposed, .utf8, false, false, false, nil, Editor.sha(Data(p.proposed.utf8))), file: name,
                                   title: "\(name) (proposed)", place: server.map(AISession.label) ?? "this Mac", from: (server, path))
        EditorHost.tabs.compare(old: e, new: copy, snapshots: [copy])
    }

    private func say(_ words: String, error: Bool) {
        said.stringValue = words
        said.textColor = error ? Palette.fail : .secondaryLabelColor
    }

    private static func line(_ s: String, _ color: NSColor) -> NSView {
        ChatText(NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color]))
    }
}
