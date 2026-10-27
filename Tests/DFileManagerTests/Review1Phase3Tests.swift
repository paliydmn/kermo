import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Review 1, phase 3: keys, not prose — one key bar for the panels, the terminal, the command line, Pickers and windows.

/// The words of a text, letters only: "Show Hidden Files" → show, hidden, files; "Mark ↓" → mark.
private func words(_ s: String) -> [String] {
    s.lowercased().split { !$0.isLetter }.map(String.init)
}

/// R-33: a slot's label is words of its command's menu title, or of its menu and title (Git ▸ Diff: "Git Diff") — no
/// "MkDir" for New Folder…, no "Commands" for Search… — in Title Case. Where the bar says what the menu can't, the exceptions are listed here, each with why.
@MainActor @Test func labelsAreWordsOfTheirMenuTitles() {
    let commands = AppDelegate().makeCommands()
    let exceptions: [String: String] = [
        "file.trash Delete…": "F8 on a server deletes, after a question: no Trash there (the menu item says Delete… then too)",
        "file.copy Extract": "F5 in an archive extracts (the menu item says Extract To… then too)",
        "view.terminal Hide Terminal": "⌃O in the terminal hides it; the menu item is the switch, Terminal with ✓",
    ]
    let terminal = AppDelegate.terminalCommands.compactMap { id in commands.first { $0.id == id } }
    let all = KeyBarModel.layers(commands) + KeyBarModel.layers(commands, server: true) + KeyBarModel.layers(commands, archive: true)
        + KeyBarModel.layers(terminal, terminal: true)
    var used: Set<String> = []
    for slot in all.flatMap(\.slots) {
        guard let id = slot.id, let c = commands.first(where: { $0.id == id }) else { continue }
        if exceptions["\(id) \(slot.label)"] != nil {
            used.insert("\(id) \(slot.label)")
            continue
        }
        let title = Set(words(c.title) + words(c.topMenu ?? ""))
        #expect(words(slot.label).allSatisfy(title.contains), "\(id): “\(slot.label)” isn't in “\(c.title)”")
        let small: Set<String> = ["to", "in", "of", "by", "as", "and", "or", "on", "for", "at"]
        for (i, w) in slot.label.split(separator: " ").enumerated() where w.first?.isLetter == true {
            #expect(w.first!.isUppercase || i > 0 && small.contains(String(w)), "\(id): “\(slot.label)” isn't in Title Case")
        }
        #expect(!slot.label.contains("("), "\(id): no brackets")
    }
    #expect(used == Set(exceptions.keys), "an exception no slot needs any more goes")
    #expect(KeyBarModel.layers(commands).first { $0.mods == .shift }?.slots.first { $0.key == "⇧F10" }?.label == "Menu",
            "Menu is the context menu's alone")
}

/// R-32: ⇧ ⌥ ⌘ ⌃ chips in place of "Hold — ▾": held, a chip lights and its layer shows; a click keeps it (outlined),
/// a second click or ⎋ lets go, as does a command.
@MainActor @Test func modifierChipsHoldAndPin() async {
    let bar = KeyBarView()
    bar.reload(AppDelegate().makeCommands())
    func state(_ f: NSEvent.ModifierFlags) -> (held: Bool, pinned: Bool) { bar.chipStates.first { $0.flag == f }.map { ($0.held, $0.pinned) } ?? (false, false) }
    func click(_ f: NSEvent.ModifierFlags) {
        func chips(_ v: NSView) -> [ModChip] { v.subviews.flatMap { ($0 as? ModChip).map { [$0] } ?? chips($0) } }
        let c = chips(bar).first { $0.flag == f }!
        _ = (c.target as? NSObject)?.perform(c.action, with: c)
    }
    #expect(bar.chipStates.map(\.flag) == [.shift, .option, .command, .control])
    #expect(bar.shownSlots.first?.key == "F1")

    bar.modifiersChanged(.command)
    for _ in 0..<100 where bar.mods != .command { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(state(.command) == (true, false) && bar.shownSlots.allSatisfy { $0.key.hasPrefix("⌘") })
    bar.modifiersChanged([])
    #expect(bar.mods == [] && state(.command) == (false, false))

    click(.shift)
    #expect(bar.pinned == .shift && state(.shift) == (false, true) && bar.shownSlots.contains { $0.key == "⇧F6" })
    click(.command)
    #expect(bar.pinned == [.shift, .command] && bar.shownSlots.contains { $0.key == "⇧⌘P" }, "two chips: their combination")
    click(.command)
    click(.shift)
    #expect(bar.pinned == [] && bar.shownSlots.first?.key == "F1", "a second click lets go")
    click(.option)
    #expect(bar.unpin() && bar.pinned == [] && !bar.unpin(), "⎋ lets go; then ⎋ is the panel's again")
    click(.control)
    bar.commandRan("view.terminal")
    #expect(bar.pinned == [], "a command lets go too")

    func chipLabels() -> [String] {
        func chips(_ v: NSView) -> [ModChip] { v.subviews.flatMap { ($0 as? ModChip).map { [$0] } ?? chips($0) } }
        return chips(bar).compactMap { $0.accessibilityLabel() }
    }
    click(.shift)
    #expect(chipLabels() == ["Shift layer, pinned", "Option layer", "Command layer", "Control layer"])
}

/// R-36: with the keys in the terminal the bar shows its commands from the registry — its panes' too — and ⌃O hides it
/// (phase 4: the drawer). None of them is a bare F-key: each one's first key shows at rest.
@MainActor @Test func theTerminalsKeysComeFromTheRegistry() {
    let commands = AppDelegate().makeCommands()
    let bar = KeyBarView()
    bar.terminalShown = { true }
    bar.frame = NSRect(x: 0, y: 0, width: 1400, height: 30)
    bar.reload(commands)
    let rest = bar.shownSlots
    #expect(rest.first == KeySlot(key: "⌃O", label: "Hide Terminal", id: "view.terminal"))
    #expect(rest.contains(KeySlot(key: "⌃⇧O", label: "Maximize", id: "view.terminalFull")))
    #expect(rest.contains(KeySlot(key: "⌘T", label: "New Tab", id: "tab.new")) && rest.contains { $0.id == "term.split.right" })
    #expect(rest.compactMap(\.id).allSatisfy(AppDelegate.terminalCommands.contains))
    let terminal = AppDelegate.terminalCommands.compactMap { id in commands.first { $0.id == id } }
    let panes = KeyBarModel.layers(terminal, terminal: true).first { $0.mods == [.command, .option] }?.slots.compactMap(\.id)
    #expect(panes == ["term.pane.left", "term.pane.right", "term.pane.up", "term.pane.down"])
    #expect(!KeyBarModel.layers(commands).flatMap(\.slots).contains { $0.id?.hasPrefix("term.pane.") == true }, "not on the panels' bar")
}

/// R-36: the command line's keys, listed by its key handler, are the bar while it has the focus — one list; the line
/// itself says only what to type (phase 4, R-30). Not ⌃↩: macOS gives it to a text field's context menu, so Insert
/// Name stays the panel's.
@MainActor @Test func theCommandLinesKeysAreOneList() {
    let keys = AppDelegate.commandLineKeys
    #expect(keys.map(\.key) == ["↩", "⇧↩", "⌘↩", "↑↓", "⎋", "%f %s %d %D"])
    let commands = AppDelegate().makeCommands()
    let bar = KeyBarView()
    bar.frame = NSRect(x: 0, y: 0, width: 1400, height: 30)
    bar.reload(commands)
    var ran: [String] = []
    bar.onRun = { ran.append($0) }
    bar.canRun = { _ in false }   // a text field has the focus: the panels' commands are off, the line's own aren't
    bar.list = keys
    #expect(bar.shownSlots == keys)
    func buttons(_ v: NSView) -> [NSButton] { v.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
    let run = buttons(bar).first { $0.identifier?.rawValue == "cmdline.shell" }!
    #expect(run.isEnabled && !(buttons(bar).first { $0.accessibilityLabel() == "↑↓, History" }?.isEnabled ?? true))
    _ = (run.target as? NSObject)?.perform(run.action, with: run)
    #expect(ran == ["cmdline.shell"])
}

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// R-64, R-44: one grammar. A placeholder says what to type — no keys, no "Esc"; a row's detail names no key (the action
/// bar does); nowhere "Esc close(s)" or "⎋ closes". Read off the sources, as `everySymbolExistsAndComesFromTheRegistry`
/// is. What's still so is listed here, each with why.
@Test func placeholdersSayWhatToTypeAndHintsHaveOneGrammar() throws {
    let allowed = [
        "HeaderSearch.swift: ⌘F": "the palette (⇧⌘P) lists keys by design until phase 8 (R-43)",
    ]
    let literal = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
    func literals(_ s: String) -> [String] {
        literal.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }
    }
    var found: [String] = [], used: Set<String> = []
    for case let file as URL in FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
    where file.pathExtension == "swift" {
        for (i, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated()
        where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            let at = "\(file.lastPathComponent):\(i + 1)"
            for l in literals(line) where ["esc close", "⎋ closes"].contains(where: l.lowercased().contains) { found.append("\(at): \(l)") }
            var hinted: [String] = []
            for word in ["placeholder:", "placeholderString =", "detail:"] {
                if let r = line.range(of: word) { hinted += literals(String(line[r.lowerBound...])) }
            }
            for l in hinted where l.contains(where: "↩⌘⌃⎋".contains) || l.contains("Esc") {
                let key = "\(file.lastPathComponent): \(l)"
                if allowed[key] != nil { used.insert(key) } else { found.append("\(at): \(l)") }
            }
        }
    }
    #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    #expect(used == Set(allowed.keys), "an exception that's gone from the code goes from here")
}

extension ServerLockTests {
/// R-40, R-41: a list's keys are on its action bar — ↩ and the highlighted row's own, in the words of its menu, ⌃↩ where
/// it has one, ⎋ — each a click away, doing what the key does. Where the list is: a chip before the field, production's
/// said; the highlight is the system's, as in every list.
@MainActor @Test func servicesSayTheirKeysOnTheActionBar() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r1p3-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let app = AppDelegate()
    app.panels = [panel]
    let pb = NSPasteboard(name: .init("kermo-test-" + UUID().uuidString))
    defer { pb.releaseGlobally() }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let units = [ServiceUnit(unit: "web.service", active: "active", sub: "running")]
    let list = Picker.show(over: window, placeholder: "Filter services", scope: ("web-01", [.prod]), header: "1 unit",
                           items: units.map { app.serviceItem($0, on: .local(), of: SavedServer(target: .local()), pasteboard: pb) })
    defer { Picker.dismiss() }
    #expect(list.actionBar.map { "\($0.key) \($0.label)" }
            == ["↩ Status", "⌘L Live Logs", "⌘R Restart", "⌘E Edit Unit File", "⌘C Copy Service Name", "⌃↩ Actions", "⎋ Close"])
    func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
    let all = views(list.panel.contentView!)
    let copy = try #require(all.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "⌘C, Copy Service Name" })
    _ = (copy.target as? NSObject)?.perform(copy.action, with: copy)
    #expect(pb.string(forType: .string) == "web.service" && Picker.current === list, "the click copies, as ⌘C does; the list stays")
    #expect(all.compactMap { $0 as? ScopeChip }.first?.accessibilityLabel() == "web-01, production")
    list.panel.contentView?.layoutSubtreeIfNeeded()
    for _ in 0..<100 where list.panelBarShown.count == 7 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(list.panelBarShown.map(\.label) == ["Status", "Live Logs", "Restart", "Actions", "Close"], "a narrow picker keeps ↩, ⌃↩ and ⎋")
    let table = try #require(all.compactMap { $0 as? NSTableView }.first)
    #expect(type(of: table.rowView(atRow: 0, makeIfNecessary: true)!) == NSTableRowView.self, "the system's highlight")
}

/// R-40: Connect's keys follow the highlighted row: ⌘E edits a saved server's only. The New Server… row says what ↩ does.
@MainActor @Test func connectSaysItsKeysOnTheActionBar() throws {
    var web = SavedServer(address: "me@web.invalid")!
    web.name = "web"
    let app = AppDelegate()
    app.savedServers = [web]
    app.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
    defer { Picker.dismiss(); app.window = nil }
    app.showConnect()
    let p = try #require(Picker.current)
    #expect(p.actionBar.map(\.label) == ["New Server", "Close"])
    func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
    let table = try #require(views(p.panel.contentView!).compactMap { $0 as? NSTableView }.first)
    table.selectRowIndexes([try #require(p.rows.firstIndex { $0.title == "web" })], byExtendingSelection: false)
    #expect(p.actionBar.map { "\($0.key) \($0.label)" } == ["↩ Connect", "⌘E Edit", "⎋ Close"])
}

/// R-42: nothing to list says so in the middle — the list's own words, else "Nothing here", or "No matches" once typing
/// hid every row. A look that failed says why in the line under the rows, in place of "Looking at…", and stays.
@MainActor @Test func anEmptyPickerSaysSo() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    defer { Picker.dismiss() }
    let ports = Picker.show(over: window, placeholder: "Filter ports", empty: "Nothing listens on TCP there", items: [])
    #expect(ports.emptySaid == "Nothing listens on TCP there" && ports.actionBar.map(\.key) == ["⎋"])
    #expect(Picker.show(over: window, placeholder: "", items: []).emptySaid == "Nothing here")
    let typed = Picker.show(over: window, placeholder: "Folder", items: [Picker.Item(title: "site") {}], query: "zzz")
    #expect(typed.emptySaid == "No matches")
    let look = Picker.show(over: window, placeholder: "Filter services", empty: "Looking at services…", items: [])
    look.say(NSAttributedString(string: "ssh: connect to host web: Connection refused"))
    #expect(look.emptySaid == "" && look.said.hasPrefix("ssh:") && Picker.current === look)
}
}

// MARK: - 3b: document windows

/// R-46, Р9: a document window says its name in the title, where it is under it — "web-01 · /etc/nginx" on a server, by
/// its saved name; "~/…" here; nothing for a temporary copy — and what it shows now in a status line at the bottom.
@MainActor @Test func documentWindowsSayNamePlaceAndStatus() async throws {
    _ = NSApplication.shared
    #expect(DocFrame.place(Foundation.NSTemporaryDirectory() + "dfm-arch-1", host: nil) == "", "an archive's entry, git's output")
    #expect(DocFrame.place(NSHomeDirectory() + "/site", host: nil) == "~/site" && DocFrame.place("/etc", host: "web-01") == "web-01 · /etc")

    let dir = NSTemporaryDirectory() + "dfm-r1p3-" + UUID().uuidString   // the tests' own, on the test disk: not the app's temp folder
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try Data("GET /a 200\nERROR boom\n".utf8).write(to: URL(fileURLWithPath: dir + "/app.log"))
    let v = Viewer.show(URL(fileURLWithPath: dir + "/app.log"))
    defer { v.window?.close() }
    for _ in 0..<500 where v.window?.statusText.hasPrefix("Loading") != false { try await Task.sleep(for: .milliseconds(10)) }
    let w = try #require(v.window)
    #expect(w.title == "app.log" && w.subtitle == (dir as NSString).abbreviatingWithTildeInPath && w.statusText == "22 B · UTF-8", "\(w.subtitle) | \(w.statusText)")
    v.cycleLevels()
    for _ in 0..<500 where !w.statusText.contains("errors") { try await Task.sleep(for: .milliseconds(10)) }
    #expect(w.statusText.hasSuffix("errors and warnings") && !w.subtitle.contains("errors"), "state in words, in the status line: \(w.statusText)")

    let e = try Editor(URL(fileURLWithPath: dir + "/app.log"), remote: "web-01:/var/log/app.log")
    defer { e.close() }
    #expect(e.window?.title == "app.log" && e.window?.subtitle == "web-01 · /var/log" && e.window?.statusText == "UTF-8")
    #expect(e.window?.windowsMenuTitle == "app.log — web-01 · /var/log" && w.windowsMenuTitle == "app.log — " + w.subtitle,
            "the Window menu has no subtitles: two app.log of two servers read apart there (D-109)")

    let title = "dfm out " + UUID().uuidString.prefix(6)
    Shell.run("echo hi; sleep 0.3", in: dir, title: title)
    let o = try #require(NSApp.windows.first { $0.title == title })
    defer { o.close() }
    #expect(o.subtitle == (dir as NSString).abbreviatingWithTildeInPath && o.statusText == "running…")
    for _ in 0..<300 where !o.statusText.hasPrefix("exit") { try await Task.sleep(for: .milliseconds(10)) }
    #expect(o.statusText.hasPrefix("exit 0 · "), "\(o.statusText)")
}

/// R-46, Р9, step 8: a document window's key bar is F1 over it — its own keys, then the menu bar's that work there,
/// each key once — and a click on a slot does what the key does: "w" wraps, and the toolbar's Wrap shows it.
@MainActor @Test func aWindowsKeyBarIsItsF1AndClicksAreKeys() async throws {
    _ = NSApplication.shared
    let app = AppDelegate(), menu = app.makeMenu()
    DocFrame.rows = { app.keyRows(over: $0, menu: menu) }
    defer { DocFrame.rows = { _ in [] } }
    let dir = NSTemporaryDirectory() + "dfm-r1p3k-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try Data("one\ntwo\n".utf8).write(to: URL(fileURLWithPath: dir + "/a.log"))
    let v = Viewer.show(URL(fileURLWithPath: dir + "/a.log"))
    defer { v.window?.close() }
    let w = try #require(v.window), frame = try #require(w.docFrame)
    for _ in 0..<500 where w.statusText.hasPrefix("Loading") { try await Task.sleep(for: .milliseconds(10)) }
    frame.showKeys()
    var once: Set<String> = []
    let f1 = app.keySections(over: w, menu: menu).flatMap(\.rows).filter { once.insert($0.keys).inserted }
    #expect(frame.keys.list?.map { "\($0.key) \($0.label)" } == f1.map { "\($0.keys) \($0.title.replacingOccurrences(of: "…", with: ""))" })
    #expect(frame.keys.list?.prefix(8).map(\.key) == ["&", "e", "h", "f", "l", "w", "⌘F", "⎋"])

    func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
    let wrap = try #require(views(frame.keys).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "w, Wrap" })
    #expect(!v.wraps)
    _ = (wrap.target as? NSObject)?.perform(wrap.action, with: wrap)
    let switches = views(w.toolbar?.items.compactMap(\.view).first { ($0 as? NSSegmentedControl)?.label(forSegment: 0) == "Wrap" } ?? NSView())
    #expect(v.wraps && (switches.first as? NSSegmentedControl)?.isSelected(forSegment: 0) == true, "the slot is the key; the toolbar follows")
}

/// R-36: Run on Servers' sheet and Synchronize have the key bar too. The sheet's ⌘A / ⇧⌘A tick only while the filter has
/// the focus — in the command ⌘A selects its text — so the bar says them only then, and the filter's placeholder needn't;
/// a click is the key.
@MainActor @Test func runOnServersAndSyncHaveTheirKeys() async throws {
    _ = NSApplication.shared
    let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    RunOnServersSheet.show(on: parent, choices: [RunOnServersSheet.Choice(title: "web1", target: SFTPTarget(host: "me@web1.invalid"), saved: nil)],
                           ticked: [], command: "uptime") { _, _ in }
    let sheet = try #require(RunOnServersSheet.current)
    defer { sheet.close() }
    #expect(sheet.filter.placeholderString == "Filter by name or host")
    for _ in 0..<100 where sheet.barShown.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(sheet.barShown.map { "\($0.key) \($0.label)" } == ["↩ Run", "⎋ Cancel"], "the command has the focus")
    sheet.window?.makeFirstResponder(sheet.filter)
    for _ in 0..<100 where sheet.barShown.count == 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(sheet.barShown.map { "\($0.key) \($0.label)" } == ["↩ Run", "⌘A Tick All", "⇧⌘A Untick All", "⎋ Cancel"])
    func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
    let content = try #require(sheet.window?.contentView)
    let all = try #require(views(content).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "⌘A, Tick All" })
    _ = (all.target as? NSObject)?.perform(all.action, with: all)
    #expect(sheet.boxes.map(\.state) == [.on] && sheet.runButton.title == "Run on 1 Server")

    let dir = NSTemporaryDirectory() + "dfm-r1p3s-" + UUID().uuidString
    for side in ["a", "b"] { try FileManager.default.createDirectory(atPath: dir + "/" + side, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(atPath: dir) }
    SyncWindow.show(left: dir + "/a", right: dir + "/b", sides: (.local, .local)) { _ in false }
    let sync = try #require(NSApp.windows.first { SyncWindow.keys(of: $0) != nil && $0.subtitle.contains("dfm-r1p3s-") })
    defer { sync.close() }
    let app = AppDelegate()
    #expect(app.keyRows(over: sync, menu: app.makeMenu()).prefix(2).map { "\($0.key) \($0.title)" } == ["↩ Synchronize", "⎋ Close"],
            "its own keys first on its bar and F1, the menu's after")
}
