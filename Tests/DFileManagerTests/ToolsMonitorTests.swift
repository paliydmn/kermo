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
/// System spaces its heavier reads) — `second` first with `swap-<server>`, alone with `lone-<server>`, its cpu new each
/// time with `busy-<server>`, its mem 60 (past `pmem`'s warning) with `warm-<server>`, of this connection (`kind: self`)
/// with `self-<server>` — its pid in `pulse-<server>.pid`. `first` has a command line (`args`), its command's tip.
/// `pulse2`: the same under another name. Its dashboard has every block; its actions: Folder (`open` what `pulse-dir`
/// prints), Stop… (dangerous, only on a user's process), Deeper (a level on ↩, only on the row of `first`), Copy PID
/// (⌘C, only on `second`'s), Log (`{from}` / `{to}` into `pulse-log`), Terminal and Services (`goto`), Calm… (`confirm`).
/// `list`: also a list of three processes (`pulse-list`), the busiest two shown — `second` of this connection — and the
/// table's All Processes… to it.
@MainActor private func pulse(_ bench: ToolsBench, _ ids: [String] = ["pulse"], list: Bool = false) throws {
    try Data("""
        #!/bin/sh
        echo "pulse-list $*" >> \(bench.dir)/calls.log
        echo '{"procs":[{"pid":1,"command":"first","cpu":1.5,"kind":"user","args":"first --token=s3cret"},{"pid":2,"command":"second","cpu":20,"kind":"self"},{"pid":3,"command":"third","cpu":0.5,"kind":"user"}]}'

        """.utf8).write(to: URL(fileURLWithPath: bench.dir + "/bin/pulse-list"))
    chmod(bench.dir + "/bin/pulse-list", 0o755)
    let listed = list ? #""list": { "command": "pulse-list", "format": "json", "rows": "procs", "key": "{pid}", "sort": "-cpu", "limit": 2, "title": "{command}", "detail": "pid {pid}", "columns": [{ "field": "command", "tip": "{args}" }, { "field": "cpu:%", "title": "CPU", "help": "% of one core" }, "pid"] },"# : ""
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
              c2=20; [ -f \(bench.dir)/busy-$2 ] && c2=$((21 + i % 9))
              m2=40; [ -f \(bench.dir)/warm-$2 ] && m2=60
              k2=user; [ -f \(bench.dir)/self-$2 ] && k2=self
              p1='{"pid":1,"command":"first","cpu":1.5,"mem":30,"kind":"user","args":"first --name \\"a b\\""}'
              p2=$(printf '{"pid":2,"command":"second","cpu":%s,"mem":%s,"kind":"%s"}' "$c2" "$m2" "$k2")
              rows="$p1,$p2"; [ -f \(bench.dir)/swap-$2 ] && rows="$p2,$p1"; [ -f \(bench.dir)/lone-$2 ] && rows="$p2"
              procs=''; [ $((i % 2)) -eq 0 ] && procs=',"procs":['"$rows"']'
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
              "watch": { "every": 1, "down": 2 }, \(listed)
              "metrics": { "cpu": { "title": "CPU", "path": "cpu.pct", "unit": "%", "max": 100 }, "n": { "title": "Ticks", "path": "n" },
                           "pmem": { "title": "Process memory", "rows": "procs", "key": "pid", "path": "mem", "unit": "%", "max": 100 } },
              "summary": [ { "metric": "cpu", "as": "bar" } ],
              "alerts": [ { "id": "cpu", "metric": "cpu", "warn": 85, "crit": 95, "checks": 2 }, { "id": "pmem", "metric": "pmem", "warn": 50, "crit": 95 } ],
              "events": [ { "id": "hot", "path": "cpu.pct", "when": "is", "value": 99, "level": "warning", "message": "hot: {cpu.pct}", "goto": "services:hot.service" } ],
              "dashboard": [ { "row": [ { "stat": "cpu" }, { "stat": "n" } ] },
                             { "charts": [ ["cpu"], ["n"], ["pmem", "cpu"] ], "range": ["1h", "24h", "7d"], "log": "log" },
                             { "row": [ { "table": "procs", "title": "Processes", "key": "{pid}", \(list ? #""list": "All Processes…","# : "")
                                          "columns": [{ "field": "command", "tip": "{args}" }, { "field": "cpu:%", "help": "% of one core" }, "mem:bar", "pid"], "actions": ["folder", "stop", "deeper", "pidcopy"] },
                                        { "counts": [ { "rows": "procs", "title": "processes", "goto": "services" } ] } ] },
                             { "events": true } ],
              "actions": [
                { "id": "folder", "title": "Folder", "rows": "procs", "readonly": true, "command": "pulse-dir {pid}", "open": "{stdout}" },
                { "id": "stop", "title": "Stop…", "rows": "procs", "only": { "kind": ["user"] }, "dangerous": true, "command": "pulse-log stop {pid}" },
                { "id": "deeper", "title": "Deeper", "rows": "procs", "key": "return", "readonly": true, "only": { "command": ["first"] }, "command": "echo {pid} {command}", "output": "list",
                  "list": { "format": "lines", "key": "{line}", "empty": "nothing in {command}" }, "actions": [ { "id": "here", "title": "Here", "key": "return", "readonly": true, "command": "pulse-log here {pid} {line}" } ] },
                { "id": "pidcopy", "title": "Copy PID", "rows": "procs", "key": "cmd+c", "readonly": true, "only": { "command": ["second"] }, "command": "pulse-log copy {pid}" },
                { "id": "log", "title": "Log", "readonly": true, "command": "pulse-log {from} {to}" } ],
              "toolActions": [ { "id": "ssh", "title": "Terminal", "goto": "ssh" }, { "id": "svc", "title": "Services", "goto": "services:{server}.service" },
                               { "id": "calm", "title": "Calm…", "confirm": true, "command": "pulse-log calm" } ] }
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
        let queue = DispatchQueue(label: "local-web")   // its own: a busy run's global queues answered 10 s late
        listener.newConnectionHandler = { c in
            c.start(queue: queue)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let words = String(decoding: data ?? Data(), as: UTF8.self).split(separator: " ")
                let head = "HTTP/1.1 \(answer(words.count > 1 ? String(words[1]) : "/")) X\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                c.send(content: Data(head.utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
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
               target: ToolMonitor.target, grace: ToolMonitor.wakeGrace, power: ToolMonitor.power)
    init(_ app: AppDelegate) {
        self.app = app
        ToolMonitor.tick = 0.2
        ToolMonitor.backoff = [0.3]
        ToolMonitor.login = { _, _ in }
        ToolMonitor.target = { _ in .local() }
        ToolMonitor.wakeGrace = 0   // a Wi-Fi flap during the run mustn't hold "not answering" back
        ToolMonitor.power = { (false, false) }   // the Mac on battery mustn't make every interval three times longer
        ToolRunner.watching = { _, _ in true }
    }
    func done() {
        app.tools.settings = ToolServers()
        closeWindows()
        app.tools.monitor.reconcile()
        (ToolMonitor.tick, ToolMonitor.backoff, ToolMonitor.login, ToolRunner.watching, ServerLock.authenticate, ToolMonitor.target, ToolMonitor.wakeGrace,
         ToolMonitor.power) = was
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
@MainActor private func watching(_ app: AppDelegate, _ bench: ToolsBench, ids: [String] = ["pulse"], servers: [SavedServer]? = nil, list: Bool = false) async throws {
    try pulse(bench, ids, list: list)
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
/// A dashboard table's row buttons (its last column), the row's view made if the table hasn't drawn yet: only the
/// cursor's row and the one under the pointer have them.
@MainActor private func rowButtons(_ t: ToolsTable, _ row: Int) -> [NSButton] {
    t.table.view(atColumn: t.table.numberOfColumns - 1, row: row, makeIfNecessary: true).map(buttons) ?? []
}
@MainActor private func press(_ b: NSButton?) { _ = (b?.target as? NSObject)?.perform(b?.action, with: b) }
/// A menu's item by its title, chosen.
@MainActor private func choose(_ m: NSMenu, _ title: String) {
    if let i = m.items.firstIndex(where: { $0.title == title }) { m.performActionForItem(at: i) } else { Issue.record("no \(title) in \(m.items.map(\.title))") }
}

/// dpl's state folder under `base` (`{unit}/deploy.json`, api's YAML), a `dpl` that says its version, and a sudo for
/// the root SFTP session: it lets `-n --` through, or (`refuses`) wants a password — its calls in `sftp-sudo.log`.
@MainActor private func dplState(_ bench: ToolsBench, _ base: String, refuses: Bool = false) throws -> String {
    let fm = FileManager.default
    for (unit, json) in [("api", #"{"kind": "app", "active_version": 3, "last_version": 3, "last_status": "ready"}"#),
                         ("web", #"{"kind": "http-server", "active_version": 1, "last_version": 1, "last_status": "ready"}"#),
                         ("shop", #"{"kind": "domain", "active_version": 4, "last_version": 4, "last_status": "ready"}"#),
                         ("first", #"{"kind": "app", "last_version": 1, "last_status": "failed", "failure": {"stage": "build"}}"#)] {
        try fm.createDirectory(atPath: "\(base)/state/\(unit)", withIntermediateDirectories: true)
        try Data(json.utf8).write(to: URL(fileURLWithPath: "\(base)/state/\(unit)/deploy.json"))
    }
    try fm.createDirectory(atPath: base + "/conf", withIntermediateDirectories: true)
    try Data("image: x\nstrategy: parallel\n".utf8).write(to: URL(fileURLWithPath: base + "/conf/api.yaml"))
    try Data("#!/bin/sh\n[ \"$1\" = --version ] && echo 'dpl 0.7.1'\n".utf8).write(to: URL(fileURLWithPath: bench.dir + "/bin/dpl"))
    chmod(bench.dir + "/bin/dpl", 0o755)
    let sudo = bench.dir + "/sftp-sudo"
    try Data(("#!/bin/sh\necho \"$*\" >> \(bench.dir)/sftp-sudo.log\n" + (refuses ? "echo 'sudo: a password is required' >&2\nexit 1\n"
              : "[ \"$1\" = -n ] && [ \"$2\" = -- ] || exit 2\nshift 2\nexec \"$@\"\n")).utf8).write(to: URL(fileURLWithPath: sudo))
    chmod(sudo, 0o755)
    return sudo
}

/// dpl's tab on localhost with `base` as its folder, the target its sudo's.
@MainActor private func dplTab(_ app: AppDelegate, _ bench: ToolsBench, _ base: String, sudo: String) async throws -> (ToolsPage, SFTPTarget) {
    try await watching(app, bench)
    app.tools.settings.setVars("dpl", on: app.savedServers[0].id.uuidString, ["base": base])
    let t = SFTPTarget.local(sudo: sudo).asRoot(false)
    _ = app.tools.here(t)
    await toolsUntil { app.tools.here(t)?.tools.contains { $0.preset.id == "dpl" } == true }
    ToolsWindow.show(app, server: t)
    let page = try #require(ToolsWindow.main?.page)
    #expect(page.liveTool?.preset.id == "dpl", "its first tab: live once the window shows")
    return (page, t)
}

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
        #expect(app.idleServers([SavedServer(address: "localhost")!.target]).isEmpty, "a live tab's connection isn't idle")
        let p = pid(bench)
        #expect(alive(p))

        page.select("fail2ban")
        await toolsUntil { app.tools.monitor.server(.local())?.channel == nil && !alive(p) }
        #expect(app.tools.monitor.server(.local())?.channel == nil && !alive(p), "the stream ended on the server")
        #expect(t.history.points("cpu").last?.gap == .notWatched && !t.live)
        #expect(!app.idleServers([SavedServer(address: "localhost")!.target]).isEmpty, "the tab left: idle again")
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
        await toolsUntil { page.tabs.image(forSegment: page.tabs.selectedSegment)?.isTemplate == true }   // the page draws it after the sample
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
        UserDefaults.standard.removeObject(forKey: "toolsTableHeights")   // an earlier run's drag
        defer { quick.done(); bench.done(); done(); app.savedServers = []; UserDefaults.standard.removeObject(forKey: "toolsTableHeights") }
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
        // Its grip: dragged down 40 pt, 40 pt taller, kept as the drag ends; up past its rows, a row and the header
        // stay; a click that doesn't move keeps nothing; a double-click (its jitter after) goes back to its rows.
        let scroll = try #require(table.table.enclosingScrollView), grip = table.grip, wn = page?.window?.windowNumber ?? 0
        func mouse(_ type: NSEvent.EventType, _ y: CGFloat, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: y), modifierFlags: [], timestamp: 0, windowNumber: wn, context: nil, eventNumber: 0,
                               clickCount: clicks, pressure: 1)!
        }
        func kept() -> Any? { UserDefaults.standard.dictionary(forKey: "toolsTableHeights")?["pulse.procs"] }
        let rowsTall = scroll.frame.height
        grip.mouseDown(with: mouse(.leftMouseDown, 300))
        grip.mouseDragged(with: mouse(.leftMouseDragged, 299))
        grip.mouseUp(with: mouse(.leftMouseUp, 299))
        #expect(kept() == nil, "a click, though it wobbled a point, keeps nothing")
        grip.mouseDown(with: mouse(.leftMouseDown, 300))
        grip.mouseDragged(with: mouse(.leftMouseDragged, 280))
        grip.mouseDragged(with: mouse(.leftMouseDragged, 260))
        page?.window?.layoutIfNeeded()
        #expect(abs(scroll.frame.height - rowsTall - 40) < 1 && kept() == nil, "taller as it goes, kept only at the end: \(scroll.frame.height) \(rowsTall)")
        grip.mouseUp(with: mouse(.leftMouseUp, 260))
        #expect(kept() != nil)
        grip.mouseDown(with: mouse(.leftMouseDown, 300))
        grip.mouseDragged(with: mouse(.leftMouseDragged, 900))   // up a long way
        grip.mouseUp(with: mouse(.leftMouseUp, 900))
        page?.window?.layoutIfNeeded()
        #expect(scroll.frame.height > (table.table.headerView?.frame.height ?? 23) + table.table.rowHeight && scroll.hasVerticalScroller)
        grip.mouseDown(with: mouse(.leftMouseDown, 300, clicks: 2))
        grip.mouseDragged(with: mouse(.leftMouseDragged, 297, clicks: 2))
        grip.mouseUp(with: mouse(.leftMouseUp, 297, clicks: 2))
        page?.window?.layoutIfNeeded()
        #expect(abs(scroll.frame.height - rowsTall) < 1 && kept() == nil && !scroll.hasVerticalScroller)
        #expect(hosting?.window != nil && charts.range.segmentCount == 3 && charts.range.selectedSegment == 0)
        let d = charts.model.data
        #expect(d.charts.map(\.title) == ["CPU", "Ticks", "Process memory · CPU"] && d.charts[0].top == 100 && d.charts[0].warn == 85 && d.charts[0].crit == 95 && d.charts[1].warn == nil)
        // Two metrics in one chart: the first one's thresholds; a key named with its metric; every series counted.
        #expect(d.charts[2].warn == 50 && d.charts[2].lines.map(\.name) == ["Process memory 1", "Process memory 2", "CPU"] && d.charts[2].of == 3, "\(d.charts[2].lines.map(\.name))")
        #expect(d.charts[0].lines.first?.chart.runs.last?.last?.value == 99 && d.to.timeIntervalSince(d.from) == 3600, "\(d.charts[0].lines.first?.points.suffix(2) ?? [])")
        let model = ToolsCharts.Model()   // its own: the pointer may be over the window's charts, hovering
        (model.data, model.every) = (d, charts.model.every)
        let one = OneChart(chart: d.charts[0], model: model)
        #expect(one.said == "Now 99%" && one.spoken == "Now, 99%", "\(one.said)")
        model.hover = d.charts[0].lines.first?.points.last?.at
        #expect(one.said.hasSuffix(" · 99%") && !one.said.hasPrefix("Now"), "\(one.said)")
        #expect(d.click == "Click: the tables at this time", "a table to show the moment in")
        // Two to a row where each gets 300 pt, else one.
        for (width, columns) in [(400.0, 1), (700.0, 2)] {
            charts.setFrameSize(NSSize(width: width, height: charts.frame.height))
            charts.layout()
            #expect(charts.model.columns == columns, "\(width) pt: \(charts.model.columns)")
        }
        page?.window?.layoutIfNeeded()
        #expect(table.rows.map(\.key) == ["1", "2"] && table.rows.map(\.title) == ["first", "second"] && table.rows[1].cells.map(\.text) == ["second", "20 %", "40", "2"], "\(table.rows)")
        #expect(table.table.numberOfRows == 2 && table.table.tableColumns.map(\.title) == ["Command", "Cpu", "Mem", "Pid", ""], "\(table.table.numberOfRows) \(table.table.tableColumns.map(\.title))")
        // Buttons only on the cursor's row and the one under the pointer: two that can be undone, ⋯ the rest; Stop…
        // (dangerous) never a button — red in the row's menu, with every action of the row.
        #expect(rowButtons(table, 0).isEmpty && rowButtons(table, 1).isEmpty, "no cursor, no pointer: no buttons")
        table.table.selectRowIndexes([0], byExtendingSelection: false)
        table.hover = 1
        let first = rowButtons(table, 0)
        #expect(first.map(\.title) == ["Folder", "Deeper", "⋯"] && rowButtons(table, 1).map(\.title) == ["Folder", "Copy PID", "⋯"], "only: Deeper on first's row \(first.map(\.title))")
        try #require(first.count == 3)
        #expect(first.allSatisfy { $0.isEnabled }, "a level runs now")
        let menus = table.rows.map { table.rowMenu($0) }
        #expect(menus.map { $0.items.map(\.title) } == [["Folder", "Stop…", "Deeper", "", "Copy", "Copy Table"], ["Folder", "Stop…", "Copy PID", "", "Copy", "Copy Table"]],
                "\(menus.map { $0.items.map(\.title) })")
        #expect(menus[0].items[1].attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Palette.fail, "dangerous: red")
        #expect(menus[0].items[4].keyEquivalent == "c" && menus[1].items[2].keyEquivalent == "c" && menus[1].items[4].keyEquivalent == "",
                "⌘C: Copy, or the row's own ⌘C action")
        table.hover = nil
        table.table.deselectAll(nil)
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
        table.table.selectRowIndexes([0], byExtendingSelection: false)   // the cursor's row has the buttons; Stop… is in its menu
        choose(table.rowMenu(table.rows[0]), "Stop…")
        await toolsUntil { !page.result.stringValue.isEmpty }
        #expect(asked.first?.0 == "Stop on localhost?" && asked.first?.1 == ["Stop", "Show Exactly What Runs", "Cancel"] && asked.first?.2 == 2, "\(asked)")
        #expect(page.result.stringValue == "Stop: cancelled — nothing ran")
        choose(table.rowMenu(table.rows[0]), "Stop…")
        await toolsUntil { page.result.stringValue.contains("Stop: done") }
        #expect(page.result.stringValue.contains("Stop: done on localhost at ") && asked.count == 2, "\(page.result.stringValue) \(asked.map(\.0))")
        #expect(bench.calls.contains("pulse-log stop 1"), "the row's pid in the command: \(bench.calls)")
        // One that always asks (`confirm`) is asked with ↩ = Cancel too, as one that can't be undone.
        let calm = ToolListSource(app, try toolNamed(app, "pulse"), app.savedServers[0], .local()).listActions(nil).first { $0.title == "Calm…" }
        AppDelegate.answering = { m, b, d in asked.append((m, b, d)); return d ?? 0 }   // ↩
        _ = try #require(calm).run(false)
        await toolsUntil { asked.count == 3 }
        #expect(asked.last?.1 == ["Calm", "Show Exactly What Runs", "Cancel"] && asked.last?.2 == 2 && !bench.calls.contains("pulse-log calm"), "\(asked.last.map { "\($0)" } ?? "")")

        nonisolated(unsafe) var shown: [(SFTPTarget, String)] = []
        ToolRunner.reveal = { _, t, path in shown.append((t, path)) }
        press(rowButtons(table, 0).first { $0.title == "Folder" })
        await toolsUntil { !shown.isEmpty }
        #expect(shown.map(\.1) == ["/tmp/pulse-1"] && bench.calls.contains("pulse-dir 1") && asked.count == 3, "readonly: no question; what it printed opens")

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

    /// A dashboard table keeps its cursor on its row's key (review 3, PR A): through a sample that reorders the rows,
    /// and gone with its row — never on the neighbour. Under the pointer the rows hold still: values change in place,
    /// the order and the set wait, the note says so; the pointer gone, the latest go at once. A sample that changes one
    /// row draws that row alone. The alert on a column colors its bar and number, yours as Thresholds… set them. The
    /// note says how often and when; a server that stops answering dims the rows, "as of".
    @Test func aDashboardTableKeepsItsCursorAndHoldsStillUnderThePointer() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app), kept = ["toolsTableSort", "toolsTableColumns"]
        kept.forEach(UserDefaults.standard.removeObject)   // an earlier run's sort or columns
        defer { quick.done(); bench.done(); done(); app.savedServers = []; kept.forEach(UserDefaults.standard.removeObject) }
        try await watching(app, bench)
        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page)
        page.select("pulse")
        await toolsUntil { (live(page)?.blocks.compactMap { $0 as? ToolsTable }.first?.rows.count ?? 0) == 2 }
        let table = try #require(live(page)?.blocks.compactMap { $0 as? ToolsTable }.first), t = table.table
        func keys() -> [String] { table.rows.map(\.key) }
        func cursor() -> String? { table.rows.indices.contains(t.selectedRow) ? table.rows[t.selectedRow].key : nil }
        try #require(keys() == ["1", "2"])

        t.selectRowIndexes([0], byExtendingSelection: false)
        bench.flag("swap-localhost")
        await toolsUntil { keys() == ["2", "1"] }
        #expect(keys() == ["2", "1"] && cursor() == "1" && t.selectedRow == 1, "the cursor follows its row's key")
        #expect(rowButtons(table, 1).first?.title == "Folder" && rowButtons(table, 0).isEmpty, "its buttons with it")
        bench.flag("lone-localhost")
        await toolsUntil { keys() == ["2"] }
        #expect(keys() == ["2"] && t.selectedRow == -1 && cursor() == nil, "its row gone: no cursor — not the neighbour")
        bench.flag("lone-localhost", false)
        await toolsUntil { keys() == ["2", "1"] }

        // A move over a row — no entry came: the window became key with the pointer there — holds the rows and shows
        // that row's buttons; a move's event names no tracking area.
        let p = t.convert(NSPoint(x: 5, y: t.rect(ofRow: 1).midY), to: nil)
        table.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: 0, windowNumber: t.window?.windowNumber ?? 0,
                                                  context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
        #expect(table.pointerInside && table.hover == 1 && rowButtons(table, 1).first?.title == "Folder", "\(String(describing: table.hover))")
        table.pointerInside = false

        // Held: the pointer over the rows. A new order and a new set wait; values change in place.
        table.pointerInside = true
        bench.flag("swap-localhost", false)
        bench.flag("lone-localhost")
        bench.flag("busy-localhost")
        await toolsUntil { table.rows[0].cells[1].text != "20 %" }
        #expect(keys() == ["2", "1"] && table.rows[0].cells[1].text != "20 %" && table.holding && table.note.stringValue.hasSuffix(" · held under the pointer"),
                "\(keys()) \(table.note.stringValue)")
        bench.flag("lone-localhost", false)
        for _ in 0..<2 {   // two samples after: one has both rows again
            let was = table.rows[0].cells[1].text
            await toolsUntil { table.rows[0].cells[1].text != was }
        }
        #expect(keys() == ["2", "1"] && table.holding)
        table.pointerInside = false
        #expect(keys() == ["1", "2"] && !table.holding && !table.note.stringValue.contains("held"), "the pointer gone: the latest at once \(keys())")
        // An open menu holds them too.
        let menu = table.rowMenu(table.rows[0])
        table.menuWillOpen(menu)
        bench.flag("swap-localhost")
        await toolsUntil { table.holding }
        #expect(keys() == ["1", "2"] && table.note.stringValue.hasSuffix(" · held while its menu is open"), "\(table.note.stringValue)")
        table.menuDidClose(menu)
        #expect(keys() == ["2", "1"] && !table.holding)
        bench.flag("swap-localhost", false)
        await toolsUntil { keys() == ["1", "2"] }

        // A sample that changes the second row draws it alone: the first row's views stay.
        let firstViews = (0..<t.numberOfColumns - 1).map { t.view(atColumn: $0, row: 0, makeIfNecessary: true) }
        var made = Set<ObjectIdentifier>()
        func cells() -> Set<ObjectIdentifier> { Set((0..<t.numberOfRows).flatMap { r in (0..<t.numberOfColumns - 1).compactMap { t.view(atColumn: $0, row: r, makeIfNecessary: false).map(ObjectIdentifier.init) } }) }
        made = cells()
        var samples = 0, newViews = 0
        for _ in 0..<3 {
            let was = table.rows[1].cells[1].text, drawn = table.drawn
            await toolsUntil { table.rows[1].cells[1].text != was }
            let n = t.numberOfColumns - 1, d = table.drawn - drawn   // a sample or two came: one row's cells each
            #expect(d > 0 && d % n == 0 && d <= 2 * n, "one row's cells drawn again: \(d)")
            let now = cells()
            (samples, newViews, made) = (samples + 1, newViews + now.subtracting(made).count, made.union(now))
        }
        #expect(zip(firstViews, (0..<t.numberOfColumns - 1).map { t.view(atColumn: $0, row: 0, makeIfNecessary: false) }).allSatisfy { $0 != nil && $0 === $1 },
                "the first row's cells weren't made again")
        print("ToolsTable: \(newViews) cell views made over \(samples) samples")

        // The alert on Mem: its bar's thresholds and, past one, the number's color; yours as Thresholds… set them.
        bench.flag("busy-localhost", false)
        func mem(_ key: String) -> ToolsBarCell? { table.rows.firstIndex { $0.key == key }.flatMap { t.view(atColumn: 2, row: $0, makeIfNecessary: true) as? ToolsBarCell } }
        #expect(mem("2")?.bar.warningValue == 50 && mem("2")?.bar.criticalValue == 95 && mem("2")?.text.textColor == .labelColor && mem("2")?.text.stringValue == "40 %",
                "\(String(describing: mem("2")?.text.stringValue))")
        bench.flag("warm-localhost")
        await toolsUntil { mem("2")?.text.textColor == Palette.warn }
        #expect(mem("2")?.text.textColor == Palette.warn && mem("1")?.text.textColor == .labelColor, "past 50: the second's number in the warning's color, the first's not")
        app.tools.settings.setThreshold(.init(warn: 70, crit: 90), alert: "pmem", of: "pulse", on: nil)
        await toolsUntil { mem("2")?.bar.warningValue == 70 && mem("2")?.text.textColor == .labelColor }
        #expect(mem("2")?.bar.warningValue == 70 && mem("2")?.bar.criticalValue == 90 && mem("2")?.text.textColor == .labelColor, "yours: 60 is under your 70")

        // How often and when; not answering: dimmed, "as of".
        #expect(table.note.stringValue.hasPrefix("every ") && table.table.enclosingScrollView?.alphaValue == 1, "\(table.note.stringValue)")
        let s = try #require(app.tools.monitor.server(.local()))
        kill(try #require(pid(bench)), SIGSTOP)
        await toolsUntil { s.down != nil && table.note.stringValue.hasPrefix("as of ") }
        #expect(table.note.stringValue.hasPrefix("as of ") && table.table.enclosingScrollView?.alphaValue == 0.5, "\(table.note.stringValue)")
        kill(try #require(pid(bench)), SIGCONT)
        await toolsUntil { s.down == nil && !table.note.stringValue.hasPrefix("as of ") }
        #expect(table.table.enclosingScrollView?.alphaValue == 1, "\(table.note.stringValue)")
    }

    /// A header click sorts — a number by its value, the most first — and the sort is kept for the table; the header's
    /// menu hides a column, kept with its width; ⌘C copies the cursor's row as shown (the columns shown, tab-separated),
    /// or runs the row's own ⌘C action; Copy Table all of it with the headers; ↩ and a double-click its `return` action.
    @Test func aDashboardTableSortsCopiesAndKeepsItsColumns() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app), keys = ["toolsTableSort", "toolsTableColumns"]
        keys.forEach(UserDefaults.standard.removeObject)
        defer { quick.done(); bench.done(); done(); app.savedServers = []; keys.forEach(UserDefaults.standard.removeObject); Picker.dismiss() }
        try await watching(app, bench)
        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page)
        page.select("pulse")
        await toolsUntil { (live(page)?.blocks.compactMap { $0 as? ToolsTable }.first?.rows.count ?? 0) == 2 }
        let view = try #require(live(page)), table = try #require(view.blocks.compactMap { $0 as? ToolsTable }.first), t = table.table
        func col(_ id: String) -> NSTableColumn? { t.tableColumn(withIdentifier: .init(id)) }
        #expect(col("cpu")?.sortDescriptorPrototype?.ascending == false && col("mem")?.sortDescriptorPrototype?.ascending == false
                && col("command")?.sortDescriptorPrototype?.ascending == true && col("actions")?.sortDescriptorPrototype == nil, "a number's first click: the most first")
        t.sortDescriptors = [try #require(col("cpu")?.sortDescriptorPrototype)]   // a click on CPU
        #expect(table.rows.map(\.key) == ["2", "1"] && UserDefaults.standard.dictionary(forKey: "toolsTableSort")?["pulse.procs"] as? String == "cpu:0")
        try await Task.sleep(for: .milliseconds(700))   // samples come: the order stays
        #expect(table.rows.map(\.key) == ["2", "1"])

        // The header's menu: every column but the first; Pid hidden, Cpu wider — kept a moment later.
        let header = NSMenu()
        table.fillHeader(header)
        #expect(header.items.map(\.title) == ["Cpu", "Mem", "Pid", "", "Copy Table"] && header.items[0].state == .on)
        choose(header, "Pid")
        col("cpu")?.width = 90
        #expect(table.tableView(t, shouldReorderColumn: 0, toColumn: 2) == false && table.tableView(t, shouldReorderColumn: 1, toColumn: 0) == false
                && table.tableView(t, shouldReorderColumn: 1, toColumn: 4) == false && table.tableView(t, shouldReorderColumn: 2, toColumn: 1), "the first stays first, the buttons last")
        await toolsUntil { (UserDefaults.standard.dictionary(forKey: "toolsTableColumns")?["pulse.procs"] as? [String]) != nil }
        #expect(UserDefaults.standard.dictionary(forKey: "toolsTableColumns")?["pulse.procs"] as? [String] == ["cpu:90", "mem:100", "-pid:64"])

        // ⌘C: the cursor's row as shown — no Pid, no buttons; the second's own ⌘C action instead; Copy Table.
        table.pasteboard = NSPasteboard(name: .init("kermo-tests-\(UUID().uuidString)"))
        defer { table.pasteboard.releaseGlobally() }
        let first = try #require(table.rows.firstIndex { $0.key == "1" }), second = 1 - first
        t.selectRowIndexes([first], byExtendingSelection: false)
        t.copy(nil)
        let one = table.rows[first].cells
        #expect(table.pasteboard.string(forType: .string) == "first\t\(one[1].text)\t30 %", "\(table.pasteboard.string(forType: .string) ?? "")")
        t.selectRowIndexes([second], byExtendingSelection: false)
        table.pasteboard.clearContents()
        t.copy(nil)
        await toolsUntil { bench.calls.contains("pulse-log copy 2") }
        #expect(bench.calls.contains("pulse-log copy 2") && table.pasteboard.string(forType: .string) == nil, "the row's ⌘C action: \(bench.calls)")
        table.copyTable()
        #expect(table.pasteboard.string(forType: .string) == "Command\tCpu\tMem\nsecond\t20 %\t40 %\nfirst\t\(one[1].text)\t30 %", "\(table.pasteboard.string(forType: .string) ?? "")")
        #expect(ListPanel.tsv([["a\tb", "c\nd\r\ne"], ["f"]]) == "a b\tc d e\nf", "a tab or a line break in a text: a space")

        // ↩ and a double-click: the row's `return` action (Deeper, a level, on first's row); none on second's.
        t.selectRowIndexes([first], byExtendingSelection: false)
        t.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                         characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        let p = try #require(Picker.current)
        await toolsUntil { !p.rows.isEmpty }
        #expect(p.scopeNames == ["localhost › Pulse › first"], "\(p.scopeNames)")
        Picker.dismiss()
        table.open(second, beep: false)
        #expect(Picker.current == nil, "second's row: no ↩ action")
        table.open(first, beep: false)
        #expect(Picker.current?.scopeNames == ["localhost › Pulse › first"], "a double-click as ↩")
        Picker.dismiss()

        // Made again (the window reopened): the sort, the hidden column and the width as kept.
        let again = ToolsTable(view, table.block)
        #expect(again.table.sortDescriptors.first?.key == "cpu" && again.table.sortDescriptors.first?.ascending == false)
        #expect(again.table.tableColumns.map { "\($0.identifier.rawValue) \(Int($0.width)) \($0.isHidden)" }.dropFirst()
                == ["cpu 90 false", "mem 100 false", "pid 64 true", "actions \(Int(col("actions")?.width ?? 0)) false"], "\(again.table.tableColumns.map(\.width))")
    }

    /// A column's `tip` and `help` (review 3, PR B): the command line over the command — the text stays the command,
    /// ⌘C and Copy Table never take it; a row without one, its text. The heading's help. Stop… only on a user's
    /// process: a row of this connection (`kind: self`) has none in its menu.
    @Test func aDashboardTablesTipsHelpAndKinds() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app)
        defer { quick.done(); bench.done(); done(); app.savedServers = [] }
        try await watching(app, bench)
        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page)
        page.select("pulse")
        await toolsUntil { (live(page)?.blocks.compactMap { $0 as? ToolsTable }.first?.rows.count ?? 0) == 2 }
        let table = try #require(live(page)?.blocks.compactMap { $0 as? ToolsTable }.first), t = table.table
        try #require(table.rows.map(\.key) == ["1", "2"])
        func label(_ r: Int) -> NSTextField? { t.view(atColumn: 0, row: r, makeIfNecessary: true) as? NSTextField }
        #expect(label(0)?.stringValue == "first" && label(0)?.toolTip == #"first --name "a b""# && label(1)?.toolTip == "second", "\(label(0)?.toolTip ?? "")")
        #expect(t.tableColumns[1].headerToolTip == "% of one core" && t.tableColumns[0].headerToolTip == nil)
        table.pasteboard = NSPasteboard(name: .init("kermo-tests-\(UUID().uuidString)"))
        defer { table.pasteboard.releaseGlobally() }
        table.copyTable()
        #expect(table.pasteboard.string(forType: .string)?.contains("--name") == false, "\(table.pasteboard.string(forType: .string) ?? "")")
        func items(_ r: Int) -> [String] { table.rowMenu(table.rows[r]).items.map(\.title) }
        #expect(items(0).contains("Stop…") && items(1).contains("Stop…"))
        bench.flag("self-localhost")
        await toolsUntil { table.rows.last?.record["kind"] == "self" }
        #expect(items(0).contains("Stop…") && !items(1).contains("Stop…"), "\(items(1))")
    }

    /// Review 3, T11 "who was it?": a click on the last hour's chart shows every table as it was then — the nearest
    /// rows at or before it, read only (Copy, Copy Table, Back to Live; no buttons, ↩ runs nothing), held there as new
    /// samples come, a line at that moment on the charts — till Back to Live (⎋). A click in a band or before watching
    /// began: nothing recorded then. On 24h and 7d (no rows kept) a click is the log, as before.
    @Test func aChartsClickShowsTheTablesAsTheyWereThen() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app)
        defer { quick.done(); bench.done(); done(); app.savedServers = [] }
        try await watching(app, bench)
        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page)
        page.select("pulse")
        await toolsUntil { (live(page)?.blocks.compactMap { $0 as? ToolsTable }.first?.rows.count ?? 0) == 2 }
        let view = try #require(live(page)), table = try #require(view.blocks.compactMap { $0 as? ToolsTable }.first)
        let charts = try #require(view.blocks.compactMap { $0 as? ToolsCharts }.first)
        let then = try #require(app.tools.monitor.tool("pulse", on: .local())?.history.carried("procs")?.at)
        #expect(view.showsMoments && view.momentBar.isHidden && view.chartLog == "log")
        bench.flag("lone-localhost")
        await toolsUntil { table.rows.map(\.key) == ["2"] }
        table.table.selectRowIndexes([0], byExtendingSelection: false)
        let drawn = rowButtons(table, 0)   // the live row's, drawn before the moment
        try #require(drawn.contains { $0.title == "Folder" })
        charts.model.clicked(then, nil)
        press(drawn.first { $0.title == "Folder" })
        try await Task.sleep(for: .milliseconds(300))
        #expect(!bench.calls.contains { $0.hasPrefix("pulse-dir") }, "a button drawn before the moment runs nothing in it: \(bench.calls)")
        #expect(view.moment != nil && !view.momentBar.isHidden && view.momentText.stringValue.hasPrefix("As of "), "\(view.momentText.stringValue)")
        #expect(table.rows.map(\.key) == ["1", "2"] && table.note.stringValue.hasPrefix("as of "), "the rows then: \(table.note.stringValue)")
        #expect(charts.model.moment == view.moment, "a line at that moment on the charts")
        #expect(table.rowMenu(table.rows[0]).items.map(\.title).filter { !$0.isEmpty } == ["Copy", "Copy Table", "Back to Live"], "a moment's rows: no action")
        let calls = bench.calls.count
        table.table.selectRowIndexes([0], byExtendingSelection: false)
        table.open(0, beep: false)   // ↩: Deeper, live; nothing on a moment's row
        #expect(rowButtons(table, 0).isEmpty && bench.calls.count == calls)
        try await Task.sleep(for: .seconds(1))
        #expect(table.rows.map(\.key) == ["1", "2"], "new samples don't move a moment")
        #expect(view.liveButton.keyEquivalent == "\u{1b}")
        press(view.liveButton)
        #expect(view.moment == nil && view.momentBar.isHidden && table.rows.map(\.key) == ["2"] && charts.model.moment == nil, "Back to Live: the rows now")
        charts.model.clicked(then, .asleep)
        #expect(view.momentText.stringValue.hasPrefix("Mac asleep at ") && view.momentText.stringValue.hasSuffix("nothing recorded then"), "\(view.momentText.stringValue)")
        charts.model.clicked(then.addingTimeInterval(-3600), nil)
        #expect(table.rows.isEmpty && table.note.stringValue.hasPrefix("nothing recorded at") && view.momentText.stringValue.hasPrefix("Nothing recorded at "),
                "before watching began: \(table.note.stringValue) — \(view.momentText.stringValue)")
        press(view.liveButton)
        charts.range.selectedSegment = 1   // 24h
        charts.model.clicked(Date(timeIntervalSince1970: 1_800_000_000), nil)
        await toolsUntil { bench.calls.contains("pulse-log 1799999850 1800000150") }
        #expect(view.moment == nil && bench.calls.contains("pulse-log 1799999850 1800000150"), "on 24h a click is the log: \(bench.calls)")
    }

    /// Review 3, T12: a table's All Processes… opens the tool's list in a Picker over the Tools window — the busiest
    /// by CPU first, the line above saying how many were cut, a filter's "No matches" too; the list's rows have the table's
    /// actions by their `kind` (none on this connection's), never the chart's log. In a panel the command line is the
    /// command's tooltip and the CPU heading's help its own, ⌘C without them. A table's action reads no list after it.
    @Test func allProcessesOpensTheToolsList() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app)
        defer { quick.done(); bench.done(); done(); app.savedServers = []; Picker.dismiss() }
        try await watching(app, bench, list: true)
        ToolsWindow.show(app, server: .local())
        let w = try #require(ToolsWindow.main), page = try #require(w.page)
        page.select("pulse")
        await toolsUntil { (live(page)?.blocks.compactMap { $0 as? ToolsTable }.first?.rows.count ?? 0) == 2 }
        let table = try #require(live(page)?.blocks.compactMap { $0 as? ToolsTable }.first)
        press(buttons(table).first { $0.title == "All Processes…" })
        let p = try #require(Picker.current)
        await toolsUntil { !p.rows.isEmpty }
        #expect(p.panel.parent === w.window && p.scopeNames == ["localhost › Pulse"], "\(p.scopeNames)")
        #expect(p.rows.map(\.title) == ["second", "first"] && p.headerSaid == "the top 2 of 3 by CPU", "\(p.rows.map(\.title)) \(p.headerSaid)")
        func titles(_ t: String) -> [String] { p.rows.first { $0.title == t }?.listActions?().map(\.title) ?? [] }
        #expect(titles("first").contains("Stop…") && titles("first").contains("Deeper") && !titles("first").contains("Log"), "\(titles("first"))")
        #expect(!titles("second").contains("Stop…") && titles("second").contains("Folder"), "this connection's: no Stop… — \(titles("second"))")
        p.field.stringValue = "zzz"
        p.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: p.field))
        #expect(p.emptySaid == "No matches among the 2 shown", "\(p.emptySaid)")
        Picker.dismiss()

        let tool = try #require(app.tools.library.tools.first { $0.preset.id == "pulse" }), server = try #require(app.savedServers.first)
        let source = ToolListSource(app, tool, server, .local())
        #expect(source.relister != nil && source.every == nil)
        source.table = "procs"
        #expect(source.relister == nil, "a table's action: its rows come from watching, nothing reads the list after it")
        app.active.showList(ToolListSource(app, tool, server, .local()))
        await toolsUntil { app.active.list?.content != nil }
        let t = app.active.table
        let first = try #require(app.active.list?.shown.firstIndex { $0.title == "first" })
        #expect(t.view(atColumn: 0, row: first, makeIfNecessary: true)?.toolTip == "first --token=s3cret")
        #expect(t.tableColumns[1].headerToolTip == "% of one core")
        t.selectRowIndexes([first], byExtendingSelection: false)
        let pb = NSPasteboard(name: .init("kermo-tests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        app.listKey(Shortcut("cmd+c")!, in: app.active, pasteboard: pb)
        #expect(pb.string(forType: .string)?.hasPrefix("first\t") == true && pb.string(forType: .string)?.contains("s3cret") == false, "\(pb.string(forType: .string) ?? "")")
    }

    /// A chart's header and tip (review 4): "Now" and the latest — why there are none in a gap —, the time under the
    /// pointer, "At" the moment the tables show; the tip names each series with its value — a slot's lowest, average and
    /// highest on the history —, says the gap, the events near, the lines not drawn and what a click does.
    @Test func aChartsHeaderAndTipSayWhenAndWhat() throws {
        let ms = try JSONDecoder().decode(ToolMetric.self, from: Data(#"{ "title": "Response", "unit": "ms" }"#.utf8))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // a slot's start
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        func line(_ name: String, _ pts: [ToolPoint]) -> ToolsCharts.Line { .init(id: "latency \(name)", name: name, points: pts, chart: ToolChart(pts, now: at(60))) }
        let lines = [line("a.example", [.init(at: at(0), value: 10), .init(at: at(5), gap: .asleep), .init(at: at(20), value: 20)]),
                     line("b.example", [.init(at: at(0), value: 30), .init(at: at(5), gap: .asleep), .init(at: at(20), value: 40)])]
        let chart = ToolsCharts.Chart(id: "latency", title: "Response", metric: ms, top: 50, lines: lines, bands: lines[0].chart.bands, of: 8)
        let model = ToolsCharts.Model()
        model.every = 5
        model.data = .init(charts: [chart], from: at(-3540), to: at(60), events: [.init(at: at(1), id: "slow", level: "warning", message: "a.example is slow")],
                           click: "Click: the tables at this time")
        let one = OneChart(chart: chart, model: model)
        #expect(one.said == "Now \(ms.text(20)) · \(ms.text(40))" && one.spoken == "Now, a.example \(ms.text(20)), b.example \(ms.text(40))", "\(one.said) | \(one.spoken)")
        model.hover = at(0)
        #expect(one.said == model.time(at(0)) + " · \(ms.text(10)) · \(ms.text(30))", "\(one.said)")
        let tip = OneChart.tip(chart, model, at: at(0))
        #expect(tip.rows.map(\.name) == ["a.example", "b.example"] && tip.rows.map(\.value) == [ms.text(10), ms.text(30)] && tip.rows.map(\.color) == [0, 1])
        #expect(tip.notes == ["Warning \(at(1).formatted(date: .omitted, time: .shortened)) · a.example is slow", "2 of 8 drawn: the first by name",
                              "Click: the tables at this time"], "\(tip.notes)")
        var busy = model.data
        busy.events += (2...4).map { ToolEventRecord(at: at(Double($0)), id: "e\($0)", level: "critical", message: "e\($0)") }
        model.data = busy
        let four = OneChart.tip(chart, model, at: at(0)).notes
        #expect(four.count == 6 && four[1].hasPrefix("Critical ") && four[3] == "and 1 more", "three events and a count: \(four)")
        model.data.events = Array(model.data.events.prefix(1))
        let asleep = OneChart.tip(chart, model, at: at(12))
        #expect(asleep.rows.isEmpty && asleep.notes.first == "Mac asleep", "a gap: why, no values")
        model.hover = at(12)
        #expect(one.said == model.time(at(12)) + " · Mac asleep")
        (model.hover, model.moment) = (nil, at(20))
        #expect(one.said == "At " + model.time(at(20)) + " · \(ms.text(20)) · \(ms.text(40))", "the moment the tables show: \(one.said)")
        model.moment = nil
        var gone = model.data
        gone.to = at(60)
        let sleeping = line("a.example", [.init(at: at(0), value: 10), .init(at: at(5), gap: .asleep)])
        gone.charts = [ToolsCharts.Chart(id: "latency", title: "Response", metric: ms, top: 50, lines: [sleeping], bands: sleeping.chart.bands)]
        model.data = gone
        #expect(OneChart(chart: gone.charts[0], model: model).said == "Now · Mac asleep" && OneChart(chart: gone.charts[0], model: model).spoken == "Now, Mac asleep",
                "in a gap now: why, not dashes")
        // The history: a slot's lowest, average and highest, its 15 minutes.
        (model.every, model.history) = (ToolSlots.length, true)
        let slot = line("a.example", [.init(at: t0, value: 10, low: 2, high: 99)])
        let week = ToolsCharts.Chart(id: "latency", title: "Response", metric: ms, top: 100, lines: [slot], bands: [], of: 1)
        let h = OneChart.tip(week, model, at: t0)
        #expect(h.rows.map(\.value) == ["\(ms.text(2)) – \(ms.text(10)) – \(ms.text(99))"] && h.notes.first == "Lowest – average – highest" && h.time.contains("–"), "\(h)")
    }

    /// The sort: numbers by value ("1,25" before "1,5"; 2 KB before 1 MB), text as Finder sorts names, nothing last
    /// either way, equal values by key.
    @Test func aDashboardTableSortsNumbersByValue() {
        func row(_ key: String, _ text: String, _ value: Double?) -> ToolRow {
            var r = ToolRow(key: key, title: key, record: [:])
            r.cells = [.init(field: "v", format: "%", text: text, value: value.map { .number($0) })]
            return r
        }
        let rows = [row("a", "1,5 %", 1.5), row("b", "1,25 %", 1.25), row("c", "", nil), row("d", "10 %", 10), row("e", "9 %", 9), row("f", "9 %", 9)]
        func keys(_ up: Bool) -> String { ToolsTable.sorted(rows, by: NSSortDescriptor(key: "v", ascending: up)).map(\.key).joined() }
        #expect(keys(true) == "baefdc" && keys(false) == "defabc", "\(keys(true)) \(keys(false))")
        #expect(ToolsTable.sorted(rows, by: nil).map(\.key).joined() == "abcdef", "no sort: as they came")
        #expect(ToolsTable.display(rows[2].cells.first) == "—" && ToolsTable.display(rows[0].cells.first) == "1,5 %", "no number: a dash, not blank")
        let sizes = [row("x", "1 MB", 1_048_576), row("y", "2 KB", 2048), row("z", "b", nil)]
        #expect(ToolsTable.sorted(sizes, by: NSSortDescriptor(key: "v", ascending: true)).map(\.key) == ["y", "x", "z"]
                && ToolsTable.sorted(sizes, by: NSSortDescriptor(key: "v", ascending: false)).map(\.key) == ["x", "y", "z"], "text with no number after the numbers, either way")
    }

    /// A table row's level (Biggest Folders) opens in a Picker over the Tools window, the level its first: where it is
    /// as its chip, the action's rows read with the row's fields, a row's action down there with its parent's too; ⎋
    /// closes it.
    @Test func aTableRowsLevelOpensInAPickerOverTheToolsWindow() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app)
        defer { quick.done(); bench.done(); done(); app.savedServers = []; Picker.dismiss() }
        try await watching(app, bench)
        ToolsWindow.show(app, server: .local())
        let w = try #require(ToolsWindow.main), page = try #require(w.page)
        page.select("pulse")
        await toolsUntil { (live(page)?.blocks.compactMap { $0 as? ToolsTable }.first?.rows.count ?? 0) == 2 }
        let table = try #require(live(page)?.blocks.compactMap { $0 as? ToolsTable }.first)
        table.table.selectRowIndexes([0], byExtendingSelection: false)
        press(rowButtons(table, 0).first { $0.title == "Deeper" })
        let p = try #require(Picker.current)
        await toolsUntil { !p.rows.isEmpty }
        #expect(p.panel.parent === w.window && p.scopeNames == ["localhost › Pulse › first"], "\(p.scopeNames)")
        #expect(p.rows.map(\.title) == ["1 first"] && bench.calls.contains("pulse-log here 1 1 first") == false, "\(p.rows.map(\.title))")
        p.highlighted?.run()
        await toolsUntil { bench.calls.contains("pulse-log here 1 1 first") }
        #expect(bench.calls.contains("pulse-log here 1 1 first"), "the parent row's pid with the level's line: \(bench.calls)")
        #expect(p.actionBar.last?.label == "Close", "its first level: ⎋ closes")
        _ = p.panel.onKey?(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                             characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)   // ⌘↩
        await toolsUntil { app.panels.contains { ($0.list?.source as? ToolListSource)?.level != nil } }
        let other = try #require(app.panels.first { ($0.list?.source as? ToolListSource)?.level != nil })
        #expect(other.list?.shown.map(\.title) == ["1 first"] && other.pathBar.shownCrumbs == ["Pulse", "first"], "the level in the other panel: \(other.pathBar.shownCrumbs)")
        #expect(app.window.firstResponder === other.table, "the keys there")
        other.goUp()   // a dashboard isn't a list: back to the server's place, on the tool's row
        #expect(other.list?.source is PlaceSource && other.list?.cursor?.title == "Pulse", "\(other.list?.cursor?.title ?? "")")
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
        #expect(app.tools.here(.local())?.tools.last?.preset.id == "sites", "last with addresses too: Watch… is another tool's")
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
        table.table.selectRowIndexes([1], byExtendingSelection: false)
        #expect(rowButtons(table, 1).map(\.title) == ["Open", "Check Now", "⋯"], "\(rowButtons(table, 1).map(\.title))")
        let checked = table.rows[1].record["checked"]
        press(rowButtons(table, 1).first { $0.title == "Check Now" })
        await toolsUntil { posts.sent.count == 1 }
        #expect(posts.sent.first?.body == "Sites: \(web.url)/down is down: 503" && monitor.worst(s).state == .critical, "\(posts.sent)")
        await toolsUntil { table.rows[1].record["checked"] != checked }
        #expect(table.rows[1].key == "\(web.url)/down" && table.table.selectedRow == 1, "a row is its address: the cursor stays through new numbers")
    }

    /// Sites is on every saved server: with no addresses its tab — the last — says so beside Add Address…, with no empty
    /// table or chart, and nothing is checked; a server that isn't saved has none — its addresses would have nowhere to
    /// be kept.
    @Test func aSavedServerWithoutAddressesHasASitesTabThatSaysSo() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app)
        defer { quick.done(); bench.done(); done(); app.savedServers = [] }
        try await watching(app, bench)
        #expect(app.savedServers.first?.sites.isEmpty == true && app.tools.here(.local())?.tools.last?.preset.id == "sites", "\(app.tools.here(.local())?.tools.map(\.preset.id) ?? [])")
        ToolsWindow.show(app, server: .local())
        let page = try #require(ToolsWindow.main?.page)
        page.select("sites")
        let view = try #require(live(page))
        #expect(view.banner.stringValue.hasPrefix("No addresses yet: add localhost's web addresses") && !view.banner.isHidden && !view.addButton.isHidden, "\(view.banner.stringValue)")
        #expect(view.blocks.allSatisfy { $0.isHidden } && view.foot.isHidden, "no empty table or chart")
        try await Task.sleep(for: .milliseconds(400))
        #expect(app.tools.monitor.tool("sites", on: .local())?.history.last == nil, "nothing to check")
        closeWindows()
        app.openTool(try toolNamed(app, "sites"), on: app.savedServers[0], .local())   // Tools ▸ Sites: its tab, never a list over SSH
        #expect(ToolsWindow.main?.page?.tab == "sites" && Picker.current == nil)
        closeWindows()
        app.savedServers = []
        #expect(app.tools.here(.local())?.tools.contains { $0.preset.id == "sites" } == false, "not saved: no Sites")
        ToolsWindow.show(app, server: .local())
        let add = try #require(ToolsWindow.main?.page?.addMenu().items.first { $0.title.hasPrefix("Sites") })
        #expect(add.title == "Sites — save the server to use it here" && !add.isEnabled, "\(add.title)")
    }

    /// The channel's interval is its streams' and polls': checks from this Mac every second beside a poll every 3 s
    /// miss nothing of the poll — no gap, never "not answering".
    @Test func checksFromThisMacLeaveASlowPollsIntervalAlone() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app), web = try LocalWeb { _ in 200 }
        defer { web.done(); quick.done(); bench.done(); done(); app.savedServers = [] }
        try FileManager.default.createDirectory(atPath: bench.dir + "/own", withIntermediateDirectories: true)
        try Data(#"{ "schema": 1, "id": "slowpoll", "title": "Slow Poll", "watch": { "every": 3, "down": 2 }, "poll": { "command": "echo '{\"n\":1}'", "format": "json" }, "metrics": { "n": { "title": "N", "path": "n" } } }"#.utf8)
            .write(to: URL(fileURLWithPath: bench.dir + "/own/slowpoll.json"))
        try Data(#"{ "schema": 1, "id": "hits", "title": "Hits", "where": "mac", "http": { "urls": "server", "timeout": 2 }, "watch": { "every": 1 }, "metrics": { "up": { "title": "Up", "rows": "urls", "key": "url", "path": "ok" } } }"#.utf8)
            .write(to: URL(fileURLWithPath: bench.dir + "/own/hits.json"))
        var saved = SavedServer(address: "localhost")!
        saved.sites = [web.url + "/"]
        try await watching(app, bench, ids: ["pulse"], servers: [saved])
        for id in ["slowpoll", "hits"] { app.tools.trust.trust(try #require(app.tools.library.tools.first { $0.preset.id == id })) }
        app.tools.askAgain()
        _ = app.tools.here(.local())
        await toolsUntil { app.tools.here(.local())?.tools.contains { $0.preset.id == "slowpoll" } == true }
        let monitor = app.tools.monitor
        monitor.watch(try toolNamed(app, "slowpoll"), on: .local(), true)
        monitor.watch(try toolNamed(app, "hits"), on: .local(), true)
        await toolsUntil { monitor.tool("slowpoll", on: .local())?.history.last != nil && (monitor.tool("hits", on: .local())?.history.rows("urls").count ?? 0) > 0 }
        let s = try #require(monitor.server(.local())), poll = try #require(s.tools["slowpoll"])
        #expect(s.every == 3, "the poll's, not the checks' 1 s")
        try await Task.sleep(for: .milliseconds(2600))   // past twice the checks' second: what the old interval called missed
        #expect(s.missed == 0 && s.down == nil && !poll.history.points("n").contains { $0.gap == .noAnswer }, "\(poll.history.points("n").map { $0.gap?.rawValue ?? "v" })")
    }

    /// The channel's trouble leaves Sites alone: a stream killed between two failed checks of an address is a gap of
    /// its own, while the address's streak goes on — the second failed check is `down` — and its series has no band.
    @Test func aChannelGapLeavesASitesStreakAlone() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app), posts = Posts(), web = try LocalWeb { _ in 503 }
        defer { web.done(); posts.done(); quick.done(); bench.done(); done(); app.savedServers = [] }
        var saved = SavedServer(address: "localhost")!
        saved.sites = [web.url + "/down"]
        try await watching(app, bench, servers: [saved])
        let monitor = app.tools.monitor
        await toolsUntil { app.tools.here(.local())?.tools.contains { $0.preset.id == "sites" } == true }
        monitor.watch(try toolNamed(app, "pulse"), on: .local(), true)
        monitor.watch(try toolNamed(app, "sites"), on: .local(), true)
        await toolsUntil { monitor.tool("pulse", on: .local())?.history.last != nil && monitor.tool("sites", on: .local())?.history.rows("urls").count == 1 }
        let s = try #require(monitor.server(.local())), stream = try #require(s.tools["pulse"]), sites = try #require(s.tools["sites"])
        #expect(sites.alerts.worst == nil, "one failed check isn't down yet")
        kill(try #require(pid(bench)), SIGKILL)
        await toolsUntil { stream.history.points("cpu").contains { $0.gap == .reconnecting } }
        #expect(stream.history.points("cpu").contains { $0.gap == .reconnecting })
        monitor.check(sites, on: s)   // the second check, every 60 s otherwise
        await toolsUntil { sites.alerts.worst == .critical }
        #expect(sites.alerts.worst == .critical && posts.sent.map(\.body) == ["Sites: \(web.url)/down is down: 503"], "the streak went on: \(posts.sent)")
        #expect(!sites.history.points("up", web.url + "/down").contains { $0.gap != nil }, "\(sites.history.points("up", web.url + "/down"))")
    }

    /// On battery (or in Low Power Mode) watching is three times less often: the channel starts again with its
    /// `{every}` three times longer, the tab says so; Settings' switch off, it's as on power. On power, Keep This Mac
    /// Awake holds an assertion while something is watched — not on battery, not once nothing is. Open at Login is as
    /// macOS has it, never a copy.
    @Test func batteryPaceKeepAwakeAndOpenAtLogin() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app), login = ToolMonitor.loginItem
        nonisolated(unsafe) var battery = false, status = SMAppService.Status.notRegistered
        ToolMonitor.power = { (battery, false) }   // Quick puts its own back
        ToolMonitor.loginItem = ({ status }, { status = $0 ? .enabled : .notRegistered })
        defer {
            ToolMonitor.loginItem = login
            for k in ["monitorKeepAwake", "monitorSlowOnBattery"] { app.defaults.removeObject(forKey: k) }
            quick.done(); bench.done(); done(); app.savedServers = []
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
        #expect(live(page)?.strip.stringValue.hasPrefix("Watched in the background · every 3 s to save power") == true, "\(live(page)?.strip.stringValue ?? "")")
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
        await toolsUntil { ToolSlots.read(dir, tool: "pulse", from: Date().addingTimeInterval(-3600)).last?.gap == .notWatched }
        let lines = ToolSlots.read(dir, tool: "pulse", from: Date().addingTimeInterval(-3600))   // two slots, if the samples straddled a quarter
        #expect(lines.first?.v?["cpu"]?[""]?[1] == 10 && lines.last?.gap == .notWatched && lines.count >= 2, "\(lines)")

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
        #expect(cpu.lines.first?.points.compactMap(\.value).isEmpty == false && cpu.lines.first?.points.compactMap(\.value).allSatisfy { $0 == 10 } == true
                && cpu.bands.first?.gap == .notWatched && cpu.bands.last?.gap == .notWatched,
                "before it, and since: \(cpu.bands)")
        #expect(cpu.lines.first?.points.filter { $0.value != nil }.allSatisfy { $0.low == 10 && $0.high == 10 } == true, "each slot's lowest and highest")
        let said = OneChart(chart: cpu, model: charts.model).said
        #expect(said.hasSuffix(" · 10%") && said.contains("–") && !said.hasPrefix("Now"), "the last slot's 15 minutes, not now: \(said)")
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
        #expect(asked.filter { $0.tool == "pulse" }.map { "\($0.alert) \($0.scope == nil ? "all" : "this")" } == ["cpu all", "cpu this", "pmem all", "pmem this"], "\(asked)")
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

    /// dpl's dashboard (§8.7) by its own preset, on a state folder of fixtures: while the tab shows, its list of files
    /// is read beside its stream — as root over one kept SFTP session, never a password — "3 of 4" units ready on the
    /// tile and in WATCHED's summary, the Units table with each row's actions (`only`: an app's), the failed deploy's
    /// critical event, and `deployed` once a unit's active version goes up.
    @Test func dplsDashboardReadsItsListOfFiles() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app), was = SFTP.sudoPassword
        nonisolated(unsafe) var asked = 0
        SFTP.sudoPassword = { _, _ in asked += 1; return nil }
        defer { quick.done(); bench.done(); done(); app.savedServers = []; SFTP.sudoPassword = was }
        let base = bench.dir + "/dpl", sudo = try dplState(bench, base)
        let (page, t) = try await dplTab(app, bench, base, sudo: sudo)
        await toolsUntil { (live(page)?.blocks.compactMap { $0 as? ToolsTable }.first?.rows.count ?? 0) == 4 }
        let view = try #require(live(page)), table = try #require(view.blocks.compactMap { $0 as? ToolsTable }.first)
        guard let tool = app.tools.monitor.tool("dpl", on: t), let s = app.tools.monitor.server(t), table.rows.count == 4 else {   // #require would reflect the app
            Issue.record("dpl isn't live on its first tab: \(app.tools.monitor.servers.mapValues { Array($0.tools.keys) }), \(table.rows.count) rows")
            return   // a row's buttons of a table with none would end the run
        }
        #expect(view.tiles.first?.value.stringValue == "3 of 4" && view.tiles.first?.detail.stringValue == "", "\(view.tiles.map(\.value.stringValue)) \(view.tiles.first?.detail.stringValue ?? "")")
        #expect(app.tools.monitor.summary(tool, on: s).first?.text == "3 of 4 ready")
        #expect(table.rows.map(\.title) == ["api", "first", "shop", "web"] && table.rows[0].cells.map(\.text).prefix(5) == ["api", "app", "ready", "v3", "parallel"],
                "\(table.rows.map { $0.cells.map(\.text) })")
        #expect(table.rowMenu(table.rows[0]).items.map(\.title) == ["Inspect", "Logs", "Deploy…", "Roll Back…", "Edit Config", "Undeploy…", "", "Copy", "Copy Table"],
                "\(table.rowMenu(table.rows[0]).items.map(\.title))")
        #expect(table.rowMenu(table.rows[2]).items.map(\.title) == ["Inspect", "Edit Config", "Undeploy…", "", "Copy", "Copy Table"], "a domain: \(table.rowMenu(table.rows[2]).items.map(\.title))")
        table.table.selectRowIndexes([0], byExtendingSelection: false)
        table.hover = 2
        #expect(rowButtons(table, 0).map(\.title) == ["Inspect", "Logs", "⋯"] && rowButtons(table, 2).map(\.title) == ["Inspect", "Edit Config", "⋯"] && rowButtons(table, 1).isEmpty,
                "\(rowButtons(table, 0).map(\.title)) \(rowButtons(table, 2).map(\.title))")
        #expect(tool.events.map(\.message) == ["first: v1 failed at build"] && tool.events.first?.level == "critical", "\(tool.events.map(\.message))")
        let sudoRuns = { ((try? String(contentsOfFile: bench.dir + "/sftp-sudo.log", encoding: .utf8)) ?? "").split(separator: "\n").count }
        let before = sudoRuns()

        try Data(#"{"kind": "app", "active_version": 4, "last_version": 4, "last_status": "ready"}"#.utf8).write(to: URL(fileURLWithPath: base + "/state/api/deploy.json"))
        tool.due = nil   // the next read now, not in 10 s
        await toolsUntil { tool.events.count == 2 }
        #expect(tool.events.first?.message == "api v4 serving", "\(tool.events.map(\.message))")
        #expect(sudoRuns() == before && asked == 0, "the same session: no sudo again, no password asked")
        #expect(tool.history.points("apps", "all").count == 2 && tool.history.last?.record["rows"] == nil, "the stream's last is the stream's")
    }

    /// A root list whose sudo wants a password (§8.7): watching asks none — the tab says what sudoers needs, the
    /// list's tile stays empty, and nothing is read till sudo lets it.
    @Test func aListWhoseSudoWantsAPasswordAsksNone() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app), was = SFTP.sudoPassword
        nonisolated(unsafe) var asked = 0
        SFTP.sudoPassword = { _, _ in asked += 1; return "secret" }
        defer { quick.done(); bench.done(); done(); app.savedServers = []; SFTP.sudoPassword = was }
        let base = bench.dir + "/dpl", sudo = try dplState(bench, base, refuses: true)
        let (page, _) = try await dplTab(app, bench, base, sudo: sudo)
        await toolsUntil { live(page)?.banner.stringValue.isEmpty == false }
        let view = try #require(live(page))
        #expect(view.banner.stringValue.hasPrefix("The list wasn't read: sudo on localhost needs a password to run sftp-server as root."), "\(view.banner.stringValue)")
        #expect(asked == 0 && view.tiles.first?.value.stringValue == "—")
    }

    /// A tool that has only a list (§8.7): its command polled in the channel every `watch.every`, each run's rows a
    /// sample — its count, and `added` for a row that wasn't there.
    @Test func aCommandsListIsPolledInTheChannel() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app)
        defer { quick.done(); bench.done(); done(); app.savedServers = [] }
        try Data("a\nb\n".utf8).write(to: URL(fileURLWithPath: bench.dir + "/jobs"))
        try FileManager.default.createDirectory(atPath: bench.dir + "/own", withIntermediateDirectories: true)
        try Data("""
            { "schema": 1, "id": "jobs", "title": "Jobs", "list": { "command": "cat \(bench.dir)/jobs", "format": "lines", "key": "{line}" },
              "watch": { "every": 1 }, "metrics": { "n": { "title": "Jobs", "rows": "list", "count": "state" } },
              "events": [ { "id": "new", "rows": "list", "key": "line", "when": "added", "message": "{line} new" } ] }
            """.utf8).write(to: URL(fileURLWithPath: bench.dir + "/own/jobs.json"))
        try await watching(app, bench, ids: ["pulse"])
        let jobs = try #require(app.tools.library.tools.first { $0.preset.id == "jobs" })
        app.tools.trust.trust(jobs)
        app.tools.monitor.watch(try toolNamed(app, "jobs"), on: .local(), true)
        await toolsUntil { app.tools.monitor.tool("jobs", on: .local())?.history.latest("n")["all"] == 2 }
        let tool = try #require(app.tools.monitor.tool("jobs", on: .local()))
        #expect(tool.history.latest("n")["all"] == 2 && app.tools.monitor.server(.local())?.channel != nil)
        try Data("a\nb\nc\n".utf8).write(to: URL(fileURLWithPath: bench.dir + "/jobs"))
        await toolsUntil { tool.events.contains { $0.message == "c new" } }
        #expect(tool.events.map(\.message) == ["c new"] && tool.history.latest("n")["all"] == 3, "\(tool.events.map(\.message))")
        try FileManager.default.removeItem(atPath: bench.dir + "/jobs")   // the list's run fails: a gap that says why, not zero rows
        await toolsUntil { tool.listError != nil }
        #expect(tool.listError == "exit 1" && tool.history.latest("n").isEmpty, "\(tool.listError ?? "-") \(tool.history.latest("n"))")
        try Data("a\nb\nc\nd\n".utf8).write(to: URL(fileURLWithPath: bench.dir + "/jobs"))
        await toolsUntil { tool.events.contains { $0.message == "d new" } }
        #expect(tool.events.map(\.message) == ["d new", "c new"] && tool.listError == nil, "after the gap only what's new: \(tool.events.map(\.message))")
        app.tools.monitor.watch(tool.loaded, on: .local(), false)
    }

    /// A critical event that only says how things stood when watching started — a unit failed days ago — is listed
    /// and not notified, at every launch and every Watch (a second one too); the same state coming later is a change,
    /// and notifies.
    @Test func howThingsStoodIsListedNotNotified() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), quick = Quick(app), posts = Posts()
        defer { posts.done(); quick.done(); bench.done(); done(); app.savedServers = [] }
        try Data("down".utf8).write(to: URL(fileURLWithPath: bench.dir + "/state"))
        try FileManager.default.createDirectory(atPath: bench.dir + "/own", withIntermediateDirectories: true)
        try Data("""
            { "schema": 1, "id": "state", "title": "State",
              "stream": { "command": "while :; do printf '{\\"state\\":\\"%s\\"}\\n' \\"$(cat \(bench.dir)/state)\\"; sleep 0.3; done", "format": "jsonl" },
              "watch": { "every": 1 }, "metrics": { "n": { "title": "N", "path": "n" } },
              "events": [ { "id": "down", "path": "state", "when": "is", "value": "down", "level": "critical", "message": "it's down" } ] }
            """.utf8).write(to: URL(fileURLWithPath: bench.dir + "/own/state.json"))
        try await watching(app, bench)
        app.tools.trust.trust(try #require(app.tools.library.tools.first { $0.preset.id == "state" }))
        app.tools.monitor.watch(try toolNamed(app, "state"), on: .local(), true)
        await toolsUntil { app.tools.monitor.tool("state", on: .local())?.events.isEmpty == false }
        guard let t = app.tools.monitor.tool("state", on: .local()) else { Issue.record("not watched"); return }   // #require would reflect the app
        try await Task.sleep(for: .milliseconds(700))
        #expect(t.events.map(\.message) == ["it's down"] && t.events.first?.found == true && posts.sent.isEmpty, "\(posts.sent.map(\.body))")
        try Data("up".utf8).write(to: URL(fileURLWithPath: bench.dir + "/state"))
        try await Task.sleep(for: .milliseconds(700))
        try Data("down".utf8).write(to: URL(fileURLWithPath: bench.dir + "/state"))
        await toolsUntil { !posts.sent.isEmpty }
        #expect(posts.sent.map(\.body) == ["State: it's down"] && t.events.first?.found == false, "\(posts.sent.map(\.body))")
        app.tools.monitor.watch(t.loaded, on: .local(), false)   // stopped and watched again, still down: how it stood
        let listed = t.events.count
        app.tools.monitor.watch(t.loaded, on: .local(), true)
        await toolsUntil { t.events.count > listed }
        try await Task.sleep(for: .milliseconds(700))
        #expect(t.events.first?.found == true && posts.sent.count == 1, "\(posts.sent.map(\.body))")
        app.tools.monitor.watch(t.loaded, on: .local(), false)
    }
}
