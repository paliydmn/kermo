import AppKit
import DFMCore

/// Fuzzy "type to choose" popup (command palette, folder jump, user menu).
/// ↑↓ move, ↩ runs, ⎋ or clicking elsewhere closes.
@MainActor
final class Picker: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        var title: String
        var subtitle = ""
        var detail = ""
        var edit: (@MainActor () -> Void)? = nil   // ⌘E on the highlighted row
        var keys: [Shortcut: @MainActor () -> Void] = [:]   // more keys on the highlighted row (F3, ⌘⇧D…); the picker closes first
        var preview: (@MainActor () -> Void)? = nil   // the row got highlighted
        var id = ""   // what `update` finds it by, and what stays highlighted when its row changes
        var subtitleColor: NSColor? = nil   // a state that must show whatever the highlight (a failed service: red)
        var busy = false   // a spinner after the subtitle: something runs on it
        var keepsOpen: Set<Shortcut> = []   // of `keys` (⌘E too): run with the picker staying open
        var menu: (@MainActor () -> NSMenu?)? = nil   // its context menu: right-click, ⌃-click, ⌃↩ or ⇧F10
        var run: @MainActor () -> Void
    }

    private(set) static var current: Picker?
    let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                 styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    private let field = NSTextField()
    private let table = PickerTable()
    private var items: [Item]
    private var shown: [Item] = []
    private let rank: (Item, String) -> Int?
    private let freeText: ((String) -> [Item])?
    private let freeTextLast: Bool
    private let selected: Int
    private var selectID: String?
    private var onDismiss: (@MainActor () -> Void)?
    private let onClose: (@MainActor (_ query: String, _ id: String?) -> Void)?
    private weak var parent: NSWindow?
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let output = NSButton(title: "Output…", target: nil, action: nil)
    private var showOutput: MenuAction?
    private var holds = 0

    /// `rank` scores an item against the query (nil = hide); default fuzzy-matches title + subtitle.
    /// Ties keep the given order, so pass items best-first.
    /// `freeText` turns whatever was typed into extra first rows (e.g. "Connect to “user@host”"); `freeTextLast`: after
    /// the matches instead, so ↩ takes a match (Switch Branch: "conf" switches to a branch, not creates "conf").
    /// `selected`: the row highlighted while nothing is typed. `onDismiss`: closed without choosing.
    /// `query` and `select` (an item's `id`): what was typed and highlighted when it was last open; `onClose` gets them
    /// as it closes, either way. `highlight`: the highlighted row's color, in place of the system's.
    @discardableResult
    static func show(over window: NSWindow, placeholder: String, items: [Item], rank: ((Item, String) -> Int?)? = nil,
                     freeText: ((String) -> [Item])? = nil, freeTextLast: Bool = false, selected: Int = 0,
                     query: String = "", select: String? = nil, highlight: NSColor? = nil,
                     onDismiss: (@MainActor () -> Void)? = nil, onClose: (@MainActor (String, String?) -> Void)? = nil) -> Picker {
        current?.close()
        let p = Picker(parent: window, placeholder: placeholder, items: items,
                       rank: rank ?? { item, q in Fuzzy.score(q, item.title + " " + item.subtitle) }, freeText: freeText,
                       freeTextLast: freeTextLast, selected: selected, query: query, select: select, highlight: highlight,
                       onDismiss: onDismiss, onClose: onClose)
        current = p
        p.present()
        return p
    }

    /// Closes the one showing, as ⎋ does (its `onDismiss` runs): one shown while something loads, which failed.
    static func dismiss() { current?.close() }

    private init(parent: NSWindow, placeholder: String, items: [Item], rank: @escaping (Item, String) -> Int?,
                 freeText: ((String) -> [Item])?, freeTextLast: Bool, selected: Int, query: String, select: String?,
                 highlight: NSColor?, onDismiss: (@MainActor () -> Void)?, onClose: (@MainActor (String, String?) -> Void)?) {
        self.parent = parent
        self.items = items
        self.rank = rank
        self.freeText = freeText
        self.freeTextLast = freeTextLast
        self.selected = selected
        self.selectID = select
        self.onDismiss = onDismiss
        self.onClose = onClose
        self.highlight = highlight
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.delegate = self
        panel.onKey = { [unowned self] e in
            let key = Shortcut(event: e)   // the physical key: ⌘E is "у" on a Ukrainian layout
            guard let row = highlighted else { return false }
            if Self.menuKeys.contains(key), row.menu != nil { return popUpMenu() }
            guard let run = row.keys[key] ?? (key == Shortcut("cmd+e") ? row.edit : nil) else { return false }
            if row.keepsOpen.contains(key) {
                run()
                return true
            }
            self.onDismiss = nil
            close()
            DispatchQueue.main.async { run() }
            return true
        }

        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 16)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self

        let col = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 26
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(choose)
        table.menuFor = { [unowned self] row in
            guard shown.indices.contains(row), let menu = shown[row].menu else { return nil }   // an empty spot: none
            table.selectRowIndexes([row], byExtendingSelection: false)   // what it acts on is what's highlighted
            return menu()
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.backgroundColor = .clear

        footer.font = .systemFont(ofSize: 12)
        footer.maximumNumberOfLines = 3
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        output.bezelStyle = .inline
        output.controlSize = .small
        let bottom = NSStackView(views: [footer, output])   // hidden till something is said there
        bottom.alignment = .firstBaseline
        bottom.isHidden = true
        let bg = NSVisualEffectView()
        bg.material = .popover
        for v in [field, scroll, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: bg.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -4),
            bottom.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            bottom.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            bottom.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -8),
        ])
        bottomRow = bottom
        panel.contentView = bg
        field.stringValue = query
        filter()
    }

    private let highlight: NSColor?
    private var bottomRow: NSStackView?

    // MARK: - What a picker that stays open does

    /// The keys that open a row's menu: ⌃↩, and ⇧F10 and the Menu key of a PC keyboard.
    static let menuKeys: Set<Shortcut> = [Shortcut("ctrl+return")!, Shortcut("shift+f10")!, Shortcut("menu")!]

    /// The row whose `id` is `item`'s gets it — the highlight, what's typed and the scroll stay as they are.
    func update(_ item: Item) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        guard let r = shown.firstIndex(where: { $0.id == item.id }) else { return }
        shown[r] = item
        table.reloadData(forRowIndexes: [r], columnIndexes: [0])
    }

    func has(_ id: String) -> Bool { items.contains { $0.id == id } }

    /// A line under the rows that stays till the next one, or the picker's end; nil takes it away. `output`: a
    /// button that shows more (a command's whole output).
    func say(_ text: NSAttributedString?, output show: (@MainActor () -> Void)? = nil) {
        footer.attributedStringValue = text ?? NSAttributedString()
        bottomRow?.isHidden = text == nil
        output.isHidden = show == nil
        showOutput = show.map { MenuAction.attach(to: output, $0) }
        if let text { NSAccessibility.post(element: panel, notification: .announcementRequested,
                                           userInfo: [.announcement: text.string, .priority: NSAccessibilityPriorityLevel.high.rawValue]) }
    }

    var said: String { bottomRow?.isHidden == false ? footer.stringValue : "" }
    var rows: [Item] { shown }   // what's listed now, as typing filtered it
    var highlighted: Item? { shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : nil }

    /// The panel the picker is in: a sheet asking about its row goes there, and the picker stays.
    var window: NSWindow { panel }

    /// Runs `work` — one that may ask (Touch ID, a question, a password): the picker stays open while something
    /// of the app's or the system's asks, and closes when the user turns to another of the app's windows, as ever.
    func holding<T>(_ work: () async -> T) async -> T {
        holds += 1
        defer {
            holds -= 1
            if holds == 0, Self.current === self, NSApp.isActive, NSApp.keyWindow == nil { panel.makeKey() }
        }
        return await work()
    }

    var isHolding: Bool { holds > 0 }

    private func present() {
        guard let parent else { return }
        let f = parent.frame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - 70 - panel.frame.height))
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func close() {
        guard Self.current === self || panel.isVisible else { return }   // once
        panel.delegate = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKeyAndOrderFront(nil)
        if Self.current === self { Self.current = nil }
        onClose?(field.stringValue, highlighted?.id)
        onDismiss?()
    }

    /// The highlighted row's menu, under it: ⎋ closes it, and typing goes on in the field.
    private func popUpMenu() -> Bool {
        let r = table.selectedRow
        guard shown.indices.contains(r), let menu = shown[r].menu?() else { return false }
        table.scrollRowToVisible(r)
        let rect = table.rect(ofRow: r)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX + 24, y: rect.maxY), in: table)
        return true
    }

    @objc private func choose() {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard shown.indices.contains(r) else { return NSSound.beep() }
        let item = shown[r]
        onDismiss = nil
        close()
        DispatchQueue.main.async { item.run() }   // after focus is back on the main window
    }

    private func filter() {
        let q = field.stringValue
        var first = 0
        if q.trimmingCharacters(in: .whitespaces).isEmpty {
            shown = Array(items.prefix(300))
            if shown.indices.contains(selected) { first = selected }
            if let id = selectID, let at = shown.firstIndex(where: { $0.id == id }) { first = at }
        } else {
            shown = items.enumerated()
                .compactMap { i, it in rank(it, q).map { (score: $0, i: i, it: it) } }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.i < $1.i }
                .prefix(300).map(\.it)
            let extra = freeText?(q.trimmingCharacters(in: .whitespaces)) ?? []
            if freeTextLast { shown += extra } else { shown.insert(contentsOf: extra, at: 0) }
            if let id = selectID, let at = shown.firstIndex(where: { $0.id == id }) { first = at }
        }
        selectID = nil   // only as it opens: typing then highlights the best match
        table.reloadData()
        if !shown.isEmpty {
            table.selectRowIndexes([first], byExtendingSelection: false)
            table.scrollRowToVisible(first)
        }
    }

    // MARK: - Delegates

    func windowDidResignKey(_ notification: Notification) {
        guard holds > 0 else { return close() }
        // Who took the key isn't settled yet: Touch ID or ssh's password (another app: none of ours) or a sheet on
        // this panel keep it; the main window, clicked, closes it.
        DispatchQueue.main.async { [weak self] in
            guard let self, Self.current === self, !panel.isKeyWindow else { return }
            if let key = NSApp.keyWindow, key.sheetParent !== panel { close() }
        }
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let r = table.selectedRow + (sel == #selector(NSResponder.moveDown(_:)) ? 1 : -1)
            if shown.indices.contains(r) {
                table.selectRowIndexes([r], byExtendingSelection: false)
                table.scrollRowToVisible(r)
            }
        case #selector(NSResponder.insertNewline(_:)): choose()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if shown.indices.contains(table.selectedRow) { shown[table.selectedRow].preview?() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? PickerCell ?? PickerCell()
        let it = shown[row]
        cell.show(title: it.title, subtitle: it.subtitle, detail: it.detail, subtitleColor: it.subtitleColor, busy: it.busy)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        highlight.map { color in tableView.makeView(withIdentifier: .init("row"), owner: nil) as? HighlightRow ?? HighlightRow(color) }
    }
}

/// The table of a picker: a row's context menu, after it's highlighted.
final class PickerTable: NSTableView {
    var menuFor: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        menuFor?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

/// A highlighted row in a color of its own: a light fill with an outline — the shape tells it too, not the color
/// alone — whose text stays as it is (a failed state's red stays red). Stronger with Increase Contrast.
final class HighlightRow: NSTableRowView {
    private let color: NSColor
    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        identifier = .init("row")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }   // dark text on the light fill
    override func drawSelection(in dirtyRect: NSRect) {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1.5), xRadius: 5, yRadius: 5)
        color.withAlphaComponent(contrast ? 0.35 : dark ? 0.26 : 0.18).setFill()
        shape.fill()
        color.withAlphaComponent(contrast ? 1 : 0.7).setStroke()
        shape.lineWidth = contrast ? 2 : 1
        shape.stroke()
    }
}

/// Borderless-looking panels must opt in to becoming key to receive typing.
final class KeyPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?   // a row's keys (⌘E, F3), before the main menu and the text field see them
    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { onKey?(event) == true || super.performKeyEquivalent(with: event) }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }   // F3 and the like: not always a key equivalent
        super.sendEvent(event)
    }
}

/// Title, dimmed subtitle, right-aligned detail (keys). Also the toolbar search's rows.
final class PickerCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let remove = NSButton()   // hidden unless the row can be taken out of a list (the search's Recent)
    let spinner = NSProgressIndicator()   // hidden unless something runs on the row

    init() {
        super.init(frame: .zero)
        identifier = .init("cell")
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 12)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove")
        remove.isBordered = false
        remove.contentTintColor = .tertiaryLabelColor
        remove.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let end = NSStackView(views: [spinner, detail, remove])   // a hidden ✕ takes no room
        end.spacing = 6
        for v in [title, end] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            end.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            end.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            end.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(title t: String, subtitle: String, detail d: String, subtitleColor: NSColor? = nil, busy: Bool = false) {
        let s = NSMutableAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        if !subtitle.isEmpty {
            s.append(NSAttributedString(string: "   " + subtitle, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: subtitleColor ?? NSColor.secondaryLabelColor]))
        }
        title.attributedStringValue = s
        detail.stringValue = d
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}
