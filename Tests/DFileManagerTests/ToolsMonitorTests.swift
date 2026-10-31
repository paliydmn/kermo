import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Tools PR 5a: watching. A stream runs while its tab shows and stops when it doesn't; Watch keeps it without a
// window and in tools/servers.json; a drop is a gap and a reconnect; a server that isn't connected never logs in for
// a tab, and one whose login would ask says "needs login"; a locked server is watched without Touch ID and stays
// in use; WATCHED lists problems first; two tools on one server share one channel. Against `ToolsBench` and a
// stream of its own (`pulse`) on this Mac.

/// A stream on this Mac: a JSON line every 0.3 s — cpu 10, or 99 while the flag `hot-<server>` is there; every 1.3 s
/// with `slow-<server>`; with `event-<server>`, an `_event` in each line; two `procs` rows in every other line (as
/// System spaces its heavier reads) — its pid in `pulse-<server>.pid`. `pulse2`: the same under another name. Its
/// dashboard has every block; its actions: Folder (`open` what `pulse-dir` prints), Stop… (dangerous), Deeper (a
/// level: not run yet), Log (`{from}` / `{to}` into `pulse-log`), Terminal and Services (`goto`).
@MainActor private func pulse(_ bench: ToolsBench, _ ids: [String] = ["pulse"]) throws {
    for id in ids {
        try Data("""
            #!/bin/sh
            echo "\(id) $*" >> \(bench.dir)/calls.log
            echo $$ > \(bench.dir)/\(id)-$2.pid
            i=0
            while :; do
              cpu=10; [ -f \(bench.dir)/hot-$2 ] && cpu=99
              ev=''; [ -f \(bench.dir)/event-$2 ] && ev=',"_event":{"id":"tick","level":"info","message":"tick"}'
              procs=''; [ $((i % 2)) -eq 0 ] && procs=',"procs":[{"pid":1,"command":"first","cpu":1.5},{"pid":2,"command":"second","cpu":20}]'
              printf '{"cpu":{"pct":%s},"n":%s%s%s}\\n' "$cpu" "$i" "$ev" "$procs"
              i=$((i+1))
              if [ -f \(bench.dir)/slow-$2 ]; then sleep 1.3; else sleep 0.3; fi
            done

            """.utf8).write(to: URL(fileURLWithPath: bench.dir + "/bin/" + id))
        chmod(bench.dir + "/bin/" + id, 0o755)
        for (name, body) in [("pulse-dir", "echo /tmp/pulse-$1"), ("pulse-log", ":")] {
            try Data("#!/bin/sh\necho \"\(name) $*\" >> \(bench.dir)/calls.log\n\(body)\n".utf8).write(to: URL(fileURLWithPath: bench.dir + "/bin/" + name))
            chmod(bench.dir + "/bin/" + name, 0o755)
        }
        try FileManager.default.createDirectory(atPath: bench.dir + "/own", withIntermediateDirectories: true)
        try Data("""
            { "schema": 1, "id": "\(id)", "title": "\(id.capitalized)",
              "stream": { "command": "\(id) {every} {server}", "format": "jsonl" },
              "watch": { "every": 1, "down": 2 },
              "metrics": { "cpu": { "title": "CPU", "path": "cpu.pct", "unit": "%", "max": 100 }, "n": { "title": "Ticks", "path": "n" } },
              "summary": [ { "metric": "cpu", "as": "bar" } ],
              "alerts": [ { "id": "cpu", "metric": "cpu", "warn": 85, "crit": 95, "checks": 2 } ],
              "events": [ { "id": "hot", "path": "cpu.pct", "when": "is", "value": 99, "level": "warning", "message": "hot: {cpu.pct}", "goto": "services:hot.service" } ],
              "dashboard": [ { "row": [ { "stat": "cpu" }, { "stat": "n" } ] },
                             { "charts": [ ["cpu"], ["n"] ], "range": ["1h", "24h", "7d"], "log": "log" },
                             { "row": [ { "table": "procs", "title": "Processes", "key": "{pid}", "columns": ["command", "cpu:%", "pid"], "actions": ["folder", "stop", "deeper"] },
                                        { "counts": [ { "rows": "procs", "title": "processes", "goto": "services" } ] } ] },
                             { "events": true } ],
              "actions": [
                { "id": "folder", "title": "Folder", "rows": "procs", "readonly": true, "command": "pulse-dir {pid}", "open": "{stdout}" },
                { "id": "stop", "title": "Stop…", "rows": "procs", "dangerous": true, "command": "pulse-log stop {pid}" },
                { "id": "deeper", "title": "Deeper", "rows": "procs", "readonly": true, "command": "echo {pid}", "output": "list", "list": { "format": "lines", "key": "{line}" } },
                { "id": "log", "title": "Log", "readonly": true, "command": "pulse-log {from} {to}" } ],
              "toolActions": [ { "id": "ssh", "title": "Terminal", "goto": "ssh" }, { "id": "svc", "title": "Services", "goto": "services:{server}.service" } ] }
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
               target: ToolMonitor.target, grace: ToolMonitor.wakeGrace)
    init() {
        ToolMonitor.tick = 0.2
        ToolMonitor.backoff = [0.3]
        ToolMonitor.login = { _, _ in }
        ToolMonitor.target = { _ in .local() }
        ToolMonitor.wakeGrace = 0   // a Wi-Fi flap during the run mustn't hold "not answering" back
        ToolRunner.watching = { _, _ in true }
    }
    func done() {
        (ToolMonitor.tick, ToolMonitor.backoff, ToolMonitor.login, ToolRunner.watching, ServerLock.authenticate, ToolMonitor.target, ToolMonitor.wakeGrace) = was
        closeWindows()
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
@MainActor private func labels(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(labels) }
/// A dashboard table's row buttons (its last column), the row's view made if the table hasn't drawn yet.
@MainActor private func rowButtons(_ t: ToolsTable, _ row: Int) -> [NSButton] {
    t.table.view(atColumn: t.table.numberOfColumns - 1, row: row, makeIfNecessary: true).map(buttons) ?? []
}
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
        #expect(s.tools["pulse"]?.events.filter { $0.message == "hot: 99" && $0.level == "warning" }.count == 1, "the `is` event, once")
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

    /// A stream that runs a little slower than `every` (System sleeps after its reads) is no gap: nothing missed, no
    /// mark, the alerts' clocks untouched. Once it really stops, the intervals are missed from half of one on.
    @Test func aSlightlyLateStreamIsNoGap() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick()
        defer { quick.done(); bench.done(); done(); app.savedServers = [] }
        try await watching(app, bench)
        bench.flag("slow-localhost")
        app.tools.monitor.watch(try toolNamed(app, "pulse"), on: .local(), true)
        await toolsUntil { app.tools.monitor.tool("pulse", on: .local())?.history.points("cpu").count ?? 0 >= 3 }
        let s = try #require(app.tools.monitor.server(.local())), t = try #require(s.tools["pulse"])
        #expect(s.missed == 0 && t.history.points("cpu").allSatisfy { $0.gap == nil }, "1.3 s against every 1: \(t.history.points("cpu").map { $0.gap?.rawValue ?? "v" })")
        kill(try #require(pid(bench)), SIGSTOP)
        await toolsUntil { s.missed >= 1 }
        #expect(s.missed >= 1 && t.history.points("cpu").last?.gap == .noAnswer)
        kill(try #require(pid(bench)), SIGCONT)
    }

    /// A script's `_event`s go through ten an hour; the rest are held and said as "N more" with the next that goes
    /// through — never one "1 more" each.
    @Test func scriptedEventsAreBudgeted() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick()
        defer { quick.done(); bench.done(); done(); app.savedServers = [] }
        try await watching(app, bench)
        bench.flag("event-localhost")
        app.tools.monitor.watch(try toolNamed(app, "pulse"), on: .local(), true)
        await toolsUntil { (app.tools.monitor.tool("pulse", on: .local())?.history.points("n").count ?? 0) >= 14 }
        let t = try #require(app.tools.monitor.tool("pulse", on: .local()))
        #expect(t.events.filter { $0.id == "tick" }.count == ToolEventBudget.perHour && !t.events.contains { $0.id == "more" }, "\(t.events.map(\.message))")
        #expect(t.budget.held >= 2, "the rest wait for the hour")
    }

    /// While a click's login runs, no quiet login runs beside it (a reconcile meanwhile would find it refused and say
    /// "needs login" again); a login refused for another reason than a password — the server unreachable — is retried.
    @Test func aClicksLoginRunsAloneAndOtherFailuresRetry() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick()
        defer { quick.done(); bench.done(); done(); app.savedServers = []; ToolRunner.hasMaster = { _ in true } }
        try await watching(app, bench)
        ToolRunner.hasMaster = { _ in false }
        nonisolated(unsafe) var logins: [Bool] = []
        nonisolated(unsafe) var refuse = "ssh: connect to host localhost port 22: Connection refused"
        let gate = DispatchSemaphore(value: 0)
        ToolMonitor.login = { _, quiet in
            logins.append(quiet)
            if quiet { throw SFTPError(message: refuse) }
            gate.wait()   // the sheet is up
            ToolRunner.hasMaster = { _ in true }
        }
        app.tools.monitor.watch(try toolNamed(app, "pulse"), on: .local(), true)
        await toolsUntil { app.tools.monitor.server(.local())?.retryAt != nil }
        let s = try #require(app.tools.monitor.server(.local()))
        #expect(!s.needsLogin && s.retryAt != nil, "unreachable: retried, not a click's")
        refuse = "Permission denied (publickey)."
        await toolsUntil { s.needsLogin }
        #expect(s.needsLogin && logins.count >= 2 && logins.allSatisfy { $0 })
        let quietSoFar = logins.count
        app.tools.monitor.connect(.local())
        await toolsUntil { logins.count == quietSoFar + 1 }
        #expect(s.connecting && app.tools.monitor.worst(s).why == "logging in…")
        app.tools.monitor.reconcile()
        try await Task.sleep(for: .milliseconds(300))
        #expect(logins.count == quietSoFar + 1 && logins.last == false, "no quiet login beside the click's")
        gate.signal()
        await toolsUntil { s.tools["pulse"]?.history.last != nil }
        #expect(!s.needsLogin && !s.connecting && s.channel != nil)
    }

    /// The dashboard's blocks draw from the stream: two charts with the series (24h and 7d greyed), the processes
    /// table from the last line that had the rows (every other one), their count, the events with where they go
    /// — the hover's values in a chart's words. Closing the window takes the charts out of the view tree.
    @Test func theDashboardDrawsItsBlocksFromTheStream() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick()
        defer { quick.done(); bench.done(); done(); app.savedServers = [] }
        try await watching(app, bench)
        bench.flag("hot-localhost")
        ToolsWindow.show(app, server: .local())
        weak var page = ToolsWindow.main?.page
        page?.select("pulse")
        await toolsUntil { (app.tools.monitor.tool("pulse", on: .local())?.history.points("cpu").count ?? 0) >= 3 }
        let view = try #require(page.flatMap(live))
        let charts = try #require(view.blocks.compactMap { $0 as? ToolsCharts }.first), table = try #require(view.blocks.compactMap { $0 as? ToolsTable }.first)
        let counts = try #require(view.blocks.compactMap { $0 as? ToolsCounts }.first), events = try #require(view.blocks.compactMap { $0 as? ToolsEvents }.first)
        await toolsUntil { table.rows.count == 2 && charts.model.data.charts.first?.lines.first?.points.count ?? 0 >= 3 && !(events.subviews.isEmpty) }
        weak var hosting = charts.hosting
        page?.window?.layoutIfNeeded()
        #expect(view.frame.height > 200 && view.frame.width > 300, "the live tab takes the page's body: \(view.frame)")
        #expect(hosting?.window != nil && charts.range.segmentCount == 3 && charts.range.isEnabled(forSegment: 0) && !charts.range.isEnabled(forSegment: 1))
        let d = charts.model.data
        #expect(d.charts.map(\.title) == ["CPU", "Ticks"] && d.charts[0].top == 100 && d.charts[0].warn == 85 && d.charts[0].crit == 95 && d.charts[1].warn == nil)
        #expect(d.charts[0].lines.first?.chart.runs.last?.last?.value == 99 && d.to.timeIntervalSince(d.from) == 3600, "\(d.charts[0].lines.first?.points.suffix(2) ?? [])")
        let model = ToolsCharts.Model()   // its own: the pointer may be over the window's charts, hovering
        (model.data, model.every) = (d, charts.model.every)
        let one = OneChart(chart: d.charts[0], model: model)
        #expect(one.said == "99%", "\(one.said)")
        model.hover = d.charts[0].lines.first?.points.last?.at
        #expect(one.said.hasPrefix("99% · "), "\(one.said)")
        #expect(table.rows.map(\.key) == ["1", "2"] && table.rows.map(\.title) == ["first", "second"] && table.rows[1].cells.map(\.text) == ["second", "20 %", "2"], "\(table.rows)")
        #expect(table.table.numberOfRows == 2 && table.table.tableColumns.map(\.title) == ["Command", "Cpu", "Pid", ""], "\(table.table.numberOfRows) \(table.table.tableColumns.map(\.title))")
        let first = rowButtons(table, 0)
        #expect(first.map(\.title) == ["Folder", "Stop…", "Deeper"] && rowButtons(table, 1).map(\.title) == first.map(\.title), "\(first.map(\.title))")
        try #require(first.count == 3)
        #expect(first[0].isEnabled && first[1].isEnabled && !first[2].isEnabled && first[2].toolTip?.contains("later release") == true)
        #expect(first[1].attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Palette.fail, "dangerous: red")
        #expect(counts.numbers.map(\.stringValue) == ["2"] && buttons(counts).map(\.title) == ["Services…"])
        #expect(buttons(events).map(\.title) == ["Services…"] && events.subviews.first.map { labels($0) }?.contains("hot: 99") == true, "\(events.subviews.first.map(labels) ?? [])")

        page?.select("fail2ban")   // away: the charts leave the tree and go; back: the same tab, its size again, charts anew
        await toolsUntil { hosting == nil }
        #expect(hosting == nil && charts.hosting == nil, "the charts go with the tab")
        page?.select("pulse")
        page?.window?.layoutIfNeeded()
        #expect(live(page!) === view && view.frame.height > 200 && charts.hosting?.window != nil, "back from another tab: \(view.frame)")
        weak var again = charts.hosting

        closeWindows()
        await toolsUntil { page == nil && again == nil }
        #expect(page == nil && again == nil, "the charts leave the view tree with the window: page \(page != nil), charts \(again != nil)")
    }

    /// A table row's action goes down the one path every action takes: Stop… asks everywhere (↩ = Cancel) and runs
    /// with the row's fields; Folder runs its command and shows what it printed in the panel; the line under the
    /// page says how each went. On a locked server the row's action asks Touch ID first — metrics never did.
    @Test func aTableRowsActionsTakeTheActionsPath() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick()
        let reveal = ToolRunner.reveal
        defer { quick.done(); bench.done(); done(); app.savedServers = []; ToolRunner.reveal = reveal; AppDelegate.answering = nil }
        try await watching(app, bench)
        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page)
        page.select("pulse")
        await toolsUntil { (live(page)?.blocks.compactMap { $0 as? ToolsTable }.first?.rows.count ?? 0) == 2 }
        let table = try #require(live(page)?.blocks.compactMap { $0 as? ToolsTable }.first)
        var asked: [(String, [String], Int?)] = []
        AppDelegate.answering = { m, b, d in asked.append((m, b, d)); return asked.count == 1 ? 2 : 0 }
        press(rowButtons(table, 0).first { $0.title == "Stop…" })
        await toolsUntil { !page.result.stringValue.isEmpty }
        #expect(asked.first?.0 == "Stop on localhost?" && asked.first?.1 == ["Stop", "Show Exactly What Runs", "Cancel"] && asked.first?.2 == 2, "\(asked)")
        #expect(page.result.stringValue == "Stop: cancelled — nothing ran")
        press(rowButtons(table, 0).first { $0.title == "Stop…" })
        await toolsUntil { page.result.stringValue.contains("Stop: done") }
        #expect(page.result.stringValue.contains("Stop: done on localhost at ") && asked.count == 2, "\(page.result.stringValue) \(asked.map(\.0))")
        #expect(bench.calls.contains("pulse-log stop 1"), "the row's pid in the command: \(bench.calls)")

        nonisolated(unsafe) var shown: [(SFTPTarget, String)] = []
        ToolRunner.reveal = { _, t, path in shown.append((t, path)) }
        press(rowButtons(table, 0).first { $0.title == "Folder" })
        await toolsUntil { !shown.isEmpty }
        #expect(shown.map(\.1) == ["/tmp/pulse-1"] && bench.calls.contains("pulse-dir 1") && asked.count == 2, "readonly: no question; what it printed opens")

        var locked = app.savedServers[0]
        locked.locked = true
        ServerLock.servers = { [locked] }
        var touched = 0
        ServerLock.authenticate = { _ in touched += 1; return false }
        press(rowButtons(table, 0).first { $0.title == "Folder" })
        await toolsUntil { touched == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(touched == 1 && shown.count == 1, "locked: Touch ID first, and nothing without it")
    }

    /// `goto` and the chart's click: an event's Services… and a count's open the server's services in the search;
    /// a click on a chart runs the `log` action with five minutes around that moment, by the server's clock.
    @Test func gotoAndAChartsClickFromTheDashboard() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick()
        defer { quick.done(); bench.done(); done(); app.savedServers = []; Picker.dismiss() }
        try await watching(app, bench)
        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page)
        page.select("pulse")
        await toolsUntil { (live(page)?.blocks.compactMap { $0 as? ToolsCounts }.first?.numbers.first?.stringValue ?? "—") != "—" }
        let view = try #require(live(page))
        press(buttons(try #require(view.blocks.compactMap { $0 as? ToolsCounts }.first)).first)
        let picker = try #require(Picker.current)
        #expect(picker.scopeNames.last == "Services", "\(picker.scopeNames)")
        Picker.dismiss()
        #expect(ToolRunner.Goto("services:nginx.service") == .services(unit: "nginx.service") && ToolRunner.Goto("containers:api") == .containers(name: "api")
                && ToolRunner.Goto("ssh") == .ssh && ToolRunner.Goto("mail") == nil)

        let at = Date(timeIntervalSince1970: 1_800_000_000)
        view.log("log", at: at)
        await toolsUntil { bench.calls.contains { $0.hasPrefix("pulse-log") } }
        #expect(bench.calls.contains("pulse-log 1799999850 1800000150"), "\(bench.calls)")
        await toolsUntil { page.result.stringValue.contains("Log: done") }
        #expect(page.result.stringValue.contains("Log: done on localhost"), "\(page.result.stringValue)")
        #expect(buttons(view).map(\.title).contains("Terminal") == false, "a tool's goto isn't a dashboard button")
    }

    /// A tick that comes late — the main thread was busy — judges no interval missed: the stream's lines that
    /// came meanwhile are still to be read, so nothing is a gap.
    @Test func aLateTickJudgesNoInterval() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick()
        defer { quick.done(); bench.done(); done(); app.savedServers = [] }
        try await watching(app, bench)
        bench.flag("slow-localhost")   // a line every 1.3 s against every 1: healthy, and sparse enough that the tick comes first
        app.tools.monitor.watch(try toolNamed(app, "pulse"), on: .local(), true)
        await toolsUntil { (app.tools.monitor.tool("pulse", on: .local())?.history.points("cpu").count ?? 0) >= 2 }
        let s = try #require(app.tools.monitor.server(.local())), t = try #require(s.tools["pulse"])
        usleep(1_800_000)   // the main thread busy past 3 ticks: the timer and the lines wait
        try await Task.sleep(for: .milliseconds(300))
        #expect(s.missed == 0 && !t.history.points("cpu").contains { $0.gap == .noAnswer }, "\(t.history.points("cpu").map { $0.gap?.rawValue ?? "v" })")
    }

    /// Back from sleep, or on another network, each channel is ended and comes back: a gap, one more round trip,
    /// the series going on.
    @Test func aWakeRestartsTheChannel() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick()
        defer { quick.done(); bench.done(); done(); app.savedServers = [] }
        try await watching(app, bench)
        app.tools.monitor.watch(try toolNamed(app, "pulse"), on: .local(), true)
        await toolsUntil { app.tools.monitor.tool("pulse", on: .local())?.history.last != nil }
        let s = try #require(app.tools.monitor.server(.local())), t = try #require(s.tools["pulse"])
        let trips = bench.trips, first = pid(bench)
        app.tools.monitor.restart()
        #expect(s.channel == nil && s.retryAt != nil && t.history.points("cpu").last?.gap == .reconnecting)
        await toolsUntil { bench.trips > trips && pid(bench) != first && t.history.points("cpu").last?.value != nil }
        #expect(bench.trips == trips + 1 && !alive(first) && s.channel != nil, "the old run ended on the server, a new one runs")
    }
}
