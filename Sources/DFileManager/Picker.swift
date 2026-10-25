import AppKit
import DFMCore

/// Fuzzy "type to choose" popup (folder jump, user menu, a server's services…): the field — after where its list is
/// ("web-01 ›") — then a line about the list, the rows, a line saying how the last action went, and the highlighted
/// row's keys along the bottom ("↩ Status  ⌘L Live Logs  ⌃↩ Actions  ⎋ Close"), each a click away.
/// ↑↓ move, ↩ runs, ⎋ or clicking elsewhere closes.
@MainActor
final class Picker: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        /// A key of the highlighted row besides ↩, its word on the action bar beside it (none: it works, without a
        /// slot — F3 where ↩ views too). The picker closes first, unless it `keepsOpen`.
        struct Action {
            let key: Shortcut
            let label: String
            var keepsOpen = false
            let run: @MainActor () -> Void
        }
        var title: String
        var subtitle = ""
        var badges: [NSImage] = []   // before the title: a server's chips (`Chip`), a symbol (a tag, a favorite)
        var detail = ""
        var actions: [Action] = []   // the action bar's order
        var verb = "Open"   // what ↩ does, on the action bar
        var preview: (@MainActor () -> Void)? = nil   // the row got highlighted
        var id = ""   // what `update` finds it by, and what stays highlighted when its row changes
        var subtitleColor: NSColor? = nil   // a state that must show whatever the highlight (a failed service: red)
        var busy = false   // a spinner after the subtitle: something runs on it
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
    private let header = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let emptyText: String
    private let bar = KeyBarView(chips: false)
    private let hints: [KeySlot]

    /// `rank` scores an item against the query (nil = hide); default fuzzy-matches title + subtitle.
    /// Ties keep the given order, so pass items best-first.
    /// `freeText` turns whatever was typed into extra first rows (e.g. "Connect to “user@host”"); `freeTextLast`: after
    /// the matches instead, so ↩ takes a match (Switch Branch: "conf" switches to a branch, not creates "conf").
    /// `selected`: the row highlighted while nothing is typed. `onDismiss`: closed without choosing.
    /// `query` and `select` (an item's `id`): what was typed and highlighted when it was last open; `onClose` gets them
    /// as it closes, either way. `placeholder`: what to type, no keys. `scope`: where the list is, a chip before the
    /// field ("web-01 ›", in its place's color). `header`: what's known about the whole list ("52 units · 1 failed").
    /// `empty`: said when there's nothing at all (else "Nothing here"; "No matches" when typing hid every row).
    /// `hints`: keys to know that aren't a row's (the user menu's %f), on the action bar before ⎋.
    @discardableResult
    static func show(over window: NSWindow, placeholder: String, scope: (name: String, chips: [Chip])? = nil, header: String? = nil,
                     empty: String = "Nothing here", hints: [KeySlot] = [], items: [Item], rank: ((Item, String) -> Int?)? = nil,
                     freeText: ((String) -> [Item])? = nil, freeTextLast: Bool = false, selected: Int = 0,
                     query: String = "", select: String? = nil,
                     onDismiss: (@MainActor () -> Void)? = nil, onClose: (@MainActor (String, String?) -> Void)? = nil) -> Picker {
        current?.close()
        let p = Picker(parent: window, placeholder: placeholder, scope: scope, header: header, empty: empty, hints: hints, items: items,
                       rank: rank ?? { item, q in Fuzzy.score(q, item.title + " " + item.subtitle) }, freeText: freeText,
                       freeTextLast: freeTextLast, selected: selected, query: query, select: select,
                       onDismiss: onDismiss, onClose: onClose)
        current = p
        p.present()
        return p
    }

    /// Closes the one showing, as ⎋ does (its `onDismiss` runs): one shown while something loads, which failed.
    static func dismiss() { current?.close() }

    private init(parent: NSWindow, placeholder: String, scope: (name: String, chips: [Chip])?, header: String?, empty: String, hints: [KeySlot],
                 items: [Item], rank: @escaping (Item, String) -> Int?, freeText: ((String) -> [Item])?, freeTextLast: Bool, selected: Int,
                 query: String, select: String?, onDismiss: (@MainActor () -> Void)?, onClose: (@MainActor (String, String?) -> Void)?) {
        self.parent = parent
        self.items = items
        self.rank = rank
        self.freeText = freeText
        self.freeTextLast = freeTextLast
        self.selected = selected
        self.selectID = select
        self.onDismiss = onDismiss
        self.onClose = onClose
        self.emptyText = empty
        self.hints = hints
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
            guard let a = row.actions.first(where: { $0.key == key }) else { return false }
            perform(a)
            return true
        }
        bar.keep = ["return", "menu", "esc"]   // a narrow picker keeps ↩, ⌃↩ and ⎋ in sight
        bar.onRun = { [unowned self] id in   // a slot's click: what its key does
            switch id {
            case "return": choose()
            case "esc": close()
            case "menu": _ = popUpMenu()
            default: if let i = Int(id), let a = highlighted?.actions, a.indices.contains(i) { perform(a[i]) }
            }
        }

        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 16)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        let top = NSStackView(views: (scope.map { [ScopeChip($0.name, chips: $0.chips)] } ?? []) + [field])
        top.spacing = 6
        self.header.stringValue = header ?? ""
        self.header.font = .systemFont(ofSize: 11.5)
        self.header.textColor = .secondaryLabelColor
        self.header.isHidden = header == nil
        self.header.alignment = .left
        let head = NSStackView(views: [top, self.header])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 6
        top.widthAnchor.constraint(equalTo: head.widthAnchor).isActive = true
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

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
        for v in [head, scroll, emptyLabel, bottom, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(v)
        }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: bg.topAnchor, constant: 14),
            head.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            head.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -4),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -24),
            bottom.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            bottom.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            bottom.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: bottom.bottomAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 2),
            bar.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -2),
            bar.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -2),
        ])
        bottomRow = bottom
        panel.contentView = bg
        field.stringValue = query
        filter()
    }

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
        if r == table.selectedRow { updateBar() }   // its keys may have changed (a run started on it)
    }

    func has(_ id: String) -> Bool { items.contains { $0.id == id } }

    /// A line under the rows that stays till the next one, or the picker's end; nil takes it away. `output`: a
    /// button that shows more (a command's whole output).
    func say(_ text: NSAttributedString?, output show: (@MainActor () -> Void)? = nil) {
        footer.attributedStringValue = text ?? NSAttributedString()
        bottomRow?.isHidden = text == nil
        if items.isEmpty { emptyLabel.isHidden = text != nil }   // "Looking at…" gives way to why it didn't
        output.isHidden = show == nil
        showOutput = show.map { MenuAction.attach(to: output, $0) }
        if let text { NSAccessibility.post(element: panel, notification: .announcementRequested,
                                           userInfo: [.announcement: text.string, .priority: NSAccessibilityPriorityLevel.high.rawValue]) }
    }

    var said: String { bottomRow?.isHidden == false ? footer.stringValue : "" }
    /// What the action bar offers now, the highlighted row's keys first; and what's said where there are no rows.
    var actionBar: [KeySlot] { bar.list ?? [] }
    var panelBarShown: [KeySlot] { bar.shownSlots }   // tests: what fits, the rest under "+N"
    var emptySaid: String { emptyLabel.isHidden ? "" : emptyLabel.stringValue }
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

    /// A row's key, pressed or its slot clicked.
    private func perform(_ a: Item.Action) {
        if a.keepsOpen { return a.run() }
        onDismiss = nil
        close()
        DispatchQueue.main.async { a.run() }
    }

    /// ↩ and the highlighted row's keys, its menu if it has one, the picker's hints, ⎋.
    private func updateBar() {
        var slots: [KeySlot] = []
        if let row = highlighted {
            slots.append(KeySlot(key: "↩", label: row.verb, id: "return"))
            slots += row.actions.enumerated().filter { !$0.element.label.isEmpty }.map { KeySlot(key: $0.element.key.display, label: $0.element.label, id: "\($0.offset)") }
            if row.menu != nil { slots.append(KeySlot(key: "⌃↩", label: "Actions", id: "menu")) }
        }
        bar.list = slots + hints + [KeySlot(key: "⎋", label: "Close", id: "esc")]
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
        emptyLabel.stringValue = items.isEmpty ? emptyText : "No matches"
        emptyLabel.isHidden = !shown.isEmpty
        updateBar()
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
        updateBar()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? PickerCell ?? PickerCell()
        let it = shown[row]
        cell.show(title: it.title, subtitle: it.subtitle, detail: it.detail, subtitleColor: it.subtitleColor, busy: it.busy, badges: it.badges)
        return cell
    }

}

/// The table of a picker: a row's context menu, after it's highlighted.
final class PickerTable: NSTableView {
    var menuFor: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        menuFor?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

/// "web-01 ›" before a Picker's field: where its list is, in that place's color (production's purple, root's orange),
/// its chips after the name — the word, not the color alone.
final class ScopeChip: NSView {
    private let text: NSAttributedString
    private let color: NSColor

    init(_ name: String, chips: [Chip]) {
        color = Chip.tint(chips) ?? .labelColor   // secondary text all but goes on the popover
        let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let t = NSMutableAttributedString(string: name.bidiVisible + " ", attributes: [.font: font, .foregroundColor: color])
        for c in chips { t.append(c.text); t.append(NSAttributedString(string: " ")) }
        t.append(NSAttributedString(string: "›", attributes: [.font: font, .foregroundColor: color]))
        text = t
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(([name] + chips.map(\.spoken)).joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(text.size().width) + 16, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        text.draw(at: NSPoint(x: 8, y: (bounds.height - text.size().height) / 2))
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

/// Badges, title, dimmed subtitle, right-aligned detail (keys). Also the toolbar search's rows.
final class PickerCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    private let lead = NSStackView()   // the badges, then the title
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
        remove.image = Symbol.remove.image("Remove")
        remove.isBordered = false
        remove.contentTintColor = .tertiaryLabelColor
        remove.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let end = NSStackView(views: [spinner, detail, remove])   // a hidden ✕ takes no room
        end.spacing = 6
        lead.spacing = 4
        lead.addArrangedSubview(title)
        for v in [lead, end] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            lead.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            lead.centerYAnchor.constraint(equalTo: centerYAnchor),
            end.leadingAnchor.constraint(greaterThanOrEqualTo: lead.trailingAnchor, constant: 12),
            end.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            end.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(title t: String, subtitle: String, detail d: String, subtitleColor: NSColor? = nil, busy: Bool = false, badges: [NSImage] = []) {
        lead.arrangedSubviews.dropLast().forEach { $0.removeFromSuperview() }
        for (i, b) in badges.enumerated() { lead.insertArrangedSubview(NSImageView(image: b), at: i) }
        texts = (t, subtitle, subtitleColor)
        paint()
        detail.stringValue = d
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private var texts: (title: String, subtitle: String, color: NSColor?) = ("", "", nil)
    override var backgroundStyle: NSView.BackgroundStyle { didSet { paint() } }

    /// On the system's highlight all of it in its text color — a failed state's red too (its ◆ still says so).
    private func paint() {
        let on = backgroundStyle == .emphasized, white = NSColor.alternateSelectedControlTextColor
        let s = NSMutableAttributedString(string: texts.title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: on ? white : .labelColor])
        if !texts.subtitle.isEmpty {
            s.append(NSAttributedString(string: "   " + texts.subtitle, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: on ? white.withAlphaComponent(0.8) : texts.color ?? NSColor.secondaryLabelColor]))
        }
        title.attributedStringValue = s
        detail.textColor = on ? white.withAlphaComponent(0.8) : .secondaryLabelColor
    }
}
