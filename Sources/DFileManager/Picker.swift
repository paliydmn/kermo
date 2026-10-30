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
        // In a panel (`ListPanel`), not here: its columns besides title, subtitle and detail; its state as a shape (and
        // problems first); what its keys and menu do there — the list `actions`, `run` and `menu` are made of.
        var cells: [String: String] = [:]
        var state: StateMark? = nil
        var listActions: (@MainActor () -> [ListAction])? = nil
        // The palette's (⇧⌘P): the group whose header it comes under, its chips and its one key on the right, and how
        // it leaves the list (✕, ⌘⌫ — a Recent row).
        var group = ""
        var chips: [Chip] = []
        var cap = ""
        var remove: (@MainActor () -> Void)? = nil
        /// What's behind it, a list of its own (a server's place, its Services): ↩ in a panel shows it there, ⇥ in the
        /// palette goes into it. None: ⇥ goes into its actions (`listActions`), if it has more than ↩ and ⌘↩.
        var into: (@MainActor () -> ListSource)? = nil
        var titleColor: NSColor? = nil   // an action that can't run now (grey), or can't be undone (red)
        var keepsOpen = false   // ↩ runs it with the picker open: it says itself whether it closes
        var run: @MainActor () -> Void
    }

    private(set) static var current: Picker?
    let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                 styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    let field = NSTextField()
    private let table = PickerTable()
    private var items: [Item]
    private var shown: [Item] = []
    /// The table's rows: a group's header before its first item (`Item.group`), then items by their index in `shown`.
    private enum Line { case group(String), item(Int) }
    private var lines: [Line] = []
    /// Ranks off the main thread, once typing pauses (the palette: every name in a big folder): what it gave is `items`.
    private var results: ((String, CancelFlag) async -> [Item])?
    private var pending: Task<Void, Never>?
    private var ranking: CancelFlag?
    private var ranked: String?   // the query the rows are `results`' for
    private var rank: (Item, String) -> Int?
    private var freeText: ((String) -> [Item])?
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
    private var emptyText: String
    private let bar = KeyBarView(chips: false)
    private let hints: [KeySlot]
    /// ⌘↩: the same list in the other panel, with what's typed and highlighted and its rows as they are now — a run
    /// on one since it opened shows (`show(other:)`).
    private var other: (@MainActor (_ query: String, _ id: String?, _ rows: [Item]) -> Void)?
    /// The palette's levels (⇥ into a row, ⌫ on an empty field and ⎋ back): the ones above this, each as it was left.
    /// `listInOther`: ⌘↩ on a list's level — set, ⇥ goes into rows.
    private var above: [Level] = []
    private let listInOther: (@MainActor (ListSource, String, String?, [Item]) -> Void)?
    private var source: ListSource?   // this level's list
    private var actionsOf: Item?   // the row whose actions this level lists
    private var onLeave: ((String, String?) -> Void)?   // this level's: what was typed and highlighted as it goes
    private var reading: CancelFlag?
    private var scopes: [(name: String, chips: [Chip])]
    private let top = NSStackView()

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
    /// `other`: ⌘↩ Other Panel — the picker closes (`onClose` first) and the list goes on in the other panel.
    /// `results`: the rows for what's typed, ranked off the main thread after a pause (the palette); `items` and `rank`
    /// then go unused. `width`: the palette's is narrower. `listInOther`: ⇥ goes into a row (the palette's levels), and
    /// ⌘↩ on a list's level shows it in the other panel so.
    @discardableResult
    static func show(over window: NSWindow, placeholder: String, scope: (name: String, chips: [Chip])? = nil, header: String? = nil,
                     empty: String = "Nothing here", hints: [KeySlot] = [], items: [Item], rank: ((Item, String) -> Int?)? = nil,
                     freeText: ((String) -> [Item])? = nil, freeTextLast: Bool = false, selected: Int = 0,
                     query: String = "", select: String? = nil,
                     onDismiss: (@MainActor () -> Void)? = nil, onClose: (@MainActor (String, String?) -> Void)? = nil,
                     other: (@MainActor (String, String?, [Item]) -> Void)? = nil,
                     width: CGFloat = 640, results: ((String, CancelFlag) async -> [Item])? = nil,
                     listInOther: (@MainActor (ListSource, String, String?, [Item]) -> Void)? = nil) -> Picker {
        current?.close()
        let p = Picker(parent: window, placeholder: placeholder, scope: scope, header: header, empty: empty, hints: hints, items: items,
                       rank: rank ?? { item, q in Fuzzy.score(q, item.title + " " + item.subtitle) }, freeText: freeText,
                       freeTextLast: freeTextLast, selected: selected, query: query, select: select,
                       onDismiss: onDismiss, onClose: onClose, other: other, width: width, results: results, listInOther: listInOther)
        current = p
        p.present()
        return p
    }

    /// Closes the one showing, as ⎋ does (its `onDismiss` runs): one shown while something loads, which failed.
    static func dismiss() { current?.close() }

    private init(parent: NSWindow, placeholder: String, scope: (name: String, chips: [Chip])?, header: String?, empty: String, hints: [KeySlot],
                 items: [Item], rank: @escaping (Item, String) -> Int?, freeText: ((String) -> [Item])?, freeTextLast: Bool, selected: Int,
                 query: String, select: String?, onDismiss: (@MainActor () -> Void)?, onClose: (@MainActor (String, String?) -> Void)?,
                 other: (@MainActor (String, String?, [Item]) -> Void)?, width: CGFloat, results: ((String, CancelFlag) async -> [Item])?,
                 listInOther: (@MainActor (ListSource, String, String?, [Item]) -> Void)?) {
        self.parent = parent
        self.results = results
        self.listInOther = listInOther
        self.scopes = scope.map { [$0] } ?? []
        self.other = other
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

        panel.setContentSize(NSSize(width: width, height: panel.frame.height))
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.delegate = self
        panel.onKey = { [unowned self] e in
            let key = Shortcut(event: e)   // the physical key: ⌘E is "у" on a Ukrainian layout
            // ⌘↩: the row's own, if it has one (an overview's row in the other panel), else the list's.
            if key == Self.otherKey, self.other != nil, highlighted?.actions.contains(where: { $0.key == key }) != true { openOther(); return true }
            guard let row = highlighted else {   // no row: the list's own actions (an empty Tools list's)
                if Self.menuKeys.contains(key), !listActions.isEmpty { return popUpMenu() }
                guard let a = listActions.first(where: { $0.key == key }) else { return false }
                run(a)
                return true
            }
            if Self.menuKeys.contains(key), row.menu != nil { return popUpMenu() }
            guard let a = row.actions.first(where: { $0.key == key }) else { return false }
            perform(a)
            return true
        }
        bar.keep = ["return", "into", "other", "menu", "back", "esc"]   // a narrow picker keeps ↩, ⇥, ⌘↩, ⌃↩, ⌫ and ⎋ in sight
        bar.onRun = { [unowned self] id in   // a slot's click: what its key does
            switch id {
            case "return": choose()
            case "into": goInto()
            case "back": up()
            case "other": openOther()
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
        top.spacing = 6
        showScopes()
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
            guard let i = index(at: row), let menu = shown[i].menu else { return nil }   // an empty spot, a header: none
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

    /// The row whose `id` is `item`'s gets it — the highlight, what's typed and the scroll stay as they are — on a level
    /// above too; the level of its actions lists them as they are now.
    func update(_ item: Item) {
        let item = listInOther == nil ? item : keyed(item)
        for l in above.indices { if let j = above[l].items.firstIndex(where: { $0.id == item.id }) { above[l].items[j] = item } }
        if actionsOf?.id == item.id {
            actionsOf = item
            (items, selectID) = (actionRows(item), highlighted?.id)
            filter()
        }
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        guard let r = shown.firstIndex(where: { $0.id == item.id }) else { return }
        shown[r] = item
        table.reloadData(forRowIndexes: [line(of: r)], columnIndexes: [0])
        if r == index(at: table.selectedRow) { updateBar() }   // its keys may have changed (a run started on it)
    }

    func has(_ id: String) -> Bool {
        items.contains { $0.id == id } || source?.listID == id || above.contains { l in l.items.contains { $0.id == id } || l.source?.listID == id }
    }

    func reload(_ c: ListContent, having id: String) {
        func rows(_ s: ListSource?) -> [Item] { (s?.keepsOrder == true ? c.rows : ListPanel.problemsFirst(c.rows)).map(keyed) }
        for l in above.indices where above[l].source != nil && (above[l].items.contains { $0.id == id } || above[l].source?.listID == id) {
            above[l].items = rows(above[l].source)
        }
        guard source != nil, items.contains(where: { $0.id == id }) || source?.listID == id else { return }
        selectID = ListPanel.stay(highlighted?.id, in: shown.map(\.id), now: Set(c.rows.map(\.id)))
        show(c)
    }

    /// This level's list read again (a Tools row's menu: Refresh).
    func reread() { if let source { read(source) } }

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
    var headerSaid: String { header.isHidden ? "" : header.stringValue }
    var rows: [Item] { shown }   // what's listed now, as typing filtered it
    var highlighted: Item? { index(at: table.selectedRow).map { shown[$0] } }
    /// The group headers as listed (tests).
    var groups: [String] { lines.compactMap { if case .group(let g) = $0 { g } else { nil } } }

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
        panel.appearance = parent.appearance   // Kermo's theme, as the window's: a dark one's questions over it too
        let f = parent.frame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - 70 - panel.frame.height))
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func close() {
        guard Self.current === self || panel.isVisible else { return }   // once
        pending?.cancel()   // a ranking still running mustn't show rows
        ranking?.cancel()
        reading?.cancel()
        onLeave?(field.stringValue, highlighted?.id)
        panel.delegate = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKeyAndOrderFront(nil)
        if Self.current === self { Self.current = nil }
        onClose?(field.stringValue, highlighted?.id)
        onDismiss?()
    }

    /// This level's list's own actions (`ListContent.actions`): with no row highlighted, its keys and its menu.
    private var listActions: [ListAction] { source?.content?.actions?() ?? [] }

    /// The highlighted row's menu, under it: ⎋ closes it, and typing goes on in the field. No row: the list's actions.
    private func popUpMenu() -> Bool {
        let r = table.selectedRow
        guard let i = index(at: r) else {
            guard !listActions.isEmpty else { return false }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for a in listActions {
                let item = MenuAction.item(a.title) { [unowned self] in run(a) }
                if a.dangerous { item.attributedTitle = NSAttributedString(string: a.title, attributes: [.foregroundColor: Palette.fail]) }
                (item.isEnabled, item.toolTip) = (a.why == nil, a.why)
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 24, y: 0), in: table)
            return true
        }
        guard let menu = shown[i].menu?() else { return false }
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

    /// ↩ and the highlighted row's keys — ⇥ where it goes in — its menu if it has one, ⌘↩, the picker's hints, then ⎋
    /// Close, or on a level ⌫ ⎋ Back.
    private func updateBar() {
        var slots: [KeySlot] = []
        if let row = highlighted {
            slots.append(KeySlot(key: "↩", label: row.verb, id: "return"))
            if canGoInto(row) { slots.append(KeySlot(key: "⇥", label: "Into", id: "into")) }
            slots += row.actions.enumerated().filter { !$0.element.label.isEmpty }.map { KeySlot(key: $0.element.key.display, label: $0.element.label, id: "\($0.offset)") }
            if row.menu != nil { slots.append(KeySlot(key: "⌃↩", label: "Actions", id: "menu")) }
        } else if !listActions.isEmpty {
            slots.append(KeySlot(key: "⌃↩", label: "Actions", id: "menu"))
        }
        if other != nil, highlighted?.actions.contains(where: { $0.key == Self.otherKey }) != true {
            slots.append(KeySlot(key: "⌘↩", label: "Other Panel", id: "other"))
        }
        // On a level ⎋ goes up, as ⌫ on an empty field does: one slot says both.
        bar.list = slots + hints + [above.isEmpty ? KeySlot(key: "⎋", label: "Close", id: "esc") : KeySlot(key: "⌫ ⎋", label: "Back", id: "back")]
    }

    // MARK: - Levels: ⇥ goes into a row, ⌫ on an empty field and ⎋ come back (the palette)

    private static let otherKey = Shortcut("cmd+return")!
    private static let enter = Shortcut("return")!

    /// A level as it was left for a deeper one: its chip, rows and their ranking, what's said about them, ⌘↩, and what
    /// was typed and highlighted there.
    private struct Level {
        let placeholder: String
        var items: [Item]
        let rank: (Item, String) -> Int?
        let results: ((String, CancelFlag) async -> [Item])?
        let freeText: ((String) -> [Item])?
        let header: String?
        let empty: String
        let other: (@MainActor (String, String?, [Item]) -> Void)?
        let source: ListSource?
        let actionsOf: Item?
        let onLeave: ((String, String?) -> Void)?
        let query: String
        let select: String?
    }

    /// Whether ⇥ goes somewhere from `row`: its list, or its actions besides ↩ and ⌘↩ (an overview's Files has none).
    private func canGoInto(_ row: Item) -> Bool {
        listInOther != nil && (row.into != nil || row.listActions?().contains { $0.key != Self.enter && $0.key != Self.otherKey } == true)
    }

    private func goInto() {
        guard let row = highlighted, canGoInto(row) else { return NSSound.beep() }
        if let make = row.into { go(into: make()) } else { go(intoActionsOf: row) }
    }

    /// `s`'s rows as the next level — at once if it has them (a place), else read first: "Looking at services…", a locked
    /// server's Touch ID and the login asking over the picker, ⎋ stopping it. Its chip: the server, in its place's
    /// color, then what it lists. `query` and `select` (a row's id): as it was left; `onLeave` hears that as it goes.
    func go(into s: ListSource, query: String = "", select: String? = nil, onLeave: ((String, String?) -> Void)? = nil) {
        let name = SavedServer.name(for: s.target.asUser), chips = Chip.of(s.target)
        let here = source.map { ServerRow.key($0.target) == ServerRow.key(s.target) } == true   // its server's place is the level above
        push(s is PlaceSource ? (name, chips) : here ? (s.title, []) : ("\(name) › \(s.title)", chips), placeholder: "Filter \(s.title.lowercased())")
        (source, field.stringValue, selectID, self.onLeave) = (s, query, select, onLeave)
        rank = { item, q in Fuzzy.score(q, item.title + " " + item.subtitle + " " + item.detail) }
        let inOther = listInOther   // not self: ⌘↩ runs it after the picker closed and went
        other = { q, id, rows in inOther?(s, q, id, rows) }
        guard let c = s.content else { return read(s) }
        show(c)
    }

    private func show(_ c: ListContent) {
        items = (source?.keepsOrder == true ? c.rows : ListPanel.problemsFirst(c.rows)).map(keyed)
        setHeader(c.rows.isEmpty ? nil : c.header)
        emptyText = c.empty
        filter()
    }

    private func read(_ s: ListSource) {
        (items, emptyText) = ([], "Looking at \(s.title.lowercased())…")
        let select = selectID   // for the rows, not for "Looking at…"
        filter()
        selectID = select
        let flag = CancelFlag(), depth = above.count
        reading = flag
        Task {
            let r = await holding { () async -> Result<ListContent, Error> in
                do { return .success(try await s.read(flag)) } catch { return .failure(error) }
            }
            guard !flag.isCancelled, Self.current === self, source === s, above.count == depth else { return }
            reading = nil
            switch r {
            case .success(let c): show(c)
            case .failure(is CancellationError): break
            case .failure(let e):
                let font = NSFont.systemFont(ofSize: 12), line = NSMutableAttributedString()
                if !(e is AppDelegate.Locked) { line.append(Symbol.failed.text(Palette.fail, font: font, label: "failed")); line.append(NSAttributedString(string: " ")) }
                line.append(NSAttributedString(string: e.localizedDescription, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
                let output = (e as? ShowsOutput)?.output ?? "", title = "What \(s.title) said"
                var show: (@MainActor () -> Void)?
                if !output.isEmpty { show = { [weak picker = self] in picker?.showOutput(title, String(output.suffix(4000))) } }
                say(line, output: show)
            }
        }
    }

    /// What the server said when a list's read failed, as a failed change's Output… shows it.
    private func showOutput(_ title: String, _ text: String) {
        Task { await holding { _ = await (NSApp.delegate as? AppDelegate)?.choose(title, info: text, ["OK"], on: window) } }
    }

    /// `row`'s actions as the next level: its chip, the actions as rows.
    private func go(intoActionsOf row: Item) {
        push((row.title, []), placeholder: "Filter actions")
        actionsOf = row
        rank = { item, q in Fuzzy.score(q, item.title) }
        items = actionRows(row)
        emptyText = "No actions"
        filter()
    }

    /// A row's actions as rows: its key on the right, why it can't now under it (the title grey), red what can't be
    /// undone, the command it runs under the rest.
    private func actionRows(_ row: Item) -> [Item] {
        (row.listActions?() ?? []).map { a in
            var it = Item(title: a.title, subtitle: a.why ?? a.command ?? "", verb: "Run") { [unowned self] in
                if let now = actionsOf?.listActions?().first(where: { $0.title == a.title }) { run(now) }   // as it is now
            }
            it.id = "action " + a.title
            it.cap = a.key?.display ?? ""
            it.titleColor = a.why != nil ? .tertiaryLabelColor : a.dangerous ? Palette.fail : nil
            it.keepsOpen = true
            return it
        }
    }

    /// A list action, from its row's level or its key: `why` says why not; one that opens a window of its own closes the
    /// picker first; the rest run with it open — their question over it, how they went under the rows, their row
    /// updated (`AppDelegate.rowLists`).
    private func run(_ a: ListAction) {
        if let why = a.why {
            NSSound.beep()
            return say(NSAttributedString(string: why, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
        }
        guard a.closes else { _ = a.run(false); return }
        onDismiss = nil
        close()
        DispatchQueue.main.async { _ = a.run(false) }   // after focus is back on the main window
    }

    /// A list's row with no keys of its own for a Picker (a tunnel's) gets its list actions' — but ↩, its own.
    private func keyed(_ row: Item) -> Item {
        guard row.actions.isEmpty, let all = row.listActions?() else { return row }
        var r = row
        r.actions = all.compactMap { a in
            a.key.flatMap { $0 == Self.enter ? nil : Item.Action(key: $0, label: a.title.replacingOccurrences(of: "…", with: ""), keepsOpen: true) { [unowned self] in
                run(row.listActions?().first { $0.title == a.title } ?? a)
            } }
        }
        return r
    }

    /// The level below goes on top of this one, which is kept as it is.
    private func push(_ chip: (name: String, chips: [Chip]), placeholder: String) {
        pending?.cancel()
        ranking?.cancel()
        above.append(Level(placeholder: field.placeholderString ?? "", items: items, rank: rank, results: results, freeText: freeText,
                           header: header.isHidden ? nil : header.stringValue, empty: emptyText, other: other, source: source,
                           actionsOf: actionsOf, onLeave: onLeave, query: field.stringValue, select: highlighted?.id))
        scopes.append(chip)
        showScopes()
        (results, freeText, other, source, actionsOf, onLeave) = (nil, nil, nil, nil, nil, nil)
        (field.stringValue, field.placeholderString) = ("", placeholder)
        setHeader(nil)
        say(nil)
    }

    /// Back to the level above, as it was left: what was typed there, its row highlighted. A read on its way stops.
    private func up() {
        guard let l = above.popLast() else { return }
        reading?.cancel()
        reading = nil
        onLeave?(field.stringValue, highlighted?.id)
        scopes.removeLast()
        showScopes()
        (items, rank, results, freeText, emptyText, other, source, actionsOf, onLeave) = (l.items, l.rank, l.results, l.freeText, l.empty, l.other, l.source, l.actionsOf, l.onLeave)
        (field.stringValue, field.placeholderString, selectID) = (l.query, l.placeholder, l.select)
        setHeader(l.header)
        filter()
    }

    /// The chips of where the list is, before the field: "web-01 › Services ›". The field stays where it is, typing on:
    /// taken out of the window, it would lose the keys.
    private func showScopes() {
        top.arrangedSubviews.filter { $0 !== field }.forEach { $0.removeFromSuperview() }
        for (i, s) in scopes.enumerated() { top.insertArrangedSubview(ScopeChip(s.name, chips: s.chips), at: i) }
        if field.superview == nil { top.addArrangedSubview(field) }
    }

    private func setHeader(_ text: String?) {
        header.stringValue = text ?? ""
        header.isHidden = text == nil
    }

    /// Where the palette is (tests): its chips, as shown.
    var scopeNames: [String] { scopes.map(\.name) }

    /// ⌘↩: closes — saying what was typed and highlighted (`onClose`) — then hands that to `other`.
    private func openOther() {
        guard let other else { return }
        let (q, id, rows) = (field.stringValue, highlighted?.id, items)
        onDismiss = nil
        close()
        DispatchQueue.main.async { other(q, id, rows) }   // after focus is back on the main window
    }

    @objc private func choose() {
        guard let r = index(at: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow) else { return NSSound.beep() }
        let item = shown[r]
        if item.keepsOpen { return item.run() }
        onDismiss = nil
        close()
        DispatchQueue.main.async { item.run() }   // after focus is back on the main window
    }

    private func filter() {
        if results != nil { return rank() }
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
        list(first)
    }

    /// `shown` in the table, a header before each group, `first` highlighted.
    private func list(_ first: Int) {
        lines = []
        var group = ""
        for (i, it) in shown.enumerated() {
            if !it.group.isEmpty, it.group != group { lines.append(.group(it.group)) }
            group = it.group
            lines.append(.item(i))
        }
        table.reloadData()
        select(first)
        emptyLabel.stringValue = (results == nil ? items.isEmpty : field.stringValue.isEmpty) ? emptyText : "No matches"
        emptyLabel.isHidden = !shown.isEmpty
        updateBar()
    }

    private func select(_ i: Int) {
        guard shown.indices.contains(i) else { return }
        table.selectRowIndexes([line(of: i)], byExtendingSelection: false)
        table.scrollRowToVisible(line(of: i))
    }

    /// The table row of `shown[i]`, and back (nil: a header, or nothing).
    private func line(of i: Int) -> Int { lines.firstIndex { if case .item(i) = $0 { true } else { false } } ?? -1 }
    private func index(at line: Int) -> Int? { if lines.indices.contains(line), case .item(let i) = lines[line] { i } else { nil } }

    /// `results`' rows for what the field says, once typing pauses for `delay` (a keystroke per name in a big folder
    /// stalled the field) — unless the field says something else by then; then `then`.
    private func rank(delay: Duration = .zero, then: (() -> Void)? = nil) {
        guard let results else { return }
        pending?.cancel()
        ranking?.cancel()
        let q = field.stringValue, flag = CancelFlag()
        ranking = flag
        pending = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            let r = await results(q, flag)
            guard !Task.isCancelled, above.isEmpty, q == field.stringValue else { return }
            (items, shown, ranked) = (r, r, q)
            let first = selectID.flatMap { id in r.firstIndex { $0.id == id } } ?? 0
            selectID = nil
            list(first)
            then?()
        }
    }

    /// ✕ or ⌘⌫ on a row that can go (`Item.remove`, the palette's Recent): it goes, the list stays, and the next such
    /// row takes the highlight (⌘⌫ again removes it).
    private func remove(_ i: Int?) {
        guard let i, shown.indices.contains(i), let gone = shown[i].remove else { return NSSound.beep() }
        gone()
        rank { [self] in
            for j in [i, i - 1] where shown.indices.contains(j) && shown[j].remove != nil { return select(j) }
        }
    }

    @objc private func removeClicked(_ sender: NSButton) { remove(index(at: table.row(for: sender))) }

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

    func controlTextDidChange(_ obj: Notification) { results == nil ? filter() : rank(delay: .milliseconds(100)) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let step = sel == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            var r = table.selectedRow + step
            while lines.indices.contains(r), index(at: r) == nil { r += step }   // over a group's header
            if let i = index(at: r) { select(i) }
        case #selector(NSResponder.insertNewline(_:)):
            // Typing paused less than 100 ms ago: the rows are the last query's (a recent command, say) — rank what was typed first.
            if results != nil, ranked != field.stringValue { rank { [self] in choose() } } else { choose() }
        case #selector(NSResponder.deleteToBeginningOfLine(_:)) where field.stringValue.isEmpty && results != nil:   // ⌘⌫
            remove(index(at: table.selectedRow))
        case #selector(NSResponder.insertTab(_:)) where listInOther != nil: goInto()
        case #selector(NSResponder.deleteBackward(_:)) where field.stringValue.isEmpty && !above.isEmpty: up()
        case #selector(NSResponder.cancelOperation(_:)): above.isEmpty ? close() : up()
        default: return false
        }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if let i = index(at: table.selectedRow) { shown[i].preview?() }
        updateBar()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { index(at: row) != nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { index(at: row) == nil ? 20 : 26 }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let i = index(at: row) else {
            guard case .group(let g)? = lines.indices.contains(row) ? lines[row] : nil else { return nil }
            let l = NSTextField(labelWithString: g.uppercased())
            l.font = .systemFont(ofSize: 10, weight: .semibold)
            l.textColor = .secondaryLabelColor
            return l
        }
        let cell = tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? PickerCell ?? PickerCell()
        let it = shown[i]
        // Its chips, then its one key, on the right (the palette's rows).
        let marks = NSMutableAttributedString()
        for c in it.chips { marks.append(c.text); marks.append(NSAttributedString(string: " ")) }
        if !it.cap.isEmpty { marks.append(KeyCap.text(it.cap, font: .systemFont(ofSize: 12))) }
        if canGoInto(it) {   // there's more behind it
            if marks.length > 0 { marks.append(NSAttributedString(string: " ")) }
            marks.append(KeyCap.text("⇥", font: .systemFont(ofSize: 12)))
        }
        cell.show(title: it.title, subtitle: it.subtitle, detail: it.detail, subtitleColor: it.subtitleColor, busy: it.busy, badges: it.badges,
                  marks: marks.length > 0 ? marks : nil, titleColor: it.titleColor)
        cell.remove.isHidden = it.remove == nil
        cell.remove.target = self
        cell.remove.action = #selector(removeClicked)
        cell.remove.toolTip = "Remove from Recent  ⌘⌫"
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
        // A long detail (a tool's `about` in a server's overview) gives way before the title does.
        detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        detail.lineBreakMode = .byTruncatingTail
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

    /// `marks`: after the detail — chips, a key (the palette's).
    func show(title t: String, subtitle: String, detail d: String, subtitleColor: NSColor? = nil, busy: Bool = false, badges: [NSImage] = [],
              marks: NSAttributedString? = nil, titleColor: NSColor? = nil) {
        lead.arrangedSubviews.dropLast().forEach { $0.removeFromSuperview() }
        for (i, b) in badges.enumerated() { lead.insertArrangedSubview(NSImageView(image: b), at: i) }
        texts = (t, subtitle, subtitleColor)
        self.titleColor = titleColor
        end = (d, marks)
        paint()
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private var texts: (title: String, subtitle: String, color: NSColor?) = ("", "", nil)
    private var end: (detail: String, marks: NSAttributedString?) = ("", nil)
    private var titleColor: NSColor?
    override var backgroundStyle: NSView.BackgroundStyle { didSet { paint() } }

    /// On the system's highlight all of it in its text color — a failed state's red too (its ◆ still says so).
    private func paint() {
        let on = backgroundStyle == .emphasized, white = NSColor.alternateSelectedControlTextColor
        let line = NSMutableParagraphStyle()
        line.lineBreakMode = .byTruncatingMiddle   // one line: an attributed value drops the label's own mode, and a long subtitle wrapped into the next row
        let s = NSMutableAttributedString(string: texts.title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: on ? white : titleColor ?? .labelColor,
                                                                            .paragraphStyle: line])
        if !texts.subtitle.isEmpty {
            s.append(NSAttributedString(string: "   " + texts.subtitle, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: on ? white.withAlphaComponent(0.8) : texts.color ?? NSColor.secondaryLabelColor, .paragraphStyle: line]))
        }
        title.attributedStringValue = s
        let d = NSMutableAttributedString(string: end.detail, attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                                          .foregroundColor: on ? white.withAlphaComponent(0.8) : NSColor.secondaryLabelColor])
        if let marks = end.marks { if d.length > 0 { d.append(NSAttributedString(string: "  ")) }; d.append(marks) }
        let tail = NSMutableParagraphStyle()
        tail.lineBreakMode = .byTruncatingTail
        d.addAttribute(.paragraphStyle, value: tail, range: NSRange(location: 0, length: d.length))
        detail.attributedStringValue = d
    }
}
