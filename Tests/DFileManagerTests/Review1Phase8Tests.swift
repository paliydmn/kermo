import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Review 1, phase 8: the palette (⇧⌘P) — a Picker that finds every server and the rows of their places, what's chosen
// most and lately first, one key per row. Made-up servers: nothing goes to a server.

@MainActor private func until(_ done: () -> Bool) async {
    for _ in 0..<250 where !done() { try? await Task.sleep(for: .milliseconds(20)) }
}

@MainActor private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/kermo-p8-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor private func window() -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    return w
}

/// Typed into a picker's field, and a key pressed there, as from the keyboard.
@MainActor private func type(_ p: Picker, _ q: String) {
    p.field.stringValue = q
    p.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: p.field))
}
@MainActor @discardableResult private func press(_ p: Picker, _ sel: Selector) -> Bool { p.control(p.field, textView: NSTextView(), doCommandBy: sel) }

/// Apps made here live to the end of the run: a panel's callbacks hold them unowned (phase 7's `keptApps`).
@MainActor private var keptApps: [AppDelegate] = []

/// A list of made-up rows, its reads counted; a read gives `next` — none: the test fails — or, with `hold`, waits
/// till it's stopped.
@MainActor private final class Listed: ListSource {
    let title: String
    let target: SFTPTarget
    let columns = [ListColumn(title: "Name", field: .title, width: 120), ListColumn(title: "State", field: .subtitle, width: 120, state: true)]
    var content: ListContent?
    var next: ListContent?
    var hold = false
    private(set) var reads = 0, stopped = false

    init(_ title: String, on t: SFTPTarget, rows: [Picker.Item]? = nil, header: String? = nil) {
        (self.title, target) = (title, t)
        content = rows.map { ListContent(rows: $0, header: header) }
    }

    func read(_ cancel: CancelFlag) async throws -> ListContent {
        reads += 1
        while hold, !cancel.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
        if cancel.isCancelled { stopped = true; throw CancellationError() }
        guard let next else { throw JobErrorMessage("read, but nothing may be") }
        content = next
        return next
    }
}

/// A row with a service's actions, each run written down: Status (↩) and Live Logs (⌘L) open windows of their own;
/// Stop… asks everywhere, red; Restart (⌘R) asks on production. A change asks over whoever shows the row, as a
/// service's does, then updates it there and says how it went.
@MainActor private func unit(_ app: AppDelegate, _ title: String, on t: SFTPTarget, state: String = "active · running", mark: StateMark = .on,
                             ran: Later<[String]>, why: [String: String] = [:], over: Later<[NSWindow?]> = Later([])) -> Picker.Item {
    let id = "unit " + title
    var it = Picker.Item(title: title, subtitle: state, verb: "Status") { ran.value.append("Status \(title)") }
    (it.id, it.state) = (id, mark)
    it.listActions = { [unowned app] in
        @MainActor func change(_ name: String, _ key: String?, asks: ListAction.Asks, dangerous: Bool = false) -> ListAction {
            ListAction(title: name, key: key.flatMap(Shortcut.init), group: 1, closes: false, why: why[name], command: "systemctl \(name) -- \(title)",
                       runsOn: t, asks: asks, dangerous: dangerous) { asked in
                Task { @MainActor in
                    let shown = app.rowLists(id).first
                    if !asked, asks == .always || asks == .prod && SavedServer.isProd(t) {
                        over.value.append(shown?.sheetWindow)
                        var c = Confirm("\(name) \(title)?", on: t, action: name)
                        c.returnCancels = true
                        guard await app.confirm(c, on: shown?.sheetWindow) == 0 else { return }
                    }
                    ran.value.append("\(name) \(title)")
                    for l in app.rowLists(id) {
                        l.update(unit(app, title, on: t, state: "\(name.lowercased())ed", ran: ran, why: why, over: over))
                        l.said(NSAttributedString(string: "\(name) \(title): done"), about: id, failed: false, output: nil)
                    }
                }
                return nil
            }
        }
        return [ListAction(title: "Status", key: Shortcut("return"), group: 0, closes: true, why: nil) { _ in ran.value.append("Status \(title)"); return nil },
                ListAction(title: "Live Logs", key: Shortcut("cmd+l"), group: 0, closes: true, why: nil) { _ in ran.value.append("Live Logs \(title)"); return nil },
                change("Stop…", nil, asks: .always, dangerous: true), change("Restart", "cmd+r", asks: .prod)]
    }
    return it
}

/// A key to the picker's panel, as from the keyboard (⌘↩, ⌘R): its row keys, before the field.
@MainActor @discardableResult private func key(_ p: Picker, _ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags) -> Bool {
    p.panel.onKey?(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                                    characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!) == true
}

extension ServerLockTests {
    /// Two wired panels in a window, the registry and the menu bar — as the app; the search's history empty.
    @MainActor private func palette() throws -> (AppDelegate, PanelViewController, PanelViewController, () -> Void) {
        _ = NSApplication.shared
        let dir = try tempDir(), was = AppDelegate.keymapDir
        AppDelegate.keymapDir = dir
        for k in ["searchFrecency", "searchRecent", "placeLastList"] { UserDefaults.standard.removeObject(forKey: k) }
        let recents = UserDefaults.standard.stringArray(forKey: "recentServers")   // the test runner's: not this test's servers
        UserDefaults.standard.removeObject(forKey: "recentServers")
        let app = AppDelegate()
        keptApps.append(app)
        app.terminal = EmbeddedTerminal(covering: NSView())
        app.applyConfig(reportProblems: false)
        let a = PanelViewController(tabs: [dir], index: 0, showHidden: false), b = PanelViewController(tabs: [dir], index: 0, showHidden: false)
        app.panels = [a, b]
        app.wireKeyBar()
        app.window = window()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        app.window.contentView = host
        for (i, p) in [a, b].enumerated() { p.view.frame = NSRect(x: CGFloat(i) * 450, y: 0, width: 450, height: 600); host.addSubview(p.view) }
        [a, b].forEach(app.wire)
        for p in [a, b] { p.onSessionsChange = { [weak app] in app?.refreshSidebar() } }
        (app.savedServers, app.configHosts, app.serverPins) = ([], [], [])
        app.setUpSearch()
        return (app, a, b, {
            Picker.dismiss()
            [a, b].forEach { $0.shutdown() }
            app.window = nil
            AppDelegate.keymapDir = was
            try? FileManager.default.removeItem(atPath: dir)
            for k in ["searchFrecency", "searchRecent", "placeLastList"] { UserDefaults.standard.removeObject(forKey: k) }
            UserDefaults.standard.set(recents, forKey: "recentServers")
            ServerLock.servers = { [] }
        })
    }

    /// P19, the search as a Picker: what's typed is ranked once typing pauses, for what the field says then — not per
    /// keystroke. Opened, it ranks at once (what's chosen lately).
    @Test func paletteRanksAfterTypingPauses() async throws {
        _ = NSApplication.shared
        let w = window()
        let asked = Later<[String]>([])
        let p = Picker.show(over: w, placeholder: "", items: [], results: { q, _ in asked.value.append(q); return [Picker.Item(title: q) {}] })
        defer { Picker.dismiss() }
        await until { !asked.value.isEmpty }
        for q in ["a", "ab", "abc"] { type(p, q) }
        #expect(asked.value == [""], "nothing ranked while typing")
        await until { asked.value.count > 1 }
        try await Task.sleep(for: .milliseconds(200))   // long enough for a second ranking, were one coming
        #expect(asked.value == ["", "abc"], "one ranking, of what the field says now")
        #expect(p.rows.map(\.title) == ["abc"])
    }

    /// P19: ↩ before the pause is over ranks what was typed first — the rows still up are the last query's (the recent
    /// commands, "Move to Trash" among them), and those aren't what runs.
    @Test func paletteEnterInsideThePauseRunsTheTypedHit() async throws {
        _ = NSApplication.shared
        let w = window()
        let asked = Later<[String]>([]), chosen = Later<[String]>([])
        let p = Picker.show(over: w, placeholder: "", items: [], results: { q, _ in
            asked.value.append(q)
            return [Picker.Item(title: q.isEmpty ? "Move to Trash" : q) { chosen.value.append(q.isEmpty ? "file.trash" : q) }]
        })
        defer { Picker.dismiss() }
        await until { !asked.value.isEmpty }   // the recents are up
        for q in ["z", "zi", "zip"] { type(p, q) }
        press(p, #selector(NSResponder.insertNewline(_:)))
        await until { !chosen.value.isEmpty }
        #expect(chosen.value == ["zip"])
        #expect(asked.value == ["", "zip"], "what was typed got ranked, not its prefixes")
    }

    /// R-03: every server — saved and never connected to, ~/.ssh/config's — with its chips; typed, the rows of saved
    /// servers' places too ("serv web" → Services — web-01), made from what's known here: nothing is read. ↩ on a place's
    /// row opens it in the active panel, ⌘↩ in the other.
    @Test func searchFindsEveryServerAndItsPlacesRows() async throws {
        let (app, a, b, done) = try palette()
        defer { done() }
        var web = SavedServer(address: "deploy@web-01.invalid")!
        (web.name, web.prod) = ("web-01", true)
        app.savedServers = [web, SavedServer(address: "deploy@db-01.invalid")!]
        ServerLock.servers = { [web] }
        app.configHosts = ["cfg-only"]
        let masters = SFTP.masterTargets
        let empty = await app.search.results("", CancelFlag())
        let servers = empty.filter { $0.group == "Servers" }
        #expect(Set(servers.map(\.title)).isSuperset(of: ["web-01", "deploy@db-01.invalid", "cfg-only"]), "\(servers.map(\.title))")
        let w01 = try #require(servers.first { $0.title == "web-01" })
        #expect(w01.chips == [.prod] && w01.subtitle == "deploy@web-01.invalid" && w01.actions.map(\.label) == ["Other Panel"])
        #expect(servers.first { $0.title == "cfg-only" }?.subtitle == "~/.ssh/config")
        #expect(!empty.contains { $0.group == "On Servers" }, "a place's rows only for what's typed")

        let typed = await app.search.results("serv web", CancelFlag())
        let place = typed.filter { $0.group == "On Servers" }
        #expect(place.first?.title == "Services — web-01" && place.first?.chips == [.prod], "\(place.map(\.title))")
        #expect(!place.contains { $0.title.hasSuffix("db-01.invalid") })
        #expect(SFTP.masterTargets == masters && a.list == nil, "nothing asked of a server")

        let tunnels = try #require(await app.search.results("tunnels web", CancelFlag()).first { $0.title == "Tunnels — web-01" })
        tunnels.run()   // ↩: Tunnels are this Mac's — a list read here
        await until { a.list?.source is TunnelList }
        #expect(a.list?.source.title == "Tunnels")
        try #require(tunnels.actions.first { $0.key == Shortcut("cmd+return") }).run()
        await until { b.list?.source is TunnelList }
        #expect(b.list?.source is TunnelList)
    }

    /// Recent is what's chosen most and lately (frecency): the old list of the last ten comes in once, in its order;
    /// a choice counts; ✕ — and ⌘⌫ in the palette — takes a row out, the next Recent row then highlighted.
    @Test func recentIsByFrecency() async throws {
        let (app, a, _, done) = try palette()
        defer { done() }
        UserDefaults.standard.set(["file.copy", "folder:/gone-p8", "command:file.move"], forKey: "searchRecent")
        #expect(app.searchFrecency.ranked() == ["command:file.copy", "folder:/gone-p8", "command:file.move"], "in its order")
        #expect(UserDefaults.standard.stringArray(forKey: "searchRecent") == nil)
        #expect(AppDelegate.searchFrecency(UserDefaults.standard).ranked().count == 3, "kept at once, before anything is chosen")
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        app.frecency.visit(dir)   // a folder the search lists
        let name = (dir as NSString).lastPathComponent
        for _ in 0..<2 {
            try #require(await app.search.results(name, CancelFlag()).first { $0.id == "folder:" + dir }).run()
        }
        await until { a.path == dir }
        let recent = await app.search.results("", CancelFlag()).filter { $0.group == "Recent" }
        #expect(recent.map(\.id) == ["folder:" + dir, "command:file.copy", "command:file.move"], "chosen twice first; a gone folder left out")
        #expect(recent.allSatisfy { $0.remove != nil })
        let stored = try #require(UserDefaults.standard.data(forKey: "searchFrecency"))
        #expect(try JSONDecoder().decode(Frecency.self, from: stored).ranked().first == "folder:" + dir, "kept in defaults")

        recent[1].remove?()
        #expect(!app.searchFrecency.ranked().contains("command:file.copy"))
        let p = app.search.focus(over: app.window)
        await until { !p.rows.isEmpty }
        #expect(p.panel.frame.width == 560 && p.groups.first == "Recent" && p.highlighted?.id == "folder:" + dir)
        press(p, #selector(NSResponder.deleteToBeginningOfLine(_:)))   // ⌘⌫
        await until { p.rows.first?.id != "folder:" + dir }
        #expect(p.rows.first?.id == "command:file.move" && p.highlighted?.id == "command:file.move")
        #expect(!app.searchFrecency.ranked().contains("folder:" + dir))
    }

    /// R-43: a command's row has one key — its menu's — as a capsule on the right, not every key as text; its menu
    /// path under it. A folder's says nothing on the right; ↩ runs a command, opens the rest.
    @Test func aCommandRowHasOneKey() async throws {
        let (app, _, _, done) = try palette()
        defer { done() }
        let vols = try #require(await app.search.results("volumes", CancelFlag()).first { $0.id == "command:go.volumes" })
        #expect(vols.cap == "⇧⌘V" && vols.detail.isEmpty && vols.subtitle == "Go" && vols.verb == "Run")
        let disk = try #require(await app.search.results("zzqx", CancelFlag()).last)
        #expect(disk.title == "Search “zzqx” on disk…" && disk.subtitle == "Nothing matches “zzqx”" && disk.cap == "⌘F" && disk.group.isEmpty)
    }

    /// Р8: ⇥ on a server goes into its place — the overview's rows, nothing sent: a locked one asks no Touch ID. ⇥ on its
    /// Services is the first thing that goes there: Touch ID, which says no — it stays locked, said under the rows.
    /// ⌫ on an empty field and ⎋ go up a level, as left; ⎋ on top closes.
    @Test func intoAServerAndBack() async throws {
        let (app, _, _, done) = try palette()
        let was = (AppDelegate.connected, ServerLock.authenticate)
        defer { done(); (AppDelegate.connected, ServerLock.authenticate) = was }
        var web = SavedServer(address: "deploy@web-01.invalid")!
        (web.name, web.prod, web.locked) = ("web-01", true, true)
        app.savedServers = [web]
        ServerLock.servers = { [web] }
        var touched = 0
        ServerLock.authenticate = { _ in touched += 1; return false }
        AppDelegate.connected = { _ in false }
        let p = app.search.focus(over: app.window)
        type(p, "web-01")
        await until { p.highlighted?.title == "web-01" }
        #expect(p.actionBar.map(\.key) == ["↩", "⇥", "⌘↩", "⎋"], "\(p.actionBar.map(\.key))")
        press(p, #selector(NSResponder.insertTab(_:)))
        #expect(p.scopeNames == ["web-01"] && p.rows.map(\.title) == ["Home", "/", "Services", "Containers", "Ports", "Tunnels", "File History"])
        #expect(p.field.currentEditor() != nil && p.panel.firstResponder === p.field.currentEditor(), "the field keeps the keys")
        #expect(touched == 0 && p.actionBar.last == KeySlot(key: "⌫ ⎋", label: "Back", id: "back") && !p.actionBar.contains { $0.label == "Close" }, "⎋ goes up here")
        press(p, #selector(NSResponder.insertTab(_:)))   // Home: no list behind it
        #expect(p.scopeNames == ["web-01"])
        type(p, "services")
        press(p, #selector(NSResponder.insertTab(_:)))
        #expect(p.scopeNames == ["web-01", "Services"])
        await until { p.said == "web-01 stays locked" }
        #expect(p.said == "web-01 stays locked" && touched == 1 && Picker.current === p, "asked over the palette, which stays")
        press(p, #selector(NSResponder.deleteBackward(_:)))   // ⌫: up, on Services, as typed
        #expect(p.scopeNames == ["web-01"] && p.field.stringValue == "services" && p.highlighted?.title == "Services")
        press(p, #selector(NSResponder.cancelOperation(_:)))   // ⎋: up
        #expect(p.scopeNames.isEmpty && p.field.stringValue == "web-01")
        await until { p.highlighted?.title == "web-01" }
        #expect(p.highlighted?.title == "web-01")
        press(p, #selector(NSResponder.cancelOperation(_:)))   // ⎋ on top: closed
        #expect(Picker.current == nil)
    }

    /// ⇥ into a list reads it once — "Looking at services…" till then — problems first, the line about it on top; ⎋
    /// while it reads stops it and goes up. ⌘↩ on a list shows its rows in the other panel as they are: no read.
    @Test func aListIsReadOnceAndEscStopsIt() async throws {
        let (app, _, b, done) = try palette()
        defer { done() }
        let t = SFTPTarget(host: "deploy@web-01.invalid"), ran = Later<[String]>([])
        let slow = Listed("Services", on: t)
        slow.hold = true
        do {
            let p = app.search.focus(over: app.window)
            p.go(into: slow)
            #expect(p.emptySaid == "Looking at services…" && p.scopeNames == ["deploy@web-01.invalid › Services"])
            await until { slow.reads == 1 }
            press(p, #selector(NSResponder.cancelOperation(_:)))
            await until { slow.stopped }
            #expect(slow.stopped && p.scopeNames.isEmpty && Picker.current === p)
        }

        let s = Listed("Services", on: t)
        s.next = ListContent(rows: [unit(app, "cron", on: t, ran: ran), unit(app, "nginx", on: t, state: "activating", mark: .attention, ran: ran),
                                    unit(app, "worker", on: t, state: "failed", mark: .failed, ran: ran)], header: "3 units · 1 failed")
        weak var closed: Picker?
        try await {   // nothing here holds the palette once ⌘↩ closed it: the app doesn't either
            let p = try #require(Picker.current)
            closed = p
            p.go(into: s)
            await until { !p.rows.isEmpty }
            #expect(s.reads == 1 && p.rows.map(\.title) == ["worker", "nginx", "cron"] && p.headerSaid == "3 units · 1 failed")
            #expect(p.actionBar.map(\.label).starts(with: ["Status", "Into", "Live Logs", "Restart"]), "\(p.actionBar.map(\.label))")
            type(p, "ngi")
            #expect(key(p, 36, "\r", .command))   // ⌘↩: the list in the other panel, as typed and highlighted
        }()
        await until { b.list?.source === s }
        #expect(b.list?.source === s && s.reads == 1 && b.list?.shown.map(\.title) == ["nginx"] && b.list?.cursor?.title == "nginx" && Picker.current == nil)
        #expect(closed == nil, "the palette went once closed — what ⌘↩ shows doesn't need it")
    }

    /// ⇥ on a row: its actions — its key on the right, why it can't now under it, Stop… red. ↩ runs one as its list
    /// does: Restart on production asks over the palette, ↩ there being Cancel — nothing runs; ⌘↩ runs it, the row
    /// updated on the level above, how it went under the rows. ⌘R works on the list's level too, no ⇥.
    @Test func aRowsActionsRunAsInItsList() async throws {
        let (app, _, _, done) = try palette()
        defer { done(); AppDelegate.answering = nil }
        var web = SavedServer(address: "deploy@web-01.invalid")!
        web.prod = true
        ServerLock.servers = { [web] }
        let t = web.target, ran = Later<[String]>([]), over = Later<[NSWindow?]>([])
        let s = Listed("Services", on: t, rows: [unit(app, "nginx", on: t, ran: ran, over: over),
                                                 unit(app, "cron", on: t, ran: ran, why: ["Restart": "cron is restarting… wait for it"], over: over)])
        let p = app.search.focus(over: app.window)
        p.go(into: s)
        #expect(p.highlighted?.title == "nginx")
        press(p, #selector(NSResponder.insertTab(_:)))
        #expect(p.scopeNames == ["deploy@web-01.invalid › Services", "nginx"] && p.rows.map(\.title) == ["Status", "Live Logs", "Stop…", "Restart"])
        #expect(p.rows.map(\.cap) == ["↩", "⌘L", "", "⌘R"] && p.rows[2].titleColor == Palette.fail && p.rows[3].subtitle == "systemctl Restart -- nginx")
        var asked: [String] = []
        AppDelegate.answering = { m, _, d in asked.append(m); return d ?? 0 }   // ↩
        type(p, "restart")
        press(p, #selector(NSResponder.insertNewline(_:)))
        await until { !asked.isEmpty }
        #expect(asked == ["Restart nginx?"] && ran.value.isEmpty && over.value == [p.window] && Picker.current === p)
        AppDelegate.answering = { _, _, _ in 0 }   // ⌘↩
        press(p, #selector(NSResponder.insertNewline(_:)))
        await until { !ran.value.isEmpty }
        #expect(ran.value == ["Restart nginx"])
        await until { p.said == "Restart nginx: done" }
        press(p, #selector(NSResponder.cancelOperation(_:)))
        #expect(p.rows.first { $0.title == "nginx" }?.subtitle == "restarted", "updated on the level above")

        type(p, "cron")
        press(p, #selector(NSResponder.insertTab(_:)))
        #expect(p.rows.first { $0.title == "Restart" }?.subtitle == "cron is restarting… wait for it" && p.rows.first { $0.title == "Restart" }?.titleColor == .tertiaryLabelColor)
        type(p, "restart")
        press(p, #selector(NSResponder.insertNewline(_:)))
        #expect(p.said == "cron is restarting… wait for it" && ran.value == ["Restart nginx"], "said why, nothing ran")
        press(p, #selector(NSResponder.deleteBackward(_:)))   // the field isn't empty: a letter goes
        press(p, #selector(NSResponder.cancelOperation(_:)))
        type(p, "nginx")
        #expect(key(p, 15, "r", .command))   // ⌘R on the list's level
        await until { ran.value.count == 2 }
        #expect(ran.value == ["Restart nginx", "Restart nginx"])
        type(p, "")
        press(p, #selector(NSResponder.insertNewline(_:)))   // ↩ on a row: its own ↩, Status
        await until { ran.value.count == 3 }
        #expect(ran.value.last == "Status nginx" && Picker.current == nil)
    }

    /// Tools PR 2 adds a place provider and a source, the palette as it is: search finds "Deployments (dpl) — web-01";
    /// ⇥ reads the preset — its line, failed first — ⇥ on a row, its actions: Deploy… red, asking on production.
    /// An empty preset says its own words.
    @Test func aToolsPresetWalksThroughUnchanged() async throws {
        let (app, _, _, done) = try palette()
        defer { done(); AppDelegate.answering = nil; AppDelegate.placeProviders.removeLast() }
        var web = SavedServer(address: "deploy@web-01.invalid")!
        (web.name, web.prod) = ("web-01", true)
        app.savedServers = [web]
        ServerLock.servers = { [web] }
        let ran = Later<[String]>([])
        func app_(_ title: String, _ state: String, _ mark: StateMark, busy: Bool = false) -> Picker.Item {
            var it = Picker.Item(title: title, subtitle: state) { ran.value.append("Logs \(title)") }
            (it.id, it.state, it.busy) = ("dpl " + title, mark, busy)
            it.listActions = { [unowned app] in
                [ListAction(title: "Logs", key: Shortcut("return"), group: 0, closes: true, why: nil) { _ in ran.value.append("Logs \(title)"); return nil },
                 ListAction(title: "Deploy…", key: nil, group: 1, closes: false, why: nil, command: "dpl deploy \(title)", runsOn: web.target, asks: .prod, dangerous: true) { asked in
                     Task { @MainActor in
                         var c = Confirm("Deploy \(title)?", on: web.target, action: "Deploy")
                         c.returnCancels = true
                         if !asked, await app.confirm(c, on: app.rowLists("dpl " + title).first?.sheetWindow) != 0 { return }
                         ran.value.append("Deploy \(title)")
                     }
                     return nil
                 }]
            }
            return it
        }
        let preset = Listed("Deployments (dpl)", on: web.target)
        preset.next = ListContent(rows: [app_("web", "ok", .on), app_("api", "failed", .failed), app_("worker", "deploying", .attention, busy: true)],
                                  header: "3 apps · 1 failed", empty: "No apps yet")
        AppDelegate.placeProviders.append { app, p in
            [app.placeRow("Deployments (dpl)", p, state: "", about: "dpl", into: { preset })]
        }
        let p = app.search.focus(over: app.window)
        type(p, "deployments")
        await until { p.highlighted?.title == "Deployments (dpl) — web-01" }
        #expect(p.highlighted?.group == "On Servers")
        press(p, #selector(NSResponder.insertTab(_:)))
        await until { !p.rows.isEmpty }
        #expect(p.scopeNames == ["web-01 › Deployments (dpl)"] && p.rows.map(\.title) == ["api", "worker", "web"] && p.headerSaid == "3 apps · 1 failed")
        press(p, #selector(NSResponder.insertTab(_:)))   // api
        #expect(p.rows.map(\.title) == ["Logs", "Deploy…"] && p.rows[1].titleColor == Palette.fail)
        var asked: [String] = []
        AppDelegate.answering = { m, _, d in asked.append(m); return d ?? 0 }
        type(p, "deploy")
        press(p, #selector(NSResponder.insertNewline(_:)))
        await until { !asked.isEmpty }
        #expect(asked == ["Deploy api?"] && ran.value.isEmpty, "↩ = Cancel: nothing deployed")

        let none = Listed("Deployments (dpl)", on: web.target)
        none.next = ListContent(rows: [], empty: "No apps yet")
        p.go(into: none)
        await until { p.emptySaid == "No apps yet" }
        #expect(p.emptySaid == "No apps yet")
    }

    /// `:` in a list: the palette, on its server's place — ⌫ goes up to the search.
    @Test func colonInAListOpensThePaletteOnItsServer() async throws {
        let (app, a, _, done) = try palette()
        defer { done() }
        let t = SFTPTarget(host: "deploy@db-01.invalid")
        a.showList(Listed("Services", on: t, rows: []))
        app.window.makeFirstResponder(a.table)
        app.goToList()
        let p = try #require(Picker.current)
        #expect(p.panel.frame.width == 560 && p.scopeNames == ["deploy@db-01.invalid"] && p.rows.map(\.title).contains("Containers"))
        press(p, #selector(NSResponder.deleteBackward(_:)))
        #expect(p.scopeNames.isEmpty && Picker.current === p)
    }

    /// D-120: a Picker takes its window's appearance — a dark Kermo theme's — and so do the questions over it.
    @Test func aPickerFollowsTheThemesAppearance() throws {
        _ = NSApplication.shared
        let w = window()
        w.appearance = try #require(Theme.all.first { $0.name == "Midnight Commander" }).appearance
        let p = Picker.show(over: w, placeholder: "", items: [])
        defer { Picker.dismiss() }
        #expect(p.panel.appearance?.name == .darkAqua && p.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }
}
