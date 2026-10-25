import AppKit
import DFMCore

/// ⌘⇧S Synchronize Folders: compare the two panels recursively, review/adjust each row's direction,
/// then copy through the normal job queue. The preview is the dry run. Mirror modes also send what exists
/// only on the target side to the Trash (a server has none: deleted there). Either side may be a server.
@MainActor
final class SyncWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var open: [SyncWindow] = []
    private let left: String
    private let right: String
    private let sides: (left: Endpoint, right: Endpoint)
    private let enqueue: ([(job: FileJob, label: String)]) async -> Bool   // false: nothing queued (locked, Cancel)
    private var compared: [DirSync.Item] = []   // as compared (two-way defaults)
    private var items: [DirSync.Item] = []      // with the chosen mode and the user's edits
    private var comparedAt: Double?                // when the Compare that `compared` holds began
    private var shown: [Int] = []   // indices into items
    private var flag: CancelFlag?

    private let table = NSTableView()
    private let contentBox = NSButton(checkboxWithTitle: "Compare contents (slow)", target: nil, action: nil)
    private let hiddenBox = NSButton(checkboxWithTitle: "Include hidden", target: nil, action: nil)
    private let equalBox = NSButton(checkboxWithTitle: "Show equal", target: nil, action: nil)
    private let modePopup = NSPopUpButton(title: "", target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private let syncButton = NSButton(title: "Synchronize", target: nil, action: nil)
    private let keys = KeyBarView(chips: false)

    static func show(left: String, right: String, sides: (left: Endpoint, right: Endpoint),
                     enqueue: @escaping ([(job: FileJob, label: String)]) async -> Bool) {
        let w = SyncWindow(left: left, right: right, sides: sides, enqueue: enqueue)
        open.append(w)
        w.showWindow(nil)
        w.compare()
    }

    private init(left: String, right: String, sides: (left: Endpoint, right: Endpoint), enqueue: @escaping ([(job: FileJob, label: String)]) async -> Bool) {
        self.left = left
        self.right = right
        self.sides = sides
        self.enqueue = enqueue
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Synchronize Folders"
        w.subtitle = DirSync.place(sides.left, left) + "  ↔  " + DirSync.place(sides.right, right)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self

        for (id, title, width) in [("path", "Path", 380.0), ("left", "Left", 200), ("action", "", 44), ("right", "Right", 200)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            if id == "action" { c.headerCell.alignment = .center }
            table.addTableColumn(c)
        }
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        for b in [contentBox, hiddenBox] { b.target = self; b.action = #selector(compare) }
        contentBox.isEnabled = sides == (.local, .local)   // it reads both files whole: not across a network
        equalBox.target = self
        equalBox.action = #selector(refilter)
        modePopup.addItems(withTitles: ["Two-way (newer wins)", "Mirror → right", "Mirror ← left"])
        modePopup.target = self
        modePopup.action = #selector(applyMode)
        func button(_ t: String, _ a: Selector) -> NSButton {
            let b = NSButton(title: t, target: self, action: a)
            b.controlSize = .small
            return b
        }
        let top = NSStackView(views: [modePopup, contentBox, hiddenBox, equalBox, NSView(),
                                      NSTextField(labelWithString: "Selected:"), button("→ Right", #selector(setRight)),
                                      button("← Left", #selector(setLeft)), button("Trash", #selector(setTrash)), button("Skip", #selector(setSkip))])
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        syncButton.target = self
        syncButton.action = #selector(synchronize)
        syncButton.keyEquivalent = "\r"
        let bottom = NSStackView(views: [summary, syncButton])

        let root = NSView()
        for v in [top, scroll, bottom, keys] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: v === keys ? 0 : 12),
                v.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: v === keys ? 0 : -12),
            ])
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            bottom.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            keys.topAnchor.constraint(equalTo: bottom.bottomAnchor, constant: 4),
            keys.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        w.contentView = root
        w.center()
        w.setFrameAutosaveName("Sync")
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let dateFormat: DateFormatter = {   // one, not one per cell
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

    override func cancelOperation(_ sender: Any?) { window?.performClose(nil) }   // ⎋: closes, and so stops Comparing…

    /// Its own keys, first on its key bar (then the menu bar's that work there, as F1 over it lists them).
    static func keys(of window: NSWindow?) -> [AppDelegate.KeyRow]? {
        open.first { $0.window === window && window != nil }.map { s in
            [AppDelegate.KeyRow(section: "Synchronize", title: "Synchronize", key: "↩") { if s.syncButton.isEnabled { s.synchronize() } },
             AppDelegate.KeyRow(section: "Synchronize", title: "Close", key: "⎋") { s.cancelOperation(nil) }]
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {   // the menu's keys work by the key window
        if let w = window { keys.show(DocFrame.rows(w)) }
    }

    func windowWillClose(_ notification: Notification) {
        flag?.cancel()
        Self.open.removeAll { $0 === self }
    }

    // MARK: - Compare (background)

    @objc private func compare() {
        flag?.cancel()
        let flag = CancelFlag()
        self.flag = flag
        summary.stringValue = "Comparing…"
        let began = Date().timeIntervalSince1970
        syncButton.isEnabled = false
        let (l, r, sides, byContent, hidden) = (left, right, sides, contentBox.isEnabled && contentBox.state == .on, hiddenBox.state == .on)
        Task { [weak self] in
            let result = await Blocking.run(.userInitiated) {
                let (a, b) = (DirSync.lister(sides.left, env: SSHAskpass.env, cancel: flag), DirSync.lister(sides.right, env: SSHAskpass.env, cancel: flag))
                defer { a.close(); b.close() }
                return DirSync.compare(left: l, right: r, byContent: byContent, includeHidden: hidden, isCancelled: { flag.isCancelled },
                                       list: a.list, listRight: b.list,
                                       tolerance: DirSync.mtimeTolerance([sides.left == .local ? l : nil, sides.right == .local ? r : nil].compactMap { $0 }))
            }
            guard let self, !flag.isCancelled else { return }
            compared = result
            comparedAt = began
            applyMode()
        }
    }

    @objc private func applyMode() {
        let m = modePopup.indexOfSelectedItem
        items = m == 0 ? compared : DirSync.mirror(compared, toRight: m == 1)
        refilter()
    }

    @objc private func refilter() {
        shown = items.indices.filter { equalBox.state == .on || items[$0].action != .equal }
        table.reloadData()
        updateSummary()
    }

    private func updateSummary() {
        func total(_ a: DirSync.Action, _ side: (DirSync.Item) -> FileItem?) -> (Int, Int64) {
            let xs = items.filter { $0.action == a }
            return (xs.count, xs.reduce(0) { $0 + (side($1)?.size ?? 0) })
        }
        let (nr, br) = total(.toRight, \.left)
        let (nl, bl) = total(.toLeft, \.right)
        let conflicts = items.filter { $0.isConflict && $0.action == .skip }.count
        let equal = items.filter { $0.action == .equal }.count
        let trash = items.filter { $0.action == .trashLeft || $0.action == .trashRight }.count
        func gone(_ a: DirSync.Action, _ side: Endpoint) -> String {
            let n = items.filter { $0.action == a }.count
            guard n > 0 else { return "" }
            if case .sftp(let t) = side { return "deleted on \(t.host): \(n)   " }
            return "to Trash: \(n)   "
        }
        summary.stringValue = items.isEmpty && flag?.isCancelled == false ? "Folders are identical."
            : "→ \(nr) (\(ByteCountFormatter.short(br)))   ← \(nl) (\(ByteCountFormatter.short(bl)))   "
            + gone(.trashLeft, sides.left) + gone(.trashRight, sides.right) + "conflicts skipped: \(conflicts)   equal: \(equal)   · click a row's arrow to change it"
        syncButton.isEnabled = nr + nl + trash > 0
    }

    // MARK: - Editing directions

    private func setAction(_ a: DirSync.Action, rows: IndexSet) {
        for r in rows where shown.indices.contains(r) {
            let i = shown[r]
            let choices = DirSync.choices(items[i])
            if choices.contains(a) { items[i].action = a }
            else if a == .trashLeft, choices.contains(.trashRight) { items[i].action = .trashRight }   // Trash: whichever side has it
        }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 2))
        updateSummary()
    }

    @objc private func setRight() { setAction(.toRight, rows: table.selectedRowIndexes) }
    @objc private func setLeft() { setAction(.toLeft, rows: table.selectedRowIndexes) }
    @objc private func setSkip() { setAction(.skip, rows: table.selectedRowIndexes) }
    @objc private func setTrash() { setAction(.trashLeft, rows: table.selectedRowIndexes) }

    /// Clicking the arrows' column cycles through what the row can do.
    @objc private func rowClicked() {
        guard table.clickedColumn == 2, shown.indices.contains(table.clickedRow) else { return }
        let it = items[shown[table.clickedRow]]
        let choices = DirSync.choices(it)
        setAction(choices[((choices.firstIndex(of: it.action) ?? -1) + 1) % choices.count], rows: [table.clickedRow])
    }

    /// The window (and its edited plan) stays if the jobs weren't queued: a server stayed locked, or Cancel.
    @objc private func synchronize() {
        syncButton.isEnabled = false
        let jobs = DirSync.jobs(items, left: left, right: right, sides: sides, env: SSHAskpass.env, comparedAt: comparedAt)
        Task { [weak self] in
            if await self?.enqueue(jobs) == true { self?.window?.close() } else { self?.syncButton.isEnabled = true }
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let tf = tableView.makeView(withIdentifier: .init("t"), owner: nil) as? NSTextField ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = .init("t")
            t.lineBreakMode = .byTruncatingMiddle
            return t
        }()
        let it = items[shown[row]]
        let df = Self.dateFormat
        func side(_ f: FileItem?) -> String {
            guard let f else { return "—" }
            return f.kind == .dir ? "folder" : "\(ByteCountFormatter.short(f.size)) · \(df.string(from: Date(timeIntervalSince1970: f.mtime)))"
        }
        tf.alignment = .left
        tf.font = .systemFont(ofSize: NSFont.systemFontSize)
        tf.textColor = .labelColor
        switch column?.identifier.rawValue {
        case "path":
            tf.stringValue = it.path + ((it.left ?? it.right)?.kind == .dir ? "/" : "") + (it.unreadable.map { "  — can't read: \($0)" } ?? "")
            if it.isConflict { tf.textColor = Palette.warn }
        case "left": tf.stringValue = side(it.left)
        case "right": tf.stringValue = side(it.right)
        default:
            tf.alignment = .center
            tf.font = .boldSystemFont(ofSize: 14)
            let font = tf.font!, dot = NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            let center = NSMutableParagraphStyle()
            center.alignment = .center
            let mark = NSMutableAttributedString()
            switch it.action {   // which way, in the text's color; a conflict amber, the Trash red: it deletes
            case .toRight: mark.append(Symbol.right.text(.labelColor, font: font, label: "copy to the right"))
            case .toLeft: mark.append(Symbol.left.text(.labelColor, font: font, label: "copy to the left"))
            case .skip where it.isConflict: mark.append(Symbol.warn.text(Palette.warn, font: font, label: "conflict, skipped"))
            case .skip: mark.append(NSAttributedString(string: "·", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            case .equal: mark.append(NSAttributedString(string: "=", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            case .trashLeft: mark.append(Symbol.trash.text(Palette.fail, font: font, label: "to the Trash on the left")); mark.append(dot)
            case .trashRight: mark.append(dot); mark.append(Symbol.trash.text(Palette.fail, font: font, label: "to the Trash on the right"))
            }
            mark.addAttribute(.paragraphStyle, value: center, range: NSRange(location: 0, length: mark.length))
            tf.attributedStringValue = mark
        }
        return tf
    }
}
