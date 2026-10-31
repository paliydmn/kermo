import AppKit
import DFMCore
import Network

/// Watching (protocol §8, monitor decisions 1–23): a server's watched tools (`tools/servers.json`, `watch`) and the
/// tool live on an open tab, their streams and polls over one channel of its connection (`ToolPayload.watch`), each
/// sample into its tool's series, alerts and events (`ToolRules`). A drop is a gap and a reconnect — 2, 5, 15, 30,
/// 60 s, one server after another after a wake or a network change; no sample for `watch.down` intervals is "not
/// answering", unless this Mac has no network or just woke. A watched server logs in with no dialog (a key, a
/// password in the Keychain) or says "needs login"; a tab alone never logs in. A locked server is watched read-only,
/// without Touch ID: its connection stays up (`inUse`), the lock guards actions (decision 23).
@MainActor final class ToolMonitor {
    unowned let app: AppDelegate

    /// Tests: the seconds between retries; the login (`quiet`: a saved password, never a dialog); the tick.
    nonisolated(unsafe) static var backoff: [Double] = [2, 5, 15, 30, 60]
    nonisolated(unsafe) static var login: @Sendable (SFTPTarget, _ quiet: Bool) throws -> Void = { t, quiet in
        try SFTP.startMaster(t, env: quiet ? SSHAskpass.quietEnv : SSHAskpass.env.merging(["DFM_ASKPASS_WHY": "For watching \(t.shown)"]) { $1 })
    }
    nonisolated(unsafe) static var tick: TimeInterval = 1
    /// Tests: a saved server's target (a local stand-in's way of running isn't in servers.json).
    nonisolated(unsafe) static var target: @MainActor (SavedServer) -> SFTPTarget = { $0.target }
    /// A minute after a wake, and while this Mac has no network, no answer isn't "down" (§8.1). Tests: shorter.
    nonisolated(unsafe) static var wakeGrace: TimeInterval = 60

    /// One tool on one server: what came of it.
    final class Tool {
        let loaded: LoadedTool
        var history = ToolHistory()
        var alerts = ToolAlerts()
        /// Newest first, the last 40.
        var events: [ToolEventRecord] = []
        var budget = ToolEventBudget()
        /// A script's critical `_event`s notified and not closed yet (`level: "ok"`): one notification each (§8.7).
        var open: Set<String> = []
        var frames: ToolFrames
        /// Watched in the background; live on an open tab.
        var watched = false, live = false
        init(_ t: LoadedTool) { (loaded, frames) = (t, ToolFrames(split: t.preset.source?.parse.split)) }
        var preset: ToolPreset { loaded.preset }
        var wanted: Bool { watched || live }
        /// The channel ended: a frame half-read stays there.
        func reset() { frames = ToolFrames(split: preset.source?.parse.split) }
    }

    /// A server watched or live: its channel on the server, its tools, how it's doing.
    final class Server {
        let saved: SavedServer
        /// As its user; a locked one's connection lingers as any other's, not 60 s (decision 23).
        let target: SFTPTarget
        var tools: [String: Tool] = [:]
        var channel: CancelFlag?
        /// The channel's stdin: its end of file is how the run ends on the server (the payload's watcher), before
        /// the client is told to go.
        var hold: CancelFlag?
        /// This Mac's clock at the last line; the server's clock minus this Mac's.
        var lastLine: Date?
        var skew: TimeInterval = 0
        /// Intervals with no sample; not answering since.
        var missed = 0
        var down: Date?
        /// Its login would ask: a click logs in once — `connecting` while that login runs.
        var needsLogin = false, connecting = false
        /// Why the last channel ended, or the login failed.
        var error: String?
        var retries = 0
        var retryAt: Date?
        var since: Date?
        /// The server's own events: watching started, not answering, answers again.
        var events: [ToolEventRecord] = []
        /// Maintenance (this Mac's clock), now or the last: no notification till `until`; the charts mark it.
        /// ponytail: in memory — a relaunch ends it, and an earlier one in the hour isn't drawn.
        var maintenance: (from: Date, until: Date)?
        var inMaintenance: Bool { maintenance.map { $0.until > Date() } == true }
        /// Silenced at the last tick (Snooze, Maintenance): when that ends, what still stands is sent.
        var quiet = false
        init(_ s: SavedServer, _ t: SFTPTarget) { (saved, target) = (s, t) }
        var every: Double { tools.values.compactMap { $0.preset.watch?.every }.min() ?? 60 }
        var downAfter: Int { tools.values.compactMap { $0.preset.watch?.down }.min() ?? 3 }
        var watched: Bool { tools.values.contains(where: \.watched) }
        var wanted: Bool { tools.values.contains(where: \.wanted) }
        var key: String { ServerRow.key(target) }
    }

    private(set) var servers: [String: Server] = [:]
    /// Set once the app has its Keychain hooks (`applicationDidFinishLaunching`): a quiet login before that would
    /// find no saved password and say "needs login" for nothing. Till then `reconcile` only notes what's wanted.
    var ready = false
    private var timer: Timer?
    private var wokeAt: Date?, sleptAt: Date?
    private var lastRetry = Date.distantPast
    private let network = NWPathMonitor()
    private(set) var online = true
    /// Something changed: the Tools window draws it — once the current turn is over, so a page's refresh that reconciles
    /// never redraws itself from inside, and a tick's many changes draw once.
    var onChange: @MainActor () -> Void = { ToolsWindow.live() }
    private var drawing = false
    /// The menu bar's item: the app's, made at launch (a test's app has none).
    var menuBar: ToolsMenuBar?
    /// What Send Test did (Settings ▸ Monitor).
    var tested = ""

    func changed() {
        guard !drawing else { return }
        drawing = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.draw() } }
    }

    private func draw() {
        drawing = false
        onChange()
        menuBar?.update()
        DockTile.problems = watched.filter { [.critical, .warning].contains(worst($0).state) }.count
    }

    init(_ app: AppDelegate) {
        self.app = app
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.sleeping() } }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.woke() } }
        network.pathUpdateHandler = Masters.changes { [weak self] (p: NWPath) in
            let on = p.status == .satisfied
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.online = on; self?.wokeAt = Date(); self?.restart() } }
        }
        network.start(queue: DispatchQueue(label: "dfm.monitor.network"))
    }

    /// Watched servers' keys: in use, so their connections stay up (`AppDelegate.idleServers`).
    var inUse: Set<String> { Set(servers.values.filter(\.watched).map(\.key)) }

    func server(_ t: SFTPTarget) -> Server? { servers[ServerRow.key(t.asUser)] }
    func tool(_ id: String, on t: SFTPTarget) -> Tool? { server(t)?.tools[id] }

    // MARK: What should run

    /// What should run now: each saved server's watched tools, and the tool on each open tab of a server that's
    /// connected (never a login for a tab, §10.5). Channels started and stopped to match; what stopped keeps its
    /// hour of series, marked "not watched" from here on.
    func reconcile() {
        var want: [String: (SavedServer, SFTPTarget, [(LoadedTool, Bool)])] = [:]
        func add(_ s: SavedServer, _ t: SFTPTarget, _ tool: LoadedTool, watched: Bool) {
            let key = ServerRow.key(t.asUser)
            var w = want[key] ?? (s, t.asUser.persisting(nil), [])
            w.2.append((tool, watched))
            want[key] = w
        }
        let tools = app.tools.tools.filter(\.preset.watchable)
        for s in app.savedServers {
            for tool in tools where app.tools.settings.watches(tool.preset.id, on: s.id.uuidString) { add(s, Self.target(s), tool, watched: true) }
        }
        for page in ToolsWindow.pages where page.window?.isVisible == true {
            if let tool = page.liveTool, AppDelegate.connected(page.target) { add(page.server, page.target, tool, watched: false) }
        }
        let wereWatched = Set(servers.values.filter(\.watched).map(\.key))
        for (key, s) in servers {
            let w = want[key]
            for (id, t) in s.tools {
                t.watched = w?.2.contains { $0.0.preset.id == id && $0.1 } ?? false
                t.live = w?.2.contains { $0.0.preset.id == id && !$0.1 } ?? false
                if !t.watched { t.open = [] }
                if !t.wanted { t.alerts.clear() }   // a stop is no recovery, and nothing to say
            }
            if !s.watched { s.quiet = false }   // watched again later: nothing of before is "still standing"
            if !s.wanted { stop(s, why: .notWatched) }
        }
        for (key, w) in want {
            let s = servers[key] ?? Server(w.0, w.1)
            servers[key] = s
            var sources = Set(s.tools.keys)
            for (tool, watched) in w.2 {
                let t = s.tools[tool.preset.id] ?? Tool(tool)
                s.tools[tool.preset.id] = t
                if watched { t.watched = true } else { t.live = true }
                sources.insert(tool.preset.id)
            }
            if !wereWatched.contains(key), s.watched { note(s, "Watching started · every \(Int(s.every)) s") }
            // A tool joined, or one left: the channel runs anew with the sources as they are now.
            if s.channel != nil, Set(s.tools.filter(\.value.wanted).keys) != channelSources[key] { stop(s, why: .reconnecting); s.retryAt = Date() }
            if ready, s.channel == nil, s.retryAt == nil, !s.needsLogin, !s.connecting { start(s) }
        }
        tickIfNeeded()
        changed()
    }

    /// The tools each server's channel runs.
    private var channelSources: [String: Set<String>] = [:]

    private func tickIfNeeded() {
        let needed = servers.values.contains(where: \.wanted)
        if needed, timer == nil {
            lastTock = Date()
            timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tock() } }
        } else if !needed { timer?.invalidate(); timer = nil }
    }

    // MARK: The channel

    /// The server's sources in one payload, over its connection. A watched server logs in quietly first (a saved
    /// password; anything that would ask fails: "needs login"); a live-only one rides a connection that's up.
    private func start(_ s: Server) {
        let wanted = s.tools.values.filter(\.wanted)
        guard !wanted.isEmpty, s.channel == nil, !s.connecting else { return }
        let t = s.target, watched = s.watched, login = Self.login
        var sources: [ToolPayload.Watched] = []
        for tool in wanted {
            let p = tool.preset
            guard let source = p.source else { continue }
            sources.append(.init(tool: p, run: source.run, every: p.stream == nil ? p.watch?.every ?? 60 : nil, scope: app.tools.scope(p, on: s.saved, t), scripts: tool.loaded.scripts))
        }
        // ponytail: sources that can't share a channel (sudo differs), a value missing, and sudo that wants a password
        // (`sudo -n` is refused, retried each minute) wait for a later PR; the built-ins share one and run as you.
        // Such a server stays as it is, its row and its tab saying why.
        let payload: ToolPayload?
        do { payload = try ToolPayload.watch(sources, sudoProgram: ToolRunner.sudoProgram) } catch { s.error = "\(error)"; return changed() }
        guard let payload else { s.error = "these tools can't share one channel (sudo differs)"; return changed() }
        let cancel = CancelFlag(), hold = CancelFlag()
        (s.channel, s.hold) = (cancel, hold)
        s.error = nil
        channelSources[s.key] = Set(wanted.map { $0.preset.id })
        if s.since == nil { s.since = Date() }
        let key = s.key, env = SSHAskpass.env, command = ToolRunner.command, stdin = payload.stdin(), has = ToolRunner.hasMaster
        Thread { [weak self] in
            if watched, !has(t) {
                do { try login(t, true) } catch {
                    let said = error.localizedDescription
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.loginFailed(key, said, cancel: cancel) } }
                    return
                }
            } else if !has(t) {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(key, "not connected", cancel: cancel) } }
                return
            }
            var reader = ToolRunOutput(nonce: payload.nonce), rest = Data()
            let r = Result {
                try ToolExec.channel(t, cancel: cancel) {
                    try SSHCommand.run(t, command(payload), env: env, cancel: cancel, stdin: stdin, holdStdin: hold) { chunk in
                        rest += reader.feed(chunk)
                        guard let last = rest.lastIndex(of: 0x0A) else { return }
                        let lines = ToolParse.lines(String(decoding: rest[...last], as: UTF8.self)).filter { !$0.isEmpty }
                        rest = Data(rest[(last + 1)...])
                        let skew = reader.skew ?? 0
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.got(key, lines, skew: skew, cancel: cancel) } }
                    }
                }
            }
            let why: String = switch r {
            case .success(let (status, said)): said.split(whereSeparator: \.isNewline).first.map(String.init) ?? (status == 255 ? "connection lost" : "ended (exit \(status))")
            case .failure(let e): e.localizedDescription
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(key, why, cancel: cancel) } }
        }.start()
    }

    /// The channel's end: stdin closed first — on the server the payload's watcher ends the run and the session with
    /// it, so nothing stays behind — and the client told to go 3 s later if it hasn't (a dead link). A client killed
    /// at once leaves its session on the server: the shared connection keeps the channel open for no one.
    private func stop(_ s: Server, why: ToolGap) {
        if let run = s.channel {
            s.hold?.cancel()
            Timeouts.queue.asyncAfter(deadline: .now() + 3) { run.cancel() }
        }
        (s.channel, s.hold) = (nil, nil)
        channelSources[s.key] = nil
        (s.retryAt, s.retries) = (nil, 0)
        if why == .notWatched { s.since = nil }
        s.tools.values.forEach { $0.reset() }
        gap(s, why)
    }

    /// Lines came: each one its tool's, a frame, a sample — its series, its alerts' changes as events, its events.
    private func got(_ key: String, _ lines: [String], skew: TimeInterval, cancel: CancelFlag) {
        guard let s = servers[key], s.channel === cancel else { return }
        s.skew = skew
        (s.lastLine, s.missed, s.retries, s.error) = (Date(), 0, 0, nil)
        if let since = s.down {
            s.down = nil
            note(s, "Answers again · after " + ToolAlerts.minutes(Date().timeIntervalSince(since)), level: "ok")
        }
        quietOver(s)   // before this sample's own changes: what they raise isn't "still standing" too
        let now = Date().addingTimeInterval(skew)
        for line in lines {
            guard let tagged = ToolPayload.watchLine(line), let t = s.tools[tagged.tool], let source = t.preset.source else { continue }
            let p = t.preset
            for frame in t.frames.feed(tagged.line) {
                guard let sample = source.parse.sample(frame, at: now) else { continue }
                let values = t.history.add(sample, metrics: p.metrics ?? [:], now: now, states: p.list?.view.state)
                var fresh: [ToolEventRecord] = []
                for c in t.alerts.judge(values, alerts: alerts(t, on: s), metrics: p.metrics ?? [:], sample: sample, now: now) {
                    switch c {
                    case .worse(let alert, let key, let level, let message):
                        fresh.append(ToolEventRecord(at: now, id: "alert", level: level.name, message: message))
                        if level == .critical { deliver(s, tool: t, alert: alert, id: "\(s.key) \(p.id) \(alert) \(key)", message) }
                    case .ok(let alert, let key, _, let since):
                        let what = (p.alerts ?? []).first { ($0.id ?? $0.metric) == alert }.flatMap { a in a.metric.flatMap { p.metrics?[$0]?.title } } ?? alert
                        fresh.append(ToolEventRecord(at: now, id: "ok", level: "ok", message: "Back to normal: \(what)\(key.isEmpty ? "" : " " + key) · after " + ToolAlerts.minutes(now.timeIntervalSince(since))))
                    }
                }
                let raised = ToolEvents.raised(p.events ?? [], in: sample, previous: t.history.previous, carrying: t.history.carriedBefore,
                                               scope: app.tools.scope(p, on: s.saved, s.target))
                for e in raised where e.level == "critical" { deliver(s, tool: t, id: "\(s.key) \(p.id) \(e.id)", e.message) }
                fresh += raised
                if let e = ToolEvents.scripted(sample) {
                    if e.level == "ok" { t.open.remove(e.id) }
                    if t.budget.allows(now) {   // past 10 an hour: held, said as "N more" once there's room
                        let held = t.budget.takeHeld()
                        if held > 0 { fresh.append(ToolEventRecord(at: now, id: "more", level: "info", message: "\(p.title): \(held) more")) }
                        fresh.append(e)
                        // Silenced, it isn't marked sent: its next line after the quiet sends it.
                        if e.level == "critical", t.watched, !silent(s), t.open.insert(e.id).inserted {
                            deliver(s, tool: t, id: "\(s.key) \(p.id) _event \(e.id)", e.message)
                        }
                    }
                }
                t.events = Array((fresh.reversed() + t.events).prefix(40))
            }
        }
        changed()
    }

    private func ended(_ key: String, _ why: String, cancel: CancelFlag) {
        guard let s = servers[key], s.channel === cancel else { return }
        (s.channel, s.hold) = (nil, nil)
        channelSources[key] = nil
        s.error = why
        s.tools.values.forEach { $0.reset() }
        guard s.wanted else { return changed() }
        gap(s, .reconnecting)
        retryLater(s)
        changed()
    }

    /// The quiet login failed: a refusal means it would ask — "needs login", a click's; anything else is retried.
    /// ponytail: told apart by ssh's words; a server that refuses a key for another reason waits for the click too.
    private func loginFailed(_ key: String, _ why: String, cancel: CancelFlag) {
        guard let s = servers[key], s.channel === cancel else { return }
        s.channel = nil
        channelSources[key] = nil
        s.error = why
        if ["Permission denied", "Host key verification failed", "passphrase", "Authentication"].contains(where: why.contains) {
            s.needsLogin = true
            (s.retryAt, s.retries) = (nil, 0)
            gap(s, .reconnecting)
        } else {
            gap(s, .reconnecting)
            retryLater(s)
        }
        changed()
    }

    /// 2, 5, 15, 30, 60 s on; a second and a half after the server scheduled before it, so a wake or a network change
    /// brings them back one after another (§8.5).
    private func retryLater(_ s: Server) {
        let wait = Self.backoff[min(s.retries, Self.backoff.count - 1)]
        s.retries += 1
        let at = max(Date().addingTimeInterval(wait), lastRetry.addingTimeInterval(1.5))
        (s.retryAt, lastRetry) = (at, at)
    }

    private func gap(_ s: Server, _ why: ToolGap) {
        let at = Date().addingTimeInterval(s.skew)
        for t in s.tools.values {
            t.history.mark(why, at: at)
            t.alerts.gap()
        }
    }

    func note(_ s: Server, _ text: String, level: String = "info") {
        s.events = Array(([ToolEventRecord(at: Date().addingTimeInterval(s.skew), id: "watch", level: level, message: text)] + s.events).prefix(40))
    }

    private var lastTock = Date()

    /// Every second: retries due, intervals missed, "not answering" after `down` of them. A tick that comes late —
    /// the app was busy, or stopped a while — judges nothing: the lines that came meanwhile are still to be read.
    private func tock() {
        let now = Date(), stalled = now.timeIntervalSince(lastTock) > max(3 * Self.tick, 1.5)
        lastTock = now
        let grace = wokeAt.map { now.timeIntervalSince($0) < Self.wakeGrace } ?? false
        // Back from sleep or offline, what stood before isn't known to stand: the quiet's end waits for that to pass.
        if !stalled, online, !grace { servers.values.filter(\.watched).forEach(quietOver) }
        for s in servers.values where s.wanted {
            if s.channel == nil, !s.needsLogin, let at = s.retryAt, at <= now {
                s.retryAt = nil
                start(s)
                continue
            }
            guard s.channel != nil, let last = s.lastLine, !stalled else { continue }
            // A stream sleeps `every` after its reads, so samples come a little late: an interval is missed only past
            // half of one more, else a healthy stream would mark gaps and start every `for` over.
            let missed = max(0, Int((now.timeIntervalSince(last) - s.every / 2) / s.every))
            guard missed > s.missed else { continue }
            s.missed = missed
            gap(s, .noAnswer)
            if missed >= s.downAfter, s.down == nil, online, !grace {
                s.down = last
                note(s, "Not answering — \(missed) checks in a row", level: "critical")
                deliver(s, tool: nil, id: "\(s.key) down", "Not answering — \(missed) checks in a row. This Mac is online: it's the server or the way to it.")
            }
            changed()
        }
        tickIfNeeded()
    }

    // MARK: Sleep, wake, the click

    private func sleeping() {
        sleptAt = Date()
        for s in servers.values where s.wanted { gap(s, .asleep) }
    }

    /// Back from sleep, or on another network: the shared connections are stopped (`Masters`), but a session on one
    /// lives on till ssh notices the dead link (ServerAlive: some 90 s) — so each channel is ended here and comes back
    /// staggered, with a minute's grace before any "not answering".
    private func woke() {
        wokeAt = Date()
        for s in servers.values where s.wanted {
            note(s, "Paused while this Mac slept" + (sleptAt.map { " since " + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
            s.missed = 0
        }
        restart()
    }

    func restart() {
        for s in servers.values where s.wanted && s.channel != nil {
            stop(s, why: .reconnecting)
            retryLater(s)
        }
        changed()
    }

    /// "Needs login": the lock, then the login as any look's, then the channel.
    func connect(_ t: SFTPTarget) {
        guard let s = server(t), s.needsLogin, !s.connecting else { return }
        s.connecting = true   // no quiet login meanwhile: a reconcile would find it refused and say "needs login" again
        changed()
        let target = s.target, login = Self.login
        Task {
            defer { s.connecting = false; changed() }
            guard await ServerLock.authorize(target, "connect to") else { return }
            do {
                try await Blocking.run { try login(target, false) }
                app.noteLook(target)
                s.needsLogin = false
                s.connecting = false
                start(s)
            } catch { s.error = error.localizedDescription }
        }
    }

    /// Watch (true) or Stop Watching `tool` on `t`'s server: `tools/servers.json`, and the channel to match.
    func watch(_ tool: LoadedTool, on t: SFTPTarget, _ on: Bool) {
        guard let id = app.tools.serverID(t) else { return }
        app.tools.settings.watch(tool.preset.id, on: id, on)
        app.tools.saveSettings()
        if !on, let s = server(t) { s.needsLogin = false }
        reconcile()
    }

    // MARK: How a server is doing

    enum State: Equatable { case critical, warning, ok, off }

    /// The worst of a server: not answering, an alert standing, else paused / connecting / needs login / fine — and
    /// a word on it.
    func worst(_ s: Server) -> (state: State, why: String) {
        if s.down != nil { return (.critical, "not answering") }
        if s.needsLogin { return (.off, s.connecting ? "logging in…" : "needs login") }
        if s.channel == nil, s.retryAt == nil, let why = s.error { return (.off, why) }   // can't run as it is: its tab says why
        let standing = s.tools.values.flatMap { t in t.alerts.standing.map { (level: $0.state.level!, text: $0.state.message ?? $0.alert) } }
        if let top = standing.max(by: { $0.level < $1.level }) {
            let n = standing.count
            return (top.level == .critical ? .critical : .warning, n == 1 ? top.text : "\(n) alerts")
        }
        if s.channel == nil { return (.off, s.retryAt == nil ? "" : "connecting…") }
        if s.missed > 0 { return (.off, "no answer \(s.missed) of \(s.downAfter)") }
        if let m = s.maintenance, s.inMaintenance { return (.ok, "maintenance till " + m.until.formatted(date: .omitted, time: .shortened)) }
        return (.ok, "")
    }

    /// The worst standing alert of one tool.
    func level(_ tool: String, on t: SFTPTarget) -> ToolLevel? { self.tool(tool, on: t)?.alerts.worst }

    /// WATCHED's order: problems first, then by name.
    var watched: [Server] {
        servers.values.filter(\.watched).sorted { a, b in
            let x = worst(a).state, y = worst(b).state
            func rank(_ s: State) -> Int { s == .critical ? 0 : s == .warning ? 1 : 2 }
            return rank(x) != rank(y) ? rank(x) < rank(y) : a.saved.title.localizedStandardCompare(b.saved.title) == .orderedAscending
        }
    }

    /// `t`'s alerts on `s` with your thresholds (Thresholds…).
    func alerts(_ t: Tool, on s: Server) -> [ToolAlert] { app.tools.settings.alerts(t.preset, on: s.saved.id.uuidString) }

    /// A tool's `summary` on a server (§6.3): each item's value now — a bar's share of `max`, a count's label with
    /// `{ok}` / `{bad}` / `{all}`, a text — with the alert's thresholds for the bar.
    func summary(_ t: Tool, on s: Server) -> [(label: String, value: Double?, max: Double, text: String, warn: Double?, crit: Double?, level: ToolLevel?)] {
        let p = t.preset, alerts = alerts(t, on: s)
        return (p.summary ?? []).compactMap { item in
            guard let m = p.metrics?[item.metric] else { return nil }
            let latest = t.history.latest(item.metric)
            let alert = alerts.first { $0.metric == item.metric }
            let level = t.alerts.worst(metric: item.metric, alerts: alerts)
            switch item.as ?? "text" {
            case "count":
                let scope = ToolTemplate.Scope(inputs: Dictionary(uniqueKeysWithValues: latest.map { ($0.key, ToolValue.number($0.value)) }))
                return (m.title ?? item.metric, nil, 100, item.label.map { ToolTemplate.text($0, scope) } ?? latest["all"].map { ToolValue.number($0).text } ?? "—", nil, nil, level)
            default:
                let v = ToolMetric.one(latest, of: item.of)
                return (item.label ?? m.title ?? item.metric, item.as == "bar" ? v : nil, m.max ?? 100, v.map(m.text) ?? "—", alert?.warn, alert?.crit, level)
            }
        }
    }
}

extension SSHAskpass {
    /// For watching (§8.5): the saved password answers, as ever; anything else — a password not kept, a passphrase,
    /// a host key to confirm — fails the login instead of asking.
    static let quietEnv: [String: String] = {
        let path = SFTP.controlDir + "/askpass-quiet"
        try? ("#!/bin/sh\n" + SFTP.askpassSavedPassword + "\nexit 1\n").write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o700)
        return ["SSH_ASKPASS": path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0"]
    }()
}
