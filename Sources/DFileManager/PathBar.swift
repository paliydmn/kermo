import AppKit
import DFMCore

/// A panel's path bar (R-22, §11 decisions 3 and 3a): a chip for the place — `Mac`, a server by its name with its
/// PROD / ROOT / LOCKED chips, an archive, search results — then the path as crumbs; on the right a kept filter,
/// "→ F5" and Copy. In a narrow panel the middle crumbs give way to "…", never the first. A click on a crumb goes
/// there (⌥: in the other panel), a file dropped on one is copied there; a click on an empty spot turns the bar into a
/// field with the plain path, as ⌘L does. The 2 pt line under it is the active panel's (`LinedStack`).
@MainActor
final class PathBar: LinedStack {
    /// A part of the path: its words, and where a click goes on the panel's side (a folder here or on the server, a
    /// folder inside an archive); nil: nowhere (search results' title).
    struct Crumb: Equatable {
        let title: String
        let path: String?
    }

    let field = NSTextField(string: "")
    private let placeIcon = NSImageView()
    private let placeName = NSTextField(labelWithString: "")
    private let placeChips = NSStackView()
    private let crumbRow = CrumbRow()
    private let filterChip = NSButton(title: "", target: nil, action: nil)
    let targetMark = NSImageView()
    private let copyButton = NSButton(title: "", target: nil, action: nil)
    private var copiedAt = 0

    var onCrumb: ((Crumb, NSEvent.ModifierFlags) -> Void)?
    var onEdit: (() -> Void)?
    /// The path to copy: plain, or (⌥) `user@host:path` on a server.
    var onCopy: ((_ scp: Bool) -> Void)?
    var onFilter: (() -> Void)?
    /// A drop on a crumb: what it would do there, and doing it.
    var validateDrop: ((Crumb, NSDraggingInfo) -> NSDragOperation)? {
        get { crumbRow.validateDrop }
        set { crumbRow.validateDrop = newValue }
    }
    var acceptDrop: ((Crumb, NSDraggingInfo) -> Bool)? {
        get { crumbRow.acceptDrop }
        set { crumbRow.acceptDrop = newValue }
    }

    init() {
        super.init(frame: .zero)
        spacing = 4
        edgeInsets = NSEdgeInsets(top: 0, left: 3, bottom: 4, right: 0)   // the line's room
        heightAnchor.constraint(equalToConstant: 24).isActive = true   // the crumbs' height, the field's too: the list doesn't jump
        placeIcon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        placeName.font = .systemFont(ofSize: 12, weight: .semibold)
        placeName.setContentCompressionResistancePriority(.init(700), for: .horizontal)
        placeChips.spacing = 3
        crumbRow.onClick = { [unowned self] in onCrumb?($0, $1) }
        crumbRow.setContentCompressionResistancePriority(.init(1), for: .horizontal)   // gives way first, to its "…"
        crumbRow.setContentHuggingPriority(.init(1), for: .horizontal)   // and takes the room: the right part at the end
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        field.lineBreakMode = .byTruncatingHead
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.isHidden = true
        filterChip.isBordered = false
        filterChip.target = self
        filterChip.action = #selector(filterClicked)
        filterChip.isHidden = true
        targetMark.toolTip = "F5 / F6 copy and move here"
        targetMark.setContentCompressionResistancePriority(.required, for: .horizontal)
        copyButton.isBordered = false
        copyButton.imagePosition = .imageLeading
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.refusesFirstResponder = true
        copyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [placeIcon, placeName, placeChips, crumbRow, field, filterChip, targetMark, copyButton] as [NSView] { addArrangedSubview(v) }
        setCustomSpacing(8, after: placeChips)
        showCopy(done: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The place: its symbol and name, a server's chips. `scp`: on a server, what ⌥-click on Copy gives. `copy`: there's
    /// a path to copy (a list of a server's isn't one: no button).
    func showPlace(_ symbol: Symbol?, _ name: String, chips: [Chip], scp: String?, copy: Bool = true) {
        copyButton.isHidden = !copy
        placeIcon.image = symbol?.image(name)
        placeIcon.isHidden = symbol == nil
        placeName.stringValue = name.bidiVisible
        placeName.isHidden = name.isEmpty
        placeChips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chips.forEach { placeChips.addArrangedSubview(NSImageView(image: $0.image)) }
        placeChips.isHidden = chips.isEmpty
        copyButton.toolTip = "Copy the path" + (scp.map { " — ⌥-click: \($0)" } ?? "")
        copyButton.setAccessibilityLabel("Copy path")
        copyButton.setAccessibilityCustomActions(scp == nil ? nil : [
            NSAccessibilityCustomAction(name: "Copy user@host:path") { [weak self] in self?.onCopy?(true); return true },
        ])
    }

    var crumbs: [Crumb] {
        get { crumbRow.crumbs }
        set { crumbRow.crumbs = newValue }
    }
    /// What the crumbs show now — "…" for those that gave way (tests).
    var shownCrumbs: [String] { crumbRow.shown }

    /// Active: in full contrast; else dimmed. `dim`: the theme's dimmed text, for the "›" between crumbs. A theme in a
    /// monospaced font gets its crumbs so.
    func style(text: NSColor, dim: NSColor, mono: Bool) {
        placeIcon.contentTintColor = text
        placeName.textColor = text
        field.textColor = text
        crumbRow.style(text: text, dim: dim, mono: mono)
    }

    /// A filter kept after ↩: its text as a chip (a click goes back to the filter field).
    var filter: String? {
        didSet {
            filterChip.isHidden = filter == nil
            guard let filter else { return }
            filterChip.attributedTitle = Chip.plain(filter, symbol: .filter)
            filterChip.toolTip = "Filtered by “\(filter)” — / to change, ⎋ there to clear"
            filterChip.setAccessibilityLabel("Filter: \(filter)")
        }
    }

    /// The field with the plain path in place of the crumbs (⌘L, a click on an empty spot); `false`: the crumbs back.
    var editing: Bool {
        get { !field.isHidden }
        set {
            field.isHidden = !newValue
            crumbRow.isHidden = newValue
            placeName.isHidden = newValue || placeName.stringValue.isEmpty
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !editing else { return super.mouseDown(with: event) }
        onEdit?()   // an empty spot: the crumbs and the buttons take their own clicks
    }

    @objc private func filterClicked() { onFilter?() }

    @objc private func copyClicked() {
        onCopy?(NSApp.currentEvent?.modifierFlags.contains(.option) == true)
        copied()
    }

    /// ✓ Copied for a second, without a sound or a dialog.
    func copied() {
        copiedAt += 1
        let n = copiedAt
        showCopy(done: true)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, n == copiedAt else { return }
            showCopy(done: false)
        }
    }
    var showsCopied: Bool { copyButton.title == "Copied" }   // tests

    private func showCopy(done: Bool) {
        copyButton.image = (done ? Symbol.check : Symbol.copy).image(done ? "Copied" : "Copy path", color: done ? Palette.ok : .secondaryLabelColor, size: 11)
        copyButton.attributedTitle = NSAttributedString(string: done ? "Copied" : "", attributes: [.foregroundColor: Palette.ok, .font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
    }

    /// Tests: a click on a crumb, as the mouse does it.
    func click(_ crumb: Int, _ mods: NSEvent.ModifierFlags = []) { crumbRow.onClick?(crumbs[crumb], mods) }
}

/// The crumbs, laid out by hand: as many as fit, the first always whole; the middle ones go into "…".
@MainActor
final class CrumbRow: NSView {
    var crumbs: [PathBar.Crumb] = [] { didSet { if crumbs != oldValue { rebuild() } } }
    var onClick: ((PathBar.Crumb, NSEvent.ModifierFlags) -> Void)?
    var validateDrop: ((PathBar.Crumb, NSDraggingInfo) -> NSDragOperation)?
    var acceptDrop: ((PathBar.Crumb, NSDraggingInfo) -> Bool)?
    private var buttons: [CrumbButton] = []
    private var separators: [NSTextField] = []
    private let more = NSTextField(labelWithString: "…")
    private(set) var shown: [String] = []
    private var text: NSColor = .labelColor
    private var dim: NSColor = .secondaryLabelColor
    private var font = NSFont.systemFont(ofSize: 12.5)
    private static let gap: CGFloat = 2

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 20) }
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        addSubview(more)
    }
    required init?(coder: NSCoder) { fatalError() }

    func style(text: NSColor, dim: NSColor, mono: Bool) {
        self.text = text
        self.dim = dim
        font = mono ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12.5)
        rebuild()
    }

    private func rebuild() {
        (buttons as [NSView] + separators).forEach { $0.removeFromSuperview() }
        buttons = crumbs.enumerated().map { i, c in
            let b = CrumbButton(c, text: text, font: font, last: i == crumbs.count - 1)
            b.target = self
            b.action = #selector(clicked(_:))
            b.row = self
            addSubview(b)
            return b
        }
        separators = crumbs.dropFirst().map { _ in
            let s = NSTextField(labelWithString: "›")
            s.font = font
            s.textColor = dim
            addSubview(s)
            return s
        }
        more.font = font
        more.textColor = text
        needsLayout = true
    }

    /// Which crumbs show in `room`: all, else the first, "…" (nil) and as many of the last as fit — at least the last,
    /// which is cut at its end if even that doesn't fit. The start never goes.
    static func fit(_ widths: [CGFloat], separator: CGFloat, ellipsis: CGFloat, room: CGFloat) -> [Int?] {
        func width(_ shown: [Int?]) -> CGFloat {
            shown.map { $0.map { widths[$0] } ?? ellipsis }.reduce(0, +) + CGFloat(max(shown.count - 1, 0)) * separator
        }
        let all = Array(widths.indices).map { Optional($0) }
        guard widths.count > 2, width(all) > room else { return all }
        for dropped in 1...(widths.count - 2) {
            let shown: [Int?] = [0, nil] + (dropped + 1..<widths.count).map { Optional($0) }
            if width(shown) <= room { return shown }
        }
        return [0, nil, widths.count - 1]
    }

    override func layout() {
        super.layout()
        let sepWidth = (separators.first?.fittingSize.width ?? 8) + 2 * Self.gap
        let widths = buttons.map { ceil($0.fittingSize.width) }
        let shown = Self.fit(widths, separator: sepWidth, ellipsis: more.fittingSize.width, room: bounds.width)
        (buttons as [NSView] + separators + [more]).forEach { $0.isHidden = true }
        var x: CGFloat = 0
        for (n, i) in shown.enumerated() {
            if n > 0, let s = separators.first(where: { $0.isHidden }) {
                s.isHidden = false
                s.frame = NSRect(x: x + Self.gap, y: (bounds.height - s.fittingSize.height) / 2, width: s.fittingSize.width, height: s.fittingSize.height)
                x += sepWidth
            }
            let v: NSView = i.map { buttons[$0] } ?? more
            v.isHidden = false
            let w = min(i.map { widths[$0] } ?? more.fittingSize.width, max(bounds.width - x, 0))
            v.frame = NSRect(x: x, y: (bounds.height - v.fittingSize.height) / 2, width: w, height: v.fittingSize.height)
            x += w
        }
        self.shown = shown.map { $0.map { crumbs[$0].title } ?? "…" }
    }

    @objc private func clicked(_ sender: CrumbButton) {
        onClick?(sender.crumb, NSApp.currentEvent?.modifierFlags.intersection(.option) ?? [])
    }
}

/// One crumb: a borderless button, lit under the mouse and while a file is dragged over it.
@MainActor
final class CrumbButton: NSButton {
    let crumb: PathBar.Crumb
    weak var row: CrumbRow?
    private var lit = false { didSet { if lit != oldValue { needsDisplay = true } } }

    init(_ crumb: PathBar.Crumb, text: NSColor, font: NSFont, last: Bool) {
        self.crumb = crumb
        super.init(frame: .zero)
        isBordered = false
        refusesFirstResponder = true
        let f = last ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
        attributedTitle = NSAttributedString(string: crumb.title.bidiVisible, attributes: [.font: f, .foregroundColor: text])
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        isEnabled = crumb.path != nil
        if let p = crumb.path {
            toolTip = p
            setAccessibilityLabel("Go to \(p)")
            registerForDraggedTypes([.fileURL, TransferItems.remoteType])
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(attributedTitle.size().width) + 8, height: 18) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { lit = isEnabled }
    override func mouseExited(with event: NSEvent) { lit = false }

    override func draw(_ dirtyRect: NSRect) {
        if lit {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        let t = attributedTitle, h = t.size().height
        t.draw(with: NSRect(x: 4, y: (bounds.height - h) / 2, width: bounds.width - 8, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = row?.validateDrop?(crumb, sender) ?? []
        lit = !op.isEmpty
        return op
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { row?.validateDrop?(crumb, sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { lit = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        lit = false
        return row?.acceptDrop?(crumb, sender) ?? false
    }
}
