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
    app.window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)   // not key: a viewer is
    for id in appWide { #expect(app.validateMenuItem(menuItem(id)), "\(id) with another window key") }
    for id in ["file.copy", "help.keys", "view.terminal"] { #expect(!app.validateMenuItem(menuItem(id)), "\(id) with another window key") }

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

/// P-5: ⌘A and ⌘F stay with Edit ▸ Select All / Find…: keymap.json moving them is reported, as a key macOS takes is.
@MainActor @Test func keymapMovingCommandAOrFIsReported() {
    func problems(_ id: String, _ specs: [String]) -> [String] { AppDelegate.keymapProblems(id, specs.map { Shortcut($0)! }) }
    #expect(problems("mark.all", ["cmd+a"]).isEmpty && problems("search", ["opt+f7", "cmd+f"]).isEmpty, "Edit Keymap… writes the defaults")
    #expect(problems("mark.all", ["cmd+opt+a"]) == ["keymap.json: mark.all: ⌘A stays Edit ▸ Select All's, which in a panel does Mark All"])
    #expect(problems("search", ["opt+f7"]) == ["keymap.json: search: ⌘F stays Edit ▸ Find…'s, which in a panel does Search Files"])
    #expect(problems("file.copy", ["f5", "cmd+f"]) == ["keymap.json: file.copy: ⌘F stays Edit ▸ Find…'s, which in a panel does Search Files"])
    #expect(problems("file.diff", ["cmd+opt+d"]).first?.contains("macOS takes it first") == true)
    #expect(problems("file.copy", ["f5"]).isEmpty)
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
