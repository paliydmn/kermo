import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Tools PR 4a: the Tools window — a server's page with its tools as tabs, a list's Open in Panel, a launcher's buttons
// down the same path as its rows; Use on Servers…, Hide and the vars a tool asks for, in tools/servers.json, seen the
// same in Tools ▸, a place's rows and the window. Against `ToolsBench`'s stand-ins on this Mac.

@MainActor private func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
@MainActor private func press(_ b: NSButton?) { _ = (b?.target as? NSObject)?.perform(b?.action, with: b) }
@MainActor private func fire(_ menu: NSMenu, _ title: String) throws {
    let it = try #require(menu.items.first { $0.title == title }, "\(menu.items.map(\.title))")
    _ = (it.target as? NSObject)?.perform(it.action, with: it)
}
@MainActor private func labels(_ c: NSSegmentedControl) -> [String] { (0..<c.segmentCount).compactMap { c.label(forSegment: $0) } }
@MainActor private func closeToolsWindows() {
    (ToolsWindow.main.map { [$0.window] } ?? []).forEach { $0.close() }
    ToolsWindow.alone.forEach { $0.window.close() }
}
@MainActor private func own(_ bench: ToolsBench, _ files: [String: String]) throws {
    try FileManager.default.createDirectory(atPath: bench.dir + "/own", withIntermediateDirectories: true)
    for (name, text) in files { try Data(text.utf8).write(to: URL(fileURLWithPath: bench.dir + "/own/" + name)) }
}

extension ServerLockTests {
    /// Not connected: what it had, nothing sent, Connect. Connected: a tab per tool it shows, the open one's header
    /// line; a list's tab opens it in a panel of the main window (the same source); ⌘3 is the third tab; a launcher's
    /// tab is its buttons.
    @Test func aServersPageHasItsToolsAsTabs() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { closeToolsWindows(); bench.done(); done(); app.savedServers = [] }
        app.savedServers = [SavedServer(address: "localhost")!]
        var up = false
        AppDelegate.connected = { _ in up }
        ToolsWindow.show(app, server: .local())
        let w = try #require(ToolsWindow.main), page = try #require(w.page)
        #expect(w.rows.first == .header("SERVERS") && w.rows.contains(.library(mine: true)))
        #expect(page.body.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.first == "localhost isn't connected.")
        #expect(buttons(page.body).map(\.title) == ["Connect"] && bench.trips == 0, "nothing logs in to draw a page")

        up = true
        page.refresh()
        await toolsUntil { app.tools.here(.local())?.tools.isEmpty == false }
        page.refresh()
        #expect(labels(page.tabs) == ["Banned IPs", "Server Info", "Firewall", "Sites"] && page.tab == "fail2ban" && page.tabs.isEnabled, "\(labels(page.tabs))")
        #expect(buttons(page.body).map(\.title) == ["Open in Panel", "Open in Search"])
        await toolsUntil { page.line.stringValue.hasPrefix("jails: sshd") }
        #expect(page.line.stringValue.hasPrefix("jails: sshd"), "the header line, as the list has it above its rows: \(page.line.stringValue) \(bench.calls)")
        #expect(!bench.calls.contains { $0.hasPrefix("fail2ban-client status sshd") }, "a list's rows aren't read for the page")

        press(buttons(page.body).first { $0.title == "Open in Panel" })
        #expect((app.active.list?.source as? ToolListSource)?.preset.id == "fail2ban")
        await toolsUntil { app.active.list?.shown.isEmpty == false }
        #expect(app.active.list?.shown.map(\.title) == ["203.0.113.7", "198.51.100.2"], "\(String(describing: app.active.list?.shown.map(\.title))) \(app.active.busyMessage ?? "")")

        let three = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "3", charactersIgnoringModifiers: "3", isARepeat: false, keyCode: 20)!
        #expect(page.performKeyEquivalent(with: three) && page.tab == "ufw")
        page.select("sysinfo")
        #expect(buttons(page.body).map(\.title).prefix(3) == ["Full Report", "CPU · RAM Now", "Live Load"])
    }

    /// After a restart the Tools windows open at quit come back (`Session.tools`), each on its saved server's page and
    /// tab, in its frame — not connected: nothing is sent to draw them. One whose server is no longer saved is left
    /// out, and a session saved before there were any reads as none.
    @Test func toolsWindowsComeBackAfterARestart() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { closeToolsWindows(); bench.done(); done(); app.savedServers = [] }
        let here = SavedServer(address: "localhost")!, gone = SavedServer(address: "web-01")!
        app.savedServers = [here, gone]
        AppDelegate.connected = { $0.host == "localhost" }
        _ = app.tools.answer(.local())   // what it has, known: its tabs
        await toolsUntil { app.tools.answers[ServerRow.key(.local())] != nil }
        AppDelegate.connected = { _ in false }
        ToolsWindow.show(app, server: .local())
        let main = try #require(ToolsWindow.main)
        main.page?.select("ufw")
        main.window.setFrame(NSRect(x: 120, y: 140, width: 960, height: 600), display: false)
        ToolsWindow.showAlone(app, gone, gone.target)
        let saved = ToolsWindow.saved(app)
        #expect(saved.map(\.server) == [here.id.uuidString, gone.id.uuidString] && saved.map(\.tab) == ["ufw", nil] && saved.map(\.alone) == [nil, true], "\(saved)")
        let data = try JSONEncoder().encode(Session(panels: [], tools: saved))
        #expect(try JSONDecoder().decode(Session.self, from: data).tools == saved)
        #expect(try JSONDecoder().decode(Session.self, from: Data(#"{"panels":[],"active":0,"dividers":[]}"#.utf8)).tools == nil, "an older session: none")

        closeToolsWindows()
        app.savedServers = [here]   // web-01 deleted meanwhile
        let trips = bench.trips
        ToolsWindow.restore(app, saved)
        let back = try #require(ToolsWindow.main)
        #expect(back !== main && back.page.map { ServerRow.key($0.target) } == ServerRow.key(here.target) && back.page?.tab == "ufw")
        #expect(back.window.frame == NSRect(x: 120, y: 140, width: 960, height: 600) && ToolsWindow.alone.isEmpty, "\(back.window.frame) \(ToolsWindow.alone.count)")
        #expect(bench.trips == trips && buttons(back.page!.body).map(\.title) == ["Connect"], "not connected: nothing sent")
    }

    /// A launcher's button goes the way its row does: on production the question, then the run, the line under the
    /// buttons saying how it went — the page is the list it's said on, and the question's window is the page's. A
    /// `readonly` one asks nothing. What stops one with a window before it runs — Touch ID refused — is said there too.
    @Test func aLauncherButtonRunsItsActionTheSameWay() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), auth = ServerLock.authenticate
        defer { closeToolsWindows(); bench.done(); done(); app.savedServers = []; ServerLock.authenticate = auth }
        try own(bench, ["kit.json": #"""
            { "schema": 1, "id": "kit", "title": "Kit", "toolActions": [
                { "id": "hello", "title": "Say Hello", "command": "echo hello", "done": "Said hello" },
                { "id": "peek", "title": "Peek", "readonly": true, "command": "echo peek", "done": "Peeked" },
                { "id": "win", "title": "Window", "readonly": true, "command": "echo win", "output": "window" } ] }
            """#])
        _ = app.tools.reload()
        app.tools.trust.trust(try #require(app.tools.library.tools.first { $0.preset.id == "kit" }))
        var prod = SavedServer(address: "localhost")!
        prod.prod = true
        app.savedServers = [prod]
        ServerLock.servers = { [prod] }
        AppDelegate.connected = { _ in true }
        _ = app.tools.answer(.local())
        await toolsUntil { app.tools.answers[ServerRow.key(.local())] != nil }
        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page)
        page.select("kit")
        #expect(buttons(page.body).map(\.title) == ["Say Hello", "Peek", "Window"] && page.title.textColor == Palette.prod)
        let id = ToolListSource(app, try toolNamed(app, "kit"), prod, .local()).rowID("Say Hello")
        #expect(app.rowLists(id).first === page && app.rowLists(id).first?.sheetWindow === ToolsWindow.main?.window)

        var asked: [String] = []
        AppDelegate.answering = { m, _, _ in
            asked.append(m)
            MainActor.assumeIsolated { page.refresh() }   // drawn again while it's asked, as a sheet's end makes the window key
            return 0
        }
        press(buttons(page.body).first { $0.title == "Say Hello" })
        await toolsUntil { page.result.stringValue.contains("Said hello") }
        await toolsUntil { buttons(page.body).first { $0.title == "Say Hello" }?.isEnabled == true }
        #expect(buttons(page.body).first { $0.title == "Say Hello" }?.isEnabled == true, "not left saying one change at a time")
        #expect(asked == ["Say Hello on localhost?"] && page.result.stringValue.contains("Said hello on localhost at "), "\(asked) \(page.result.stringValue)")
        #expect(try String(contentsOfFile: bench.dir + "/audit.jsonl", encoding: .utf8).contains("tool kit hello"))
        press(buttons(page.body).first { $0.title == "Peek" })
        await toolsUntil { page.result.stringValue.contains("Peeked") }
        #expect(asked.count == 1, "readonly: no question")

        var locked = prod
        locked.locked = true
        ServerLock.servers = { [locked] }
        ServerLock.authenticate = { _ in false }
        press(buttons(page.body).first { $0.title == "Window" })
        await toolsUntil { page.result.stringValue.hasPrefix("Window") }
        #expect(page.result.stringValue == "Window: localhost stays locked — nothing ran", "on the page, not the main window: \(page.result.stringValue)")
    }

    /// Use on Servers… "only on the servers checked" takes a tool off every other server — Tools ▸, the place's rows,
    /// the page — and back "wherever it's found"; Hide on one server, ＋ shows it again. tools/servers.json keeps it,
    /// owner-only.
    @Test func useOnServersAndHideShowTheSameEverywhere() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { closeToolsWindows(); ToolRunner.choosing = nil; bench.done(); done(); app.savedServers = [] }
        let here = SavedServer(address: "localhost")!, other = SavedServer(address: "web-01")!
        app.savedServers = [here, other]
        AppDelegate.connected = { $0.host == "localhost" }
        _ = app.tools.answer(.local())
        await toolsUntil { app.tools.answers[ServerRow.key(.local())] != nil }
        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page), place = PlaceSource(app, here, .local()), ufw = try toolNamed(app, "ufw")
        func everywhere() -> [Bool] {
            [app.toolsItem(for: .local())?.submenu?.items.contains { $0.title == "Firewall (ufw)" } == true,
             place.content?.rows.contains { $0.title == "Firewall" } == true, labels(page.tabs).contains("Firewall")]
        }
        #expect(everywhere() == [true, true, true])

        var offered: [String] = []
        ToolRunner.choosing = { _, all in offered = all.map(\.title); return (true, [other.id.uuidString]) }
        await app.tools.useOnServers(ufw, window: nil)
        #expect(offered == ["localhost", "web-01"] && everywhere() == [false, false, false])
        #expect(app.tools.state(ufw, on: other) == "not checked yet" && app.tools.state(ufw, on: here) == "ufw found")
        ToolRunner.choosing = { _, _ in (false, [here.id.uuidString, other.id.uuidString]) }
        await app.tools.useOnServers(ufw, window: nil)
        #expect(everywhere() == [true, true, true])

        page.select("ufw")
        try fire(page.moreMenu(), "Hide Firewall on localhost")
        #expect(everywhere() == [false, false, false] && page.tab == "fail2ban")
        Config.flush()
        let file = bench.dir + "/own/servers.json"
        #expect(try String(contentsOfFile: file, encoding: .utf8).contains(#""hidden" : true"#))
        #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int) == 0o600)
        try fire(page.addMenu(), "Firewall (ufw) — hidden here")
        #expect(everywhere() == [true, true, true] && page.tab == "ufw")
    }

    /// A tool that asks for a value (§9 `ask`) shows on a saved server only, as "Set Up on …" till it's set there:
    /// the vars sheet (a value its pattern refuses keeps nothing), then its page's button runs it with the value. Not
    /// on a server that isn't saved: there's nowhere to keep the value.
    @Test func aToolsValuesAreSetUpPerServer() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { closeToolsWindows(); ToolRunner.settingUp = nil; bench.done(); done(); app.savedServers = [] }
        try own(bench, ["greet.json": #"""
            { "schema": 1, "id": "greet", "title": "Greet", "command": "echo hi {name}", "done": "Greeted {name}",
              "vars": { "name": { "title": "Name", "ask": true, "pattern": "[a-z]+" } } }
            """#])
        _ = app.tools.reload()
        let greet = try #require(app.tools.library.tools.first { $0.preset.id == "greet" })
        app.tools.trust.trust(greet)
        AppDelegate.connected = { _ in true }
        _ = app.tools.answer(.local())
        await toolsUntil { app.tools.answers[ServerRow.key(.local())] != nil }
        #expect(app.tools.here(.local())?.tools.contains { $0.preset.id == "greet" } == false, "not saved: not shown")

        app.savedServers = [SavedServer(address: "localhost")!]
        let item = try #require(app.toolsItem(for: .local())?.submenu?.items.first { $0.title.hasPrefix("Greet") })
        #expect(item.title == "Greet — Set Up on localhost…")
        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page)
        page.select("greet")
        #expect(buttons(page.body).map(\.title) == ["Set Up on localhost…"])

        var offered: [String: String] = [:]
        ToolRunner.settingUp = { _, start in offered = start; return ["name": "Not A Name"] }
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        await toolsUntil { !offered.isEmpty }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(offered == ["name": ""] && app.tools.settings.vars("greet", on: app.savedServers[0].id.uuidString).isEmpty)

        ToolRunner.settingUp = { _, _ in ["name": "kermo"] }
        press(buttons(page.body).first)
        await toolsUntil { buttons(page.body).map(\.title) == ["Greet"] }
        #expect(app.toolsItem(for: .local())?.submenu?.items.contains { $0.title == "Greet" } == true)
        press(buttons(page.body).first)   // a one-command tool's output: a window of its own
        await toolsUntil { NSApp.windows.contains { $0.title == "Greet — localhost" && $0.isVisible } }
        let w = try #require(NSApp.windows.first { $0.title == "Greet — localhost" })
        #expect(((w.docFrame?.scroll.documentView as? NSTextView)?.string ?? "").hasPrefix("hi kermo"))
        w.close()
    }

    /// Open in New Window: a server's page alone, several at once; the same server again comes to the front.
    @Test func serversPagesInWindowsOfTheirOwn() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { closeToolsWindows(); bench.done(); done(); app.savedServers = [] }
        let a = SavedServer(address: "localhost")!, b = SavedServer(address: "web-01")!
        app.savedServers = [a, b]
        ToolsWindow.show(app, server: .local())
        try fire(try #require(ToolsWindow.main?.page).moreMenu(), "Open in New Window")
        ToolsWindow.showAlone(app, b, b.target)
        ToolsWindow.showAlone(app, a, .local())
        #expect(ToolsWindow.alone.map(\.window.title) == ["localhost — Tools", "web-01 — Tools"] && ToolsWindow.alone.allSatisfy(\.window.isVisible))
        #expect(ToolsWindow.pages.count == 3)
        let alone = try #require(ToolsWindow.alone.last?.page)   // not connected: says so, nothing logs in (`aServersPageHasItsToolsAsTabs`)
        #expect(alone.body.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.first == "web-01 isn't connected.")
    }
}
