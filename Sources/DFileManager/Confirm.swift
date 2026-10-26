import AppKit
import DFMCore

/// A question before something that changes things (R-54, research §5.8), one anatomy for all of them: the title says
/// the verb and the target; a strip says production or root in its chip's color; then what exactly (up to five, "and
/// N more"), how it runs and the command as it runs (mono), what follows in one sentence. On production and for what
/// can't be undone ↩ is Cancel and the action ⌘↩, and a line of keys says so. The action is named by what it does, red
/// only when it can't be undone. Built here (`alert`), shown by `AppDelegate.confirm`.
struct Confirm {
    struct Item {
        var name: String
        var symbol: Symbol? = nil
        var size = ""
    }

    var title: String
    /// The strip's chips (production, root; a lock isn't shown) and the place they're about: "web-01", "this Mac".
    var chips: [Chip] = []
    var place = ""
    var items: [Item] = []
    /// How it runs, over the command: "Runs on web-01 as root, through the server's sudo."
    var runs: String? = nil
    /// Exactly what runs, as it runs; several lines too (a script that goes on stdin).
    var command: String? = nil
    /// What follows, one sentence: "A server has no Trash. This can't be undone."
    var note: String? = nil
    /// One more control under the note (none yet; Tools' "Don't ask again for 10 minutes").
    var extra: NSView? = nil
    var action: String
    /// Buttons between the action and Cancel: "Compare".
    var others: [String] = []
    /// The button that does nothing: "Keep Mine" where that's what nothing means.
    var cancel = "Cancel"
    var irreversible = false
    /// ↩ is Cancel even where nothing says so (a Stop, asked first everywhere).
    var returnCancels = false

    var buttons: [String] { [action] + others + [cancel] }
    var strip: [Chip] { chips.filter { $0 != .locked } }
    /// ↩ answers Cancel, the action takes ⌘↩: production, or what can't be undone.
    var safe: Bool { returnCancels || irreversible || strip.contains(.prod) }

    static let width: CGFloat = 360
    static let listed = 5

    /// For a server: its chips and the name it goes by.
    @MainActor init(_ title: String, on t: SFTPTarget? = nil, action: String) {
        self.title = title
        self.action = action
        if let t { on([t]) }
    }

    /// The strip for servers: their chips, their names ("db-01 and web-01").
    @MainActor mutating func on(_ targets: [SFTPTarget]) {
        let all = targets.map { Chip.of($0) }
        chips = Chip.allCases.filter { c in all.contains { $0.contains(c) } }
        place = targets.map { SavedServer.name(for: $0.asUser) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " and ")
    }

    /// The alert, its buttons in `buttons`' order (on screen: the action rightmost or on top, Cancel left or at the
    /// bottom), everything under the title in its accessory view.
    @MainActor func alert() -> NSAlert {
        let a = NSAlert()
        a.messageText = title.bidiVisible
        a.alertStyle = .warning
        buttons.forEach { a.addButton(withTitle: $0) }
        a.buttons[0].hasDestructiveAction = irreversible
        if safe {
            a.buttons.forEach { $0.keyEquivalent = "" }
            a.buttons.last!.keyEquivalent = "\r"   // ⎋ too: `AppDelegate.sheet`
            a.buttons[0].keyEquivalent = "\r"
            a.buttons[0].keyEquivalentModifierMask = .command
        }
        a.accessoryView = accessory()
        return a
    }

    @MainActor private func accessory() -> NSView? {
        var views: [NSView] = []
        if let s = Self.strip(strip, place) { views.append(s) }
        if !items.isEmpty { views.append(Self.list(items)) }
        if let runs { views.append(Self.label(runs, color: .secondaryLabelColor, size: 11)) }
        if let command { views.append(Self.commandBox(command)) }
        if let note { views.append(Self.label(note)) }
        if let extra { views.append(extra) }
        if safe { views.append(keys()) }
        return views.isEmpty ? nil : Self.stack(views)
    }

    /// "↩ Cancel · ⌘↩ Delete", in the key bar's caps.
    @MainActor private func keys() -> NSView {
        let font = NSFont.systemFont(ofSize: 11)
        let s = NSMutableAttributedString()
        let word = { (w: String) in NSAttributedString(string: " " + w, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]) }
        s.append(KeyCap.text("↩", font: font)); s.append(word(cancel))
        s.append(word("  ·  "))
        s.append(KeyCap.text("⌘↩", font: font)); s.append(word(action.replacingOccurrences(of: "…", with: "")))
        let l = NSTextField(labelWithAttributedString: s)
        l.setAccessibilityLabel("Return: \(cancel); Command-Return: \(action)")
        return l
    }

    // MARK: - Parts, for other sheets too (a prompt's strip and list)

    /// The views one under another, `width` wide, sized to fit (NSAlert takes the frame).
    @MainActor static func stack(_ views: [NSView], width: CGFloat = width) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for v in views { v.widthAnchor.constraint(equalToConstant: width).isActive = true }
        stack.setFrameSize(NSSize(width: width, height: stack.fittingSize.height))
        return stack
    }

    /// Production or root, in its color: "[PROD] web-01 — production server". nil for neither.
    @MainActor static func strip(_ chips: [Chip], _ place: String) -> NSView? {
        let chips = chips.filter { $0 != .locked }
        guard let tint = Chip.tint(chips) else { return nil }
        let says = [chips.contains(.prod) ? "production server" : nil, chips.contains(.root) ? "as root" : nil].compactMap { $0 }.joined(separator: ", ")
        let text = NSMutableAttributedString(attributedString: Chip.text(chips)!)
        text.append(NSAttributedString(string: "  " + place.bidiVisible, attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: " — " + says, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.setAccessibilityLabel(chips.map(\.spoken).joined(separator: ", ") + ": " + place)
        return TintBox(label, fill: tint.withAlphaComponent(0.13), inset: NSSize(width: 8, height: 5))
    }

    /// Up to `listed` rows — mark, name, size if known — then "and N more".
    @MainActor static func list(_ items: [Item]) -> NSView {
        var rows: [NSView] = items.prefix(listed).map { it in
            let name = NSTextField(labelWithString: it.name.bidiVisible)
            name.lineBreakMode = .byTruncatingMiddle
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let size = NSTextField(labelWithString: it.size)
            size.textColor = .secondaryLabelColor
            size.setContentHuggingPriority(.required, for: .horizontal)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let mark = it.symbol.map { NSImageView(image: $0.image(nil, color: .secondaryLabelColor, size: 12)) }
            mark?.widthAnchor.constraint(equalToConstant: 16).isActive = true   // a folder's mark is wider than a file's
            let row = NSStackView(views: [mark, name, spacer, size].compactMap { $0 })
            row.spacing = 6
            return row
        }
        if items.count > listed { rows.append(label("and \(items.count - listed) more", color: .secondaryLabelColor)) }
        let list = NSStackView(views: rows)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 3
        for r in rows { r.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        return list
    }

    /// The command as it runs: mono, selectable, wrapped; a long one scrolls past 8 lines.
    @MainActor static func commandBox(_ command: String) -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), inset = NSSize(width: 8, height: 6), fill = NSColor.labelColor.withAlphaComponent(0.08)
        let text = NSTextField(wrappingLabelWithString: command)
        text.font = font
        text.isSelectable = true
        text.preferredMaxLayoutWidth = width - 2 * inset.width
        text.setAccessibilityLabel("Command: " + command)
        let line = NSLayoutManager().defaultLineHeight(for: font)
        guard text.fittingSize.height > 8 * line + 1 else { return TintBox(text, fill: fill, inset: inset) }
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.string = command
        view.font = font
        view.isEditable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.setAccessibilityLabel("Command")
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(equalToConstant: 8 * line).isActive = true
        return TintBox(scroll, fill: fill, inset: inset)
    }

    @MainActor static func label(_ s: String, color: NSColor = .labelColor, size: CGFloat = 12) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s.bidiVisible)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.preferredMaxLayoutWidth = width
        return l
    }
}

/// A rounded, tinted box around one view, held by constraints: an NSBox doesn't size to what's in it under Auto Layout
/// (NSAlert's accessory). Drawn each time, so its color follows light and dark.
final class TintBox: NSView {
    private let fill: NSColor
    init(_ content: NSView, fill: NSColor, inset: NSSize) {
        self.fill = fill
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.width),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.width),
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset.height),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset.height),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}
