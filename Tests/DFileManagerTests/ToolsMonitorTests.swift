import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Tools PR 5a: watching. A stream runs while its tab shows and stops when it doesn't; Watch keeps it without a
// window and in tools/servers.json; a drop is a gap and a reconnect; a server that isn't connected never logs in for
// a tab, and one whose login would ask says "needs login"; a locked server is watched without Touch ID and stays
// in use; WATCHED lists problems first; two tools on one server share one channel. Against `ToolsBench` and a
// stream of its own (`pulse`) on this Mac.

/// A stream on this Mac: a JSON line every 0.3 s — cpu 10, or 99 while the flag `hot-<server>` is there — its pid in
/// `pulse-<server>.pid`. `pulse2`: the same under another name.
@MainActor private func pulse(_ bench: ToolsBench, _ ids: [String] = ["pulse"]) throws {
    for id in ids {
        try Data("""
            #!/bin/sh
            echo "\(id) $*" >> \(bench.dir)/calls.log
            echo $$ > \(bench.dir)/\(id)-$2.pid
            i=0
            while :; do
              cpu=10; [ -f \(bench.dir)/hot-$2 ] && cpu=99
              printf '{"cpu":{"pct":%s},"n":%s}\\n' "$cpu" "$i"
              i=$((i+1))
              sleep 0.3
            done

            """.utf8).write(to: URL(fileURLWithPath: bench.dir + "/bin/" + id))
        chmod(bench.dir + "/bin/" + id, 0o755)
        try FileManager.default.createDirectory(atPath: bench.dir + "/own", withIntermediateDirectories: true)
        try Data("""
            { "schema": 1, "id": "\(id)", "title": "\(id.capitalized)",
              "stream": { "command": "\(id) {every} {server}", "format": "jsonl" },
              "watch": { "every": 1, "down": 2 },
              "metrics": { "cpu": { "title": "CPU", "path": "cpu.pct", "unit": "%", "max": 100 }, "n": { "title": "Ticks", "path": "n" } },
              "summary": [ { "metric": "cpu", "as": "bar" } ],
              "alerts": [ { "id": "cpu", "metric": "cpu", "warn": 85, "crit": 95, "checks": 2 } ],
              "events": [ { "id": "hot", "path": "cpu.pct", "when": "is", "value": 99, "level": "warning", "message": "hot: {cpu.pct}" } ],
              "dashboard": [ { "row": [ { "stat": "cpu" }, { "stat": "n" } ] } ] }
            """.utf8).write(to: URL(fileURLWithPath: bench.dir + "/own/\(id).json"))
    }
}

@MainActor private func pid(_ bench: ToolsBench, _ server: String = "localhost", _ id: String = "pulse") -> pid_t? {
    (try? String(contentsOfFile: bench.dir + "/\(id)-\(server).pid", encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}
@MainActor private func alive(_ p: pid_t?) -> Bool { p.map { kill($0, 0) == 0 } ?? false }

/// The watching seams quick, and back after.
@MainActor private struct Quick {
    let was = (tick: ToolMonitor.tick, backoff: ToolMonitor.backoff, login: ToolMonitor.login, watching: ToolRunner.watching, auth: ServerLock.authenticate,
               target: ToolMonitor.target)
    init() {
        ToolMonitor.tick = 0.2
        ToolMonitor.backoff = [0.3]
        ToolMonitor.login = { _, _ in }
        ToolMonitor.target = { _ in .local() }
        ToolRunner.watching = { _, _ in true }
    }
    func done() {
        (ToolMonitor.tick, ToolMonitor.backoff, ToolMonitor.login, ToolRunner.watching, ServerLock.authenticate, ToolMonitor.target) = was
        (ToolsWindow.main.map { [$0.window] } ?? []).forEach { $0.close() }
        ToolsWindow.alone.forEach { $0.window.close() }
    }
}

@MainActor private func closeWindows() {
    (ToolsWindow.main.map { [$0.window] } ?? []).forEach { $0.close() }
    ToolsWindow.alone.forEach { $0.window.close() }
}

/// The app with `pulse` loaded and trusted, localhost saved; its tools known once connected.
@MainActor private func watching(_ app: AppDelegate, _ bench: ToolsBench, ids: [String] = ["pulse"], servers: [SavedServer]? = nil) async throws {
    try pulse(bench, ids)
    app.tools.monitor.ready = true
    _ = app.tools.reload()
    for id in ids { app.tools.trust.trust(try #require(app.tools.library.tools.first { $0.preset.id == id })) }
    app.savedServers = servers ?? [SavedServer(address: "localhost")!]
    AppDelegate.connected = { _ in true }
    _ = app.tools.here(.local())
    await toolsUntil { app.tools.here(.local())?.tools.contains { $0.preset.id == ids[0] } == true }
}

@MainActor private func live(_ page: ToolsPage) -> ToolsLive? { page.body.arrangedSubviews.first as? ToolsLive }
@MainActor private func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
@MainActor private func press(_ b: NSButton?) { _ = (b?.target as? NSObject)?.perform(b?.action, with: b) }

extension ServerLockTests {
    /// A tab on a server that isn't connected logs nothing in. Connected, its stream runs while the tab shows — one
    /// round trip, the tiles with its numbers, the strip saying it's live while open — and ends on the server when
    /// another tab is chosen.
    @Test func aStreamRunsWhileItsTabShowsAndStopsWhenItDoesnt() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick()
        defer { quick.done(); bench.done(); done(); app.savedServers = [] }
        try await watching(app, bench)
        let trips = bench.trips
        AppDelegate.connected = { _ in false }
        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page)
        page.select("pulse")
        try await Task.sleep(for: .milliseconds(500))
        #expect(bench.trips == trips && app.tools.monitor.server(.local()) == nil, "no login for a tab")
        #expect(buttons(page.body).map(\.title) == ["Connect"])

        AppDelegate.connected = { _ in true }
        page.refresh()
        await toolsUntil { app.tools.monitor.tool("pulse", on: .local())?.history.last != nil }
        let t = try #require(app.tools.monitor.tool("pulse", on: .local()))
        #expect(t.live && !t.watched && bench.trips == trips + 1, "\(bench.calls)")
        #expect(bench.calls.contains("pulse 1 localhost"), "{every} and {server} are the stream's: \(bench.calls)")
        let view = try #require(live(page))
        #expect(view.strip.stringValue.hasPrefix("Live while open") && view.watchButton.title == "Watch in Background…")
        await toolsUntil { view.tiles.first?.value.stringValue == "10%" }
        #expect(view.tiles.map(\.value.stringValue).first == "10%" && view.tiles[0].bar?.doubleValue == 10 && view.foot.stringValue.hasPrefix("Live · last sample"))
        #expect(app.tools.monitor.worst(app.tools.monitor.server(.local())!) == (.ok, ""))
        let p = pid(bench)
        #expect(alive(p))

        page.select("fail2ban")
        await toolsUntil { app.tools.monitor.server(.local())?.channel == nil && !alive(p) }
        #expect(app.tools.monitor.server(.local())?.channel == nil && !alive(p), "the stream ended on the server")
        #expect(t.history.points("cpu").last?.gap == .notWatched && !t.live)
    }

    /// Watch in Background… (the page's ⋯) keeps the stream with the window closed, writes `watch` into
    /// tools/servers.json, lists the server under WATCHED with its summary bar, and keeps its connection in use.
    /// Stop Watching ends it and takes the key out.
    @Test func watchKeepsTheStreamWithoutAWindow() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick()
        defer { quick.done(); bench.done(); done(); app.savedServers = [] }
        try await watching(app, bench)
        ToolsWindow.show(app, server: .local())
        let w = try #require(ToolsWindow.main), page = try #require(w.page)
        page.select("pulse")
        let tool = try toolNamed(app, "pulse")
        let menu = page.moreMenu(), item = try #require(menu.items.first { $0.title.hasPrefix("Watch") })
        #expect(item.title == "Watch Pulse in Background…" && item.isEnabled)
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        await toolsUntil { app.tools.monitor.tool("pulse", on: .local())?.watched == true }
        let file = bench.dir + "/own/servers.json"
        await toolsUntil { ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").contains("watch") }   // written off the main thread
        let saved = try String(contentsOfFile: file, encoding: .utf8)
        #expect(saved.contains(#""watch" : true"#), "\(saved)")
        #expect(app.tools.settings.watches("pulse", on: app.savedServers[0].id.uuidString))
        #expect(page.moreMenu().items.contains { $0.title == "Stop Watching Pulse on localhost" })
        await toolsUntil { app.tools.monitor.tool("pulse", on: .local())?.history.last != nil }
        w.reload()
        #expect(w.rows.first == .header("WATCHED") && w.rows[2] == .header("OTHER SERVERS"), "\(w.rows)")
        if case .watched(let s, _) = w.rows[1] { #expect(s.title == "localhost") } else { Issue.record("no WATCHED row: \(w.rows)") }
        #expect(w.sidebar.selectedRow == 1, "the page's server, now under WATCHED")
        #expect(app.idleServers([SavedServer(address: "localhost")!.target]).isEmpty, "a watched server's connection isn't idle")
        #expect(live(page)?.strip.stringValue.hasPrefix("Watched in the background · every 1 s") == true)

        closeWindows()
        try await Task.sleep(for: .milliseconds(400))
        let s = try #require(app.tools.monitor.server(.local()))
        #expect(s.channel != nil && alive(pid(bench)), "watched: the window's closing changes nothing")
        #expect(s.events.last?.message == "Watching started · every 1 s")

        app.tools.monitor.watch(tool, on: .local(), false)
        await toolsUntil { s.channel == nil && !alive(pid(bench)) }
        #expect(s.channel == nil && !alive(pid(bench)) && !app.tools.settings.watches("pulse", on: app.savedServers[0].id.uuidString))
        await toolsUntil { !((try? String(contentsOfFile: file, encoding: .utf8)) ?? "watch").contains("watch") }
        #expect(!(try String(contentsOfFile: file, encoding: .utf8)).contains("watch"))
        #expect(app.tools.monitor.watched.isEmpty && !app.idleServers([SavedServer(address: "localhost")!.target]).isEmpty)
    }

    /// The stream's end on the server (its process killed) is a gap, then a reconnect after the backoff — one more
    /// round trip, the series going on after the gap. No answer for `down` intervals is "not answering", critical in
    /// WATCHED, and "answers again" once a sample comes.
    @Test func aDropIsAGapAndAReconnect() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick()
        defer { quick.done(); bench.done(); done(); app.savedServers = [] }
        try await watching(app, bench)
        let tool = try toolNamed(app, "pulse")
        app.tools.monitor.watch(tool, on: .local(), true)
        await toolsUntil { app.tools.monitor.tool("pulse", on: .local())?.history.last != nil }
        let s = try #require(app.tools.monitor.server(.local())), t = try #require(s.tools["pulse"])
        let trips = bench.trips, first = pid(bench)
        kill(try #require(first), SIGKILL)
        await toolsUntil { s.channel == nil || bench.trips > trips }
        await toolsUntil { bench.trips > trips && t.history.points("cpu").last?.value != nil && pid(bench) != first }
        #expect(bench.trips == trips + 1, "reconnected once: \(bench.trips - trips)")
        let points = t.history.points("cpu")
        #expect(points.contains { $0.gap == .reconnecting } && points.last?.value == 10, "a gap, then values again: \(points.suffix(4))")
        #expect(s.retries == 0 && s.error == nil)

        // The server stops answering (its stream stopped, the channel open): missed intervals, then "not answering".
        kill(try #require(pid(bench)), SIGSTOP)
        await toolsUntil { s.down != nil }
        #expect(s.down != nil && app.tools.monitor.worst(s) == (.critical, "not answering") && s.events.first?.level == "critical", "\(s.events)")
        #expect(t.history.points("cpu").last?.gap == .noAnswer && t.alerts.worst == nil)
        kill(try #require(pid(bench)), SIGCONT)
        await toolsUntil { s.down == nil }
        #expect(s.down == nil && s.events.first?.message.hasPrefix("Answers again") == true && app.tools.monitor.worst(s).state == .ok)
    }

    /// A watched server whose login would ask isn't logged in behind your back: "needs login", nothing sent, until a
    /// click — the lock, then the login as any look's — brings its stream up.
    @Test func aLoginThatWouldAskWaitsForAClick() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick()
        defer { quick.done(); bench.done(); done(); app.savedServers = []; ToolRunner.hasMaster = { _ in true } }
        try await watching(app, bench)
        ToolRunner.hasMaster = { _ in false }
        nonisolated(unsafe) var logins: [Bool] = []
        ToolMonitor.login = { _, quiet in
            logins.append(quiet)
            if quiet { throw SFTPError(message: "user@localhost: Permission denied (publickey,password).") }
            ToolRunner.hasMaster = { _ in true }
        }
        let trips = bench.trips
        app.tools.monitor.watch(try toolNamed(app, "pulse"), on: .local(), true)
        await toolsUntil { app.tools.monitor.server(.local())?.needsLogin == true }
        let s = try #require(app.tools.monitor.server(.local()))
        #expect(s.needsLogin && logins == [true] && bench.trips == trips && s.channel == nil)
        #expect(app.tools.monitor.worst(s) == (.off, "needs login"))
        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page)
        page.select("pulse")
        let view = try #require(live(page))
        #expect(view.banner.stringValue.hasPrefix("localhost needs login") && !view.connectButton.isHidden)

        var touched = 0
        ServerLock.authenticate = { _ in touched += 1; return true }
        press(view.connectButton)
        await toolsUntil { s.tools["pulse"]?.history.last != nil }
        #expect(logins == [true, false] && touched == 0 && !s.needsLogin && s.channel != nil, "the login as any look's; not locked: no Touch ID")
        #expect(view.banner.isHidden)
    }

    /// A locked server is watched read-only, without Touch ID; its connection stays in use; the tab says so.
    @Test func aLockedServerIsWatchedWithoutTouchID() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick()
        defer { quick.done(); bench.done(); done(); app.savedServers = [] }
        var locked = SavedServer(address: "localhost")!
        locked.locked = true
        try await watching(app, bench, servers: [locked])
        ServerLock.servers = { [locked] }
        var touched = 0
        ServerLock.authenticate = { _ in touched += 1; return false }
        app.tools.monitor.watch(try toolNamed(app, "pulse"), on: .local(), true)
        await toolsUntil { app.tools.monitor.tool("pulse", on: .local())?.history.last != nil }
        let s = try #require(app.tools.monitor.server(.local()))
        #expect(touched == 0 && s.channel != nil && s.target.persist == nil, "metrics without the lock; the connection lingers as any other's")
        #expect(app.idleServers([locked.target]).isEmpty, "stays connected while watched")
        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page)
        page.select("pulse")
        #expect(live(page)?.banner.stringValue == "localhost is locked: watching reads metrics only; any action asks Touch ID.")
    }

    /// WATCHED puts a problem first: a stream past a threshold two checks in a row is a critical alert — the
    /// server's row says its words, the tab shows the mark — and back to normal is an event; the words say so.
    @Test func aProblemShowsInWatchedAndOnTheTab() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick()
        defer { quick.done(); bench.done(); done(); app.savedServers = [] }
        try await watching(app, bench)
        let tool = try toolNamed(app, "pulse")
        app.tools.monitor.watch(tool, on: .local(), true)
        await toolsUntil { app.tools.monitor.tool("pulse", on: .local())?.history.last != nil }
        let s = try #require(app.tools.monitor.server(.local()))
        bench.flag("hot-localhost")
        await toolsUntil { s.tools["pulse"]?.alerts.worst == .critical }
        #expect(app.tools.monitor.worst(s) == (.critical, "CPU 99%") && s.tools["pulse"]?.events.first?.message == "CPU 99%", "\(s.tools["pulse"]?.events ?? [])")
        #expect(s.tools["pulse"]?.events.contains { $0.message == "hot: 99" && $0.level == "warning" } == true, "the `is` event, once")
        #expect(app.tools.monitor.watched.map(\.saved.title) == ["localhost"] && app.tools.monitor.summary(s.tools["pulse"]!).first?.level == .critical)
        ToolsWindow.show(app, server: .local())
        let w = try #require(ToolsWindow.main), page = try #require(w.page)
        page.select("pulse")
        #expect(w.rows[1] == .watched(app.savedServers[0], SFTPTarget.local().persisting(nil)) && w.sidebar.selectedRow == 1)
        #expect(page.tabs.image(forSegment: page.tabs.selectedSegment)?.isTemplate == false, "the mark, not the icon")
        #expect(live(page)?.tiles.first?.value.textColor == Palette.fail)
        bench.flag("hot-localhost", false)
        await toolsUntil { s.tools["pulse"]?.alerts.worst == nil }
        #expect(s.tools["pulse"]?.events.first?.message.hasPrefix("Back to normal: CPU") == true && app.tools.monitor.worst(s).state == .ok, "\(s.tools["pulse"]?.events ?? [])")
        #expect(page.tabs.image(forSegment: page.tabs.selectedSegment)?.isTemplate == true)
    }

    /// Two watched tools on one server run in one channel: one round trip, both their series fed.
    @Test func twoToolsOnOneServerShareOneChannel() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick()
        defer { quick.done(); bench.done(); done(); app.savedServers = [] }
        try await watching(app, bench, ids: ["pulse", "pulse2"])
        let trips = bench.trips
        app.tools.monitor.watch(try toolNamed(app, "pulse"), on: .local(), true)
        app.tools.monitor.watch(try toolNamed(app, "pulse2"), on: .local(), true)
        await toolsUntil { app.tools.monitor.tool("pulse", on: .local())?.history.last != nil && app.tools.monitor.tool("pulse2", on: .local())?.history.last != nil }
        let s = try #require(app.tools.monitor.server(.local()))
        #expect(s.tools.count == 2 && s.tools.values.allSatisfy { $0.history.last != nil })
        #expect(bench.trips - trips <= 2 && bench.calls.contains("pulse 1 localhost") && bench.calls.contains("pulse2 1 localhost"), "\(bench.trips - trips) \(bench.calls)")
        #expect(alive(pid(bench)) && alive(pid(bench, "localhost", "pulse2")))
        let runs = try toolNamed(app, "pulse").runs
        #expect(runs.groups.last?.title == "In the background, when you watch it" && runs.background.first?.text == "  stream: pulse {every} {server}   — every 1 s on each watched server")
    }
}
