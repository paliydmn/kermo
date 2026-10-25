import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Review 1, phase 3: keys, not prose — one key bar for the panels, the terminal, the command line, Pickers and windows.

/// The words of a text, letters only: "Show/Hide Sidebar" → show, hide, sidebar; "Mark ↓" → mark.
private func words(_ s: String) -> [String] {
    s.lowercased().split { !$0.isLetter }.map(String.init)
}

/// R-33: a slot's label is words of its command's menu title — no "MkDir" for New Folder…, no "Commands" for Search… —
/// in Title Case. Where the bar says what the menu can't, the exceptions are listed here, each with why.
@MainActor @Test func labelsAreWordsOfTheirMenuTitles() {
    let commands = AppDelegate().makeCommands()
    let exceptions: [String: String] = [
        "file.trash Delete…": "F8 on a server deletes, after a question: no Trash there (the menu item says Delete… then too)",
    ]
    let terminal = AppDelegate.terminalCommands.compactMap { id in commands.first { $0.id == id } }
    let all = KeyBarModel.layers(commands) + KeyBarModel.layers(commands, server: true) + KeyBarModel.layers(terminal, terminal: true)
    var used: Set<String> = []
    for slot in all.flatMap(\.slots) {
        guard let id = slot.id, let c = commands.first(where: { $0.id == id }) else { continue }
        if exceptions["\(id) \(slot.label)"] != nil {
            used.insert("\(id) \(slot.label)")
            continue
        }
        let title = Set(words(c.title))
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

/// R-36: with the terminal up the bar shows the terminal's commands from the registry — its panes' too — and ⌃O goes
/// back to the panels. None of them is a bare F-key: each one's first key shows at rest.
@MainActor @Test func theTerminalsKeysComeFromTheRegistry() {
    let commands = AppDelegate().makeCommands()
    let bar = KeyBarView()
    bar.terminalShown = { true }
    bar.frame = NSRect(x: 0, y: 0, width: 1400, height: 30)
    bar.reload(commands)
    let rest = bar.shownSlots
    #expect(rest.first == KeySlot(key: "⌃O", label: "Panels", id: "view.terminal"))
    #expect(rest.contains(KeySlot(key: "⌘T", label: "New Tab", id: "tab.new")) && rest.contains { $0.id == "term.split.right" })
    #expect(rest.compactMap(\.id).allSatisfy(AppDelegate.terminalCommands.contains))
    let terminal = AppDelegate.terminalCommands.compactMap { id in commands.first { $0.id == id } }
    let panes = KeyBarModel.layers(terminal, terminal: true).first { $0.mods == [.command, .option] }?.slots.compactMap(\.id)
    #expect(panes == ["term.pane.left", "term.pane.right", "term.pane.up", "term.pane.down"])
    #expect(!KeyBarModel.layers(commands).flatMap(\.slots).contains { $0.id?.hasPrefix("term.pane.") == true }, "not on the panels' bar")
}

/// R-36: the command line's keys, listed by its key handler, are the bar while it has the focus and its placeholder —
/// one list. Not ⌃↩: macOS gives it to a text field's context menu, so Insert Name stays the panel's.
@MainActor @Test func theCommandLinesKeysAreOneList() {
    let keys = AppDelegate.commandLineKeys
    #expect(keys.map(\.key) == ["↩", "⇧↩", "⌘↩", "↑↓", "⎋", "%f %s %d %D"])
    let hint = AppDelegate.commandHint(root: nil)
    for k in keys { #expect(hint.contains(k.key), "\(k.key)") }
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
/// is. What's still so is listed here, each with why; the command line's placeholder (phase 4, R-30) is made from its
/// keys, see `theCommandLinesKeysAreOneList`.
@Test func placeholdersSayWhatToTypeAndHintsHaveOneGrammar() throws {
    let allowed = [
        "PanelViewController.swift: filter: text, *.glob or re:regex · ↩ keep · ⎋ clear": "the panel's filter field: phase 4 (R-29)",
        "RunOnServers.swift: Filter by name or host — ⌘A ticks all shown, ⇧⌘A none": "Run on Servers has no key bar yet (R-49, no phase)",
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
