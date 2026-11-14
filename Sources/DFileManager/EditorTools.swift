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
    let symbol: String
    let source: Source
    /// Its heading in More Tools.
    let group: String
    var toggle = false
    /// The editor window's own (`AppDelegate.editorWindowOnly`, its tabs, panes, terminal): not in a tool's window.
    var windowOnly = false
    var when: When?
    /// Which goes into the toolbar's » last on a narrow window.
    var priority = NSToolbarItem.VisibilityPriority.standard

    init(_ id: String, _ label: String, _ symbol: String, _ source: Source, _ group: String, toggle: Bool = false,
         windowOnly: Bool = false, when: When? = nil, priority: NSToolbarItem.VisibilityPriority = .standard) {
        (self.id, self.label, self.symbol, self.source, self.group) = (.init(id), label, symbol, source, group)
        (self.toggle, self.windowOnly, self.when, self.priority) = (toggle, windowOnly, when, priority)
    }

    /// Every tool, in More Tools' order.
    static let all: [EditorTool] = [
        .init("quickOpen", "Quick Open", "doc.text.magnifyingglass", .command("go.jump"), "File", windowOnly: true),
        .init("save", "Save", "square.and.arrow.down", .action(#selector(Editor.saveDocument(_:))), "File", priority: .high),
        .init("new", "New", "square.and.pencil", .command("editor.new"), "File"),
        .init("saveAs", "Save As", "square.and.arrow.down.on.square", .action(#selector(Editor.saveDocumentAs(_:))), "File"),
        .init("reopen", "Reopen Tab", "arrow.uturn.backward", .command("go.tree"), "File", windowOnly: true),
        .init("copyPath", "Copy Path", "doc.on.clipboard", .command("edit.copyPath"), "File"),
        .init("find", "Find", "magnifyingglass", .action(#selector(NSResponder.performTextFinderAction(_:)), tag: NSTextFinder.Action.showFindInterface.rawValue),
              "Find", priority: .high),
        .init("goToLine", "Go to Line", "number", .command("go.path"), "Find"),
        .init("comment", "Comment", "chevron.left.forwardslash.chevron.right", .command("view.filterPresets"), "Text", priority: .low),
        .init("wrap", "Wrap", "text.append", .command("text.wrap"), "Text", toggle: true),
        .init("invisibles", "Invisibles", "paragraphsign", .command("text.invisibles"), "Text", toggle: true, priority: .low),
        .init("newline", "Final Newline", "return", .action(#selector(Editor.toggleFinalNewline(_:))), "Text", toggle: true, priority: .low),
        .init("indent", "Indentation", "increase.indent", .submenu(of: "text.indent.4"), "Text"),
        .init("lineUp", "Line Up", "arrow.up.to.line.compact", .command("text.line.up"), "Lines"),
        .init("lineDown", "Line Down", "arrow.down.to.line.compact", .command("text.line.down"), "Lines"),
        .init("duplicate", "Duplicate", "plus.square.on.square", .command("text.line.duplicate"), "Lines"),
        .init("deleteLine", "Delete Line", "text.badge.minus", .command("text.line.delete"), "Lines"),
        .init("send", "Send", "apple.terminal", .command("editor.send"), "Terminal", windowOnly: true, priority: .high),
        .init("execute", "Execute", "play", .command("editor.execute"), "Terminal", windowOnly: true, priority: .high),
        .init("tabs", "All Tabs", "list.bullet", .command("editor.tabs"), "Panes", windowOnly: true),
        .init("splitRight", "Split Right", "rectangle.split.2x1", .command("term.split.right"), "Panes", windowOnly: true, priority: .low),
        .init("splitDown", "Split Down", "rectangle.split.1x2", .command("term.split.down"), "Panes", windowOnly: true),
        .init("join", "Join Panes", "rectangle", .command("editor.joinPanes"), "Panes", windowOnly: true),
        .init("moveToPane", "Move to Pane", "rectangle.righthalf.inset.filled.arrow.right", .command("editor.moveToPane"), "Panes", windowOnly: true),
        .init("cloneToPane", "Clone to Pane", "rectangle.on.rectangle", .command("editor.cloneToPane"), "Panes", windowOnly: true),
        .init("compare", "Compare", "arrow.left.arrow.right", .command("file.diff"), "Panes", windowOnly: true),
        .init("bigger", "Bigger", "textformat.size.larger", .command("term.bigger"), "View"),
        .init("smaller", "Smaller", "textformat.size.smaller", .command("term.smaller"), "View"),
        .init("history", "History", "clock.arrow.circlepath", .command("server.history"), "", when: .server),
        .init("prevChange", "Previous", "arrow.up", .command("editor.compare.prev"), "", windowOnly: true, when: .comparing, priority: .high),
        .init("nextChange", "Next", "arrow.down", .command("editor.compare.next"), "", windowOnly: true, when: .comparing, priority: .high),
        .init("copyLeft", "Copy Left", "arrow.left.to.line", .command("editor.compare.copyLeft"), "", windowOnly: true, when: .comparing),
        .init("copyRight", "Copy Right", "arrow.right.to.line", .command("editor.compare.copyRight"), "", windowOnly: true, when: .comparing),
        .init("stopCompare", "Stop", "xmark", .command("editor.compare.stop"), "", windowOnly: true, when: .comparing, priority: .high),
    ]
    static func named(_ id: NSToolbarItem.Identifier) -> EditorTool? { all.first { $0.id == id } }

    static let backID = NSToolbarItem.Identifier("back"), moreID = NSToolbarItem.Identifier("moreTools")
    /// The toolbar's own at first, a space between groups.
    private static let first: [NSToolbarItem.Identifier] = ["quickOpen", "save", "|", "find", "goToLine", "|",
        "comment", "wrap", "invisibles", "newline", "|", "send", "execute", "|", "splitRight", "compare"].map { $0 == "|" ? .space : .init($0) }

    /// Back (Close in a tool's window) before the title, the tools on the right, More Tools' chevron last.
    static func defaults(tabbed: Bool) -> [NSToolbarItem.Identifier] {
        let ids = first.filter { tabbed || named($0)?.windowOnly != true }
        let kept = ids.enumerated().filter { i, id in id != .space || i > 0 && ids[i - 1] != .space }.map(\.element)   // a tool window's: no two spaces running
        return [backID, .flexibleSpace] + kept + [moreID]
    }
    static func allowed(tabbed: Bool) -> [NSToolbarItem.Identifier] {
        [backID, moreID, .space, .flexibleSpace] + all.filter { tabbed || !$0.windowOnly }.map(\.id)
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
    /// menu's title (an editor's: Go to Line…, Toggle Comment) with its key, or the editor's own for it (⌃↩ Send to Terminal).
    func state(in w: NSWindow) -> (enabled: Bool, on: Bool, tip: String) {
        guard let it = menuItem() else { return (false, false, label) }
        if case .submenu = source { return (it.submenu?.items.contains { AppDelegate.works($0, in: w) } == true, false, it.title) }
        let enabled = AppDelegate.works(it, in: w)
        let key = Shortcut(menuItem: it)?.display ?? Editor.keys(of: w)?.first { $0.title == it.title }?.key
        return (enabled, it.state == .on, it.title + (key.map { " " + $0 } ?? ""))
    }

    /// Clicked: its item's action, as the menu sends it (a submenu's tool pops its menu up under `view`).
    func run(in w: NSWindow, from view: NSView?) {
        guard let it = menuItem() else { return NSSound.beep() }
        if case .submenu = source, let view {
            _ = Self.copy(of: it.submenu)?.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
            return
        }
        guard let action = it.action, AppDelegate.works(it, in: w) else { return NSSound.beep() }
        NSApp.sendAction(action, to: it.target, from: it)
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
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: target, action: action)
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
        guard let menu = menu(), let host = e.host else { return [] }
        func item(_ id: String) -> NSMenuItem? {
            guard let it = menu.allItems.first(where: { $0.representedObject as? String == id })?.copy() as? NSMenuItem else { return nil }
            if let panel = AppDelegate.editorTerminalKeys.first(where: { $0.value == id })?.key,   // a key picked off the panels'
               let k = Editor.app()?.commands.first(where: { $0.id == panel })?.keys.first {
                (it.keyEquivalent, it.keyEquivalentModifierMask) = (k.menuKey, k.flags)
            }
            return it
        }
        let lines = menu.allItems.first { $0.submenu?.items.contains { $0.representedObject as? String == "text.line.up" } == true }.map { parent in
            let it = NSMenuItem(title: parent.title, action: nil, keyEquivalent: "")
            it.submenu = copy(of: parent.submenu)
            return it
        }
        let file = e.url != nil || e.server != nil
        let groups: [[NSMenuItem?]] = [
            host.tabbed ? [item("editor.send"), item("editor.execute")] : [],
            [item("view.filterPresets"), lines],
            host.comparison != nil ? [item("editor.compare.copyLeft"), item("editor.compare.copyRight")] : [],
            [file ? item("edit.copyPath") : nil, e.server != nil ? item("server.history") : nil],
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
        let image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.label)
        if tool.toggle {   // a button of its own: AppKit's toolbar items have no "on"
            view = tool.button(target: host, action: action)
            menuFormRepresentation = NSMenuItem(title: tool.label, action: action, keyEquivalent: "")
            menuFormRepresentation?.target = host
            menuFormRepresentation?.identifier = NSUserInterfaceItemIdentifier(tool.id.rawValue)
        } else {
            self.image = image
            isBordered = true
            target = host
            self.action = action
        }
    }

    override func validate() {
        guard let w = host?.window else { return }
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
        for g in groups {
            let width = g.map(\.fittingSize.width).reduce(0, +) + CGFloat(g.count) * stack.spacing + 14
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
