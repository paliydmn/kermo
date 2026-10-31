import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Review 1, phase 6: the menu bar from the registry — groups, submenus, Server and Help, ✓ on switches.

/// The commands that are keys by nature, each with why: everything else is a menu item, so macOS's Help search finds it.
private let keyboardOnly: [String: String] = [
    "panel.switch": "⇥ between panels; the mouse clicks one",
    "open": "↩ on a row; the mouse double-clicks it",
    "term.pane.left": "moves between terminal panes; the mouse clicks one", "term.pane.right": "as Focus Pane Left",
    "term.pane.up": "as Focus Pane Left", "term.pane.down": "as Focus Pane Left",
    "term.resize.left": "moves a pane divider; the mouse drags it", "term.resize.right": "as Move Pane Divider Left",
    "term.resize.up": "as Move Pane Divider Left", "term.resize.down": "as Move Pane Divider Left",
    "panel.menu": "⇧F10 or the Menu key; the mouse right-clicks",
    "mark.down": "marks while moving the cursor; Mark / Unmark is in the menu", "mark.up": "as Mark and Move Down",
    "cmdline.insert": "types into the command line from a panel", "cmdline.insertPaths": "as Insert Name into Command Line",
    "list.keys": "? inside a list of a server's only (type-select elsewhere); F1 lists every key",
    "list.go": ": inside a list of a server's only (type-select elsewhere); the overview's rows are the menu's Server ▸ Overview",
]

@MainActor private func app() -> AppDelegate {
    _ = NSApplication.shared
    let app = AppDelegate()
    app.commands = app.makeCommands()
    return app
}

/// A menu as titles: "Name ▸" a submenu, "—" a separator.
private func titles(_ nodes: [AppDelegate.MenuNode]) -> [String] {
    nodes.map { n in
        switch n {
        case .command(let c): c.title
        case .submenu(let name, _): name + " ▸"
        case .separator: "—"
        }
    }
}

@MainActor private func submenu(_ menu: NSMenu, _ path: String) -> NSMenu? {
    var m: NSMenu? = menu
    for title in path.split(separator: "/") { m = m?.items.first { $0.submenu?.title == String(title) }?.submenu }
    return m
}

@MainActor @Test func everyCommandIsAMenuItem() {
    let app = app()
    let listed = Set(app.makeMenu().allItems.compactMap { $0.representedObject as? String })
    for c in app.commands where !c.hidden {
        #expect(listed.contains(c.id) != (keyboardOnly[c.id] != nil), "\(c.id): a menu item, or keyboard only with a reason")
        #expect((c.menu == nil) == (keyboardOnly[c.id] != nil), "\(c.id)")
    }
    #expect(Set(keyboardOnly.keys).isSubset(of: app.commands.map(\.id)), "a renamed command leaves the list")
    #expect(!app.commands.filter(\.hidden).contains { listed.contains($0.id) })
}

@MainActor @Test func theMenuBarIsTheRegistrys() throws {
    let app = app(), menu = app.makeMenu()
    #expect(menu.items.compactMap(\.submenu?.title) == ["Kermo", "File", "Edit", "Mark", "View", "Go", "Server", "Git", "Window", "Help"])
    // By title: `NSApp.helpMenu` is global, and a test beside this one may have made its own menu (as D-108).
    #expect(NSApp.helpMenu?.title == "Help" && NSApp.helpMenu?.items.contains { $0.representedObject as? String == "help.keys" } == true)
    #expect(titles(AppDelegate.menuItems(app.commands, in: "Server")) == [
        "Connect to Server…", "New SSH Session…", "New Server…", "—", "Overview", "Services…", "Containers…", "Ports & Tunnels ▸", "—",
        "Reopen as Root", "Reopen as User", "—", "Copy SSH Key to Server…", "File History…", "Watch Server…", "Run on Servers…", "—",
        "Disconnect", "Reconnect SSH Session", "Edit SSH Config…", "Production Log"])
    #expect(titles(AppDelegate.menuItems(app.commands, in: "View")).prefix(8) == ["Sidebar", "Quick View", "Terminal", "Maximize Terminal", "Activity", "—", "Tabs ▸", "Panels ▸"])
    #expect(titles(AppDelegate.menuItems(app.commands, in: "View/Sort By")) == ["Name", "Size", "Modified", "—", "Reverse"])
    #expect(titles(AppDelegate.menuItems(app.commands, in: "File/As Administrator")) == [
        "Copy as Administrator…", "Move as Administrator…", "New Folder as Administrator…", "Delete as Administrator…", "—",
        "Root Shell in Terminal", "Enable Touch ID for sudo"])
    #expect(titles(AppDelegate.menuItems(app.commands, in: "File")).last == "As Administrator ▸")
    for path in ["Kermo", "File", "Edit", "Mark", "View", "Go", "Server", "Git", "Help", "Kermo/Configuration", "View/Tabs", "Mark/Tags"] {
        let t = titles(AppDelegate.menuItems(app.commands, in: path))
        #expect(t.first != "—" && t.last != "—" && !zip(t, t.dropFirst()).contains { $0 == "—" && $1 == "—" }, "\(path): \(t)")
    }
    // The built menu: the registry's items, then what's live (tunnels) under them; Admin is gone.
    let ports = try #require(submenu(menu, "Server/Ports & Tunnels"))
    #expect(ports.items.map(\.title) == ["Tunnels…", "New Tunnel…", "Forward Port…"])
    ports.delegate?.menuNeedsUpdate?(ports)
    #expect(ports.items.prefix(3).map(\.title) == ["Tunnels…", "New Tunnel…", "Forward Port…"], "kept when it opens")
    #expect(submenu(menu, "File/As Administrator")?.items.first?.representedObject as? String == "admin.copy")
    #expect(!app.commands.contains { $0.topMenu == "Admin" })
}

/// Tools PR 2 / phase 7 add Server ▸ Tools ▸ and Overview as commands: one registry entry, no `makeMenu` change.
@MainActor @Test func aNewSubmenuIsOneRegistryEntry() {
    let tool = Command(id: "tools.x", title: "Firewall…", keys: [], menu: "Server/Tools", group: 2, short: "", aliases: "") { _ in }
    let server = titles(AppDelegate.menuItems(app().commands + [tool], in: "Server"))
    #expect(server.firstIndex(of: "Tools ▸") == server.firstIndex(of: "Ports & Tunnels ▸").map { $0 + 1 }, "\(server)")
    #expect(titles(AppDelegate.menuItems([tool], in: "Server/Tools")) == ["Firewall…"])
}

/// No key is on two menu items — the first would take it (D-101) — and a command's item has its first key.
@MainActor @Test func noKeyIsOnTwoMenuItems() {
    let app = app(), items = app.makeMenu().allItems.filter { !$0.keyEquivalent.isEmpty }
    var seen: [String: String] = [:]
    for it in items {
        let k = "\(it.keyEquivalentModifierMask.rawValue) \(it.keyEquivalent)"
        // Edit ▸ Select All comes first and takes ⌘A; in a panel it does Mark All (`fixedKeys`).
        #expect(seen[k] == nil || [seen[k], it.title] == ["Select All", "Mark All"], "\(it.title) and \(seen[k] ?? "") share a key")
        seen[k] = it.title
    }
    for it in items {
        guard let id = it.representedObject as? String, let c = app.commands.first(where: { $0.id == id }) else { continue }
        #expect(it.keyEquivalent == c.keys.first?.menuKey && it.keyEquivalentModifierMask == c.keys.first?.flags, "\(id)")
    }
}

/// Switches show ✓ for their state (`Command.on`), asked as the menu opens.
@MainActor @Test func switchesShowTheirState() {
    let app = app()
    let switches = ["view.sidebar", "view.quickview", "view.terminal", "view.terminalFull", "view.activity", "view.hidden", "view.perms",
                    "view.gitOnly", "go.bookmark", "view.sort.name", "view.sort.size", "view.sort.mtime", "view.sort.reverse", "app.update.auto",
                    "monitor.keepAwake", "monitor.slowOnBattery", "monitor.openAtLogin"]   // Settings ▸ Monitor's
    #expect(Set(app.commands.filter { $0.on != nil }.map(\.id)) == Set(switches))
    let item = NSMenuItem(title: "", action: NSSelectorFromString("menuCommand:"), keyEquivalent: "")
    item.representedObject = "view.quickview"
    for on in [true, false] {
        app.quickViewOn = on
        _ = app.validateMenuItem(item)
        #expect(item.state == (on ? .on : .off))
    }
    for id in switches {   // no window, no panels yet (launch): off, not a crash
        item.representedObject = id
        _ = app.validateMenuItem(item)
        #expect(["app.update.auto", "view.hidden", "view.perms", "monitor.slowOnBattery"].contains(id) || item.state == .off, "\(id)")   // as defaults have them
    }
}

/// R-65: new titles; the old ones still find the command in ⇧⌘P, which shows its menu under it.
@MainActor @Test func oldTitlesStillFindTheirCommands() {
    let commands = AppDelegate().makeCommands()
    for (id, old) in [("view.sidebar", "Show/Hide Sidebar"), ("view.terminal", "Show/Hide Terminal"), ("view.quickview", "Quick View Panel"),
                      ("panel.compare", "Compare Folders"), ("file.diff", "Compare Files (diff)"), ("admin.shell", "Root Shell Here"),
                      ("git.diff", "Git Diff"), ("git.changes", "Git Changes"), ("view.gitOnly", "Show Only Git Changes"),
                      ("server.disconnect", "Disconnect Server"), ("server.history", "Server File History"), ("admin.rootPanel", "Reopen Panel as Root"),
                      ("admin.auditLog", "Show Production Log"), ("view.sort.name", "Sort by Name"), ("view.hidden", "Show Hidden Files")] {
        let hits = HeaderSearchModel.results(old, commands: commands, folders: [], files: [], recent: []).flatMap(\.hits)
        #expect(hits.contains { if case .command(let c) = $0.target { c == id } else { false } }, "\(old) → \(id)")
    }
    let sort = HeaderSearchModel.results("sort by name", commands: commands, folders: [], files: [], recent: []).flatMap(\.hits)
        .first { if case .command("view.sort.name") = $0.target { true } else { false } }
    #expect(sort?.title == "Name" && sort?.subtitle == "View ▸ Sort By")
    #expect(commands.first { $0.id == "git.diff" }?.short == "Git Diff", "the key bar keeps its word")
}

/// F1 groups keys by the new menus, in the menus' order.
@MainActor @Test func keyHelpFollowsTheMenuBar() {
    let commands = AppDelegate().makeCommands(), s = KeyHelp.sections(commands)
    #expect(s.map(\.title) == ["File", "Edit", "Mark", "View", "Go", "Server", "Git", "Window", "Help", "Kermo", "Keyboard"])
    #expect(s.first { $0.title == "View" }?.rows.prefix(3).map(\.title) == ["Sidebar", "Quick View", "Terminal"])
    #expect(s.first { $0.title == "Server" }?.rows.map(\.title).contains("Reopen as Root") == true)
}

/// Every "Menu ▸ … ▸ Item" in the docs is in the menu bar: a moved or renamed item breaks no page.
@MainActor @Test func docsMenuPathsAreInTheMenuBar() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let docs = root.appendingPathComponent("docs")
    let pages = try FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil).filter { $0.pathExtension == "md" }
        + [root.appendingPathComponent("README.md")]
    // Any one word first, so a menu that's gone (Admin) is caught too.
    let bold = try NSRegularExpression(pattern: #"\*\*([A-Z][A-Za-z]+ ▸ [^*]+?)\*\*"#)
    let half = try NSRegularExpression(pattern: #"\b([A-Z][A-Za-z]+ ▸) \*\*([^*]+?)\*\*"#)
    let menu = app().makeMenu()
    var found = 0
    for page in pages {
        let s = try String(contentsOf: page, encoding: .utf8), ns = s as NSString, all = NSRange(location: 0, length: ns.length)
        let paths = bold.matches(in: s, range: all).map { ns.substring(with: $0.range(at: 1)) }
            + half.matches(in: s, range: all).map { ns.substring(with: $0.range(at: 1)) + " " + ns.substring(with: $0.range(at: 2)) }
        for path in paths {
            found += 1
            let parts = path.components(separatedBy: " ▸ ")
            var m = menu.items.first { $0.submenu?.title == parts[0] }?.submenu
            #expect(m != nil, "\(page.lastPathComponent): \(path) — no such menu")
            for (i, title) in parts.dropFirst().enumerated() {
                let it = m?.items.first { $0.title == title }
                #expect(it != nil, "\(page.lastPathComponent): \(path)")
                m = i < parts.count - 2 ? it?.submenu : m
            }
        }
    }
    #expect(found > 20, "the scan found the paths")
}
