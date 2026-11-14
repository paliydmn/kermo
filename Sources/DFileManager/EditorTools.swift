import AppKit

/// A button of the editor's toolbar, or of More Tools, the row under it: the menu bar item it stands for — found by its
/// command or its action — and a symbol. Enabled, checked and the key in its tooltip go by that item, and a click sends
/// that item's action: one rule for the menu, the toolbar and the row (D-101).
@MainActor
struct EditorTool {
    enum Source {
        case command(String)
        case action(Selector, tag: Int = 0)
        /// The submenu holding this command's item (View ▸ Indentation): a menu to pick from.
        case submenu(of: String)
    }
    /// Shown by itself, as the shown tab is: a server's file, while it compares. Never in More Tools.
    enum When { case server, comparing }

    let id: NSToolbarItem.Identifier
    let label: String
    let symbol: Symbol
    let source: Source
    /// Its heading in More Tools.
    let group: String
    var toggle = false
    /// The editor window's own (`AppDelegate.editorWindowOnly`, its tabs, panes, terminal): not in a tool's window.
    var windowOnly = false
    var when: When?
    /// Which goes into the toolbar's » last on a narrow window.
    var priority = NSToolbarItem.VisibilityPriority.standard

    init(_ id: String, _ label: String, _ symbol: Symbol, _ source: Source, _ group: String, toggle: Bool = false,
         windowOnly: Bool = false, when: When? = nil, priority: NSToolbarItem.VisibilityPriority = .standard) {
        (self.id, self.label, self.symbol, self.source, self.group) = (.init(id), label, symbol, source, group)
        (self.toggle, self.windowOnly, self.when, self.priority) = (toggle, windowOnly, when, priority)
    }

    /// Every tool, in More Tools' order.
    static let all: [EditorTool] = [
        .init("quickOpen", "Quick Open", .quickOpen, .command("go.jump"), "File", windowOnly: true),
        .init("save", "Save", .save, .action(#selector(Editor.saveDocument(_:))), "File", priority: .high),
        .init("new", "New", .newDocument, .command("editor.new"), "File"),
        .init("saveAs", "Save As", .saveAs, .action(#selector(Editor.saveDocumentAs(_:))), "File"),
        .init("reopen", "Reopen Tab", .undo, .command("go.tree"), "File", windowOnly: true),
        .init("copyPath", "Copy Path", .copyPath, .command("edit.copyPath"), "File"),
        .init("find", "Find", .search, .action(#selector(NSResponder.performTextFinderAction(_:)), tag: NSTextFinder.Action.showFindInterface.rawValue),
              "Find", priority: .high),
        .init("goToLine", "Go to Line", .root, .command("go.path"), "Find"),
        .init("comment", "Comment", .comment, .command("view.filterPresets"), "Text", priority: .low),
        .init("wrap", "Wrap", .wrapLines, .command("text.wrap"), "Text", toggle: true),
        .init("invisibles", "Invisibles", .invisibles, .command("text.invisibles"), "Text", toggle: true, priority: .low),
        .init("newline", "Final Newline", .finalNewline, .action(#selector(Editor.toggleFinalNewline(_:))), "Text", toggle: true, priority: .low),
        .init("indent", "Indentation", .indent, .submenu(of: "text.indent.4"), "Text"),
        .init("lineUp", "Line Up", .lineUp, .command("text.line.up"), "Lines"),
        .init("lineDown", "Line Down", .lineDown, .command("text.line.down"), "Lines"),
        .init("duplicate", "Duplicate", .duplicate, .command("text.line.duplicate"), "Lines"),
        .init("deleteLine", "Delete Line", .deleteLine, .command("text.line.delete"), "Lines"),
        .init("send", "Send", .ssh, .command("editor.send"), "Terminal", windowOnly: true, priority: .high),
        .init("execute", "Execute", .execute, .command("editor.execute"), "Terminal", windowOnly: true, priority: .high),
        .init("tabs", "All Tabs", .list, .command("editor.tabs"), "Panes", windowOnly: true),
        .init("splitRight", "Split Right", .splitRight, .command("term.split.right"), "Panes", windowOnly: true, priority: .low),
        .init("splitDown", "Split Down", .splitDown, .command("term.split.down"), "Panes", windowOnly: true),
        .init("join", "Join Panes", .joinPanes, .command("editor.joinPanes"), "Panes", windowOnly: true),
        .init("moveToPane", "Move to Pane", .moveToPane, .command("editor.moveToPane"), "Panes", windowOnly: true),
        .init("cloneToPane", "Clone to Pane", .cloneToPane, .command("editor.cloneToPane"), "Panes", windowOnly: true),
        .init("compare", "Compare", .tunnel, .command("file.diff"), "Panes", windowOnly: true),
        .init("bigger", "Bigger", .bigger, .command("term.bigger"), "View"),
        .init("smaller", "Smaller", .smaller, .command("term.smaller"), "View"),
        .init("history", "History", .activity, .command("server.history"), "", when: .server),
        .init("prevChange", "Previous", .up, .command("editor.compare.prev"), "", windowOnly: true, when: .comparing, priority: .high),
        .init("nextChange", "Next", .down, .command("editor.compare.next"), "", windowOnly: true, when: .comparing, priority: .high),
        .init("copyLeft", "Copy Left", .copyLeft, .command("editor.compare.copyLeft"), "", windowOnly: true, when: .comparing),
        .init("copyRight", "Copy Right", .copyRight, .command("editor.compare.copyRight"), "", windowOnly: true, when: .comparing),
        .init("stopCompare", "Stop", .close, .command("editor.compare.stop"), "", windowOnly: true, when: .comparing, priority: .high),
    ]
    static func named(_ id: NSToolbarItem.Identifier) -> EditorTool? { all.first { $0.id == id } }

    static let backID = NSToolbarItem.Identifier("back"), moreID = NSToolbarItem.Identifier("moreTools")
    /// The toolbar's own at first, a space between groups.
    private static let first: [NSToolbarItem.Identifier] = ["quickOpen", "save", "|", "find", "goToLine", "|",
        "comment", "wrap", "invisibles", "newline", "|", "send", "execute", "|", "splitRight", "compare"].map { $0 == "|" ? .space : .init($0) }

    /// Back (Close in a tool's window) before the title, the tools on the right, More Tools' chevron last.
    static func defaults(tabbed: Bool) -> [NSToolbarItem.Identifier] {
        let ids = first.filter { tabbed || named($0)?.windowOnly != true }
        var kept = ids.enumerated().filter { i, id in id != .space || i > 0 && ids[i - 1] != .space }.map(\.element)   // a tool window's: no two spaces running
        while kept.last == .space { kept.removeLast() }
        return [backID, .flexibleSpace] + kept + [moreID]
    }
    /// Customize Toolbar…'s: not the shown tab's own (History, Compare's), which come and go by themselves.
    static func allowed(tabbed: Bool) -> [NSToolbarItem.Identifier] {
        [backID, moreID, .space, .flexibleSpace] + all.filter { $0.when == nil && (tabbed || !$0.windowOnly) }.map(\.id)
    }

    // MARK: The menu bar item

    /// The menu bar the tools go by (tests: their own).
    static var menu: () -> NSMenu? = { NSApp.mainMenu }
    /// Found once per menu bar (a config reload makes a new one).
    private static var found: (menu: NSMenu?, items: [NSToolbarItem.Identifier: NSMenuItem]) = (nil, [:])

    func menuItem() -> NSMenuItem? {
        guard let menu = Self.menu() else { return nil }
        if Self.found.menu !== menu { Self.found = (menu, [:]) }
        if let it = Self.found.items[id] { return it }
        let it: NSMenuItem? = switch source {
        case .command(let c): menu.allItems.first { $0.representedObject as? String == c }
        case .action(let a, let tag): menu.allItems.first { $0.action == a && $0.tag == tag }
        case .submenu(let c): menu.allItems.first { $0.submenu?.items.contains { $0.representedObject as? String == c } == true }
        }
        Self.found.items[id] = it
        return it
    }

    /// As things are now in `w`: whether it works (the item's own validation), its check mark, and its tooltip — the
    /// menu's title (an editor's: Go to Line…, Toggle Comment) with its key, or the editor's own for it (⌃↩ Send to
    /// Terminal, ⌥⌘↓ Next Change).
    func state(in w: NSWindow) -> (enabled: Bool, on: Bool, tip: String) {
        guard let it = menuItem() else { return (false, false, label) }
        if case .submenu = source { return (it.submenu?.items.contains { AppDelegate.works($0, in: w) } == true, false, it.title) }
        let enabled = AppDelegate.works(it, in: w)
        let command: String? = if case .command(let c) = source { c } else { nil }
        let key = Shortcut(menuItem: it)?.display ?? command.flatMap(Editor.terminalKey)?.display
            ?? (when == .comparing ? Editor.keys(of: w)?.first { $0.title == it.title }?.key : nil)
        return (enabled, it.state == .on, it.title + (key.map { " " + $0 } ?? ""))
    }

    /// Clicked: its item's action, as the menu sends it (a submenu's tool pops its menu up under `view`).
    func run(in w: NSWindow, from view: NSView?) {
        guard let it = menuItem() else { return NSSound.beep() }
        if case .submenu = source, let view {
            _ = Self.copy(of: it.submenu)?.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
            return
        }
        guard let action = it.action, let target = AppDelegate.target(of: it, in: w), AppDelegate.works(it, in: w) else { return NSSound.beep() }
        NSApp.sendAction(action, to: target, from: it)   // to this window's, as `works` found it
    }

    /// A menu's items again, in a menu of their own: an item belongs to one menu (a toolbar's pick list, a right click).
    static func copy(of menu: NSMenu?) -> NSMenu? {
        guard let menu else { return nil }
        let m = NSMenu(title: menu.title)
        for it in menu.items { m.addItem(it.copy() as! NSMenuItem) }
        return m
    }

    /// A button for More Tools: its symbol, a toggle's on and off; a click goes to `host`.
    func button(target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(image: symbol.image(label), target: target, action: action)
        b.bezelStyle = .toolbar   // as the toolbar's: no frame until the mouse is over it
        b.setButtonType(toggle ? .pushOnPushOff : .momentaryPushIn)
        b.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
        b.setAccessibilityLabel(label)
        b.toolTip = label
        return b
    }
}

extension EditorTool {
    /// The text's right click, after Paste: the menu bar's items again for what acts on the click's place — Send /
    /// Execute in Terminal (with their ⌃↩ ⌃⇧↩), Toggle Comment, Lines ▸, Copy Change while it compares, Copy Path of a
    /// file, a server file's History. A group a separator each; they validate and run as in the menu bar.
    static func contextItems(for e: Editor) -> [NSMenuItem] {
        guard let host = e.host else { return [] }
        func item(_ tool: String) -> NSMenuItem? {
            guard let t = named(.init(tool)), let it = t.menuItem()?.copy() as? NSMenuItem else { return nil }
            if case .command(let c) = t.source, let k = Editor.terminalKey(c) { (it.keyEquivalent, it.keyEquivalentModifierMask) = (k.menuKey, k.flags) }
            return it
        }
        let lines = named(.init("lineUp"))?.menuItem()?.parent?.copy() as? NSMenuItem   // Edit ▸ Lines, its submenu copied with it
        let file = e.url != nil || e.server != nil
        let groups: [[NSMenuItem?]] = [
            host.tabbed ? [item("send"), item("execute")] : [],
            [item("comment"), lines],
            host.comparison != nil ? [item("copyLeft"), item("copyRight")] : [],
            [file ? item("copyPath") : nil, e.server != nil ? item("history") : nil],
        ]
        return groups.map { $0.compactMap { $0 } }.filter { !$0.isEmpty }.flatMap { [NSMenuItem.separator()] + $0 }
    }
}

/// A tool in the toolbar: AppKit asks it as it validates — enabled, a toggle's on, the tooltip — and it asks its tool.
@MainActor
final class ToolItem: NSToolbarItem {
    let tool: EditorTool
    private weak var host: NSWindowController?

    init(_ tool: EditorTool, host: NSWindowController, action: Selector) {
        self.tool = tool
        self.host = host
        super.init(itemIdentifier: tool.id)
        (label, paletteLabel, toolTip, visibilityPriority) = (tool.label, tool.label, tool.label, tool.priority)
        if tool.toggle {   // a button of its own: AppKit's toolbar items have no "on"
            view = tool.button(target: host, action: action)
        } else {
            image = tool.symbol.image(tool.label)
            isBordered = true
            target = host
            self.action = action
        }
    }

    /// A toggle in », its menu item again: it validates and checks itself there, as in the menu.
    override var menuFormRepresentation: NSMenuItem? {
        get {
            guard tool.toggle, let it = tool.menuItem()?.copy() as? NSMenuItem else { return super.menuFormRepresentation }
            it.title = tool.label
            return it
        }
        set { super.menuFormRepresentation = newValue }
    }

    /// The window keys go to only: the menu's items answer for that one.
    override func validate() {
        guard let w = host?.window, w === AppDelegate.keyWindow() else { return }
        let s = tool.state(in: w)
        isEnabled = s.enabled
        toolTip = s.tip
        if let b = view as? NSButton { (b.isEnabled, b.state, b.toolTip) = (s.enabled, s.on ? .on : .off, s.tip) }
    }
}

/// More Tools: the row under the toolbar with every tool the toolbar hasn't now (the user's Customize Toolbar… moves
/// them between the two), by group, flush right as the toolbar is. Open or closed for every editor window alike.
@MainActor
final class MoreTools: NSTitlebarAccessoryViewController {
    private let stack = NSStackView()
    private(set) var buttons: [(tool: EditorTool, button: NSButton)] = []
    /// Each group's heading and buttons, in order: what `viewDidLayout` shows or hides whole.
    private var groups: [[NSView]] = []

    /// Open or closed: remembered (View ▸ Show More Tools, the toolbar's chevron).
    static var shown: Bool {
        get { UserDefaults.standard.bool(forKey: "editorMoreTools") }
        set { UserDefaults.standard.set(newValue, forKey: "editorMoreTools") }
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .bottom
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 34))
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.detachesHiddenViews = true
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)   // a hidden group's width goes before the row's edges
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor), stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        view = row
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `tools` by group, each headed by its name.
    func fill(_ tools: [EditorTool], target: AnyObject, action: Selector) {
        buttons = tools.map { ($0, $0.button(target: target, action: action)) }
        groups = []
        for (i, (tool, button)) in buttons.enumerated() {
            if i == 0 || buttons[i - 1].tool.group != tool.group {
                let heading = NSTextField(labelWithString: tool.group)
                heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                heading.textColor = .secondaryLabelColor
                groups.append([heading])
            }
            groups[groups.count - 1].append(button)
        }
        stack.setViews(groups.flatMap { $0 }, in: .trailing)
        groups.dropLast().forEach { stack.setCustomSpacing(14, after: $0.last!) }
        view.needsLayout = true
    }

    /// The groups that fit the row, in order: on a narrow window the last ones go, whole.
    override func viewDidLayout() {
        super.viewDidLayout()
        var room = view.bounds.width - stack.edgeInsets.left - stack.edgeInsets.right, gone = false
        for (i, g) in groups.enumerated() {
            let width = g.map(\.fittingSize.width).reduce(0, +) + CGFloat(g.count - 1) * stack.spacing + (i > 0 ? 14 : 0)
            gone = gone || width > room
            room -= width
            for v in g where v.isHidden != gone { v.isHidden = gone }   // only a change: no layout loop
        }
    }

    /// As the toolbar's are validated: the window updates.
    func validate(in w: NSWindow) {
        for (tool, b) in buttons {
            let s = tool.state(in: w)
            (b.isEnabled, b.toolTip) = (s.enabled, s.tip)
            if tool.toggle { b.state = s.on ? .on : .off }
        }
    }
}
