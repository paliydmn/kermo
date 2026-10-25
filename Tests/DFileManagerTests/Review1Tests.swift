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
