import AppKit
import DFMCore

/// Folder tree over the active panel (MC's "Directory tree"): opens expanded down to the current folder.
/// ↑↓ move, → expand / first child, ← collapse / parent, type to jump, ↩ goes there, ⎋ closes.
@MainActor
final class DirTree: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate {
    @MainActor final class Node {
        let path: String
        var children: [Node]?   // nil = not listed yet
        init(_ path: String) { self.path = path }
        var name: String { path == "/" ? "/" : (path as NSString).lastPathComponent }
    }

    private static var current: DirTree?
    private static let icon: NSImage = {
        let i = NSWorkspace.shared.icon(for: .folder)
        i.size = NSSize(width: 16, height: 16)
        return i
    }()
    private let panel = KeyPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    private let outline = TreeOutlineView()
    private let root = Node("/")
    private let showHidden: Bool
    private let onChoose: (String) -> Void
    private weak var parent: NSWindow?

    static func show(in window: NSWindow, over view: NSView, at path: String, showHidden: Bool, onChoose: @escaping (String) -> Void) {
        current?.close()
        let t = DirTree(parent: window, showHidden: showHidden, onChoose: onChoose)
        current = t
        t.panel.setFrame(window.convertToScreen(view.convert(view.bounds, to: nil)), display: false)
        window.addChildWindow(t.panel, ordered: .above)
        t.panel.makeKeyAndOrderFront(nil)
        t.reveal(path)
    }

    private init(parent: NSWindow, showHidden: Bool, onChoose: @escaping (String) -> Void) {
        self.parent = parent
        self.showHidden = showHidden
        self.onChoose = onChoose
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.delegate = self

        let col = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .plain
        outline.rowHeight = 20
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(choose)
        outline.onKey = { [unowned self] in handleKey($0) }
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        panel.contentView = scroll
    }

    private func close() {
        panel.delegate = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKeyAndOrderFront(nil)
        if Self.current === self { Self.current = nil }
    }

    @objc private func choose() {
        guard let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
        close()
        onChoose(node.path)
    }

    // MARK: - Loading (off the main thread: a hung network volume must not freeze the UI)

    /// Folder names inside `path`; `keep` is listed even if hidden or a symlink (it's on the way to the current folder).
    private nonisolated static func subdirs(_ path: String, hidden: Bool, keep: String? = nil) -> [String] {
        ((try? DirLister.list(path)) ?? [])
            .filter { ($0.kind == .dir && (hidden || !$0.isHidden)) || $0.name == keep }
            .sortedForPanel(by: .name, ascending: true).map(\.name)
    }

    private func reveal(_ path: String) {
        let chain = path.split(separator: "/").reduce(into: ["/"]) { $0.append(($0.last! as NSString).appendingPathComponent(String($1))) }   // "/", "/Users", …
        let hidden = showHidden
        Task {
            let listings = await Blocking.run {
                chain.indices.map { i in Self.subdirs(chain[i], hidden: hidden, keep: i + 1 < chain.count ? (chain[i + 1] as NSString).lastPathComponent : nil) }
            }
            var node = root
            var expand = [root]
            for (i, names) in listings.enumerated() {
                node.children = names.map { Node((chain[i] as NSString).appendingPathComponent($0)) }
                guard i + 1 < chain.count, let next = node.children?.first(where: { $0.path == chain[i + 1] }) else { break }
                node = next
                expand.append(next)
            }
            outline.reloadData()
            for n in expand where n.children?.isEmpty == false { outline.expandItem(n) }
            let row = outline.row(forItem: node)
            outline.selectRowIndexes([max(row, 0)], byExtendingSelection: false)
            outline.scrollRowToVisible(max(row, 0))
            panel.makeFirstResponder(outline)
        }
    }

    private func load(_ node: Node) {
        let path = node.path, hidden = showHidden
        node.children = []   // don't start a second load while this one runs
        Task {
            let names = await Blocking.run { Self.subdirs(path, hidden: hidden) }
            node.children = names.map { Node((path as NSString).appendingPathComponent($0)) }
            outline.reloadItem(node, reloadChildren: true)
            if !names.isEmpty { outline.expandItem(node) }
        }
    }

    // MARK: - Keys

    private func handleKey(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        let row = outline.selectedRow
        let node = outline.item(atRow: row) as? Node
        switch e.keyCode {
        case 36, 76: choose()
        case 53: close()
        case 124:   // →
            guard let node else { return true }
            if outline.isItemExpanded(node) {
                outline.selectRowIndexes([row + 1], byExtendingSelection: false)
            } else if node.children == nil {
                load(node)
            } else {
                outline.expandItem(node)
            }
        case 123:   // ←
            guard let node else { return true }
            if outline.isItemExpanded(node) {
                outline.collapseItem(node)
            } else if let p = outline.parent(forItem: node) {
                let r = outline.row(forItem: p)
                outline.selectRowIndexes([r], byExtendingSelection: false)
                outline.scrollRowToVisible(r)
            }
        default: return false
        }
        return true
    }

    // MARK: - Data source & delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? 1 : (item as! Node).children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        item == nil ? root : (item as! Node).children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as! Node).children.map { !$0.isEmpty } ?? true
    }

    /// Clicking a disclosure triangle of a folder not listed yet loads it first.
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        let node = item as! Node
        if node.children == nil { load(node); return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = outlineView.makeView(withIdentifier: .init("cell"), owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = .init("cell")
            let iv = NSImageView(), tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            for v in [iv, tf] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
            c.imageView = iv
            c.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.imageView?.image = Self.icon
        cell.textField?.stringValue = (item as! Node).name
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as! Node).name
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

final class TreeOutlineView: NSOutlineView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}
