import AppKit
import DFMCore

/// ⌘⇧M: rename many files at once with a live preview (Total Commander's multi-rename tool).
@MainActor
final class MultiRename: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let dir: String
    private let items: [FileItem]
    private let onDone: ([(from: String, to: String)]) -> Void
    private var newNames: [String] = []
    private var bad = Set<String>()
    private var taken = Set<String>()   // the folder's names, lowercased (APFS ignores case)

    private let nameMask = NSTextField(string: "[N]")
    private let extMask = NSTextField(string: "[E]")
    private let find = NSTextField(string: "")
    private let replace = NSTextField(string: "")
    private let regex = NSButton(checkboxWithTitle: "Regex ($1 in Replace)", target: nil, action: nil)
    private let casePopup = NSPopUpButton()
    private let start = NSTextField(string: "1")
    private let step = NSTextField(string: "1")
    private let digits = NSTextField(string: "1")
    private let table = NSTableView()
    private let message = NSTextField(labelWithString: "")
    private let renameButton = NSButton(title: "Rename", target: nil, action: nil)
    private var renaming = false

    private static var current: MultiRename?

    static func show(on parent: NSWindow, dir: String, items: [FileItem], onDone: @escaping ([(from: String, to: String)]) -> Void) {
        let m = MultiRename(dir: dir, items: items, onDone: onDone)
        current = m
        parent.beginSheet(m.window!)
    }

    private init(dir: String, items: [FileItem], onDone: @escaping ([(from: String, to: String)]) -> Void) {
        self.dir = dir
        self.items = items
        self.onDone = onDone
        super.init(window: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
                                    styleMask: [.titled, .resizable], backing: .buffered, defer: false))

        for f in [nameMask, extMask, find, replace, start, step, digits] {
            f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            f.delegate = self
        }
        for f in [start, step, digits] { f.widthAnchor.constraint(equalToConstant: 50).isActive = true }
        casePopup.addItems(withTitles: RenamePattern.Case.allCases.map(\.rawValue.capitalized))
        for c in [regex, casePopup] as [NSControl] {
            c.target = self
            c.action = #selector(controlChanged)
        }
        let tokens = NSTextField(labelWithString: "[N] name  [N2-5] chars  [E] ext  [C] counter  [P] parent  [YMD] [hms] date")
        tokens.font = .systemFont(ofSize: 11)
        tokens.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameMask, NSTextField(labelWithString: "Extension:"), extMask],
            [NSGridCell.emptyContentView, tokens, NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "Find:"), find, NSTextField(labelWithString: "Replace:"), replace],
            [NSGridCell.emptyContentView, regex, NSTextField(labelWithString: "Case:"), casePopup],
            [NSTextField(labelWithString: "Counter:"),
             NSStackView(views: [NSTextField(labelWithString: "start"), start, NSTextField(labelWithString: "step"), step,
                                 NSTextField(labelWithString: "digits"), digits]),
             NSGridCell.emptyContentView, NSGridCell.emptyContentView],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 2).xPlacement = .trailing
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 1, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 4, length: 1))

        for (id, title) in [("old", "Current name"), ("new", "New name")] {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.width = 340
            table.addTableColumn(col)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        message.textColor = Palette.fail
        message.lineBreakMode = .byTruncatingTail
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet))
        cancel.keyEquivalent = "\u{1b}"
        renameButton.target = self
        renameButton.action = #selector(renameAll)
        renameButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [message, cancel, renameButton])

        let root = NSView()
        for v in [grid, scroll, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            nameMask.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            scroll.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        window!.contentView = root
        window!.initialFirstResponder = nameMask
        recompute()
        Task { [weak self] in
            let names = await Blocking.run(.userInitiated) { Set(((try? DirLister.list(dir)) ?? []).map { $0.name.lowercased() }) }
            self?.taken = names
            self?.recompute()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var pattern: RenamePattern {
        var p = RenamePattern()
        p.nameMask = nameMask.stringValue
        p.extMask = extMask.stringValue
        p.find = find.stringValue
        p.replace = replace.stringValue
        p.regex = regex.state == .on
        p.caseMode = RenamePattern.Case.allCases[max(0, casePopup.indexOfSelectedItem)]
        p.counterStart = Int(start.stringValue) ?? 1
        p.counterStep = Int(step.stringValue) ?? 1
        p.counterDigits = Int(digits.stringValue) ?? 1
        return p
    }

    private var pairs: [(from: String, to: String)] {
        zip(items, newNames).map { ((dir as NSString).appendingPathComponent($0.name), (dir as NSString).appendingPathComponent($1)) }
    }

    private func recompute() {
        let p = pattern
        do {
            newNames = try p.apply(items.map { ($0.name, $0.mtime) }, parent: dir)
            // The folder's names, listed once (no disk call per key: thousands of them on a NAS); Apply asks the disk.
            let taken = taken
            bad = BatchRename.conflicts(pairs) { taken.contains(($0 as NSString).lastPathComponent.lowercased()) }.union(zip(pairs, newNames).filter { !BatchRename.isValidName($1) }.map(\.0.from))
            let changed = zip(items, newNames).filter { $0.name != $1 }.count
            message.stringValue = bad.isEmpty ? "" : "\(bad.count) name\(bad.count == 1 ? "" : "s") invalid or already taken"
            message.textColor = Palette.fail
            renameButton.title = "Rename \(changed)"
            renameButton.isEnabled = bad.isEmpty && changed > 0
        } catch {
            newNames = items.map(\.name)
            bad = []
            message.stringValue = error is RenamePattern.Invalid ? error.localizedDescription : "Regex: \(error.localizedDescription)"
            renameButton.isEnabled = false
        }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { recompute() }
    @objc private func controlChanged() { recompute() }

    /// Off the main thread: thousands of items on a share take a while. Meanwhile neither button acts.
    @objc private func renameAll() {
        guard !renaming else { return }
        let todo = pairs.filter { $0.from != $0.to }
        renaming = true
        message.stringValue = "Renaming…"
        message.textColor = .secondaryLabelColor
        Task {
            defer { renaming = false }
            do {
                try await Blocking.run(.userInitiated) { try BatchRename.run(todo) }
                close(with: todo)
            } catch {
                message.stringValue = error.localizedDescription
                message.textColor = Palette.fail
            }
        }
    }

    @objc private func cancelSheet() { if !renaming { close(with: []) } }

    private func close(with done: [(from: String, to: String)]) {
        window!.sheetParent?.endSheet(window!)
        Self.current = nil
        if !done.isEmpty { onDone(done) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let tf = tableView.makeView(withIdentifier: .init("t"), owner: nil) as? NSTextField ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = .init("t")
            t.lineBreakMode = .byTruncatingMiddle
            return t
        }()
        let isNew = column?.identifier.rawValue == "new"
        let name = items[row].name
        tf.stringValue = isNew ? newNames[row] : name
        let src = (dir as NSString).appendingPathComponent(name)
        tf.textColor = isNew && bad.contains(src) ? Palette.fail : isNew && newNames[row] != name ? Palette.accent : .labelColor
        return tf
    }
}
