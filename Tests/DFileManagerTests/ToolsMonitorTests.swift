import AppKit
import Network
import ServiceManagement
import UserNotifications
@testable import DFMCore
import Testing
@testable import DFileManager

// Tools PR 5a: watching. A stream runs while its tab shows and stops when it doesn't; Watch keeps it without a
// window and in tools/servers.json; a drop is a gap and a reconnect; a server that isn't connected never logs in for
// a tab, and one whose login would ask says "needs login"; a locked server is watched without Touch ID and stays
// in use; WATCHED lists problems first; two tools on one server share one channel. Against `ToolsBench` and a
// stream of its own (`pulse`) on this Mac.

/// A stream on this Mac: a JSON line every 0.3 s — cpu 10, or 99 while the flag `hot-<server>` is there; every 1.3 s
/// with `slow-<server>`; with `event-<server>`, an `_event` in each line (a critical one with `boom-<server>`); two `procs` rows in every other line (as
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
              [ -f \(bench.dir)/boom-$2 ] && ev=',"_event":{"id":"boom","level":"critical","message":"boom"}'
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

/// A web server on 127.0.0.1 for Sites: each request gets the status `answer` gives for its path.
private final class LocalWeb: @unchecked Sendable {
    let listener: NWListener
    var url: String { "http://127.0.0.1:\(listener.port!.rawValue)" }
    init(_ answer: @escaping @Sendable (String) -> Int) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)   // loopback only: no firewall question
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { c in
            c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let words = String(decoding: data ?? Data(), as: UTF8.self).split(separator: " ")
                let head = "HTTP/1.1 \(answer(words.count > 1 ? String(words[1]) : "/")) X\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                c.send(content: Data(head.utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
    }
    func done() { listener.cancel() }
}

@MainActor private func pid(_ bench: ToolsBench, _ server: String = "localhost", _ id: String = "pulse") -> pid_t? {
    (try? String(contentsOfFile: bench.dir + "/\(id)-\(server).pid", encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}
@MainActor private func alive(_ p: pid_t?) -> Bool { p.map { kill($0, 0) == 0 } ?? false }

/// The watching seams quick, and back after — the app's watching stopped, so no stream of a test runs on into the next.
@MainActor private struct Quick {
    let app: AppDelegate
    let was = (tick: ToolMonitor.tick, backoff: ToolMonitor.backoff, login: ToolMonitor.login, watching: ToolRunner.watching, auth: ServerLock.authenticate,
               target: ToolMonitor.target, grace: ToolMonitor.wakeGrace)
    init(_ app: AppDelegate) {
        self.app = app
        ToolMonitor.tick = 0.2
        ToolMonitor.backoff = [0.3]
        ToolMonitor.login = { _, _ in }
        ToolMonitor.target = { _ in .local() }
        ToolMonitor.wakeGrace = 0   // a Wi-Fi flap during the run mustn't hold "not answering" back
        ToolRunner.watching = { _, _ in true }
    }
    func done() {
        app.tools.settings = ToolServers()
        closeWindows()
        app.tools.monitor.reconcile()
        (ToolMonitor.tick, ToolMonitor.backoff, ToolMonitor.login, ToolRunner.watching, ServerLock.authenticate, ToolMonitor.target, ToolMonitor.wakeGrace) = was
    }
}

/// macOS notifications' stand-in: allowed or not (nil: never asked), each one posted, each ask.
@MainActor private final class Posts {
    var allowed: Bool? = true, asked = 0
    var sent: [(id: String, title: String, body: String, info: [String: String])] = []
    let was = (notices: ToolJobs.notices, activation: AppDelegate.activation)
    /// How the app went to the menu bar alone, or back with a window in front.
    var activations: [(NSApplication.ActivationPolicy, NSWindow?)] = []
    init() {
        ToolJobs.notices = .init(allowed: { [weak self] in self?.allowed ?? nil }, ask: { [weak self] in self?.asked += 1 },
                                 post: { [weak self] in self?.sent.append(($0, $1, $2, $3)) })   // a delivery late after the test: dropped
        AppDelegate.activation = { [weak self] in self?.activations.append(($0, $1)) }
    }
    func done() { (ToolJobs.notices, AppDelegate.activation) = was }
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
        let bench = try ToolsBench(), quick = Quick(app)
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
        let bench = try ToolsBench(), quick = Quick(app)
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
        let bench = try ToolsBench(), quick = Quick(app)
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
        let bench = try ToolsBench(), quick = Quick(app)
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
        let bench = try ToolsBench(), quick = Quick(app)
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
        let bench = try ToolsBench(), quick = Quick(app)
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
        #expect(app.tools.monitor.watched.map(\.saved.title) == ["localhost"] && app.tools.monitor.summary(s.tools["pulse"]!, on: s).first?.level == .critical)
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
        let bench = try ToolsBench(), quick = Quick(app)
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
        #expect(runs.groups.last?.title == "In the background, when you watch it — may send notifications" && runs.background.first?.text == "  stream: pulse {every} {server}   — every 1 s on each watched server")
    }

    /// A stream that runs a little slower than `every` (System sleeps after its reads) is no gap: nothing missed, no
    /// mark, the alerts' clocks untouched. Once it really stops, the intervals are missed from half of one on.
    @Test func aSlightlyLateStreamIsNoGap() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app)
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
        let bench = try ToolsBench(), quick = Quick(app)
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
        let bench = try ToolsBench(), quick = Quick(app)
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
        let bench = try ToolsBench(), quick = Quick(app)
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
        #expect(hosting?.window != nil && charts.range.segmentCount == 3 && charts.range.selectedSegment == 0)
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
        let bench = try ToolsBench(), quick = Quick(app)
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
        let bench = try ToolsBench(), quick = Quick(app)
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
        let bench = try ToolsBench(), quick = Quick(app)
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
        let bench = try ToolsBench(), quick = Quick(app)
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

    // MARK: Tools PR 5b — notifications, the menu bar, the app without windows

    /// A watched tool's critical alert comes as one notification — the server, the tool's words, its ids for the
    /// buttons — and runs `on_alert` with what happened in its environment, nothing in its words; the `is` event, a
    /// warning, notifies nothing, nor does "back to normal". Snoozed, nothing goes out — what still stands when the
    /// snooze ends is sent then; a notification's Mute keeps that alert quiet on this server (tools/servers.json), and
    /// Open shows its tab with Kermo in front.
    @Test func aCriticalAlertNotifiesOnceAndRunsOnAlert() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app), posts = Posts()
        let out = bench.dir + "/on-alert.txt", script = bench.dir + "/bin/on-alert"
        try Data("#!/bin/sh\n{ echo \"argc=$#\"; env | grep '^KERMO_' | sort; } > \(out)\n".utf8).write(to: URL(fileURLWithPath: script))
        chmod(script, 0o755)
        app.defaults.set(script, forKey: "onAlert")
        defer { posts.done(); quick.done(); bench.done(); done(); app.savedServers = []; app.defaults.removeObject(forKey: "onAlert"); app.tools.monitor.snooze(until: nil) }
        try await watching(app, bench)
        let monitor = app.tools.monitor
        monitor.watch(try toolNamed(app, "pulse"), on: .local(), true)
        await toolsUntil { monitor.tool("pulse", on: .local())?.history.last != nil }
        let s = try #require(monitor.server(.local())), t = try #require(s.tools["pulse"])
        bench.flag("hot-localhost")
        await toolsUntil { t.alerts.worst == .critical && s.events.contains { $0.message == "on_alert ran" } }
        #expect(posts.sent.count == 1, "\(posts.sent)")
        let sent = try #require(posts.sent.first)
        #expect(sent.title == "localhost" && sent.body == "Pulse: CPU 99%" && sent.info == ["server": s.key, "tool": "pulse", "alert": "cpu"], "\(sent)")
        #expect(try String(contentsOfFile: out, encoding: .utf8) == "argc=0\nKERMO_LEVEL=critical\nKERMO_MESSAGE=CPU 99%\nKERMO_SERVER=localhost\nKERMO_TOOL=pulse\n")
        #expect(t.events.contains { $0.message == "hot: 99" && $0.level == "warning" }, "the warning is there, not notified")
        #expect(ToolsMenuBar.head(monitor).text == "1 critical")
        let bar = ToolsMenuBar(app)   // its popover's content, never shown: no item in the menu bar of the Mac running the tests
        bar.fill()
        let content = try #require(bar.popover.contentViewController?.view)
        #expect(labels(content).contains("Monitor · 1 critical") && labels(content).contains("localhost"), "\(labels(content))")
        #expect(buttons(content).map(\.title) == ["Open Monitor  ⌃⌘M", "Open Kermo", "Snooze Notifications ▾", "Keep This Mac Awake on Power", "Quit Kermo"] && bar.item == nil,
                "\(buttons(content).map(\.title))")
        await toolsUntil { DockTile.problems == 1 }
        #expect(DockTile.problems == 1, "the Dock's badge counts it")
        try await Task.sleep(for: .milliseconds(500))
        #expect(posts.sent.count == 1, "once, while it stands")

        bench.flag("hot-localhost", false)
        await toolsUntil { t.alerts.worst == nil }
        #expect(posts.sent.count == 1 && t.events.first?.message.hasPrefix("Back to normal") == true, "back to normal: an event only")

        monitor.clicked(ToolJobs.Notices.snooze, sent.info)
        #expect(monitor.snoozed.map { abs($0.timeIntervalSinceNow - 3600) < 5 } == true && ToolsMenuBar.head(monitor).snoozed?.hasPrefix("snoozed until") == true)
        bench.flag("hot-localhost")
        await toolsUntil { t.alerts.worst == .critical }
        try await Task.sleep(for: .milliseconds(300))
        #expect(posts.sent.count == 1, "snoozed")
        monitor.snooze(until: nil)
        await toolsUntil { posts.sent.count == 2 }
        #expect(posts.sent.count == 2 && posts.sent.last?.body == "Pulse: CPU 99%", "the snooze over: what still stands is sent")
        bench.flag("hot-localhost", false)
        await toolsUntil { t.alerts.worst == nil }

        monitor.clicked(ToolJobs.Notices.mute, sent.info)
        #expect(app.tools.settings.mutes("cpu", of: "pulse", on: app.savedServers[0].id.uuidString))
        let file = bench.dir + "/own/servers.json"
        await toolsUntil { ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").contains("muted") }
        #expect(((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").contains("muted"))
        bench.flag("hot-localhost")
        await toolsUntil { t.alerts.worst == .critical }
        try await Task.sleep(for: .milliseconds(300))
        #expect(posts.sent.count == 2 && monitor.worst(s).state == .critical, "muted: still shown, not notified")

        monitor.clicked(UNNotificationDefaultActionIdentifier, sent.info)
        let w = try #require(ToolsWindow.main)
        #expect(w.page?.tab == "pulse" && posts.activations.last?.0 == .regular && posts.activations.last?.1 === w.window, "Open: its tab, Kermo in front")
    }

    /// Sites: the server's addresses (Edit Server) checked from this Mac with no channel — each round one sample of
    /// `urls` rows, in the order saved: the table, "1 of 2 up"; two failed checks in a row are `down`, critical, a
    /// notification. Check Now in a row checks at once. An address that isn't http(s) keeps the server sheet's Save off.
    @Test func sitesChecksTheServersAddressesFromThisMac() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app), posts = Posts(), web = try LocalWeb { $0 == "/down" ? 503 : 200 }
        defer { web.done(); posts.done(); quick.done(); bench.done(); done(); app.savedServers = [] }
        var saved = SavedServer(address: "localhost")!
        saved.sites = ["ftp://example.com"]
        #expect(saved.issue?.field == .sites)
        saved.sites = [web.url + "/", web.url + "/down"]
        #expect(saved.issue == nil)
        try await watching(app, bench, servers: [saved])
        let monitor = app.tools.monitor
        await toolsUntil { app.tools.here(.local())?.tools.contains { $0.preset.id == "sites" } == true }
        monitor.watch(try toolNamed(app, "sites"), on: .local(), true)
        await toolsUntil { monitor.tool("sites", on: .local())?.history.rows("urls").count == 2 }
        let s = try #require(monitor.server(.local())), t = try #require(s.tools["sites"])
        #expect(s.channel == nil && monitor.worst(s).state == .ok, "from this Mac: no channel, and none missed")
        #expect(t.history.rows("urls").map { $0["status"] } == [200, 503] && t.history.rows("urls").map { $0["ok"] } == [true, false])
        #expect(monitor.summary(t, on: s).first?.text == "1 of 2 up" && posts.sent.isEmpty, "one failed check isn't down yet")

        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page)
        page.select("sites")
        await toolsUntil { (live(page)?.blocks.compactMap { $0 as? ToolsTable }.first?.rows.count ?? 0) == 2 }
        let view = try #require(live(page)), table = try #require(view.blocks.compactMap { $0 as? ToolsTable }.first)
        #expect(view.foot.stringValue.hasSuffix("checked from this Mac · no SSH") && !view.addButton.isHidden && view.banner.isHidden, "\(view.foot.stringValue)")
        press(rowButtons(table, 1).first { $0.title == "Check Now" })
        await toolsUntil { posts.sent.count == 1 }
        #expect(posts.sent.first?.body == "Sites: \(web.url)/down is down: 503" && monitor.worst(s).state == .critical, "\(posts.sent)")
    }

    /// On battery (or in Low Power Mode) watching is three times less often: the channel starts again with its
    /// `{every}` three times longer, the tab says so; Settings' switch off, it's as on power. On power, Keep This Mac
    /// Awake holds an assertion while something is watched — not on battery, not once nothing is. Open at Login is as
    /// macOS has it, never a copy.
    @Test func batteryPaceKeepAwakeAndOpenAtLogin() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app), was = (power: ToolMonitor.power, login: ToolMonitor.loginItem)
        nonisolated(unsafe) var battery = false, status = SMAppService.Status.notRegistered
        ToolMonitor.power = { (battery, false) }
        ToolMonitor.loginItem = ({ status }, { status = $0 ? .enabled : .notRegistered })
        defer {
            quick.done(); bench.done(); done(); app.savedServers = []
            (ToolMonitor.power, ToolMonitor.loginItem) = was
            for k in ["monitorKeepAwake", "monitorSlowOnBattery"] { app.defaults.removeObject(forKey: k) }
        }
        try await watching(app, bench)
        let monitor = app.tools.monitor, pulse = try toolNamed(app, "pulse")
        monitor.watch(pulse, on: .local(), true)
        await toolsUntil { bench.calls.contains("pulse 1 localhost") }
        battery = true
        monitor.pace()
        await toolsUntil { bench.calls.contains("pulse 3 localhost") }
        let s = try #require(monitor.server(.local()))
        #expect(monitor.slow && s.every == 3 && bench.calls.contains("pulse 3 localhost"), "on battery: three times less often")
        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page)
        page.select("pulse")
        #expect(live(page)?.strip.stringValue.hasPrefix("Watched in the background · every 3 s on battery") == true, "\(live(page)?.strip.stringValue ?? "")")
        app.run("monitor.slowOnBattery")
        await toolsUntil { bench.calls.filter { $0 == "pulse 1 localhost" }.count == 2 }
        #expect(!monitor.slow && s.every == 1, "your switch: as on power")

        battery = false
        app.run("monitor.keepAwake")
        #expect(monitor.keepingAwake && app.commands.first { $0.id == "monitor.keepAwake" }?.on?(app) == true)
        battery = true
        monitor.pace()
        #expect(!monitor.keepingAwake, "on battery it sleeps as usual")
        battery = false
        monitor.pace()
        #expect(monitor.keepingAwake)
        monitor.watch(pulse, on: .local(), false)
        #expect(!monitor.keepingAwake, "nothing watched: nothing held")

        app.run("monitor.openAtLogin")
        #expect(status == .enabled && app.commands.first { $0.id == "monitor.openAtLogin" }?.on?(app) == true)
        app.run("monitor.openAtLogin")
        #expect(status == .notRegistered && app.commands.first { $0.id == "monitor.openAtLogin" }?.on?(app) == false)
    }

    /// The history on disk: a watched tool's slot so far and "not watched" go to its server's day file when watching
    /// stops (a whole slot every 15 minutes); a tab's 24h reads them — the slot's average, the band after it — and
    /// the hour is the memory's again.
    @Test func watchingWritesItsHistoryAndTheChartsReadIt() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app)
        defer { quick.done(); bench.done(); done(); app.savedServers = [] }
        try await watching(app, bench)
        let monitor = app.tools.monitor, pulse = try toolNamed(app, "pulse"), dir = ToolMonitor.history(app.savedServers[0].id)
        monitor.watch(pulse, on: .local(), true)
        await toolsUntil { (monitor.tool("pulse", on: .local())?.history.points("cpu").count ?? 0) >= 3 }
        monitor.watch(pulse, on: .local(), false)
        await toolsUntil { ToolSlots.read(dir, tool: "pulse", from: Date().addingTimeInterval(-3600)).count == 2 }
        let lines = ToolSlots.read(dir, tool: "pulse", from: Date().addingTimeInterval(-3600))
        #expect(lines.first?.v?["cpu"]?[""]?[1] == 10 && lines.last?.gap == .notWatched, "\(lines)")

        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page)
        page.select("pulse")
        await toolsUntil { live(page)?.blocks.contains { $0 is ToolsCharts } == true }
        let charts = try #require(live(page)?.blocks.compactMap { $0 as? ToolsCharts }.first)
        #expect((0..<3).allSatisfy(charts.range.isEnabled(forSegment:)))
        charts.range.selectedSegment = 1
        _ = (charts.range.target as? NSObject)?.perform(charts.range.action, with: charts.range)
        let d = charts.model.data, cpu = try #require(d.charts.first)
        #expect(d.to.timeIntervalSince(d.from) == 86400 && charts.model.every == 900 && charts.model.days == false)
        #expect(cpu.lines.first?.points.compactMap(\.value) == [10] && cpu.bands.map(\.gap) == [.notWatched, .notWatched], "before it, and since: \(cpu.bands)")
        charts.range.selectedSegment = 0
        _ = (charts.range.target as? NSObject)?.perform(charts.range.action, with: charts.range)
        #expect(charts.model.data.to.timeIntervalSince(charts.model.data.from) == 3600 && charts.model.every == 1)
    }

    /// A script's critical `_event` notifies, as the server's not answering does; a tool only live on an open tab
    /// notifies nothing — only what's watched does (§8.7).
    @Test func eventsAndNotAnsweringNotifyOnlyWhenWatched() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app), posts = Posts()
        defer { posts.done(); quick.done(); bench.done(); done(); app.savedServers = [] }
        try await watching(app, bench)
        let monitor = app.tools.monitor
        ToolsWindow.show(app, server: .local())
        try #require(ToolsWindow.main?.page).select("pulse")
        bench.flag("hot-localhost")
        bench.flag("boom-localhost")
        await toolsUntil { monitor.tool("pulse", on: .local())?.alerts.worst == .critical }
        let t = try #require(monitor.tool("pulse", on: .local()))
        #expect(t.live && !t.watched && t.events.contains { $0.id == "boom" } && posts.sent.isEmpty, "live on a tab: nothing notifies")
        closeWindows()
        bench.flag("hot-localhost", false)

        monitor.watch(try toolNamed(app, "pulse"), on: .local(), true)
        await toolsUntil { posts.sent.contains { $0.body == "Pulse: boom" } }
        let boom = try #require(posts.sent.first { $0.body == "Pulse: boom" })
        #expect(boom.info == ["server": monitor.server(.local())!.key, "tool": "pulse"], "an event: Open and Snooze, no Mute")
        try await Task.sleep(for: .milliseconds(700))
        #expect(posts.sent.filter { $0.body == "Pulse: boom" }.count == 1, "a script's event in every line: one notification till it's closed")
        bench.flag("boom-localhost", false)
        let s = try #require(monitor.server(.local()))
        kill(try #require(pid(bench)), SIGSTOP)
        await toolsUntil { posts.sent.contains { $0.body.hasPrefix("Not answering") } }
        kill(try #require(pid(bench)), SIGCONT)
        let down = try #require(posts.sent.first { $0.body.hasPrefix("Not answering") })
        #expect(down.title == "localhost" && down.info == ["server": s.key] && down.body.hasSuffix("This Mac is online: it's the server or the way to it."), "\(down)")
    }

    /// The first Watch asks macOS for notifications, once; Settings ▸ Monitor says how they stand as macOS has it now,
    /// and Send Test runs `on_alert` with made-up values.
    @Test func watchAsksForNotificationsAndSettingsSayHowTheyStand() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app), posts = Posts()
        defer { posts.done(); quick.done(); bench.done(); done(); app.savedServers = []; app.defaults.removeObject(forKey: "onAlert") }
        try await watching(app, bench)
        posts.allowed = nil
        let tool = try toolNamed(app, "pulse")
        #expect(await app.tools.toggleWatch(tool, on: app.savedServers[0], .local(), window: nil))
        await toolsUntil { posts.asked == 1 }
        #expect(posts.asked == 1, "asked at the user's Watch")
        let rows = try #require(app.settingsTabs.first { $0.title == "Monitor" }).groups.flatMap(\.rows)
        let state = try #require(rows.first?.status)
        #expect(await state(app) == "Not asked yet: Kermo asks when you first watch a server")
        posts.allowed = false
        #expect(await state(app).hasPrefix("Notifications are off for Kermo"))
        #expect(rows.contains { $0.key == "onAlert" })

        app.defaults.set("exit 3", forKey: "onAlert")
        app.tools.monitor.test()
        await toolsUntil { app.tools.monitor.tested.contains("on_alert") }
        #expect(app.tools.monitor.tested.hasPrefix("No notification (they're off) · on_alert failed: exit 3"), "\(app.tools.monitor.tested)")
        #expect(posts.sent.isEmpty)
    }

    /// Closing the last window while something is watched leaves Kermo in the menu bar alone — no quit question, no
    /// quitting — and Open Monitor brings it back with the Tools window; with nothing watched it quits as before.
    /// Snooze ▾: 15 minutes, an hour, the morning, Resume.
    @Test func withoutWindowsKermoStaysInTheMenuBar() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app), posts = Posts()
        defer { posts.done(); quick.done(); bench.done(); done(); app.savedServers = []; app.tools.monitor.snooze(until: nil) }
        try await watching(app, bench)
        #expect(app.applicationShouldTerminateAfterLastWindowClosed(NSApp), "nothing watched: the last window quits")
        app.windowClosed { [] }
        try await Task.sleep(for: .milliseconds(100))
        #expect(posts.activations.isEmpty)

        app.tools.monitor.watch(try toolNamed(app, "pulse"), on: .local(), true)
        #expect(!app.applicationShouldTerminateAfterLastWindowClosed(NSApp) && app.windowShouldClose(app.window))
        let open = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        open.orderFront(nil)
        app.windowClosed { [open] }
        try await Task.sleep(for: .milliseconds(100))
        #expect(posts.activations.isEmpty, "a window still open")
        open.orderOut(nil)
        app.windowClosed { [open] }
        await toolsUntil { !posts.activations.isEmpty }
        #expect(posts.activations.count == 1 && posts.activations[0].0 == .accessory && posts.activations[0].1 == nil)

        try #require(app.commands.first { $0.id == "app.monitor" }).run(app)
        let w = try #require(ToolsWindow.main)
        #expect(posts.activations.last?.0 == .regular && posts.activations.last?.1 === w.window && w.sidebar.selectedRow == 1, "on WATCHED")

        // Show in the Menu Bar: pinned in tools/servers.json, its item's words — the name and the summary.
        let page = try #require(w.page), id = app.savedServers[0].id.uuidString
        let pin = try #require(page.moreMenu().items.first { $0.title == "Show localhost in the Menu Bar" })
        #expect(pin.isEnabled && pin.state == .off)
        _ = (pin.target as? NSObject)?.perform(pin.action, with: pin)
        #expect(app.tools.settings.pinned == [id] && page.moreMenu().items.first { $0.title.hasPrefix("Show localhost") }?.state == .on)
        let s = try #require(app.tools.monitor.server(.local()))
        await toolsUntil { s.tools["pulse"]?.history.last != nil }
        #expect(ToolsMenuBar.pinText(app.tools.monitor, s) == "localhost 10%", "\(ToolsMenuBar.pinText(app.tools.monitor, s))")
        app.tools.unpinFromMenuBar(app.savedServers[0])   // as deleting the server does
        #expect(app.tools.settings.pinned.isEmpty, "a deleted server doesn't hold one of the three")

        let menu = ToolsMenuBar.snoozeMenu(app.tools.monitor)
        #expect(Array(menu.items.prefix(2).map(\.title)) == ["For 15 Minutes", "For 1 Hour"] && menu.items[2].title.hasPrefix("Until ")
                && menu.items[3].title == "Resume Notifications" && !menu.items[3].isEnabled)
        _ = (menu.items[1].target as? NSObject)?.perform(menu.items[1].action, with: menu.items[1])
        #expect(app.tools.monitor.snoozed.map { abs($0.timeIntervalSinceNow - 3600) < 5 } == true)
        let again = ToolsMenuBar.snoozeMenu(app.tools.monitor)
        #expect(again.items[3].isEnabled)
        _ = (again.items[3].target as? NSObject)?.perform(again.items[3].action, with: again.items[3])
        #expect(app.tools.monitor.snoozed == nil)
    }

    /// Thresholds… on a server: yours over the tool's — the alert judged by them, the tile's bar and the sheet's
    /// next look show them — and Notify unticked mutes it there.
    @Test func thresholdsChangeWhatIsJudged() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app), posts = Posts()
        defer { posts.done(); quick.done(); bench.done(); done(); app.savedServers = []; ToolRunner.thresholding = nil }
        try await watching(app, bench)
        let monitor = app.tools.monitor, id = app.savedServers[0].id.uuidString
        monitor.watch(try toolNamed(app, "pulse"), on: .local(), true)
        await toolsUntil { monitor.tool("pulse", on: .local())?.history.last != nil }
        let s = try #require(monitor.server(.local())), t = try #require(s.tools["pulse"])
        var asked: [ToolRunner.Edit] = []
        ToolRunner.thresholding = { edits in
            asked = edits
            return edits.map { e in
                var e = e
                if e.scope == id { (e.mine, e.notify) = (.init(crit: 98), false) }
                return e
            }
        }
        await app.tools.thresholds(on: .local(), window: nil)
        #expect(asked.filter { $0.tool == "pulse" }.map { "\($0.alert) \($0.scope == nil ? "all" : "this")" } == ["cpu all", "cpu this"], "\(asked)")
        #expect(app.tools.settings.alerts(t.preset, on: id).first?.crit == 98 && app.tools.settings.mutes("cpu", of: "pulse", on: id))
        #expect(monitor.summary(t, on: s).first?.crit == 98, "WATCHED's bar by your threshold")
        bench.flag("hot-localhost")
        await toolsUntil { t.alerts.worst == .critical }
        try await Task.sleep(for: .milliseconds(400))
        #expect(monitor.worst(s) == (.critical, "CPU 99%") && posts.sent.isEmpty, "critical by your 98, and Notify unticked: shown, not sent")
    }

    /// Maintenance on a watched server: a critical alert stands as ever, nothing notifies; the live tab says till when
    /// with End Now, the charts get a band; it ends by itself or by End Now — what still stands is sent then — and
    /// notifications come again.
    @Test func maintenanceHoldsNotificationsAndMarksTheCharts() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app), posts = Posts()
        defer { posts.done(); quick.done(); bench.done(); done(); app.savedServers = [] }
        try await watching(app, bench)
        let monitor = app.tools.monitor
        monitor.watch(try toolNamed(app, "pulse"), on: .local(), true)
        await toolsUntil { monitor.tool("pulse", on: .local())?.history.last != nil }
        let s = try #require(monitor.server(.local())), t = try #require(s.tools["pulse"])
        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page)
        #expect(page.tab == "pulse" && !page.maintenance.isHidden && page.maintenance.isEnabled && !page.thresholds.isHidden, "a watched server opens on its watched tab")
        let menu = page.maintenanceMenu()
        #expect(menu.items.map(\.title).filter { !$0.isEmpty } == ["Maintenance on localhost", "30 Minutes", "1 Hour", "3 Hours", "End Maintenance", "Nothing notifies of it till then; the charts mark the time"])
        _ = (menu.items[1].target as? NSObject)?.perform(menu.items[1].action, with: menu.items[1])
        #expect(s.inMaintenance && monitor.worst(s).why.hasPrefix("maintenance till") && s.events.first?.message.hasPrefix("Maintenance till") == true)
        bench.flag("hot-localhost")
        await toolsUntil { t.alerts.worst == .critical }
        try await Task.sleep(for: .milliseconds(300))
        #expect(posts.sent.isEmpty && monitor.worst(s).state == .critical, "it stands, and nothing notifies")
        let view = try #require(live(page))
        view.update()
        #expect(view.banner.stringValue.hasPrefix("Maintenance till") && !view.endButton.isHidden, "\(view.banner.stringValue)")
        let charts = try #require(view.blocks.compactMap { $0 as? ToolsCharts }.first)
        charts.update(view)
        #expect(charts.model.data.charts.first?.bands.contains { $0.gap == .maintenance } == true)
        press(view.endButton)
        #expect(!s.inMaintenance && s.events.first?.message == "Maintenance ended")
        await toolsUntil { !posts.sent.isEmpty }
        #expect(posts.sent.count == 1 && posts.sent[0].body == "Pulse: CPU 99%", "the maintenance over: what still stands is sent")
        bench.flag("hot-localhost", false)
        await toolsUntil { t.alerts.worst == nil }
        bench.flag("hot-localhost")
        await toolsUntil { posts.sent.count == 2 }
        #expect(posts.sent.count == 2, "after maintenance: notified again")
        charts.update(view)
        #expect(charts.model.data.charts.first?.bands.contains { $0.gap == .maintenance } == true, "the band stays for the time it was")
    }
}
