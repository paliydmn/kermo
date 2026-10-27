import AppKit
import DFMCore

// Lists as panels (review 1, Р7): what a server runs — its services, containers, ports — in a panel of the main window
// as well as in a Picker: columns, a header click sorts, `/` filters, Space marks, the row's keys on the key bar, how
// the last actions went under the rows. Tools' presets come in as one more source.

/// What a list shows: rows as a Picker shows them, its columns, read again on ⌘R.
@MainActor protocol ListSource: AnyObject {
    /// What it lists, after the server's chip in the path bar: "Services".
    var title: String { get }
    /// Whose: its chips (PROD, ROOT, locked), and the connection a panel showing it holds.
    var target: SFTPTarget { get }
    var columns: [ListColumn] { get }
    /// As last read — a Picker's, handed over by ⌘↩ — shown at once; nil: it's read first.
    var content: ListContent? { get }
    /// Reads it again: a locked server asks first, then the login if one is due. ⎋ sets `cancel`.
    func read(_ cancel: CancelFlag) async throws -> ListContent
    /// Quick View next door (⌃Q) of the row under the cursor; nil: nothing more than the row says.
    func peek(_ row: Picker.Item) -> ListPeek?
    /// Its rows stay in their order (a place's); else what failed comes first.
    var keepsOrder: Bool { get }
}

extension ListSource {
    func peek(_ row: Picker.Item) -> ListPeek? { nil }
    var keepsOrder: Bool { false }
}

/// What Quick View shows of a list's row: lines as Info shows them, or a text read off the main thread once the cursor
/// rests on the row — passing over rows asks nothing (a service's `systemctl status`).
enum ListPeek {
    case rows([(String, String)])
    case text(@Sendable (CancelFlag) throws -> String)
}

/// A column: its header, and which of a row's texts it shows. `state`: the row's mark before it (a shape, not only a
/// color). The last one takes what's left of the panel's width.
struct ListColumn {
    enum Field: Equatable { case title, subtitle, detail, cell(String) }
    let title: String
    let field: Field
    var width: CGFloat = 120
    var state = false
}

/// What a read gives: the rows, a line about them all above ("10 units · 1 failed"), what's said when there are none,
/// and an action of the whole list on a button by that line (a Tools preset's `primary`: "＋ Allow Port…").
struct ListContent {
    var rows: [Picker.Item]
    var header: String? = nil
    var empty = "Nothing here"
    var primary: ListAction? = nil
}

/// What a row's keys, its menu and its slots do — one list, so a Picker and a panel act alike on the same row
/// (`serviceActions`; a Tools preset's actions). `why`: it can't now, saying why. `group`: the menu puts a line
/// between groups. `closes`: a Picker closes first (what opens a window of its own).
struct ListAction {
    /// The question before it: none (a look), on a production server, everywhere (a Stop).
    enum Asks { case never, prod, always }
    let title: String
    let key: Shortcut?
    let group: Int
    let closes: Bool
    let why: String?
    /// Its key in a panel when that isn't `key` (Stop… on F8, which a Picker leaves alone).
    var listKey: Shortcut? = nil
    /// What it runs, as it runs, and where, as whom (a root target: through the server's sudo): the question for several
    /// marked rows shows each, under production's or root's strip.
    var command: String? = nil
    var runsOn: SFTPTarget? = nil
    var asks = Asks.never
    /// Can't be undone: red in its menu and on its slot.
    var dangerous = false
    /// Starts it — at once, so a second press finds it running — and gives back what to wait for, if there's
    /// something (several marked rows run one after another). `asked`: the question was asked already, for several
    /// rows at once: it runs without asking again.
    let run: @MainActor (_ asked: Bool) -> Task<Void, Never>?

    /// Its key in a panel: `listKey`, else `key` — but ⌘E there is the command line's, so an edit takes F4, as a file's.
    var panelKey: Shortcut? { listKey ?? (key == Shortcut("cmd+e") ? Shortcut("f4") : key) }
}

/// Who shows a row a change runs on — a Picker, a list in a panel: the change asks over it, updates the row there
/// and says how it went under the rows.
@MainActor protocol RowList: AnyObject {
    func has(_ id: String) -> Bool
    func update(_ item: Picker.Item)
    /// How a run on row `id` went; `failed`: it stays till it's closed. `output`: a button that shows more.
    func said(_ text: NSAttributedString, about id: String, failed: Bool, output: (@MainActor () -> Void)?)
    /// What a question goes on.
    var sheetWindow: NSWindow? { get }
    func holding<T>(_ work: () async -> T) async -> T
}

extension Picker: RowList {
    func said(_ text: NSAttributedString, about id: String, failed: Bool, output: (@MainActor () -> Void)?) { say(text, output: output) }
    var sheetWindow: NSWindow? { window }
}

/// A list in a panel (`PanelViewController.showList`): its source's rows in its columns, on a table it's given
/// (`attach`) — the panel's own, whose keys, focus and menu stay the panel's. Problems first as read, or by a header
/// click; `/` filters as a Picker's rank does (title, subtitle, detail); Space marks by row id.
@MainActor
final class ListPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, RowList {
    let source: ListSource
    private(set) var content: ListContent?
    /// The rows as shown: filtered, sorted.
    private(set) var shown: [Picker.Item] = []
    private(set) var marked = Set<String>()
    private(set) var filter = ""
    /// A header click's order; nil: as read, problems (failed, then needing a look) first.
    private var order: (column: Int, ascending: Bool)?
    /// The row the cursor is on, by id: kept through a read, a sort, a filter.
    private(set) var cursorID: String?
    private weak var table: NSTableView?
    private var before: (columns: [NSTableColumn], sort: [NSSortDescriptor], style: NSTableView.ColumnAutoresizingStyle,
                         source: NSTableViewDataSource?, delegate: NSTableViewDelegate?)?
    var theme = Theme.current
    /// The cursor moved: Quick View next door, the key bar.
    var onCursor: (() -> Void)?
    /// Rows, marks or the filter changed: the panel's status line and its middle.
    var onChange: (() -> Void)?
    /// The header's button (`ListContent.primary`) clicked.
    var onPrimary: ((ListAction) -> Void)?
    /// Over the columns: the line about the list and its button.
    let headerView = NSStackView()
    private let headerLine = NSTextField(labelWithString: "")
    private let primary = NSButton(title: "", target: nil, action: nil)
    /// Under the rows: how the last actions went, a line each.
    let resultView = NSStackView()
    private var results: [(id: String, failed: Bool, view: NSView)] = []
    private var actionsKept: [MenuAction] = []
    private var resultGen = 0
    /// How long a line saying something went well stays.
    var resultTime: TimeInterval = 5

    /// `content`: rows already there (a tab's copy); else the source's as last read.
    init(_ source: ListSource, content: ListContent? = nil, filter: String = "", select: String? = nil) {
        self.source = source
        self.filter = filter
        cursorID = select
        super.init()
        headerLine.font = .systemFont(ofSize: 11.5)
        headerLine.lineBreakMode = .byTruncatingTail
        headerLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        primary.bezelStyle = .inline
        primary.controlSize = .small
        primary.target = self
        primary.action = #selector(primaryClicked)
        headerView.addArrangedSubview(headerLine)
        headerView.addArrangedSubview(primary)
        headerView.edgeInsets = NSEdgeInsets(top: 1, left: 4, bottom: 1, right: 0)
        headerView.isHidden = true
        resultView.orientation = .vertical
        resultView.alignment = .leading
        resultView.spacing = 2
        resultView.isHidden = true
        if let c = content ?? source.content { set(c) }
    }

    // MARK: - On a table

    /// Takes `table` over: its columns go (they come back on `detach`), the source's come.
    func attach(to table: NSTableView) {
        self.table = table
        before = (table.tableColumns, table.sortDescriptors, table.columnAutoresizingStyle, table.dataSource, table.delegate)
        (table.dataSource, table.delegate) = (nil, nil)   // nothing about the columns going
        table.tableColumns.forEach(table.removeTableColumn)
        for (i, c) in source.columns.enumerated() {
            let col = NSTableColumn(identifier: .init("list\(i)"))
            col.headerCell = PanelHeaderCell()
            (col.headerCell as? PanelHeaderCell)?.fill = theme.background
            col.title = c.title
            col.width = c.width
            col.sortDescriptorPrototype = NSSortDescriptor(key: "\(i)", ascending: true)
            table.addTableColumn(col)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.sortDescriptors = []
        (table.dataSource, table.delegate) = (self, self)
        reloadTable()
    }

    /// Gives the table back as it was.
    func detach() {
        guard let table, let b = before else { return }
        (table.dataSource, table.delegate) = (nil, nil)
        table.tableColumns.forEach(table.removeTableColumn)
        b.columns.forEach(table.addTableColumn)
        table.columnAutoresizingStyle = b.style
        table.sortDescriptors = b.sort
        (table.dataSource, table.delegate) = (b.source, b.delegate)
        (self.table, before) = (nil, nil)
    }

    /// A narrow panel: columns from the right give way (the first two never), as the files' Modified and Size do.
    func fit(_ width: CGFloat) {
        guard let table else { return }
        var room = width - (table.tableColumns.first?.width ?? 0)
        for (i, col) in table.tableColumns.enumerated().dropFirst() {
            let need = (i == table.tableColumns.count - 1 ? 60 : col.width) + table.intercellSpacing.width
            room -= need
            let hide = i > 1 && room < 0
            if col.isHidden != hide { col.isHidden = hide }
        }
    }

    // MARK: - Rows

    /// A read's rows: the marks of rows gone go, the cursor stays on its row (by id).
    func set(_ c: ListContent) {
        content = c
        marked.formIntersection(c.rows.map(\.id))
        headerLine.stringValue = c.header ?? ""
        headerLine.isHidden = c.header == nil
        primary.isHidden = c.primary == nil
        primary.title = c.primary.map { "＋ " + $0.title } ?? ""
        headerView.isHidden = c.header == nil && c.primary == nil
        apply()
    }

    /// A row of the list changed (a run on it, its state read again): in its place — no sort moves it under the cursor.
    func update(_ item: Picker.Item) {
        guard let i = content?.rows.firstIndex(where: { $0.id == item.id }) else { return }
        content?.rows[i] = item
        guard let r = shown.firstIndex(where: { $0.id == item.id }) else { return }
        shown[r] = item
        table?.reloadData(forRowIndexes: [r], columnIndexes: IndexSet(0..<(table?.numberOfColumns ?? 0)))
        if r == table?.selectedRow { onCursor?() }   // its keys may have changed (a run started on it)
    }

    func has(_ id: String) -> Bool { content?.rows.contains { $0.id == id } == true }

    var cursor: Picker.Item? { shown.first { $0.id == cursorID } }
    var cursorRow: Int? { shown.firstIndex { $0.id == cursorID } }
    var count: Int { content?.rows.count ?? 0 }

    /// What an action acts on: the marked rows as shown, else the cursor's.
    var targets: [Picker.Item] {
        marked.isEmpty ? cursor.map { [$0] } ?? [] : shown.filter { marked.contains($0.id) }
    }

    /// Typed in the panel's quick filter: the rows whose title, subtitle or detail match, in their order.
    func filter(_ text: String) {
        filter = text
        apply()
    }

    /// How it sorts by default: what failed, then what needs a look, then the rest, each as read.
    static func problemsFirst(_ rows: [Picker.Item]) -> [Picker.Item] {
        func rank(_ r: Picker.Item) -> Int { r.state == .failed ? 0 : r.state == .attention ? 1 : 2 }
        return rows.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// A row's text in a column.
    static func text(_ r: Picker.Item, _ f: ListColumn.Field) -> String {
        switch f {
        case .title: r.title
        case .subtitle: r.subtitle
        case .detail: r.detail
        case .cell(let k): r.cells[k] ?? ""
        }
    }

    private func apply() {
        let rows = content?.rows ?? []
        let q = filter.trimmingCharacters(in: .whitespaces)
        var list = q.isEmpty ? rows : rows.filter { Fuzzy.score(q, $0.title + " " + $0.subtitle + " " + $0.detail) != nil }
        if let o = order, source.columns.indices.contains(o.column) {
            let col = source.columns[o.column]
            func rank(_ r: Picker.Item) -> Int { col.state ? (r.state == .failed ? 0 : r.state == .attention ? 1 : r.state == .on ? 2 : 3) : 0 }
            list = list.enumerated().sorted { a, b in
                let (x, y) = (Self.text(a.element, col.field), Self.text(b.element, col.field))
                if rank(a.element) != rank(b.element) { return o.ascending == (rank(a.element) < rank(b.element)) }
                let c = x.localizedStandardCompare(y)
                return c == .orderedSame ? a.offset < b.offset : o.ascending == (c == .orderedAscending)
            }.map(\.element)
        } else if !source.keepsOrder {
            list = Self.problemsFirst(list)
        }
        shown = list
        reloadTable()
        onChange?()
    }

    private func reloadTable() {
        guard let table else { return }
        table.reloadData()
        let r = cursorRow ?? (shown.isEmpty ? nil : 0)
        if let r {
            table.selectRowIndexes([r], byExtendingSelection: false)
            table.scrollRowToVisible(r)
        }
        cursorID = r.map { shown[$0].id }
    }

    /// The cursor to row `r` of what's shown.
    func moveCursor(to r: Int) {
        guard let table, !shown.isEmpty else { return }
        let r = min(max(r, 0), shown.count - 1)
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    // MARK: - Marks (Space): by row, a ✓ in the marks' color, as files

    func toggleMark(move: Int) {
        guard let r = cursorRow else { return }
        let id = shown[r].id
        if !marked.insert(id).inserted { marked.remove(id) }
        table?.reloadData(forRowIndexes: [r], columnIndexes: IndexSet(0..<(table?.numberOfColumns ?? 0)))
        moveCursor(to: r + move)
        onChange?()
    }

    func markAll() { setMarks(Set(shown.map(\.id))) }
    func unmarkAll() { setMarks([]) }
    func invertMarks() { setMarks(Set(shown.map(\.id)).subtracting(marked)) }

    /// ⌘-click toggles a row, ⇧-click marks from the cursor to it.
    func markClick(_ row: Int, _ mods: NSEvent.ModifierFlags) {
        guard shown.indices.contains(row) else { return }
        if mods.contains(.shift) {
            let from = cursorRow ?? 0
            for r in min(from, row)...max(from, row) { marked.insert(shown[r].id) }
        } else if !marked.insert(shown[row].id).inserted {
            marked.remove(shown[row].id)
        }
        moveCursor(to: row)
        setMarks(marked)
    }

    private func setMarks(_ ids: Set<String>) {
        marked = ids
        table?.reloadData(forRowIndexes: IndexSet(0..<shown.count), columnIndexes: IndexSet(0..<(table?.numberOfColumns ?? 0)))
        onChange?()
    }

    // MARK: - How actions went (the Picker's line, a line per row)

    /// A run is starting: what the ones before said goes.
    func clearResults() {
        results.forEach { $0.view.removeFromSuperview() }
        results = []
        actionsKept = []
        resultView.isHidden = true
    }

    /// A row's line, in place of what was said about it before. All of them well: they go after `resultTime`;
    /// one that failed stays till its ✕.
    func said(_ text: NSAttributedString, about id: String, failed: Bool, output: (@MainActor () -> Void)?) {
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label])
        row.spacing = 6
        if let output {
            let b = NSButton(title: "Output…", target: nil, action: nil)
            (b.bezelStyle, b.controlSize) = (.inline, .small)
            actionsKept.append(MenuAction.attach(to: b, output))
            row.addArrangedSubview(b)
        }
        if failed {
            let x = NSButton(image: Symbol.close.image("Close"), target: nil, action: nil)
            x.isBordered = false
            x.toolTip = "Close"
            actionsKept.append(MenuAction.attach(to: x) { [weak self, weak row] in
                guard let self, let row else { return }
                row.removeFromSuperview()
                results.removeAll { $0.view === row }
                resultView.isHidden = results.isEmpty
            })
            row.addArrangedSubview(x)
        }
        if let i = results.firstIndex(where: { $0.id == id }) {
            results[i].view.removeFromSuperview()
            results.remove(at: i)
        }
        results.append((id, failed, row))
        resultView.addArrangedSubview(row)
        resultView.isHidden = false
        NSAccessibility.post(element: resultView, notification: .announcementRequested,
                             userInfo: [.announcement: text.string, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        resultGen += 1
        let gen = resultGen
        DispatchQueue.main.asyncAfter(deadline: .now() + resultTime) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.resultGen, !self.results.contains(where: \.failed) else { return }
                self.clearResults()
            }
        }
    }

    /// What's said under the rows now, a line each (tests).
    var resultLines: [String] { results.compactMap { ($0.view as? NSStackView)?.arrangedSubviews.first.map { ($0 as? NSTextField)?.stringValue ?? "" } } }

    var sheetWindow: NSWindow? { table?.window }
    func holding<T>(_ work: () async -> T) async -> T { await work() }

    @objc private func primaryClicked() { content?.primary.map { onPrimary?($0) } }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, let i = Int(column.identifier.rawValue.dropFirst(4)), source.columns.indices.contains(i), shown.indices.contains(row) else { return nil }
        let col = source.columns[i], it = shown[row], first = i == 0
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? PanelCell ?? Self.cell(column.identifier, first: first)
        let isMarked = marked.contains(it.id)
        let font: NSFont = theme.mono ? .monospacedSystemFont(ofSize: 12, weight: first && isMarked ? .bold : .regular)
            : first && isMarked ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        let words = Self.text(it, col.field)
        let failed = it.state == .failed && !it.busy
        cell.color = first ? (isMarked ? theme.marked : theme.text) : col.state ? (failed ? Palette.fail : theme.text) : theme.hidden
        cell.check.isHidden = !(first && isMarked)
        cell.textField?.font = font
        cell.textField?.setAccessibilityLabel(first && isMarked ? "marked" : nil)
        cell.toolTip = words.isEmpty ? nil : words
        if col.state, let mark = it.busy ? (Symbol.pending, NSColor.secondaryLabelColor, "busy") : it.state.map({ ($0.symbol, $0.color, "\($0)") }) {
            let s = NSMutableAttributedString(attributedString: mark.0.text(mark.1, font: font, label: mark.2))
            s.append(NSAttributedString(string: " " + words, attributes: [.font: font, .foregroundColor: cell.color]))
            let one = NSMutableParagraphStyle()
            one.lineBreakMode = .byTruncatingTail
            s.addAttribute(.paragraphStyle, value: one, range: NSRange(location: 0, length: s.length))
            cell.text = s
        } else {
            cell.text = nil
            cell.textField?.stringValue = words
        }
        return cell
    }

    private static func cell(_ id: NSUserInterfaceItemIdentifier, first: Bool) -> PanelCell {
        let cell = PanelCell()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1   // a long state: cut, not a second line
        tf.cell?.usesSingleLineMode = true
        tf.cell?.truncatesLastVisibleLine = true
        cell.addSubview(tf)
        cell.textField = tf
        var c = [tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]
        if first {
            cell.check.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(cell.check)
            c += [cell.check.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 1), cell.check.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                  cell.check.widthAnchor.constraint(equalToConstant: 10), tf.leadingAnchor.constraint(equalTo: cell.check.trailingAnchor, constant: 4)]
        } else {
            c.append(tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(c)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = PanelRowView()
        (v.cursor, v.outline) = (theme.cursor, theme.outline)
        return v
    }

    /// The cursor is one row, as in a folder.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        proposed.count <= 1 ? proposed : IndexSet(integer: proposed.last!)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = table?.selectedRow ?? -1
        guard shown.indices.contains(r) else { return }
        cursorID = shown[r].id
        onCursor?()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let i = d.key.flatMap(Int.init) else { return }
        order = (i, d.ascending)
        apply()
    }

    /// Typing a name jumps to it, as in a folder.
    func tableView(_ tableView: NSTableView, typeSelectStringFor column: NSTableColumn?, row: Int) -> String? {
        column?.identifier.rawValue == "list0" && shown.indices.contains(row) ? shown[row].title : nil
    }
}

// MARK: - The app's side: keys through the registry, the menu, the key bar, actions on marked rows

extension AppDelegate {
    /// A list's own commands: what they say, done to its rows (⌘R reads it again, / filters it, Space marks a row, ⌃↩
    /// and ⇧F10 its row's menu, ⌫ back).
    static let listOwn: Set<String> = ["open", "go.up", "view.refresh", "view.filter", "mark.toggle", "mark.down", "mark.up", "mark.all", "mark.none",
                                       "mark.invert", "cmdline.insert", "panel.menu"]
    /// What runs on a list besides: going elsewhere, tabs, panels, the view, the app — as on a parked tab. A file's
    /// commands don't: there's no file.
    static func runsInList(_ id: String) -> Bool {
        listOwn.contains(id) || id.hasPrefix("panel.focus") || ["panel.switch", "panel.add", "panel.close", "admin.auditLog", "admin.rootPanel", "admin.userPanel"].contains(id)
            || !listRefuses.contains(id) && ["go", "tab", "view", "app", "help", "ssh", "server", "tunnel", "term"].contains(String(id.prefix { $0 != "." }))
    }
    static let listRefuses: Set<String> = ["go.tree", "go.linktarget", "go.bookmark", "go.path", "view.dirsizes", "view.filterPresets", "view.gitOnly",
                                           "view.sort.name", "view.sort.size", "view.sort.mtime", "view.sort.reverse", "server.history"]

    /// A command that isn't the list's own and that a row's key rides (F3, F4, F8, ⌘L): named in the menu for that
    /// action, a click on it does that.
    static func titled(_ c: Command, _ actions: [ListAction]) -> ListAction? {
        listOwn.contains(c.id) ? nil : actions.first { a in a.panelKey.map(c.keys.contains) == true }
    }

    /// A command while the active panel shows a list (false: it runs as anywhere). A key the cursor's row has runs
    /// its action — only that key: F8 does Stop…, ⌘⌫ and Delete (Move to Trash's other keys) don't. A menu item named
    /// after a row's action does that. View ▸ Refresh reads the list again, ⌘R in it being the row's when it has one;
    /// ⌃↩ is the row's menu. A file's command beeps, saying why.
    func listRun(_ c: Command, key: Shortcut?, in list: ListPanel) -> Bool {
        let actions = list.cursor?.listActions?() ?? []
        if let key, let a = actions.first(where: { $0.panelKey == key }) { runList(a, in: list); return true }
        if key == nil, let a = Self.titled(c, actions) { runList(a, in: list); return true }
        switch c.id {
        case "view.refresh": active.readList()
        case "cmdline.insert": active.showContextMenu()
        case _ where Self.runsInList(c.id): return false
        default:
            NSSound.beep()
            active.listHint.map { active.flash($0) }
        }
        return true
    }

    /// The panel's ↩ or ⌘C by the mouse (a double-click, Edit ▸ Copy): the cursor row's action on that key.
    func listKey(_ key: Shortcut, in panel: PanelViewController) {
        guard let l = panel.list, let a = l.cursor?.listActions?().first(where: { $0.panelKey == key }) else { return NSSound.beep() }
        runList(a, in: l)
    }

    /// The keys that reach a list as a row's (`listRun`): a registry command's, or Edit ▸ Copy's ⌘C (to the panel's
    /// `copy`). ⌘O or ⌘S of a Picker row have none in a panel — its menu (⌃↩) has them.
    func reachesList(_ key: Shortcut) -> Bool { keymap[key] != nil || key == Shortcut("cmd+c") }

    /// The key bar while a list has the keys: the cursor row's keys in its words — ↩ first, Stop… in red — then Mark,
    /// Filter and Actions. A click runs the slot's action, as its key.
    func listKeys(_ l: ListPanel) -> [KeySlot] {
        let actions = l.cursor?.listActions?() ?? []
        let keyed = actions.enumerated().compactMap { i, a -> (Int, Shortcut, ListAction)? in a.panelKey.flatMap { reachesList($0) ? (i, $0, a) : nil } }
        let slots = keyed.sorted { ($0.1 == Shortcut("return") ? 0 : 1, $0.0) < ($1.1 == Shortcut("return") ? 0 : 1, $1.0) }
            .map { i, k, a in KeySlot(key: k.display, label: a.title, id: "list:\(i)", danger: a.dangerous) }
        func own(_ id: String, _ label: String, _ key: String) -> KeySlot {
            KeySlot(key: commands.first { $0.id == id }?.keys.first?.display ?? key, label: label, id: "list:" + id)
        }
        if l.source is PlaceSource {   // places aren't marked; its server's shell and its files as root are a key away
            return slots + [own("view.terminal", "SSH Here", "⌃O"), own("admin.rootPanel", "As Root", "⌃⌘R"), own("view.filter", "Filter", "/"),
                            own("cmdline.insert", "Actions", "⌃↩")]
        }
        return slots + [own("mark.toggle", "Mark", "Space"), own("view.filter", "Filter", "/"), own("cmdline.insert", "Actions", "⌃↩")]
    }

    /// A list slot clicked: its row action (`list:N`), or the list's own command (`list:mark.toggle`).
    func runListSlot(_ id: String) {
        let rest = String(id.dropFirst("list:".count))
        guard let l = active.list else { return }
        if let i = Int(rest), let a = l.cursor?.listActions?(), a.indices.contains(i) { return runList(a[i], in: l) }
        run(rest)
    }

    /// A row's menu in a list (⌃↩, ⇧F10, a right-click): the cursor row's actions, a line between groups; what can't
    /// run now greyed, saying why; red what can't be undone. It acts as the keys do: on the marked rows, or the cursor's.
    func fillListMenu(_ menu: NSMenu, _ l: ListPanel) {
        menu.autoenablesItems = false
        var group: Int?
        for a in l.cursor?.listActions?() ?? [] {
            if let group, group != a.group { menu.addItem(.separator()) }
            group = a.group
            let item = MenuAction.item(a.title) { [unowned self] in runList(a, in: l) }
            // Its key where the panel takes it (not ↩, F8: the open menu's; not ⌘O: no command has it here).
            if let k = a.panelKey, !k.flags.isEmpty, reachesList(k) { (item.keyEquivalent, item.keyEquivalentModifierMask) = (k.menuKey, k.flags) }
            if a.dangerous { item.attributedTitle = NSAttributedString(string: a.title, attributes: [.foregroundColor: Palette.fail]) }
            item.isEnabled = a.why == nil
            item.toolTip = a.why
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(MenuAction.item("Refresh") { [unowned self] in if active.list === l { active.readList() } })
    }

    /// `a` — an action of the cursor's row — on the marked rows, else the cursor's. One row: as a Picker runs it (its
    /// own question, if it has one). Several: a row it can't run on says why and is left out; one question for the
    /// rest — each command as it runs, production's strip, ↩ = Cancel there — then each in turn, a line each.
    func runList(_ a: ListAction, in l: ListPanel) {
        let rows = l.targets
        guard rows.count > 1 else {
            if let why = a.why { return active.flash(why, error: true) }
            if a.command != nil { l.clearResults() }
            _ = a.run(false)
            return
        }
        let each = rows.map { r in (row: r, action: r.listActions?().first { $0.title == a.title }) }
        let go = each.compactMap { r, x in x.flatMap { $0.why == nil ? (row: r, action: $0) : nil } }
        l.clearResults()
        let font = NSFont.systemFont(ofSize: 12)
        for (r, x) in each where x?.why != nil || x == nil {
            let line = NSMutableAttributedString(attributedString: Symbol.warn.text(Palette.warn, font: font, label: "left out"))
            line.append(NSAttributedString(string: " " + (x?.why ?? "\(r.title): no \(a.title)") + " — left out", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            l.said(line, about: r.id, failed: true, output: nil)
        }
        guard !go.isEmpty else { return }
        let t = l.source.target, verb = a.title.replacingOccurrences(of: "…", with: "")
        let runsOn = go.compactMap(\.action.runsOn).first ?? t
        let asks = go.contains { $0.action.dangerous || $0.action.asks == .always || $0.action.asks == .prod && SavedServer.isProd(runsOn) }
        Task {
            if asks {
                let n = go.count == 1 ? "“\(go[0].row.title)”" : "\(go.count) \(l.source.title.lowercased())"
                var c = Confirm("\(verb) \(n) on \(SavedServer.name(for: t.asUser))?", on: runsOn, action: verb)
                c.items = go.map { Confirm.Item(name: $0.row.title) }
                (c.runs, c.command) = (Self.runs(on: runsOn), go.compactMap(\.action.command).joined(separator: "\n"))
                if go.contains(where: { $0.action.asks == .always || $0.action.dangerous }) { c.returnCancels = true }
                c.irreversible = go.contains { $0.action.dangerous }
                guard await confirm(c, on: l.sheetWindow) == 0 else {
                    let line = NSAttributedString(string: "\(verb): cancelled — nothing ran", attributes: [.font: font, .foregroundColor: NSColor.labelColor])
                    return l.said(line, about: "", failed: false, output: nil)
                }
            }
            for x in go { await x.action.run(true)?.value }
        }
    }

    /// Who shows row `id` now: a Picker, lists in panels — a change updates it in each and says how it went there.
    func rowLists(_ id: String) -> [any RowList] {
        ((Picker.current.map { [$0 as any RowList] } ?? []) + panels.compactMap(\.list)).filter { $0.has(id) }
    }

    /// ⌘↩ in a Picker's list: the same rows in the other panel — as the Picker has them now, not read again — with
    /// what was typed and highlighted; the keys go there.
    func openInOther(_ source: ListSource, query: String, select: String?, rows: [Picker.Item]) {
        showPanels()
        let p = other
        var c = source.content ?? ListContent(rows: [])
        c.rows = rows
        p.showList(source, content: c, filter: query, select: select)
        window.makeFirstResponder(p.table)
    }
}
