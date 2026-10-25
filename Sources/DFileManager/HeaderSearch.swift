import AppKit
import DFMCore

/// One result of the toolbar search.
struct SearchHit: Equatable {
    enum Target: Equatable {
        case command(String)
        case folder(String)
        case server(String)
        case file(String)          // in the active panel
        case disk(String)          // "Search “q” on disk…" → ⌘F dialog

        /// How the search history keeps it ("folder:/var/log"); nil for a name in the panel — gone once the panel moves on.
        var key: String? {
            switch self {
            case .command(let id): "command:" + id
            case .folder(let p): "folder:" + p
            case .server(let s): "server:" + s
            case .disk(let q): "disk:" + q
            case .file: nil
            }
        }

        /// A bare id is a command: the history kept nothing else before.
        init(key: String) {
            guard let i = key.firstIndex(of: ":") else { self = .command(key); return }
            let rest = String(key[key.index(after: i)...])
            switch key[..<i] {
            case "command": self = .command(rest)
            case "folder": self = .folder(rest)
            case "server": self = .server(rest)
            case "disk": self = .disk(rest)
            default: self = .command(key)
            }
        }
    }
    let title: String
    var subtitle = ""
    var detail = ""                // keys
    let target: Target
    var removable = false          // a Recent row: ✕ and ⌘⌫ take it out of the history
}

/// Commands (by title, key label and aliases: "zip" → Compress), folders, then files in the active panel.
/// Fuzzy-ranked inside each group; equal scores keep source order (favorites before frecency before volumes…).
enum HeaderSearchModel {
    static let perGroup = 8
    static let recentMax = 10

    /// `cancel`: a query typed on since stops ranking a big folder's names (looked at every 1024).
    static func results(_ query: String, commands: [Command], folders: [SearchHit], files: [String], recent: [String],
                        cancel: CancelFlag? = nil) -> [(group: String, hits: [SearchHit])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let cmds = commands.filter { $0.id != "app.palette" && !$0.hidden }
        func hit(_ c: Command) -> SearchHit {
            SearchHit(title: c.title, subtitle: c.menu ?? "", detail: c.keys.map(\.display).joined(separator: "  "), target: .command(c.id))
        }
        func disk(_ q: String) -> SearchHit { SearchHit(title: "Search “\(q)” on disk…", detail: "⌘F", target: .disk(q)) }
        if q.isEmpty {
            // Folders and servers come back as the search lists them now; what it no longer lists (a gone command) is left out.
            let r = recent.map(SearchHit.Target.init(key:)).compactMap { t -> SearchHit? in
                switch t {
                case .command(let id): cmds.first { $0.id == id }.map(hit)
                case .disk(let q): disk(q)
                default: folders.first { $0.target == t }
                }
            }.prefix(recentMax).map { var h = $0; h.removable = true; return h }
            let fav = folders.filter { f in f.detail == "favorite" && !r.contains { $0.target == f.target } }
            return [("Recent", Array(r)), ("Favorites", fav)].filter { !$0.1.isEmpty }
        }
        func ranked<T>(_ items: [T], _ score: (T) -> Int?) -> [T] {
            var hits: [(Int, Int, T)] = []
            for (i, it) in items.enumerated() {
                if i & 1023 == 0, cancel?.isCancelled == true { return [] }
                if let s = score(it) { hits.append((s, i, it)) }
            }
            return hits.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.prefix(perGroup).map(\.2)
        }
        let groups: [(String, [SearchHit])] = [
            ("Commands", ranked(cmds) { c in [c.title, c.short, c.aliases].compactMap { Fuzzy.score(q, $0) }.max() }.map(hit)),
            ("Folders", ranked(folders) { Fuzzy.score(q, $0.title).map { $0 + 50 } ?? Fuzzy.score(q, $0.subtitle) }),
            ("In This Panel", ranked(files) { Fuzzy.score(q, $0) }.map { SearchHit(title: $0, target: .file($0)) }),
        ]
        return groups.filter { !$0.1.isEmpty } + [("", [disk(q)])]
    }
}

/// The search field in the toolbar (⌘⇧P, F9): results drop down under it without taking focus from the field.
/// ↑↓ choose, ↩ runs / opens, ⌘↩ opens a folder in the other panel, ⎋ closes and goes back to the panel.
/// Focused empty, it lists what was chosen lately; ✕ or ⌘⌫ takes a row out of that history.
@MainActor
final class HeaderSearch: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let item = NSSearchToolbarItem(itemIdentifier: .init("search"))
    /// Ranks the query; the ranking itself (every name in the panel) runs off the main thread, until the flag says
    /// another query took its place.
    var results: (String, CancelFlag) async -> [(group: String, hits: [SearchHit])] = { _, _ in [] }
    var onChoose: ((SearchHit, _ otherPanel: Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onRemove: ((SearchHit) -> Void)?

    private enum Row { case header(String), hit(SearchHit) }
    private var rows: [Row] = []
    private var shown: String?   // the query the rows are for; nil while the list is closed
    private var pending: Task<Void, Never>?
    private var ranking: CancelFlag?   // the pending query's ranking
    private let list = NonKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let table = NSTableView()

    override init() {
        super.init()
        let field = FocusField()
        field.onFocus = { [unowned self] in update() }   // empty: the recent choices, at once
        item.searchField = field
        item.searchField.placeholderString = "Search commands, folders, files"
        item.searchField.delegate = self
        item.preferredWidthForSearchField = 280
        item.toolTip = "Search  ⇧⌘P · F9"

        table.addTableColumn(NSTableColumn(identifier: .init("hit")))
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 4), scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: bg.topAnchor, constant: 4), scroll.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -4),
        ])
        list.contentView = bg
        list.backgroundColor = .clear
        list.hasShadow = true
    }

    func focus() {
        item.beginSearchInteraction()
        update()   // it hands the field editor the focus without asking the field (FocusField hears clicks only)
    }

    /// Ranks once typing pauses for `delay` (a keystroke per name in a big folder stalled the field), shows the
    /// result if the field still says the same, then runs `then` on it.
    private func update(delay: Duration = .zero, then: (() -> Void)? = nil) {
        pending?.cancel()
        ranking?.cancel()
        let q = item.searchField.stringValue, flag = CancelFlag()
        ranking = flag
        pending = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            let r = await results(q, flag)
            guard !Task.isCancelled, q == item.searchField.stringValue else { return }
            shown = q
            show(r)
            then?()
        }
    }

    private func show(_ results: [(group: String, hits: [SearchHit])]) {
        rows = results.flatMap { g in (g.group.isEmpty ? [] : [Row.header(g.group)]) + g.hits.map(Row.hit) }
        table.reloadData()
        select(rows.firstIndex { if case .hit = $0 { true } else { false } } ?? -1)
        guard let field = item.searchField.window.map({ $0.convertToScreen(item.searchField.convert(item.searchField.bounds, to: nil)) }),
              let parent = item.searchField.window, !rows.isEmpty else { return close() }
        let w = max(field.width, 440), h = min(CGFloat(rows.count) * 26 + 8, 460)
        list.setFrame(NSRect(x: field.maxX - w, y: field.minY - 4 - h, width: w, height: h), display: true)
        table.sizeLastColumnToFit()
        if list.parent == nil { parent.addChildWindow(list, ordered: .above) }
        list.orderFront(nil)
    }

    private func close() {
        pending?.cancel()   // a ranking still running mustn't reopen the list
        ranking?.cancel()
        shown = nil
        list.parent?.removeChildWindow(list)
        list.orderOut(nil)
    }

    private func select(_ r: Int) {
        guard rows.indices.contains(r) else { return table.deselectAll(nil) }
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    private func choose(_ r: Int, otherPanel: Bool) {
        guard rows.indices.contains(r), case .hit(let h) = rows[r] else { return NSSound.beep() }
        close()
        item.searchField.stringValue = ""
        item.endSearchInteraction()
        onChoose?(h, otherPanel)
    }

    /// Out of the history; the list stays open and the next Recent row takes the selection (⌘⌫ again removes it).
    private func remove(_ r: Int) {
        guard rows.indices.contains(r), case .hit(let h) = rows[r], h.removable else { return NSSound.beep() }
        onRemove?(h)
        update { [self] in
            for i in [r, r - 1] where rows.indices.contains(i) { if case .hit(let n) = rows[i], n.removable { return select(i) } }
        }
    }

    @objc private func removeClicked(_ sender: NSButton) { remove(table.row(for: sender)) }

    @objc private func clicked() { choose(table.clickedRow, otherPanel: NSApp.currentEvent?.modifierFlags.contains(.command) == true) }

    // MARK: - Field

    func controlTextDidChange(_ obj: Notification) { update(delay: .milliseconds(100)) }
    func controlTextDidEndEditing(_ obj: Notification) { close() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let step = sel == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            var r = table.selectedRow + step
            while rows.indices.contains(r), case .header = rows[r] { r += step }
            if rows.indices.contains(r) { select(r) }
        case #selector(NSResponder.insertNewline(_:)):
            let other = NSApp.currentEvent?.modifierFlags.contains(.command) == true
            // Typing paused less than 100 ms ago: the rows are the last query's (a recent command, say) — rank what was typed first.
            if shown == item.searchField.stringValue { choose(table.selectedRow, otherPanel: other) }
            else { update { [self] in choose(table.selectedRow, otherPanel: other) } }
        case #selector(NSResponder.deleteToBeginningOfLine(_:)) where item.searchField.stringValue.isEmpty:   // ⌘⌫
            remove(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            item.searchField.stringValue = ""
            item.endSearchInteraction()
            onCancel?()
        default:
            return false
        }
        return true
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .hit = rows[row] { true } else { false } }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .header = rows[row] { 20 } else { 26 } }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let g):
            let l = NSTextField(labelWithString: g.uppercased())
            l.font = .systemFont(ofSize: 10, weight: .semibold)
            l.textColor = .secondaryLabelColor
            return l
        case .hit(let h):
            let cell = tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? PickerCell ?? PickerCell()
            cell.show(title: h.title, subtitle: h.subtitle, detail: h.detail)
            cell.remove.isHidden = !h.removable
            cell.remove.target = self
            cell.remove.action = #selector(removeClicked)
            cell.remove.toolTip = "Remove from Recent  ⌘⌫"
            return cell
        }
    }
}

/// Says when a click puts the cursor in it; the delegate hears of nothing until the first keystroke.
private final class FocusField: NSSearchField {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        onFocus?()
        return true
    }
}

/// Clicks reach the results, but the search field keeps the focus.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

