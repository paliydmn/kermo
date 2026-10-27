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
