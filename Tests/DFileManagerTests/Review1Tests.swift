import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Review 1, phase 0: defects P-1…P-10 (tasks/review_1/README.md §5).

/// A registry command's menu item, as `makeMenu` makes it.
@MainActor private func menuItem(_ id: String) -> NSMenuItem {
    let it = NSMenuItem(title: id, action: NSSelectorFromString("menuCommand:"), keyEquivalent: "")
    it.representedObject = id
    return it
}

/// P-2: About Kermo and the update items work from any window and over the terminal; the panels' commands don't.
@MainActor @Test func appItemsWorkFromAnyWindow() {
    _ = NSApplication.shared
    let app = AppDelegate()
    let appWide = ["app.about", "app.update", "app.update.auto"]
    app.window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)   // not key (in tests none is)
    for id in appWide { #expect(app.validateMenuItem(menuItem(id)), "\(id) with another window key") }
    for id in ["file.copy", "view.terminal"] { #expect(!app.validateMenuItem(menuItem(id)), "\(id) with another window key") }

    // NSApp.keyWindow is nil here: with no window of its own the app takes itself for key, and the terminal is up.
    app.window = nil
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)), panels = NSView(frame: parent.bounds)
    parent.addSubview(panels)
    let term = EmbeddedTerminal(covering: panels)
    term.restore([SFTPTarget(host: "me@dfm-p2.invalid")])   // a tab without a process
    _ = term.show()
    app.terminal = term
    for id in appWide { #expect(app.validateMenuItem(menuItem(id)), "\(id) over the terminal") }
    #expect(!app.validateMenuItem(menuItem("file.copy")) && app.validateMenuItem(menuItem("view.terminal")))
}

/// P-5: the menu bar's own keys (⌘A, ⌘F, ⌘C, ⌘X, ⌘0 …) stay with their items: keymap.json moving one is reported, as a
/// key macOS takes is. ⌘A and ⌘F do Mark All and Search Files in a panel; no other default key is one of them.
@MainActor @Test func keymapMovingAMenuKeyIsReported() {
    _ = NSApplication.shared
    let app = AppDelegate()
    let fixed = AppDelegate.fixedKeys(app.makeMenu()), commands = app.makeCommands()
    let defaults = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0.keys) })
    func problems(_ id: String, _ specs: [String]) -> [String] {
        AppDelegate.keymapProblems(id, specs.map { Shortcut($0)! }, was: defaults[id]!, fixed: fixed)
    }
    #expect(problems("mark.all", ["cmd+a"]).isEmpty && problems("search", ["opt+f7", "cmd+f"]).isEmpty, "Edit Keymap… writes the defaults")
    #expect(problems("mark.all", ["cmd+opt+a"]) == ["keymap.json: mark.all: ⌘A stays Edit ▸ Select All's, which in a panel does Mark All"])
    #expect(problems("search", ["opt+f7"]) == ["keymap.json: search: ⌘F stays Edit ▸ Find…'s, which in a panel does Search Files"])
    #expect(problems("file.copy", ["f5", "cmd+f"]) == ["keymap.json: file.copy: ⌘F stays Edit ▸ Find…'s, which in a panel does Search Files"])
    #expect(problems("go.home", ["cmd+c", "cmd+x"]) == ["keymap.json: go.home: ⌘C stays Edit ▸ Copy's", "keymap.json: go.home: ⌘X stays Edit ▸ Cut's"])
    #expect(problems("view.refresh", ["cmd+0"]) == ["keymap.json: view.refresh: ⌘0 stays Window ▸ Main Window's"])
    #expect(problems("file.diff", ["cmd+opt+d"]).first?.contains("macOS takes it first") == true)
    #expect(problems("go.home", ["cmd+q"]).count == 1, "⌘Q: macOS's, said once")
    #expect(problems("file.copy", ["f5"]).isEmpty)
    for c in commands { for k in c.keys where fixed[k] != nil { #expect(["mark.all ⌘A", "search ⌘F"].contains("\(c.id) \(k.display)")) } }
}

/// F1 over a viewer or an editor: its own keys, then the menu bar's (the registry's only where they work there).
@MainActor @Test func keyHelpOverAViewer() async throws {
    _ = NSApplication.shared
    let app = AppDelegate()
    let s = app.keySections(over: NSWindow(), menu: app.makeMenu())
    #expect(s.map(\.title) == ["Kermo", "File", "Edit", "Window"], "no Viewer or Editor section for another window")
    #expect(s.first { $0.title == "Edit" }?.rows.map(\.keys) == ["⌘Z", "⇧⌘Z", "⌘X", "⌘C", "⌘V", "⌘A", "⌘F", "⌘G"])
    #expect(s.first { $0.title == "Window" }?.rows.contains { $0.title == "Main Window" && $0.keys == "⌘0" } == true)

    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r1-keys-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try Data("start\nGET /a 200\n".utf8).write(to: URL(fileURLWithPath: dir + "/app.log"))
    let v = Viewer(URL(fileURLWithPath: dir + "/app.log"))
    defer { v.close() }
    for _ in 0..<500 where v.window?.subtitle.contains("⎋ Close") != true { try await Task.sleep(for: .milliseconds(10)) }
    let subtitle = try #require(v.window?.subtitle)
    #expect(v.keyHints.allSatisfy { subtitle.contains("\($0.key) \($0.label)") }, "F1 and the subtitle say the same")
    #expect(v.keyHints.contains { $0 == ("&", "Filter") } && v.keyHints.last! == ("⎋", "Close"))
}

/// P-8: a server row's right-click menu starts with its first item, not a line; a favorite's ends with its own.
@MainActor @Test func aServerRowsMenuStartsWithAnItem() {
    let app = AppDelegate(), sidebar = SidebarController()
    sidebar.serverMenu = { app.serverMenu($0) }
    let row = ServerRow(target: SFTPTarget(host: "me@web.invalid"), saved: nil, title: "web")
    let server = sidebar.contextItems(.server(row), favorite: false)
    #expect(server.first?.title == "Open SSH Session" && server.last?.isSeparatorItem == false)
    #expect(zip(server, server.dropFirst()).allSatisfy { !($0.isSeparatorItem && $1.isSeparatorItem) }, "no two lines in a row")
    #expect(sidebar.contextItems(.serverFolder("me@web.invalid:/srv"), favorite: true).map(\.title) == ["Remove from Favorites"])
    #expect(sidebar.contextItems(.folder("/tmp"), favorite: false).isEmpty)
}

/// P-9: Edit ▸ Cut — text fields get ⌘X from the menu, as they get ⌘C and ⌘V. No command takes ⌘X.
@MainActor @Test func editMenuHasCut() throws {
    _ = NSApplication.shared
    let app = AppDelegate()
    let edit = try #require(app.makeMenu().items.compactMap(\.submenu).first { $0.title == "Edit" })
    let cut = try #require(edit.items.first { $0.action == #selector(NSText.cut(_:)) })
    #expect(cut.title == "Cut" && cut.keyEquivalent == "x" && cut.keyEquivalentModifierMask == .command)
    #expect(edit.items.firstIndex(of: cut).map { edit.items[$0 + 1].title } == "Copy")
    #expect(!app.makeCommands().contains { $0.keys.contains(Shortcut("cmd+x")!) })
}

/// D-101: a command's menu item keeps its key only while the command works where keys go. A disabled item took its key
/// and ran nothing (AppKit), so F3 and F10 never closed a viewer.
@MainActor @Test func disabledCommandsLeaveTheirKeys() {
    _ = NSApplication.shared
    let app = AppDelegate()
    app.commands = app.makeCommands()
    let menu = app.makeMenu()
    func item(_ id: String) -> NSMenuItem? { menu.items.compactMap(\.submenu).flatMap(\.items).first { $0.representedObject as? String == id } }
    #expect(item("file.view")?.keyEquivalent == Shortcut("f3")!.menuKey, "as built")
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)), panels = NSView(frame: parent.bounds)
    parent.addSubview(panels)
    let term = EmbeddedTerminal(covering: panels)
    app.terminal = term

    app.window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)   // not key: say a viewer is
    app.updateMenuKeys(menu)
    for id in ["file.view", "go.tree", "go.up", "git.switch"] { #expect(item(id)?.keyEquivalent == "", "\(id) over another window") }

    // In tests no window is key: with none of its own the app takes itself for key. The terminal is up: ⌃O works, F3 doesn't.
    app.window = nil
    term.restore([SFTPTarget(host: "me@dfm-d101.invalid")])   // a tab without a process
    _ = term.show()
    app.updateMenuKeys(menu)
    #expect(item("view.terminal")?.keyEquivalent == "o" && item("view.terminal")?.keyEquivalentModifierMask == .control)
    #expect(item("file.view")?.keyEquivalent == "")
}
