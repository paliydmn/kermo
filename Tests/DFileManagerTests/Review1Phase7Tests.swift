import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Review 1, phase 7: lists as panels — a source's rows in a panel (columns, a header click, `/`, Space), the row's keys
// through the registry, one question for marked rows, ⌘↩ from a Picker. Made-up rows: nothing goes to a server.

/// A list of made-up rows, its reads counted.
@MainActor private final class Stub: ListSource {
    let title: String
    let target: SFTPTarget
    let columns: [ListColumn]
    var content: ListContent?
    /// What the next read gives; nil: a read is a failure of the test.
    var next: Result<ListContent, Error>?
    private(set) var reads = 0

    static let serviceColumns = [ListColumn(title: "Unit", field: .title, width: 120), ListColumn(title: "State", field: .subtitle, width: 110, state: true),
                                 ListColumn(title: "Boot", field: .cell("boot"), width: 60), ListColumn(title: "Description", field: .detail, width: 120)]

    init(_ title: String = "Services", on t: SFTPTarget = SFTPTarget(host: "deploy@web-01.invalid"), columns: [ListColumn] = serviceColumns,
         rows: [Picker.Item]? = nil, header: String? = nil, empty: String = "Nothing runs") {
        (self.title, target, self.columns) = (title, t, columns)
        content = rows.map { ListContent(rows: $0, header: header, empty: empty) }
    }

    /// Quick View of a row: none unless a test says.
    var peeks: (Picker.Item) -> ListPeek? = { _ in nil }
    func peek(_ row: Picker.Item) -> ListPeek? { peeks(row) }

    func read(_ cancel: CancelFlag) async throws -> ListContent {
        reads += 1
        guard let next else { throw JobErrorMessage("read, but nothing may be") }
        let c = try next.get()
        content = c
        return c
    }
}

@MainActor private func row(_ title: String, _ state: StateMark? = .on, subtitle: String = "active · running", detail: String = "",
                            boot: String = "enabled", actions: (@MainActor () -> [ListAction])? = nil) -> Picker.Item {
    var it = Picker.Item(title: title, subtitle: subtitle, detail: detail) {}
    it.id = title
    it.state = state
    it.cells = ["boot": boot]
    it.listActions = actions
    return it
}

@MainActor private func until(_ done: () -> Bool) async {
    for _ in 0..<250 where !done() { try? await Task.sleep(for: .milliseconds(20)) }
}

@MainActor private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/kermo-p7-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// A panel showing `s`'s list.
@MainActor private func panel(_ s: Stub, filter: String = "", select: String? = nil) throws -> PanelViewController {
    let p = PanelViewController(tabs: [try tempDir()], index: 0, showHidden: false)
    p.loadViewIfNeeded()
    p.showList(s, filter: filter, select: select)
    return p
}

/// What a cell says, as drawn.
@MainActor private func cell(_ p: PanelViewController, _ column: Int, _ row: Int) -> String {
    let v = p.list?.tableView(p.table, viewFor: p.table.tableColumns[column], row: row) as? PanelCell
    return v?.text?.string ?? v?.textField?.stringValue ?? ""
}

/// A source's columns and rows in a panel: what failed first, then what needs a look; its line above the columns; the
/// status line counts rows. The file columns come back when the list goes.
@MainActor @Test func aListShowsItsColumnsAndProblemsFirst() async throws {
    let s = Stub(rows: [row("cron"), row("nginx", .attention, subtitle: "activating"), row("worker", .failed, subtitle: "failed")], header: "3 units · 1 failed")
    let p = try panel(s)
    defer { p.shutdown() }
    #expect(p.table.tableColumns.map(\.title) == ["Unit", "State", "Boot", "Description"])
    #expect(p.list?.shown.map(\.title) == ["worker", "nginx", "cron"], "failed, then needing a look, then as read")
    #expect(cell(p, 0, 0) == "worker" && cell(p, 1, 0).hasSuffix(" failed") && cell(p, 2, 0) == "enabled")
    #expect(cell(p, 1, 0).hasPrefix("\u{FFFC}"), "a mark — a shape — before the state")
    #expect(p.list?.headerView.isHidden == false && p.list?.headerView.isDescendant(of: p.view) == true)
    #expect(p.statusText == "3 rows" && p.statusChipWords.isEmpty, "SSH only while a connection is up")
    #expect(p.headerText == "deploy@web-01.invalid › Services" && p.pathBar.crumbs == [PathBar.Crumb(title: "Services", path: nil)])
    #expect(p.server == s.target && p.heldServers == [s.target] && p.remoteTabs.isEmpty, "it holds its server's connection; not a files session in the sidebar")
    #expect(p.item(at: 0) == nil && p.targetItems.isEmpty && p.transferItems == nil, "no file under the cursor")

    p.navigate(to: NSTemporaryDirectory())   // elsewhere: the files' columns back, once the folder's listing lands
    #expect(p.list != nil)
    await until { p.list == nil }
    #expect(p.table.tableColumns.first?.title == "Name" && p.remoteTabs.isEmpty && p.server == nil)
}

/// A header click sorts by that column, and again the other way; the cursor stays on its row.
@MainActor @Test func aHeaderClickSortsTheCursorKeepsItsRow() throws {
    // Its own server: the order is kept per server and list, and other tests' lists run meanwhile.
    let s = Stub(on: SFTPTarget(host: "deploy@header-click.invalid"), rows: [row("cron"), row("nginx", .attention), row("worker", .failed)])
    let p = try panel(s, select: "nginx")
    defer {
        p.shutdown()
        var kept = UserDefaults.standard.dictionary(forKey: "listSort") ?? [:]
        kept["deploy@header-click.invalid:22 Services"] = nil
        UserDefaults.standard.set(kept, forKey: "listSort")
    }
    #expect(p.list?.cursor?.title == "nginx")
    p.table.sortDescriptors = [NSSortDescriptor(key: "0", ascending: true)]
    #expect(p.list?.shown.map(\.title) == ["cron", "nginx", "worker"] && p.list?.cursor?.title == "nginx")
    p.table.sortDescriptors = [NSSortDescriptor(key: "0", ascending: false)]
    #expect(p.list?.shown.map(\.title) == ["worker", "nginx", "cron"] && p.table.selectedRow == 1)
}

/// `/` is the panel's quick filter: rows whose title, subtitle or detail match, the status says how many of how many;
/// Space marks the cursor's row (✓ in the marks' color) and moves on; the status says how many are marked.
@MainActor @Test func slashFiltersSpaceMarks() throws {
    let s = Stub(rows: [row("cron", detail: "Regular background program processing daemon"), row("nginx", detail: "A high performance web server"),
                        row("worker", .failed, subtitle: "failed")])
    let p = try panel(s)
    defer { p.shutdown() }
    p.beginFilter()
    p.filterField.stringValue = "web"
    p.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: p.filterField))
    #expect(p.list?.shown.map(\.title) == ["nginx"] && p.statusText == "1 row · filtered: 1 of 3")
    p.filterKey("filter.clear")
    #expect(p.list?.shown.count == 3)

    p.list?.moveCursor(to: 0)
    p.toggleMark(move: 1)
    #expect(p.list?.marked == ["worker"] && p.list?.cursor?.title == "cron" && p.statusText == "1 marked")
    let marked = p.list?.tableView(p.table, viewFor: p.table.tableColumns[0], row: 0) as? PanelCell
    #expect(marked?.check.isHidden == false && marked?.textField?.font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #expect(p.list?.targets.map(\.title) == ["worker"], "an action acts on the marked, not the cursor's")
    p.markAll()
    #expect(p.statusText == "3 marked")
    p.unmarkAll()
    #expect(p.list?.targets.map(\.title) == ["cron"])
}

/// ⌘R in the menu reads the list again: the cursor stays on its row by id wherever it went, the marks on rows still
/// there. A read that fails over nothing shown says why in the middle with Retry; a list with nothing in it says so.
@MainActor @Test func aReadKeepsTheCursorByKeyAFailureHasRetry() async throws {
    let s = Stub(rows: [row("cron"), row("nginx"), row("worker", .failed)])
    let p = try panel(s, select: "nginx")
    defer { p.shutdown() }
    p.toggleMark(move: 0)
    s.next = .success(ListContent(rows: [row("nginx"), row("cron"), row("redis")]))
    p.readList()
    await until { s.reads == 1 && p.list?.count == 3 && p.list?.shown.first?.title == "nginx" }
    #expect(p.list?.shown.map(\.title) == ["nginx", "cron", "redis"] && p.list?.cursor?.title == "nginx" && p.list?.marked == ["nginx"])

    let empty = Stub(rows: nil)
    empty.next = .failure(JobErrorMessage("ssh: Could not resolve hostname"))
    let q = try panel(empty)
    defer { q.shutdown() }
    await until { q.emptyShown?.title.hasPrefix("Can't read") == true }
    #expect(q.emptyShown?.title == "Can't read services" && q.emptyShown?.detail == "ssh: Could not resolve hostname")
    #expect(q.emptyShown?.keys.map(\.label) == ["Retry"] && q.emptyShown?.keys.first?.id == "view.refresh")
    empty.next = .success(ListContent(rows: [], empty: "systemd lists no services there"))
    q.readList()
    await until { q.emptyShown?.title == "systemd lists no services there" }
    #expect(q.emptyShown?.title == "systemd lists no services there" && empty.reads == 2)
}

/// A tab keeps its list: another tab and back shows it again, not read; ⌘T is the same list in a new tab.
@MainActor @Test func aTabKeepsItsListUnread() async throws {
    let s = Stub(rows: [row("cron"), row("nginx")])
    let p = try panel(s, select: "nginx")
    defer { p.shutdown() }
    p.newTab()
    #expect(p.list !== nil && p.list?.cursor?.title == "nginx" && p.tabPaths.count == 2)
    p.switchTab(by: 1)
    p.switchTab(by: 1)
    #expect(p.list?.cursor?.title == "nginx" && s.reads == 0)
    #expect(p.sessionTabs.allSatisfy { $0.server == s.target && $0.place == true && $0.cursor == "Services" }, "a restart brings its server's place, on its row")
}

/// The apps the tests below make live on: a panel's late work (its git status landing) calls back into its app,
/// which the app's own `wire` holds unowned — as the real app, which lives till quit.
@MainActor private var keptApps: [AppDelegate] = []

extension ServerLockTests {
    /// Two wired panels in a window, the registry, its keymap (in a folder of its own) and the menu bar — as the app.
    @MainActor private func app() throws -> (AppDelegate, PanelViewController, PanelViewController, () -> Void) {
        _ = NSApplication.shared
        let dir = try tempDir(), was = AppDelegate.keymapDir
        AppDelegate.keymapDir = dir
        for k in ["listSort", "placeLastList"] { UserDefaults.standard.removeObject(forKey: k) }   // a test's order or last list isn't the next one's
        let app = AppDelegate()
        keptApps.append(app)
        app.terminal = EmbeddedTerminal(covering: NSView())
        app.applyConfig(reportProblems: false)
        let a = PanelViewController(tabs: [dir], index: 0, showHidden: false), b = PanelViewController(tabs: [dir], index: 0, showHidden: false)
        app.panels = [a, b]
        app.wireKeyBar()
        app.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        app.window.contentView = host
        for (i, p) in [a, b].enumerated() { p.view.frame = NSRect(x: CGFloat(i) * 500, y: 0, width: 500, height: 600); host.addSubview(p.view) }
        host.layoutSubtreeIfNeeded()
        [a, b].forEach(app.wire)
        // Not `releaseIdleServers`: it stops every master not in use, another suite's made-up ones too (MastersTests).
        for p in [a, b] { p.onSessionsChange = { [weak app] in app?.refreshSidebar() } }
        return (app, a, b, {
            Picker.dismiss()
            AppDelegate.answering = nil
            [a, b].forEach { $0.shutdown() }
            app.window = nil
            AppDelegate.keymapDir = was
            try? FileManager.default.removeItem(atPath: dir)
            for k in ["listSort", "placeLastList"] { UserDefaults.standard.removeObject(forKey: k) }
        })
    }

    /// A key to the panel, as from the keyboard: the table's keyDown, then the registry (`runKey`).
    @MainActor private func press(_ p: PanelViewController, _ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) {
        p.table.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                                               characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
    }

    /// A service's row with Services…' keys, each run written down.
    @MainActor private func serviceRow(_ title: String, _ ran: Later<[String]>, why: [String: String] = [:], prod: SFTPTarget? = nil) -> Picker.Item {
        func a(_ t: String, _ key: String?, _ group: Int = 0, list: String? = nil, command: String? = nil, asks: ListAction.Asks = .never,
               dangerous: Bool = false, note: String? = nil) -> ListAction {
            ListAction(title: t, key: key.flatMap(Shortcut.init), group: group, closes: false, why: why[t], listKey: list.flatMap(Shortcut.init),
                       command: command, runsOn: prod, asks: asks, dangerous: dangerous, note: note) { asked in ran.value.append("\(t) \(title)" + (asked ? " (asked)" : "")); return nil }
        }
        return row(title, actions: {
            [a("Status", "return"), a("Live Logs", "cmd+l"), a("Edit Unit File…", "cmd+e"), a("Copy Service Name", "cmd+c"),
             a("Stop…", nil, 1, list: "f8", command: "systemctl stop -- \(title).service", asks: .always, note: "They stay stopped."),
             a("Restart", "cmd+r", 1, command: "systemctl restart -- \(title).service", asks: .prod)]
        })
    }

    /// The row's keys come through the registry's commands, each only on the key the row has: F8 is Stop…, ⌘⌫ and
    /// Delete (Move to Trash's other keys) do nothing; ⌘L is Live Logs, ⇧⌘G isn't; F4 edits (⌘E there being the command
    /// line). ⌘R from the keyboard restarts, View ▸ Refresh clicked reads the list again. A file's command is off.
    @Test func aRowsKeysRideTheRegistryOnlyOnTheirOwnKey() async throws {
        let (app, a, _, done) = try app()
        defer { done() }
        let ran = Later<[String]>([])
        let s = Stub(rows: [serviceRow("nginx", ran)])
        s.next = .success(ListContent(rows: [serviceRow("nginx", ran)]))
        a.showList(s)
        app.window.makeFirstResponder(a.table)
        #expect(app.active === a)
        press(a, 100, String(Character(UnicodeScalar(NSF8FunctionKey)!)))   // F8
        press(a, 51, "\u{8}", .command)   // ⌘⌫
        press(a, 117, String(Character(UnicodeScalar(NSDeleteFunctionKey)!)))   // Delete
        press(a, 37, "l", .command)   // ⌘L
        press(a, 5, "G", [.command, .shift])   // ⇧⌘G
        press(a, 118, String(Character(UnicodeScalar(NSF4FunctionKey)!)))   // F4
        press(a, 14, "e", .command)   // ⌘E: the command line's, as anywhere — it says a list isn't a folder
        press(a, 36, "\r")   // ↩
        press(a, 15, "r", .command)   // ⌘R
        #expect(ran.value == ["Stop… nginx", "Live Logs nginx", "Edit Unit File… nginx", "Status nginx", "Restart nginx"])
        a.copy(nil)   // Edit ▸ Copy, ⌘C
        #expect(ran.value.last == "Copy Service Name nginx")
        #expect(s.reads == 0)
        app.run("view.refresh")   // the menu item clicked
        await until { s.reads == 1 }
        #expect(s.reads == 1 && ran.value.count == 6, "View ▸ Refresh reads it again; nothing restarted")

        // The menu: F3 (no View here) and F5 off, F4 F8 ⌘L named for the row; the row's keys aren't the menu's while it
        // has them (a test's window is never key: what's on is said by `runsInList`, the keys by `listRowKeys`).
        let menu = try #require(NSApp.mainMenu)
        func title(_ id: String) -> String? {
            menu.allItems.first { $0.representedObject as? String == id }.map { _ = app.validateMenuItem($0); return $0.title }
        }
        #expect(title("file.trash") == "Stop…" && title("file.edit") == "Edit Unit File…" && title("go.path") == "Live Logs" && title("view.refresh") == "Refresh")
        #expect(title("file.view") == "View" && !AppDelegate.runsInList("file.view") && !AppDelegate.runsInList("file.copy"))
        #expect(["view.refresh", "view.filter", "mark.toggle", "go.home", "tab.new", "server.services", "view.terminal"].allSatisfy(AppDelegate.runsInList))
        #expect(app.listRowKeys == Set(["return", "cmd+l", "f4", "cmd+c", "f8", "cmd+r"].compactMap(Shortcut.init)))
        let keys = app.makeMenu().allItems.filter { $0.representedObject is String }.compactMap { Shortcut(menuItem: $0) }   // ⌘A: Edit's and Mark All's, by design
        #expect(Set(keys).count == keys.count, "no key twice among the registry's items")

        // The key bar: the row's keys in its words, ↩ first, Stop… red; then Mark, Filter, Actions. A slot clicked is its key.
        let bar = try #require(app.focusedKeys)
        #expect(bar.map(\.label) == ["Status", "Live Logs", "Edit Unit File…", "Copy Service Name", "Stop…", "Restart", "Mark", "Filter", "Actions"])
        #expect(bar.map(\.key) == ["↩", "⌘L", "F4", "⌘C", "F8", "⌘R", "Space", "/", "⌃↩"] && bar.filter(\.danger).isEmpty, "Stop… isn't red: a Start undoes it")
        app.keyBar.onRun?(try #require(bar.first { $0.label == "Restart" }?.id))
        #expect(ran.value.last == "Restart nginx")
        app.keyBar.onRun?("list:mark.toggle")
        #expect(a.list?.marked == ["nginx"])

        // Leaving the list gives the menu its keys and titles back.
        a.navigate(to: NSTemporaryDirectory())
        await until { a.list == nil }
        #expect(app.listRowKeys.isEmpty && title("file.trash") == "Move to Trash" && title("go.path") == "Go to Path…" && app.focusedKeys == nil)
    }

    /// Restart of two marked rows on production: one question for both — each command, the PROD strip, ↩ = Cancel —
    /// and nothing runs on Cancel; ⌘↩ runs each, already asked. A row the action can't run on says why and is left out.
    /// F5 into a list from the other panel is off, saying why.
    @Test func markedRowsAskOnceAndLeaveOutWhatCant() async throws {
        let (app, a, b, done) = try app()
        defer { done(); ServerLock.servers = { [] } }
        var prod = SavedServer(address: "deploy@web-01.invalid")!
        prod.prod = true
        ServerLock.servers = { [prod] }
        let t = prod.target, ran = Later<[String]>([])
        let s = Stub(on: t, rows: [serviceRow("nginx", ran, prod: t.asRoot()), serviceRow("worker", ran, prod: t.asRoot()),
                                    serviceRow("cron", ran, why: ["Restart": "cron is restarting… wait for it"], prod: t.asRoot())])
        a.showList(s)
        app.window.makeFirstResponder(a.table)
        a.markAll()
        var asked: (String, [String], Int?)?
        AppDelegate.answering = { m, buttons, d in asked = (m, buttons, d); return d ?? 0 }   // ↩
        press(a, 15, "r", .command)
        await until { asked != nil }
        #expect(asked?.0 == "Restart 2 services on deploy@web-01.invalid?" && asked?.1 == ["Restart", "Cancel"] && asked?.2 == 1, "↩ = Cancel on production")
        await until { a.list?.resultLines.contains { $0.hasSuffix("nothing ran") } == true }
        #expect(ran.value.isEmpty && a.list?.resultLines.contains { $0.hasSuffix("cron is restarting… wait for it — left out") } == true)

        AppDelegate.answering = { _, _, _ in 0 }   // ⌘↩
        press(a, 15, "r", .command)
        await until { ran.value.count == 2 }
        #expect(ran.value == ["Restart nginx (asked)", "Restart worker (asked)"], "in turn, not asked again")

        // F8 on one row: its own question (Stop asks everywhere) — here the row's own run, which asks itself.
        a.unmarkAll()
        a.list?.moveCursor(to: 0)
        press(a, 100, String(Character(UnicodeScalar(NSF8FunctionKey)!)))
        #expect(ran.value.last == "Stop… nginx")

        app.window.makeFirstResponder(b.table)
        #expect(app.active === b)
        app.run("file.copy")
        #expect(b.statusText == "The other panel: Services isn't a folder — ↩ acts on a row, ⌫ goes back")
    }

    /// ⌘↩ in a Picker's list: the other panel shows the same rows — not read again — on what was typed and highlighted,
    /// and has the keys. The Picker's own line shows ⌘↩ Other Panel.
    @Test func commandReturnInAPickerOpensTheSameRowsInTheOtherPanel() async throws {
        let (app, a, b, done) = try app()
        defer { done() }
        let s = Stub(rows: [row("cron"), row("nginx", detail: "web server"), row("worker", .failed)], header: "3 units · 1 failed")
        app.window.makeFirstResponder(a.table)
        app.showInSearch(s)
        let picker = try #require(Picker.current)
        #expect(picker.actionBar.contains(KeySlot(key: "⌘↩", label: "Other Panel", id: "other")))
        picker.update(row("worker", .on, subtitle: "active · running"))   // a restart there since it opened
        _ = picker.panel.performKeyEquivalent(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                                     windowNumber: picker.panel.windowNumber, context: nil, characters: "\r",
                                                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        await until { b.list != nil }
        #expect(Picker.current == nil && b.list?.source === s && s.reads == 0, "the Picker's rows, not read again")
        #expect(b.list?.content?.rows.first { $0.id == "worker" }?.subtitle == "active · running" && b.list?.content?.header == "3 units · 1 failed",
                "as the Picker had them: the run since shows")
        #expect(b.list?.cursor?.title == "worker", "what was highlighted: the first row — failed first, in the search as in a panel")
        #expect(app.active === b && a.list == nil)

        app.servicesKept["services " + ServerRow.key(s.target.asUser)] = ("web", "nginx")
        app.showInSearch(s)   // opens where it was left
        #expect(Picker.current?.rows.map(\.title) == ["nginx"])
        _ = Picker.current?.panel.performKeyEquivalent(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                                              windowNumber: Picker.current?.panel.windowNumber ?? 0, context: nil, characters: "\r",
                                                                              charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        await until { a.list != nil }
        #expect(a.list?.filter == "web" && a.list?.shown.map(\.title) == ["nginx"] && a.list?.cursor?.title == "nginx" && a.filterField.stringValue == "web")
    }

    /// Services… in a panel, on a stand-in systemctl: two marked restart one after the other, each row says it runs,
    /// then its state; a line each under the rows says how it went, and goes once all went well. A failed one stays,
    /// its whole output a click away, till its ✕.
    @Test func restartsInAPanelSayHowTheyWentUnderTheRows() async throws {
        let (app, a, _, done) = try app()
        let dir = try tempDir()
        defer {
            done()
            try? FileManager.default.removeItem(atPath: dir)
            AppDelegate.unitState = { try Services.state($0, on: $1, wait: $2, env: $3, cancel: $4) }
            ServerLock.servers = { [] }
        }
        ServerLock.servers = { [] }
        try FileManager.default.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho \"$*\" >> \(dir)/systemctl.log\n[ -f \(dir)/fail ] && { echo 'Job for web.service failed.'; exit 1; }\nexit 0\n".utf8)
            .write(to: URL(fileURLWithPath: dir + "/bin/systemctl"))
        chmod(dir + "/bin/systemctl", 0o755)
        try Data("#!/bin/sh\n[ \"$1\" = -n ] && [ \"$2\" = -- ] || exit 2\nshift 2\nPATH=\(dir)/bin:$PATH exec \"$@\"\n".utf8).write(to: URL(fileURLWithPath: dir + "/sudo"))
        chmod(dir + "/sudo", 0o755)
        let t = SFTPTarget.local(sudo: dir + "/sudo").asRoot(false)
        AppDelegate.unitState = { _, _, _, _, _ in .init(active: "active", sub: "running") }
        let units = [ServiceUnit(unit: "db.service", active: "active", sub: "running"), ServiceUnit(unit: "web.service", active: "failed", sub: "failed")]
        let source = ServiceList(app, SavedServer(target: t), t, units: units)
        a.showList(source)
        app.window.makeFirstResponder(a.table)
        a.list?.resultTime = 0.4
        #expect(a.list?.shown.map(\.title) == ["web", "db"] && cell(a, 2, 0) == "")
        a.markAll()
        press(a, 15, "r", .command)
        await until { a.list?.resultLines.count == 2 }
        #expect((try? String(contentsOfFile: dir + "/systemctl.log", encoding: .utf8)) == "restart -- web.service\nrestart -- db.service\n", "in turn, as marked")
        #expect(a.list?.resultLines.allSatisfy { $0.contains(" restarted on localhost at ") && $0.hasSuffix(" — active · running") } == true)
        #expect(a.list?.shown.allSatisfy { $0.subtitle == "active · running" && $0.state == .on } == true, "each row's state read again")
        await until { a.list?.resultLines.isEmpty == true }
        #expect(a.list?.resultLines.isEmpty == true, "all went well: the lines go")

        try Data().write(to: URL(fileURLWithPath: dir + "/fail"))
        AppDelegate.unitState = { _, _, _, _, _ in .init(active: "failed", sub: "failed") }
        a.unmarkAll()
        a.list?.moveCursor(to: 0)
        press(a, 15, "r", .command)
        await until { a.list?.resultLines.first?.contains("failed") == true }
        try await Task.sleep(for: .milliseconds(600))
        #expect(a.list?.resultLines.count == 1 && a.list?.resultLines.first?.contains("web: the restart failed on localhost") == true, "a failure stays")
        func buttons(_ v: NSView) -> [NSButton] { v.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        #expect(buttons(try #require(a.list?.resultView)).map(\.title).contains("Output…"))

        // Quick View of a service: its `systemctl status` over the connection the list holds; none up: it says so.
        let web = try #require(a.list?.shown.first { $0.title == "web" }), was = AppDelegate.connected
        defer { AppDelegate.connected = was }
        AppDelegate.connected = { _ in false }   // a master to localhost another test left up: not this one's
        guard case .rows(let lines)? = source.peek(web) else { Issue.record("not connected: lines, no read"); return }
        #expect(lines.first?.1 == "Not connected — Refresh reads the list again")
        AppDelegate.connected = { _ in true }
        guard case .text(let read)? = source.peek(web) else { Issue.record("connected: its status"); return }
        #expect(try !read(CancelFlag()).isEmpty, "what systemctl status said, or why it couldn't")
    }

    /// A panel showing a list keeps its server's connection: releaseIdleServers leaves it be; Disconnect closes the list
    /// back to the tab's folder.
    @Test func aListHoldsItsServerTillDisconnect() async throws {
        let (app, a, _, done) = try app()
        defer { done() }
        let s = Stub(rows: [row("nginx")])
        a.showList(s)
        #expect(app.idleServers([s.target]).isEmpty && app.idleServers([SFTPTarget(host: "other.invalid")]).count == 1)
        await app.disconnectNow(ServerRow.key(s.target))
        #expect(a.list == nil && app.idleServers([s.target]) == [s.target])
    }

    /// A source shaped as a Tools preset — `state` ok / bad / busy, `header`, `empty`, an action `dangerous` with
    /// `confirm: prod` — in a panel and in a Picker, with nothing of theirs changed: its state as a shape, its line, its
    /// question red with ↩ = Cancel on production.
    @Test func aPresetShapedSourceWorksInAPanelAndAPicker() async throws {
        let (app, a, _, done) = try app()
        defer { done(); ServerLock.servers = { [] } }
        var prod = SavedServer(address: "root@fw.invalid")!
        prod.prod = true
        ServerLock.servers = { [prod] }
        let ran = Later<[String]>([])
        func rule(_ n: String, _ state: StateMark?, busy: Bool = false) -> Picker.Item {
            var it = Picker.Item(title: n, subtitle: state == .failed ? "DENY IN" : "ALLOW IN", detail: "from anywhere") {}
            (it.id, it.state, it.busy) = (n, state, busy)
            it.listActions = {
                [ListAction(title: "Status in Full", key: Shortcut("return"), group: 0, closes: true, why: nil) { _ in ran.value.append("status \(n)"); return nil },
                 ListAction(title: "Delete Rule…", key: Shortcut("f8"), group: 1, closes: false, why: nil, command: "ufw --force delete \(n)", runsOn: prod.target,
                            asks: .prod, dangerous: true) { asked in ran.value.append("delete \(n)" + (asked ? " (asked)" : "")); return nil }]
            }
            return it
        }
        let s = Stub("Firewall", on: prod.target, columns: [ListColumn(title: "To", field: .title), ListColumn(title: "Action", field: .subtitle, state: true),
                                                             ListColumn(title: "From", field: .detail)],
                     rows: [rule("22/tcp", .on), rule("8080", .failed), rule("443", nil, busy: true)], header: "Status active · Default deny incoming",
                     empty: "No rules: ufw allows nothing in")
        a.showList(s)
        app.window.makeFirstResponder(a.table)
        #expect(a.list?.shown.map(\.title) == ["8080", "22/tcp", "443"] && a.list?.content?.header == "Status active · Default deny incoming")
        #expect(cell(a, 1, 2).hasSuffix("ALLOW IN") && cell(a, 1, 2).hasPrefix("\u{FFFC}"), "busy: a mark too")
        a.markAll()
        var asked: (String, Int?)?
        AppDelegate.answering = { m, _, d in asked = (m, d); return d ?? 0 }
        press(a, 100, String(Character(UnicodeScalar(NSF8FunctionKey)!)))
        await until { asked != nil }
        #expect(asked?.0 == "Delete Rule 3 firewall on root@fw.invalid?" && asked?.1 == 1 && ran.value.isEmpty, "↩ = Cancel")
        #expect(app.focusedKeys?.first { $0.label == "Delete Rule…" }?.danger == true)

        app.showInSearch(s)   // the same rows in the search, failed first as in the panel
        #expect(Picker.current?.rows.map(\.title) == ["8080", "22/tcp", "443"] && Picker.current?.emptySaid == "")
    }

    /// Forward Port…'s ports in a panel: Port · Process · Listens on · Tunnel, ⌘↩ from its Picker, not read again. ↩
    /// Forward and ⌘C Copy Address are keys there; ⌘O and ⌘S have no command in a panel, so they're in the row's menu.
    @Test func portsInAPanel() async throws {
        let (app, a, b, done) = try app()
        defer { done() }
        let s = SavedServer(target: SFTPTarget(host: "deploy@db-01.invalid"))
        let ports = [ListeningPort(port: 5432, addresses: ["localhost"], process: "postgres"), ListeningPort(port: 80, addresses: ["*"], process: "nginx")]
        app.window.makeFirstResponder(a.table)
        app.showPorts(ports, of: s)
        let picker = try #require(Picker.current)
        #expect(picker.actionBar.contains(KeySlot(key: "⌘↩", label: "Other Panel", id: "other")))
        _ = picker.panel.performKeyEquivalent(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                                     windowNumber: picker.panel.windowNumber, context: nil, characters: "\r",
                                                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        await until { b.list != nil }
        let list = try #require(b.list)
        #expect(b.table.tableColumns.map(\.title) == ["Port", "Process", "Listens on", "Tunnel"])
        #expect(list.shown.map(\.title) == [":5432 Postgres", ":80"] && cell(b, 1, 0) == "postgres" && cell(b, 2, 1) == "all addresses")
        #expect(list.content?.header == "2 listening" && b.headerText == "deploy@db-01.invalid › Ports")
        #expect(app.focusedKeys?.map(\.label) == ["Forward", "Copy Address", "Mark", "Filter", "Actions"])
        let menu = NSMenu()
        app.fillListMenu(menu, list)
        #expect(menu.items.map(\.title) == ["Forward", "", "Copy Address", "Open in Browser", "Save as Tunnel", "", "Refresh"])
        #expect(menu.items.map(\.keyEquivalent) == ["", "", "c", "", "", "", ""], "⌘O, ⌘S: not keys in a panel")
        #expect(app.listRowKeys.contains(Shortcut("cmd+c")!) && !app.listRowKeys.contains(Shortcut("cmd+r")!), "⌘R stays Refresh here")
    }

    /// Quick View (⌃Q) next door shows the list row under the cursor, as its source says: lines, or a text read once the
    /// cursor rests — passing over rows asks nothing. No Preview · Info · Git: a row isn't a file.
    @Test func quickViewShowsTheRowUnderTheCursor() async throws {
        let (app, a, b, done) = try app()
        let rest = PanelViewController.peekRest
        defer { done(); PanelViewController.peekRest = rest }
        PanelViewController.peekRest = 150
        let asked = Later<[String]>([])
        let s = Stub(rows: [row("cron"), row("nginx"), row("worker"), row("redis")])
        s.peeks = { r in
            r.title == "redis" ? .rows([("Name", "redis"), ("State", "running")])
                : .text { [asked] _ in asked.value.append(r.title); return "● \(r.title).service — active (running)" }
        }
        a.showList(s)
        app.window.makeFirstResponder(a.table)
        app.toggleQuickView()
        #expect(b.quickTitleShown == "cron" && !b.quickTabsShown)
        a.list?.moveCursor(to: 1)
        a.list?.moveCursor(to: 2)   // passing over nginx
        await until { b.peekedText?.hasPrefix("●") == true }
        #expect(asked.value == ["worker"] && b.peekedText == "● worker.service — active (running)" && b.quickTitleShown == "worker")
        a.list?.moveCursor(to: 3)
        await until { b.infoRows.first?.1 == "redis" }
        #expect(b.infoRows.map(\.0) == ["Name", "State"] && b.peekedText == nil)
        app.toggleQuickView()
    }

    /// A server's place: its rows from the providers, in order; opening it asks the server nothing — no Touch ID on a
    /// locked one, no read; counts only from a list read before while a connection is up, else "—". ↩ on Services is
    /// the first row that goes to the server: Touch ID then. ⌫ from the list comes back to the place on its row; ⌫ in
    /// the place asks as leaving a server's `/` does.
    @Test func aPlaceAsksTheServerNothing() async throws {
        let (app, a, _, done) = try app()
        let was = (AppDelegate.connected, PanelViewController.confirmLeavingPlace, ServerLock.authenticate)
        defer {
            done()
            (AppDelegate.connected, PanelViewController.confirmLeavingPlace, ServerLock.authenticate) = was
            ServerLock.servers = { [] }
        }
        var s = SavedServer(address: "deploy@web-01.invalid")!
        (s.prod, s.locked, s.startDir) = (true, true, "/var/www/site")
        app.savedServers = [s]
        ServerLock.servers = { [s] }
        var touched = 0
        ServerLock.authenticate = { _ in touched += 1; return false }
        AppDelegate.connected = { _ in false }
        app.window.makeFirstResponder(a.table)
        app.showPlace(s.target, in: a)
        #expect(a.isPlace && touched == 0 && app.listCounts.isEmpty)
        #expect(a.list?.shown.map(\.title) == ["Files", "Home", "/", "Services", "Containers", "Ports", "Tunnels", "File History"])
        #expect(a.list?.shown.first?.detail == "/var/www/site — start folder" && a.list?.shown[3].subtitle == "—")
        #expect(a.headerText == "deploy@web-01.invalid › Overview" && a.headerChips == [.prod, .locked] && a.remoteTabs.isEmpty, "not a session")
        #expect(app.focusedKeys?.map(\.label) == ["Open", "Open in Other Panel", "SSH Here", "As Root", "Filter", "Actions"])

        app.noteCount("services", on: s.target, 10, problems: 1)   // a list read before
        a.readList()
        await until { a.busyMessage == nil }
        #expect(a.list?.shown[3].subtitle == "—", "no connection up: not said")
        AppDelegate.connected = { _ in true }
        a.readList()
        await until { a.list?.shown[3].subtitle == "1 failed" }
        #expect(a.list?.shown[3].detail == "10 units" && a.list?.shown[3].state == .failed && touched == 0)

        a.list?.moveCursor(to: 3)
        press(a, 36, "\r")   // ↩ Services: the first thing sent — Touch ID first
        await until { a.emptyShown?.title == "Can't read services" }
        #expect(touched == 1 && a.emptyShown?.detail == "deploy@web-01.invalid stays locked" && a.headerText == "deploy@web-01.invalid › Services")
        press(a, 51, "\u{8}")   // ⌫: back to the place, on Services
        #expect(a.isPlace && a.list?.cursor?.title == "Services")
        var leaving: SFTPTarget?
        PanelViewController.confirmLeavingPlace = { t, _, _ in leaving = t; return false }
        press(a, 51, "\u{8}")
        await until { leaving != nil }
        #expect(leaving == s.target && a.isPlace, "a connection up: asked, and Cancel stays")
        AppDelegate.connected = { _ in false }
        press(a, 51, "\u{8}")   // nothing to close: no question
        await until { a.list == nil }
        #expect(a.list == nil && a.remote == nil)
        app.showPlace(s.target, in: a, select: "Services")
        #expect(a.sessionTabs.first == Session.Tab(path: a.path, cursor: "Services", server: s.target, place: true), "a restart brings the place back")
    }

    /// ⌫ at a server's `/` goes to its place — nothing asked, nothing closed; the path bar's chip goes there too. One
    /// click in the sidebar on a server with nothing open: its place; the double-click's second: SSH, as before.
    @Test func backspaceAtRootTheChipAndOneClickGoToThePlace() async throws {
        let (app, a, _, done) = try app()
        let was = PanelViewController.confirmLeaving
        defer { done(); PanelViewController.confirmLeaving = was }
        PanelViewController.confirmLeaving = { _, _, _ in Issue.record("asked"); return false }
        a.loadRemote(.local(), dir: "/", select: nil)
        await until { a.remote != nil }
        app.window.makeFirstResponder(a.table)
        a.goUp()
        #expect(a.isPlace && a.list?.cursor?.title == "/" && a.list?.source.target == SFTPTarget.local().asUser && a.remote == nil)

        // ↩ on each row goes where it says: its files at / or in the login folder, its tunnels, its file history.
        func enter(_ title: String) {
            a.list?.moveCursor(to: a.list?.shown.firstIndex { $0.title == title } ?? -1)
            press(a, 36, "\r")
        }
        enter("/")
        await until { a.remote?.dir == "/" }
        #expect(a.remote?.dir == "/" && a.list == nil)
        a.goUp()
        enter("Home")
        await until { a.remote != nil }
        #expect(a.remote?.dir == FileManager.default.currentDirectoryPath, "the login folder: a stand-in server's is where it runs")
        app.showPlace(.local(), in: a)
        enter("Tunnels")
        await until { a.list?.source is TunnelList }
        #expect(a.emptyShown?.title.hasPrefix("Tunnels belong to saved servers") == true, "none saved here: it says how to have one")
        a.goUp()
        let history = AppDelegate.historyRoot
        defer { AppDelegate.historyRoot = history }
        AppDelegate.historyRoot = try tempDir()   // not this Mac's real one
        enter("File History")
        await until { a.statusText.hasPrefix("No file history") }
        #expect(a.statusText.hasPrefix("No file history for localhost"))

        let sidebar = SidebarController()
        var placed: ServerRow?, opened: Place?
        (sidebar.onServerPlace, sidebar.onOpen) = ({ r, _ in placed = r }, { p, _ in opened = p })
        let row = ServerRow(target: SFTPTarget(host: "deploy@db-01.invalid"), title: "db-01")
        sidebar.open(place: .server(row), clicks: 1, mods: [])
        #expect(placed == row && opened == nil)
        sidebar.open(place: .server(row), clicks: 2, mods: [])
        #expect(opened == .server(row), "the second click of a double one: as before (SSH)")
        var busy = row
        busy.sessions = [ServerSession(id: UUID(), kind: .ssh, target: row.target)]
        placed = nil
        sidebar.open(place: .server(busy), clicks: 1, mods: [])
        #expect(placed == nil && opened == .server(busy), "one with a session open: to it, as before")
    }

    /// Server ▸ Overview is a menu item and a search hit; on the active panel's server.
    @Test func overviewIsInTheServerMenuAndSearch() async throws {
        let (app, a, _, done) = try app()
        defer { done() }
        let menu = try #require(NSApp.mainMenu)
        #expect(menu.items.first { $0.submenu?.title == "Server" }?.submenu?.items.contains { $0.representedObject as? String == "server.overview" } == true)
        let hits = HeaderSearchModel.results("overview", commands: app.commands, folders: [], files: [], recent: [], cancel: CancelFlag())
        #expect(hits.flatMap(\.hits).contains { $0.target == .command("server.overview") && $0.subtitle == "Server" })
        a.showList(Stub(rows: [row("nginx")]))
        app.window.makeFirstResponder(a.table)
        app.run("server.overview")
        #expect(a.isPlace && a.list?.source.target == SFTPTarget(host: "deploy@web-01.invalid"))
    }

    /// ⌘↩: a folder under the cursor in the other panel (here or on the panel's server); on an overview's row, that row
    /// there. ⌘E on a list runs on its server, in its login folder, %f its cursor's row. `?` and `:` are a list's keys
    /// only: in a folder they stay type-select's.
    @Test func commandReturnCommandLineAndAListsOwnKeys() async throws {
        let (app, a, b, done) = try app()
        defer { done() }
        let dir = try tempDir()
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        a.navigate(to: dir)
        await until { a.listedItems.count == 1 }
        app.window.makeFirstResponder(a.table)
        a.moveCursor(toName: "sub")
        press(a, 36, "\r", .command)   // ⌘↩
        await until { b.path == dir + "/sub" }
        #expect(b.path == dir + "/sub" && a.path == dir)
        let typed = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "?", charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44)!
        #expect(!app.runKey(typed), "? in a folder: type-select's")

        let s = Stub(rows: [row("nginx"), row("cron")])
        a.showList(s)
        app.window.makeFirstResponder(a.table)
        #expect(app.shellContext.dir == "." && app.shellContext.expand("systemctl status %f") == "systemctl status nginx")
        #expect(AppDelegate.runsInList("cmdline.focus") && app.runKey(typed), "? in a list: its keys")
        #expect(KeyHelp.current != nil)
        KeyHelp.current?.close()

        app.showPlace(.local(), in: a)
        app.window.makeFirstResponder(a.table)
        a.list?.moveCursor(to: a.list?.shown.firstIndex { $0.title == "/" } ?? -1)
        press(a, 36, "\r", .command)   // the row's ⌘↩: / in the other panel
        await until { b.remote?.dir == "/" }
        #expect(b.remote?.dir == "/" && a.isPlace)

        app.window.makeFirstResponder(a.table)   // ⌘↩ gave the keys to the other panel
        app.goToList()   // `:`: its overview as a picker — Tunnels, here, from this Mac
        let picker = try #require(Picker.current)
        #expect(picker.rows.map(\.title).contains("Services") && picker.rows.map(\.title).contains("Tunnels"))
        picker.rows.first { $0.title == "Tunnels" }?.run()
        await until { a.list?.source is TunnelList }
        #expect(a.headerText == "localhost › Tunnels" && a.emptyShown?.title.hasPrefix("Tunnels belong to saved servers") == true)
        Picker.dismiss()
    }

    /// A list's column order is kept per server and list; its server's overview opens on the list opened there last.
    @Test func sortOrderAndTheLastListAreKeptPerServer() async throws {
        let (app, a, _, done) = try app()
        defer { done() }
        let t = SFTPTarget(host: "deploy@sorted.invalid")   // its own key: other tests' lists run meanwhile
        let s = Stub(on: t, rows: [row("cron"), row("nginx", .attention), row("worker", .failed)])
        a.showList(s)
        #expect(a.list?.shown.map(\.title) == ["worker", "nginx", "cron"])
        a.table.sortDescriptors = [NSSortDescriptor(key: "0", ascending: true)]
        a.showList(Stub(on: t, rows: [row("cron"), row("nginx", .attention), row("worker", .failed)]))   // the same list again: as sorted
        #expect(a.list?.shown.map(\.title) == ["cron", "nginx", "worker"] && a.table.sortDescriptors.first?.key == "0")
        a.showList(Stub("Containers", on: t, rows: [row("b"), row("a", .failed)]))
        #expect(a.list?.shown.map(\.title) == ["a", "b"], "another list: its own order")
        app.showPlace(s.target, in: a)
        #expect(a.list?.cursor?.title == "Containers", "the list opened there last")
    }

    /// Tunnels as a list in a panel, from this Mac: saved and temporary ones, ↩ turns one on or off, ⌘C copies its
    /// address, Edit… on F4 and Delete… on F8 there (red: it's gone for good); ＋ New Tunnel… over the columns.
    @Test func tunnelsInAPanel() async throws {
        let (app, a, _, done) = try app()
        defer { done() }
        var s = SavedServer(address: "deploy@db-01.invalid")!
        s.tunnels = [Tunnel(name: "Main", localPort: 41001, port: 5432), Tunnel(localPort: 41002, port: 3000)]
        app.savedServers = [s]
        a.showList(TunnelList(app, s))
        app.window.makeFirstResponder(a.table)
        let l = try #require(a.list)
        #expect(l.shown.map(\.title) == ["Main", "Grafana"] && l.shown.allSatisfy { $0.state == .off } && cell(a, 2, 0) == "localhost:41001")
        #expect(l.content?.header == "2 tunnels · 0 listening" && l.content?.primary?.title == "New Tunnel…")
        let bar = try #require(app.focusedKeys)
        #expect(bar.map(\.label) == ["Turn On", "Copy Address", "Edit…", "Delete…", "Mark", "Filter", "Actions"] && bar.map(\.key).prefix(4) == ["↩", "⌘C", "F4", "F8"])
        #expect(bar.filter(\.danger).map(\.label) == ["Delete…"])
        a.list?.moveCursor(to: 1)
        guard case .rows(let peek)? = l.source.peek(try #require(l.cursor)) else { Issue.record("its lines"); return }
        #expect(peek.map(\.0) == ["Name", "State", "Here", "Goes to", "URL"] && peek.last?.1 == "http://localhost:41002")
    }

    /// ⌘L in a list: the cursor row's log as it goes next door (an output window's text, its window never shown),
    /// following the cursor; ⌘L again: the row's Quick View. In a Picker the same action opens its window, as before.
    @Test func aRowsLogFollowsNextDoor() async throws {
        let (app, a, b, done) = try app()
        let rest = PanelViewController.peekRest
        defer { done(); PanelViewController.peekRest = rest }
        PanelViewController.peekRest = 50
        func logged(_ name: String) -> Picker.Item {
            row(name, actions: {
                [ListAction(title: "Live Logs", key: Shortcut("cmd+l"), group: 0, closes: true, why: nil,
                            follow: ("echo log-of-\(name); sleep 30", nil)) { _ in Issue.record("a window, not next door"); return nil }]
            })
        }
        let s = Stub(rows: [logged("api"), logged("worker")])
        a.showList(s)
        app.window.makeFirstResponder(a.table)
        press(a, 37, "l", .command)   // ⌘L
        await until { b.logShown?.contains("log-of-api") == true }
        #expect(app.quickViewOn && b.quickTitleShown == "api — log" && b.logShown?.contains("log-of-api") == true)
        a.list?.moveCursor(to: 1)
        await until { b.logShown?.contains("log-of-worker") == true }
        #expect(b.logShown?.contains("log-of-api") == false, "the row before stopped, not appended to")
        press(a, 37, "l", .command)   // ⌘L again: back to the row's Quick View
        #expect(b.logShown == nil && b.quickTitleShown == "worker" && !app.quickLog)
        app.toggleQuickView()
    }

    /// A double-click (or ↩) on a server row with nothing open: its files, the overview's first row — not a shell.
    @Test func aServerRowsDoubleClickOpensItsFiles() async throws {
        let (app, a, _, done) = try app()
        defer { done() }
        app.window.makeFirstResponder(a.table)
        app.serverAction(ServerRow(target: .local(), title: "localhost"), .row, [])
        await until { a.remote != nil }
        #expect(a.remote?.target.host == "localhost" && app.terminal.tabs.isEmpty)
    }
}
