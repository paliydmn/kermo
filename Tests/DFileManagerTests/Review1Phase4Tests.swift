import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Review 1, phase 4: the layout — calm at rest, what's needed in its place.

@MainActor private func tempDir(_ files: [String] = []) throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r1p4-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for f in files { FileManager.default.createFile(atPath: dir + "/" + f, contents: Data("12345".utf8)) }
    return dir
}

/// By the clock: a loaded full run keeps the main actor busy.
@MainActor private func until(_ done: () -> Bool) async {
    let end = Date().addingTimeInterval(20)
    while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor private func loaded(_ dir: String, rows: Int) async -> PanelViewController {
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    await until { panel.path == dir && panel.table.numberOfRows == rows }
    return panel
}

private func buttons(_ v: NSView) -> [NSButton] { v.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
@MainActor private func click(_ b: NSButton) { _ = (b.target as? NSObject)?.perform(b.action, with: b) }

/// R-30, R-31, Р5: the command line at rest is one quiet line — where it runs, "Type a command", ⌘E — and its keys are
/// the key bar's once it has the focus (a click on ⌘E gives it). On a root panel the bar says ⌘E runs as the user.
@MainActor @Test func theCommandLineIsCollapsed() throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let app = AppDelegate()
    app.commands = app.makeCommands()
    app.terminal = EmbeddedTerminal(covering: NSView())
    app.panels = [PanelViewController(tabs: [dir], index: 0, showHidden: false)]
    defer { app.panels.forEach { $0.shutdown() } }
    let line = app.makeCommandLine()
    #expect(app.cmdField.placeholderString == "Type a command")
    let key = try #require(buttons(line).first { $0 === app.cmdKey })
    #expect(key.accessibilityLabel() == "Command Line, ⌘E" && !key.attributedTitle.string.isEmpty)
    #expect(app.focusedKeys == nil)

    app.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
    let content = NSStackView(views: [app.panels[0].view, line])
    content.orientation = .vertical
    app.window.contentView = content
    click(key)
    #expect(app.commandLineFocused && app.focusedKeys == AppDelegate.commandLineKeys, "⌘E's click is ⌘E")
    let typed = AppDelegate.commandLineKeys(root: SFTPTarget(host: "deploy@web").asRoot())
    #expect(typed.dropLast() == AppDelegate.commandLineKeys[...] && typed.last == KeySlot(key: "", label: "Runs as deploy, not root", id: nil))
    app.window = nil
}

/// R-28, Р5: on the left what matters — the marked ones (bold, in the marks' color), else how many; filtered, found,
/// git changes in words; on the right chips of what just is (free space, SFTP, an archive's read-only). Never a key:
/// ⎋ and ⌫ are pills beside it, a click on one doing what the key does.
@MainActor @Test func theStatusLineSaysWhatMattersAndNoKeys() async throws {
    let dir = try tempDir(["a.log", "b.txt"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = await loaded(dir, rows: 3)
    defer { panel.shutdown() }
    #expect(panel.statusText == "2 items · 10 B" && panel.statusChipWords.count == 1 && panel.statusChipWords[0].hasSuffix(" free"), "\(panel.statusText) \(panel.statusChipWords)")
    panel.setMarks(["a.log"])
    #expect(panel.statusText == "1 marked · 5 B", "the items' count gives way: \(panel.statusText)")
    let marked = panel.statusAttributed
    #expect(marked.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Theme.current.marked)
    #expect((marked.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    panel.unmarkAll()
    panel.applyFilter("*.log")
    #expect(panel.statusText == "1 item · 5 B · filtered: 1 of 2")
    panel.filterKey("filter.clear")

    // Busy: the message, and ⎋ as a pill whose click cancels, as ⎋ does.
    let running = Task { await panel.busy("Counting…") { flag in
        let end = Date() + 5
        while !flag.isCancelled && Date() < end { usleep(10_000) }
        return 1
    } }
    await until { panel.busyMessage != nil }
    #expect(panel.statusText == "Counting…" && !panel.cancelButton.isHidden && panel.cancelButton.accessibilityLabel() == "Cancel, ⎋")
    click(panel.cancelButton)
    #expect((try? await running.value.get()) == nil)

    // Search results: "found" in words, ⌫ a pill back to the folder.
    let flag = panel.beginSearch("*.log")
    panel.addSearchResults([FileItem(name: "a.log", kind: .file, size: 5, mtime: 0, mode: 0o644, flags: 0)], from: flag)
    panel.finishSearch(flag)
    #expect(panel.statusText == "*.log: 1 found" && !panel.backButton.isHidden)
    click(panel.backButton)
    await until { panel.searchTitle == nil && panel.table.numberOfRows == 3 }
    #expect(panel.searchTitle == nil && panel.backButton.isHidden, "⌫'s way back")

    let keys = Set("⎋⌫↩⌘⌃⌥⇧")
    for s in [panel.statusText] + panel.statusChipWords { #expect(!s.contains(where: keys.contains), "\(s)") }
    #expect(KeyBarModel.layers(AppDelegate().makeCommands(), archive: true)[0].slots.first { $0.id == "file.copy" }?.label == "Extract",
            "F5 extracts in an archive: the key bar says so, not the status line")
}

/// R-29: the quick filter's placeholder says what to type; its keys — ↩ Keep, ↓ Back to List, ⎋ Clear — are the key
/// bar's while it has the focus, and a slot's click does what its key does in the field's handler.
@MainActor @Test func theQuickFiltersKeysAreItsHandler() async throws {
    _ = NSApplication.shared
    let dir = try tempDir(["a.log", "b.txt"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = await loaded(dir, rows: 3)
    defer { panel.shutdown() }
    #expect(panel.filterField.placeholderString == "Filter: text, *.log or re:regex")
    #expect(PanelViewController.filterKeys.map(\.key) == ["↩", "↓", "⎋"] && PanelViewController.filterKeys.map(\.label) == ["Keep", "Back to List", "Clear"])
    #expect(KeyHelp.fieldKeys.map(\.title) == ["Command Line", "Quick Filter", "Path Bar"], "F1 lists them too, in the bar's words")
    #expect(KeyHelp.fieldKeys[1].rows.map(\.title) == ["Keep", "Back to List", "Clear"] && KeyHelp.fieldKeys[1].rows.map(\.keys) == ["↩", "↓", "⎋"])
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    w.contentView = panel.view
    let app = AppDelegate()
    app.window = w
    app.panels = [panel]
    defer { app.window = nil }

    func type(_ text: String) {
        panel.beginFilter()
        panel.filterField.stringValue = text
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.filterField))
    }
    let tv = NSTextView()
    type("*.log")
    #expect(panel.filterFocused && app.focusedKeys == PanelViewController.filterKeys)
    #expect(panel.control(panel.filterField, textView: tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(!panel.filterFocused && panel.listedItems.map(\.name) == ["a.log"] && UserDefaults.standard.stringArray(forKey: "recentFilters")?.first == "*.log", "↩ keeps")
    type("*.txt")
    panel.filterKey("filter.keep")   // the slot's click
    #expect(!panel.filterFocused && panel.listedItems.map(\.name) == ["b.txt"] && UserDefaults.standard.stringArray(forKey: "recentFilters")?.first == "*.txt")
    type("b")
    #expect(panel.control(panel.filterField, textView: tv, doCommandBy: #selector(NSResponder.moveDown(_:))))
    #expect(!panel.filterFocused && panel.listedItems.map(\.name) == ["b.txt"], "↓ back to the list, the filter stays")
    type("a")
    panel.filterKey("filter.clear")
    #expect(!panel.filterFocused && panel.listedItems.count == 2 && panel.filterField.isHidden, "⎋ clears")
}

/// R-26, Р5: a panel with nothing to list says why in its middle, and what comes next as keys — a click on one runs
/// what the key runs. An empty folder (here or on a server), only hidden files, a server tab not connected, a folder
/// it couldn't read; a listing on its way after a moment.
@MainActor @Test func emptyStatesSayWhyAndWhatNext() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = await loaded(dir, rows: 1)
    defer { panel.shutdown() }
    var ran: [String] = []
    panel.onCommand = { ran.append($0) }
    await until { panel.emptyShown?.title == "Empty folder" }   // "Loading…" first, on a loaded Mac
    #expect(panel.emptyShown == .init(symbol: .folder, title: "Empty folder", keys: [KeySlot(key: "F7", label: "New Folder", id: "file.mkdir"),
                                                                                KeySlot(key: "⇧F4", label: "New File", id: "file.new"),
                                                                                KeySlot(key: "⌘V", label: "Paste", id: "paste")]))
    panel.view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
    panel.view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))   // the bar places its slots after a layout
    #expect(panel.emptyKeysShown.count == 3, "all of them in a wide panel, no \"+2\": \(panel.emptyKeysShown)")
    func slots() -> [NSButton] { buttons(panel.view).filter { $0.identifier?.rawValue == "file.mkdir" } }
    let mkdir = try #require(slots().first)
    click(mkdir)
    #expect(ran == ["file.mkdir"], "F7's click is F7")

    FileManager.default.createFile(atPath: dir + "/.hidden", contents: nil)
    panel.reload()
    await until { panel.empty?.title == "1 hidden item" }
    #expect(panel.empty?.keys.first == KeySlot(key: "⇧⌘.", label: "Show Hidden Files", id: "view.hidden"))
    FileManager.default.createFile(atPath: dir + "/shown", contents: nil)
    panel.reload()
    await until { panel.listedItems.map(\.name) == ["shown"] && panel.busyMessage == nil }   // not just "Loading…" (nil too)
    #expect(panel.empty == nil)
    panel.applyFilter("nothing-matches")
    #expect(panel.empty == nil, "a filter that hides all: the status line says it")

    panel.loadError = "Permission denied"
    panel.filterKey("filter.clear")
    #expect(panel.empty == nil, "rows shown: the status line says what failed")
    try FileManager.default.removeItem(atPath: dir + "/shown")
    try FileManager.default.removeItem(atPath: dir + "/.hidden")
    panel.reload()
    await until { panel.listedItems.isEmpty && panel.busyMessage == nil }
    panel.loadError = "Permission denied"
    #expect(panel.empty == .init(symbol: .warn, title: "Can't read this folder", detail: "Permission denied", keys: [KeySlot(key: "⌘R", label: "Refresh", id: "view.refresh")]))

    // On its way: said in the middle only after a moment, ⎋ as a key there too.
    panel.loadError = nil
    let running = Task { await panel.busy("Connecting to web…") { flag in
        let end = Date() + 5
        while !flag.isCancelled && Date() < end { usleep(10_000) }
        return 1
    } }
    await until { panel.busyMessage != nil }
    #expect(panel.empty?.title != "Connecting to web…", "not at once")
    await until { panel.emptyShown?.title == "Connecting to web…" }
    #expect(panel.emptyShown == .init(title: "Connecting to web…", keys: [KeySlot(key: "⎋", label: "Cancel", id: "cancel")]))
    let cancel = try #require(buttons(panel.view).first { $0.identifier?.rawValue == "cancel" })
    click(cancel)
    #expect((try? await running.value.get()) == nil, "its ⎋ cancels")
}

/// The middle of a parked server tab: where, that nothing's sent, ↩ Connect and the ways out — the same commands the
/// keys run there. A folder that can't be listed and shows nothing says so there too.
@MainActor @Test func aParkedTabAndAFailedFolderSayItInTheMiddle() async throws {
    let web = SFTPTarget(host: "k13@r1p4.invalid")
    let panel = PanelViewController(session: [Session.Tab(path: NSTemporaryDirectory(), server: web, dir: "/var/log")], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    #expect(panel.empty == .init(symbol: .server, title: "Not connected", detail: "k13@r1p4.invalid:/var/log — nothing is sent until you ask",
                                 keys: [KeySlot(key: "↩", label: "Connect", id: "open"), KeySlot(key: "⌃⌘R", label: "As Root", id: "admin.rootPanel"),
                                        KeySlot(key: "⌘↑", label: "This Mac", id: "go.up")]))
    for id in ["open", "admin.rootPanel", "go.up"] { #expect(AppDelegate.runsParked(id), "\(id) runs on a parked tab") }

    let gone = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r1p4-gone-" + UUID().uuidString
    let failed = PanelViewController(tabs: [gone], index: 0, showHidden: false)
    var said: PanelViewController.Empty?
    failed.onGone = { _ in said = failed.empty }   // before it moves on to the home folder
    failed.loadViewIfNeeded()
    defer { failed.shutdown() }
    await until { said != nil }
    #expect(said?.title == "Can't read this folder" && said?.symbol == .warn && said?.keys.map(\.id) == ["view.refresh"])
}

/// R-22, §11 decision 3: the path bar is crumbs — "/" or "~" first, each part going where it says; in a narrow panel
/// the middle gives way to "…", never the start.
@MainActor @Test func thePathBarIsCrumbs() {
    #expect(PanelViewController.crumbs("/etc/nginx") == [.init(title: "/", path: "/"), .init(title: "etc", path: "/etc"), .init(title: "nginx", path: "/etc/nginx")])
    #expect(PanelViewController.crumbs("/") == [.init(title: "/", path: "/")])
    let home = NSHomeDirectory()
    #expect(PanelViewController.crumbs(home + "/Projects/site", home: true)
            == [.init(title: "~", path: home), .init(title: "Projects", path: home + "/Projects"), .init(title: "site", path: home + "/Projects/site")])
    #expect(PanelViewController.crumbs(home + "/x", home: false).first == .init(title: "/", path: "/"), "a server's home is no ~")
    #expect(PanelViewController.crumbs("a/b", inside: true) == [.init(title: "a", path: "a"), .init(title: "b", path: "a/b")])
    let six: [CGFloat] = [50, 50, 50, 50, 50, 50]
    #expect(CrumbRow.fit(six, separator: 10, ellipsis: 10, room: 400) == [0, 1, 2, 3, 4, 5])
    #expect(CrumbRow.fit(six, separator: 10, ellipsis: 10, room: 200) == [0, nil, 4, 5], "the middle goes, from the start's side")
    #expect(CrumbRow.fit(six, separator: 10, ellipsis: 10, room: 20) == [0, nil, 5], "the first and the last at least")
    #expect(CrumbRow.fit([50, 300], separator: 10, ellipsis: 10, room: 100) == [0, 1], "two: the last is cut at its end")
    #expect(PanelViewController.scpPath(SFTPTarget(host: "deploy@web-01").asRoot(), "/var/www/site") == "deploy@web-01:/var/www/site", "the user's, also from a root panel")
}

/// A crumb's click goes there, the cursor on the folder you came from; the bar says it in a narrow panel too. A click on
/// an empty spot is ⌘L — the plain path, all of it selected — and ⎋ brings the crumbs back. Copy copies the full path.
@MainActor @Test func aCrumbGoesThereAndAnEmptySpotTypesAPath() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(atPath: dir + "/a/b", withIntermediateDirectories: true)
    let panel = PanelViewController(tabs: [dir + "/a/b"], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await until { panel.path == dir + "/a/b" && panel.pathBar.crumbs.last?.title == "b" }
    #expect(panel.pathBar.crumbs.first?.title == "/" && panel.pathBar.crumbs.map(\.title).suffix(2) == ["a", "b"])
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    w.contentView = panel.view
    panel.view.layoutSubtreeIfNeeded()
    let shown = panel.pathBar.shownCrumbs
    #expect(shown.first == "/" && shown.contains("…") && shown.last == "b", "narrow: \(shown)")

    let pb = NSPasteboard(name: .init("dfm-r1p4-" + UUID().uuidString))
    defer { pb.releaseGlobally() }
    panel.copyPath(scp: false, to: pb)
    #expect(pb.string(forType: .string) == dir + "/a/b", "the full path, not ~")
    panel.pathBar.copied()
    #expect(panel.pathBar.showsCopied)
    await until { !panel.pathBar.showsCopied }
    #expect(!panel.pathBar.showsCopied, "back after a second")

    panel.pathBar.click(panel.pathBar.crumbs.count - 2)   // "a"
    await until { panel.path == dir + "/a" }
    #expect(panel.path == dir + "/a" && panel.currentName == "b", "up, the cursor on where it came from")

    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    panel.pathBar.mouseDown(with: down)   // an empty spot
    #expect(panel.pathBar.editing && panel.pathBar.field.stringValue == dir + "/a/" && w.firstResponder === panel.pathBar.field.currentEditor())
    let app = AppDelegate()
    app.window = w
    app.panels = [panel]
    defer { app.window = nil }
    #expect(app.focusedKeys == PanelViewController.pathKeys && PanelViewController.pathKeys.map(\.label) == ["Go", "Complete", "Back to Panel"])
    #expect(panel.control(panel.pathBar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(!panel.pathBar.editing && w.firstResponder === panel.table, "⎋: the crumbs back")
    panel.beginPathEditing()   // ⌘L: the same
    #expect(panel.pathBar.editing)
}

/// On a server: the crumbs are its folders, Copy gives its path, ⌥ `user@host:path`; a filter kept after ↩ is a chip at
/// the bar's right end.
@MainActor @Test func aServersPathBarAndAKeptFilter() async throws {
    let dir = try tempDir(["x.log", "y.txt"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    panel.loadRemote(.local(), dir: dir, select: nil)
    await until { panel.remote?.dir == dir && panel.listedItems.count == 2 }
    #expect(panel.pathBar.crumbs.last == .init(title: (dir as NSString).lastPathComponent, path: dir) && panel.headerText == "localhost:\(dir)")
    let pb = NSPasteboard(name: .init("dfm-r1p4-" + UUID().uuidString))
    defer { pb.releaseGlobally() }
    panel.copyPath(scp: false, to: pb)
    #expect(pb.string(forType: .string) == dir)
    panel.copyPath(scp: true, to: pb)
    #expect(pb.string(forType: .string) == "localhost:\(dir)")

    #expect(panel.pathBar.filter == nil)
    panel.applyFilter("*.log")
    panel.confirmFilter()
    #expect(panel.pathBar.filter == "*.log", "kept: a chip")
    panel.filterKey("filter.clear")
    #expect(panel.pathBar.filter == nil)
}
