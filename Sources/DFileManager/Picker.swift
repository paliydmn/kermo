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
        var run: @MainActor () -> Void
    }

    private(set) static var current: Picker?
    let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                 styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    private let field = NSTextField()
    private let table = NSTableView()
    private let items: [Item]
    private var shown: [Item] = []
    private let rank: (Item, String) -> Int?
    private let freeText: ((String) -> [Item])?
    private let freeTextLast: Bool
    private let selected: Int
    private var onDismiss: (@MainActor () -> Void)?
    private weak var parent: NSWindow?

    /// `rank` scores an item against the query (nil = hide); default fuzzy-matches title + subtitle.
    /// Ties keep the given order, so pass items best-first.
    /// `freeText` turns whatever was typed into extra first rows (e.g. "Connect to “user@host”"); `freeTextLast`: after
    /// the matches instead, so ↩ takes a match (Switch Branch: "conf" switches to a branch, not creates "conf").
    /// `selected`: the row highlighted while nothing is typed. `onDismiss`: closed without choosing.
    static func show(over window: NSWindow, placeholder: String, items: [Item], rank: ((Item, String) -> Int?)? = nil,
                     freeText: ((String) -> [Item])? = nil, freeTextLast: Bool = false, selected: Int = 0,
                     onDismiss: (@MainActor () -> Void)? = nil) {
        current?.close()
        let p = Picker(parent: window, placeholder: placeholder, items: items,
                       rank: rank ?? { item, q in Fuzzy.score(q, item.title + " " + item.subtitle) }, freeText: freeText,
                       freeTextLast: freeTextLast, selected: selected, onDismiss: onDismiss)
        current = p
        p.present()
    }

    /// Closes the one showing, as ⎋ does (its `onDismiss` runs): one shown while something loads, which failed.
    static func dismiss() { current?.close() }

    private init(parent: NSWindow, placeholder: String, items: [Item], rank: @escaping (Item, String) -> Int?,
                 freeText: ((String) -> [Item])?, freeTextLast: Bool, selected: Int, onDismiss: (@MainActor () -> Void)?) {
        self.parent = parent
        self.items = items
        self.rank = rank
        self.freeText = freeText
        self.freeTextLast = freeTextLast
        self.selected = selected
        self.onDismiss = onDismiss
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.delegate = self
        panel.onKey = { [unowned self] e in
            let key = Shortcut(event: e)   // the physical key: ⌘E is "у" on a Ukrainian layout
            guard shown.indices.contains(table.selectedRow), case let row = shown[table.selectedRow],
                  let run = row.keys[key] ?? (key == Shortcut("cmd+e") ? row.edit : nil) else { return false }
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
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.backgroundColor = .clear

        let bg = NSVisualEffectView()
        bg.material = .popover
        for v in [field, scroll] as [NSView] {
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
            scroll.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -6),
        ])
        panel.contentView = bg
        filter()
    }

    private func present() {
        guard let parent else { return }
        let f = parent.frame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - 70 - panel.frame.height))
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func close() {
        panel.delegate = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKeyAndOrderFront(nil)
        if Self.current === self { Self.current = nil }
        onDismiss?()
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
        } else {
            shown = items.enumerated()
                .compactMap { i, it in rank(it, q).map { (score: $0, i: i, it: it) } }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.i < $1.i }
                .prefix(300).map(\.it)
            let extra = freeText?(q.trimmingCharacters(in: .whitespaces)) ?? []
            if freeTextLast { shown += extra } else { shown.insert(contentsOf: extra, at: 0) }
        }
        table.reloadData()
        if !shown.isEmpty {
            table.selectRowIndexes([first], byExtendingSelection: false)
            table.scrollRowToVisible(first)
        }
    }

    // MARK: - Delegates

    func windowDidResignKey(_ notification: Notification) { close() }

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
        cell.show(title: it.title, subtitle: it.subtitle, detail: it.detail)
        return cell
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
        let end = NSStackView(views: [detail, remove])   // a hidden ✕ takes no room
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

    func show(title t: String, subtitle: String, detail d: String) {
        let s = NSMutableAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        if !subtitle.isEmpty {
            s.append(NSAttributedString(string: "   " + subtitle, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        title.attributedStringValue = s
        detail.stringValue = d
    }
}
