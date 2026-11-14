import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// The editor window's toolbar (icons for the menu bar's items), More Tools under it, its key bar's own keys and the
// text's right click.

private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-toolbar-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}
private func put(_ s: String, _ path: String) throws { try Data(s.utf8).write(to: URL(fileURLWithPath: path)) }

@MainActor private func until(_ what: String, _ cond: () -> Bool) async throws {
    for _ in 0..<250 where !cond() { try await Task.sleep(for: .milliseconds(20)) }
    #expect(cond(), "\(what)")
}

@MainActor private func fresh(_ dir: String) -> EditorHost {
    gone()
    UserDefaults.standard.removeObject(forKey: "NSToolbar Configuration Editor")   // the editor window keeps its toolbar: the defaults, not a past run's
    EditorHost.restore(dir, onServer: { _, _, _, _ in ({ _ in }, {}) })
    return EditorHost.tabs
}
@MainActor private func gone() {
    guard let h = EditorHost.shared else { return }
    h.stopComparing()
    for e in h.docs { e.closed(); e.host = nil }
    h.drafts?.release()
    h.window?.orderOut(nil)
    EditorHost.shared = nil
    UserDefaults.standard.removeObject(forKey: "NSToolbar Configuration Editor")
}
@MainActor private func opened(_ path: String) async throws -> Editor {
    Editor.open(URL(fileURLWithPath: path))
    try await until("opened \(path)") { Editor.document(at: path) != nil }
    return try #require(Editor.document(at: path))
}

/// A test's app, its menu bar what the tools go by, the editor window the key window.
@MainActor private func app(_ dir: String, key: @escaping () -> NSWindow?) -> (AppDelegate, restore: () -> Void) {
    let app = AppDelegate()
    app.commands = app.makeCommands()
    app.window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    app.panels = [PanelViewController(tabs: [dir], index: 0, showHidden: false)]
    app.panels.forEach { $0.loadViewIfNeeded() }
    let menu = app.makeMenu()
    Editor.app = { app }
    EditorTool.menu = { menu }
    AppDelegate.keyWindow = key
    return (app, {
        Editor.app = { NSApp.delegate as? AppDelegate }
        EditorTool.menu = { NSApp.mainMenu }
        AppDelegate.keyWindow = { NSApp.keyWindow }
    })
}

@MainActor private func ids(_ w: NSWindow?) -> [String] { w?.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [] }

extension EditorWindowTests {
    /// Every tool stands for a menu bar item that's there (its symbol is `Symbol`'s: the registry's test asks macOS for it).
    @Test func everyToolHasItsMenuItem() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        app.commands = app.makeCommands()
        let menu = app.makeMenu()
        EditorTool.menu = { menu }
        defer { EditorTool.menu = { NSApp.mainMenu } }
        for t in EditorTool.all {
            #expect(t.menuItem() != nil, "\(t.id.rawValue) has its menu item")
        }
        #expect(Set(EditorTool.all.map(\.id)).count == EditorTool.all.count)
        let reloaded = app.makeMenu()   // Reload Config: a new menu bar, found again
        EditorTool.menu = { reloaded }
        #expect(EditorTool.named(.init("save"))?.menuItem().map { it in reloaded.allItems.contains { $0 === it } } == true)
        #expect(!EditorTool.allowed(tabbed: true).contains { EditorTool.named($0)?.when != nil }, "Customize doesn't offer the shown tab's own")
        #expect(EditorTool.defaults(tabbed: false).suffix(2).first != .space)
    }

    /// The editor window's toolbar: Back, the tools in their groups, the chevron last; History for a server's file and
    /// Compare's steps while it compares come and go. A tool's window: Close, no tabs', panes' or terminal's.
    @Test func theToolbarFollowsTheShownTab() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { gone(); try? FileManager.default.removeItem(atPath: dir) }
        let h = fresh(dir + "/drafts")
        try put("a\n", dir + "/a.conf")
        try put("b\n", dir + "/b.conf")
        let a = try await opened(dir + "/a.conf")
        let plain = ["back", "NSToolbarFlexibleSpaceItem", "quickOpen", "save", "NSToolbarSpaceItem", "find", "goToLine", "NSToolbarSpaceItem",
                     "comment", "wrap", "invisibles", "newline", "NSToolbarSpaceItem", "send", "execute", "NSToolbarSpaceItem", "splitRight", "compare", "moreTools"]
        #expect(EditorTool.defaults(tabbed: true).map(\.rawValue) == plain)
        #expect(ids(h.window) == plain)
        #expect((h.window?.toolbar?.items.first as? NSToolbarItem)?.isNavigational == true && h.window?.toolbar?.allowsUserCustomization == true)

        let b = try await opened(dir + "/b.conf")
        h.compare(old: a, new: b)
        #expect(ids(h.window).suffix(6) == ["prevChange", "nextChange", "copyLeft", "copyRight", "stopCompare", "moreTools"], "\(ids(h.window))")
        h.stopComparing()
        #expect(ids(h.window) == plain)

        let t = SFTPTarget(host: "me@203.0.113.5")
        b.server = (t, "/etc/b.conf", AppDelegate.RemoteEdit(baseline: .nothing))
        h.update(b)
        #expect(ids(h.window).suffix(2) == ["history", "moreTools"])
        b.server = nil
        h.update(b)
        #expect(!ids(h.window).contains("history"))

        let tool = try Editor.open(URL(fileURLWithPath: dir + "/t.json"), text: "{}\n", beside: NSView()) { _ in }
        defer { tool.close() }
        let toolIDs = ids(tool.window)
        #expect(toolIDs.first == "back" && toolIDs.last == "moreTools" && tool.window?.toolbar?.allowsUserCustomization == false)
        #expect(!toolIDs.contains { ["quickOpen", "send", "execute", "splitRight", "compare"].contains($0) }, "\(toolIDs)")
        #expect(tool.window?.toolbar?.items.first?.label == "Close")
    }

    /// A tool goes by its menu bar item: enabled, a toggle's on, its key in the tooltip; a click sends that item's action.
    @Test func aToolIsItsMenuItem() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { gone(); try? FileManager.default.removeItem(atPath: dir) }
        let h = fresh(dir + "/drafts")
        try put("a\n", dir + "/a.conf")
        let e = try await opened(dir + "/a.conf")
        let (_, restore) = app(dir) { h.window }
        defer { restore() }
        let w = try #require(h.window)
        w.makeFirstResponder(e.textView)
        func item(_ id: String) throws -> ToolItem { try #require(w.toolbar?.items.first { $0.itemIdentifier.rawValue == id } as? ToolItem) }

        let wrap = try item("wrap"), was = Editor.wraps
        defer { if Editor.wraps != was { Editor.toggleWrap() } }
        wrap.validate()
        #expect(wrap.isEnabled && wrap.toolTip == "Wrap Lines ⌥Z" && (wrap.view as? NSButton)?.state == (was ? .on : .off))
        h.runTool(wrap.view)
        wrap.validate()
        #expect(Editor.wraps != was && (wrap.view as? NSButton)?.state == (was ? .off : .on), "the button is the menu item: it wrapped")

        let line = try item("goToLine")
        line.validate()
        #expect(line.isEnabled && line.toolTip == "Go to Line… ⌘L", "the editor's branch of ⌘L, its title and key")
        let send = try item("send")
        send.validate()
        #expect(send.toolTip == "Send to Terminal ⌃↩", "a picked-off key: the editor's own")
        let newline = try item("newline"), had = e.finalNewline
        newline.validate()
        #expect(newline.isEnabled && (newline.view as? NSButton)?.state == (had ? .on : .off))
        #expect(newline.menuFormRepresentation?.action == #selector(Editor.toggleFinalNewline(_:)), "in », its menu item: checked as there")
        h.runTool(newline.view)
        newline.validate()
        #expect(e.finalNewline != had && (newline.view as? NSButton)?.state == (had ? .off : .on))
        let stop = EditorTool.named(.init("stopCompare"))!
        #expect(!stop.state(in: w).enabled, "not comparing: Stop Comparing's item is off")
    }

    /// More Tools: every tool the toolbar hasn't, by group, flush right; what Customize takes out of the toolbar comes
    /// here. Open or closed is remembered, for every editor window; the menu item says which.
    @Test func moreToolsHasTheRestAndIsRemembered() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        let was = UserDefaults.standard.object(forKey: "editorMoreTools")
        defer { gone(); try? FileManager.default.removeItem(atPath: dir); UserDefaults.standard.set(was, forKey: "editorMoreTools") }
        MoreTools.shown = false
        let h = fresh(dir + "/drafts")
        try put("a\n", dir + "/a.conf")
        _ = try await opened(dir + "/a.conf")
        let (app, restore) = app(dir) { h.window }
        defer { restore() }
        #expect(h.moreTools == nil, "closed: not made")
        let item = try #require(app.makeMenu().allItems.first { $0.representedObject as? String == "text.moreTools" })
        #expect(app.validateMenuItem(item) && item.title == "Show More Tools")

        h.toggleMoreTools()
        let row = try #require(h.moreTools)
        #expect(MoreTools.shown && !row.isHidden && h.window?.titlebarAccessoryViewControllers.contains { $0 === row } == true)
        #expect(app.validateMenuItem(item) && item.title == "Hide More Tools")
        let rest = ["new", "saveAs", "reopen", "copyPath", "indent", "lineUp", "lineDown", "duplicate", "deleteLine",
                    "tabs", "splitDown", "join", "moveToPane", "cloneToPane", "bigger", "smaller"]
        #expect(row.buttons.map(\.tool.id.rawValue) == rest)
        #expect(row.buttons.map(\.tool.group).reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } } == ["File", "Text", "Lines", "Panes", "View"])

        row.view.setFrameSize(NSSize(width: 330, height: row.view.frame.height))   // a narrow window: the last groups go, whole
        row.viewDidLayout()
        let shown = row.buttons.filter { !$0.button.isHidden }.map(\.tool.group)
        #expect(shown.first == "File" && !shown.contains("View") && shown.count < rest.count, "\(shown)")
        row.view.setFrameSize(NSSize(width: 2000, height: row.view.frame.height))
        row.viewDidLayout()
        #expect(!row.buttons.contains { $0.button.isHidden }, "wide again: all of them")

        let tool = try Editor.open(URL(fileURLWithPath: dir + "/t.json"), text: "{}\n", beside: NSView()) { _ in }
        defer { tool.close() }
        let toolRow = try #require(tool.host.moreTools, "a window made now opens with it")
        #expect(!toolRow.isHidden && !toolRow.buttons.contains { $0.tool.windowOnly })
        // A tool's window, as its toolbar isn't kept: the editor window's would be, in the test runner's defaults.
        let bar = try #require(tool.window?.toolbar), at = try #require(bar.items.firstIndex { $0.itemIdentifier.rawValue == "comment" })
        bar.removeItem(at: at)
        try await until("Comment in More Tools") { toolRow.buttons.contains { $0.tool.id.rawValue == "comment" } }
        bar.insertItem(withItemIdentifier: .init("comment"), at: at)
        try await until("Comment back in the toolbar, out of More Tools") { !toolRow.buttons.contains { $0.tool.id.rawValue == "comment" } }
        h.toggleMoreTools()
        #expect(!MoreTools.shown && row.isHidden && toolRow.isHidden, "closed in every editor window")
    }

    /// The editor's key bar: its own keys — ⎋, ⌃↩ ⌃⇧↩ — and F1 for every key; the menu's are the toolbar's now.
    @Test func theKeyBarHasTheEditorsOwnKeys() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { gone(); try? FileManager.default.removeItem(atPath: dir) }
        let h = fresh(dir + "/drafts")
        try put("a\n", dir + "/a.conf")
        let e = try await opened(dir + "/a.conf")
        let (_, restore) = app(dir) { h.window }
        defer { restore() }
        e.frame.showKeys()
        #expect(e.frame.keys.list?.map { "\($0.key) \($0.label)" } == ["⎋ Back to Panels", "⌃↩ Send to Terminal", "⌃⇧↩ Execute in Terminal", "F1 All Keys"])
    }

    /// The right click: no spelling, substitutions, speech or layout orientation; after Paste, Send / Execute in Terminal,
    /// Toggle Comment and Lines ▸, Copy Change while it compares, Copy Path of a file only.
    @Test func theRightClickHasTheEditorsCommands() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { gone(); try? FileManager.default.removeItem(atPath: dir) }
        let h = fresh(dir + "/drafts")
        try put("a\n", dir + "/a.conf")
        let e = try await opened(dir + "/a.conf")
        let (_, restore) = app(dir) { h.window }
        defer { restore() }
        let w = try #require(h.window)
        func menu(_ e: Editor) throws -> NSMenu {   // a right click in its view that shows
            let text = try #require(e.views.first { v in h.panes.contains { $0 === v.pane && $0.active === e } }?.text)
            let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
                                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let m = try #require(text.menu(for: click))
            m.update()   // validated, as when it opens: the editor's titles
            return m
        }
        let m = try menu(e)
        let titles = m.items.map(\.title)
        #expect(!titles.contains { ["Spelling and Grammar", "Substitutions", "Speech", "Layout Orientation", "Font"].contains($0) }, "\(titles)")
        #expect(!m.items.contains { $0.action.map(NSStringFromSelector) == "_performStandardShareMenuItem:" }, "no Share…")
        let paste = try #require(titles.lastIndex { $0.hasPrefix("Paste") }), send = try #require(titles.firstIndex(of: "Send to Terminal"))
        #expect(send == paste + 2 && titles[send - 1].isEmpty, "after Cut/Copy/Paste (and Paste and Match Style), a group of its own: \(titles)")
        #expect(Array(titles[send...].prefix(7)) == ["Send to Terminal", "Execute in Terminal", "", "Toggle Comment", "Lines", "", "Copy Path"], "\(titles)")
        #expect(m.items.first { $0.title == "Send to Terminal" }.map { $0.keyEquivalent == "\r" && $0.keyEquivalentModifierMask == .control } == true)
        #expect(m.items.first { $0.title == "Toggle Comment" }.map { "\($0.keyEquivalent)|\($0.keyEquivalentModifierMask.rawValue)" } == "/|\(NSEvent.ModifierFlags.command.rawValue)", "its menu item's key")
        #expect(m.items.first { $0.title == "Lines" }?.submenu?.items.map(\.title) == ["Move Line Up", "Move Line Down", "Duplicate Line", "Duplicate Line Up", "Delete Line"])
        #expect(!m.items.contains { $0.isSeparatorItem && $0 === m.items.last })

        let untitled = Editor.untitled()
        try await until("an Untitled shown") { h.active === untitled }
        #expect(try !menu(untitled).items.contains { $0.title == "Copy Path" }, "no file, no path")
        h.compare(old: e, new: untitled)
        #expect(try menu(untitled).items.contains { $0.title == "Copy Change to Left" })
        #expect(h.active === untitled)
        _ = try menu(e)
        #expect(h.active === e, "a right click in the other pane: its tab is the one acted on")
    }
}
