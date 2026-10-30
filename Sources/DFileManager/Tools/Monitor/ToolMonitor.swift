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
    /// A minute after a wake, and while this Mac has no network, no answer isn't "down" (§8.1).
    static let wakeGrace: TimeInterval = 60

    /// One tool on one server: what came of it.
    final class Tool {
        let loaded: LoadedTool
        var history = ToolHistory()
        var alerts = ToolAlerts()
        /// Newest first, the last 40.
        var events: [ToolEventRecord] = []
        var budget = ToolEventBudget()
        var frames: ToolFrames
        /// Watched in the background; live on an open tab.
        var watched = false, live = false
        init(_ t: LoadedTool) { (loaded, frames) = (t, ToolFrames(split: (t.preset.stream ?? t.preset.poll)?.parse.split)) }
        var preset: ToolPreset { loaded.preset }
        var wanted: Bool { watched || live }
    }

    /// A server watched or live: its channel on the server, its tools, how it's doing.
    final class Server {
        let saved: SavedServer
        /// As its user; a locked one's connection lingers as any other's, not 60 s (decision 23).
        let target: SFTPTarget
        var tools: [String: Tool] = [:]
        var channel: CancelFlag?
        /// This Mac's clock at the last line; the server's clock minus this Mac's.
        var lastLine: Date?
        var skew: TimeInterval = 0
        /// Intervals with no sample; not answering since.
        var missed = 0
        var down: Date?
        /// Its login would ask: a click logs in once.
        var needsLogin = false
        /// Why the last channel ended, or the login failed.
        var error: String?
        var retries = 0
        var retryAt: Date?
        var since: Date?
        /// The server's own events: watching started, not answering, answers again.
        var events: [ToolEventRecord] = []
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

    private func changed() {
        guard !drawing else { return }
        drawing = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.drawing = false; self?.onChange() } }
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
        let tools = app.tools.tools.filter { $0.preset.watch != nil && ($0.preset.stream != nil || $0.preset.poll != nil) }
        for s in app.savedServers {
            for tool in tools where app.tools.settings.watches(tool.preset.id, on: s.id.uuidString) { add(s, Self.target(s), tool, watched: true) }
        }
        for page in ToolsWindow.pages where page.window?.isVisible == true {
            if let tool = page.liveTool, tool.preset.watch != nil, AppDelegate.connected(page.target) { add(page.server, page.target, tool, watched: false) }
        }
        for (key, s) in servers {
            let w = want[key]
            for (id, t) in s.tools {
                t.watched = w?.2.contains { $0.0.preset.id == id && $0.1 } ?? false
                t.live = w?.2.contains { $0.0.preset.id == id && !$0.1 } ?? false
                if !t.wanted { t.alerts.clear() }   // a stop is no recovery, and nothing to say
            }
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
            // A tool joined, or one left: the channel runs anew with the sources as they are now.
            if s.channel != nil, Set(s.tools.filter(\.value.wanted).keys) != channelSources[key] { stop(s, why: .reconnecting); s.retryAt = Date() }
            if ready, s.channel == nil, s.retryAt == nil, !s.needsLogin { start(s) }
        }
        tickIfNeeded()
        changed()
    }

    /// The tools each server's channel runs.
    private var channelSources: [String: Set<String>] = [:]

    private func tickIfNeeded() {
        let needed = servers.values.contains(where: \.wanted)
        if needed, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tock() } }
        } else if !needed { timer?.invalidate(); timer = nil }
    }

    // MARK: The channel

    /// The server's sources in one payload, over its connection. A watched server logs in quietly first (a saved
    /// password; anything that would ask fails: "needs login"); a live-only one rides a connection that's up.
    private func start(_ s: Server) {
        let wanted = s.tools.values.filter(\.wanted)
        guard !wanted.isEmpty, s.channel == nil else { return }
        let t = s.target, watched = s.watched, login = Self.login
        var sources: [ToolPayload.Watched] = []
        for tool in wanted {
            let p = tool.preset
            guard let source = p.stream ?? p.poll else { continue }
            var scope = app.tools.scope(p, on: s.saved, t)
            scope.levels[scope.levels.count - 1]["every"] = .number(p.watch?.every ?? 60)
            sources.append(.init(tool: p, run: source.run, every: p.stream == nil ? p.watch?.every ?? 60 : nil, scope: scope, scripts: tool.loaded.scripts))
        }
        // ponytail: sources that can't share a channel (sudo differs, a value missing) wait for a later PR; the built-ins share one.
        guard let payload = try? ToolPayload.watch(sources, sudoProgram: ToolRunner.sudoProgram) else { s.error = "these tools can't share a channel"; return }
        let cancel = CancelFlag()
        s.channel = cancel
        s.error = nil
        channelSources[s.key] = Set(wanted.map { $0.preset.id })
        if s.since == nil { s.since = Date(); note(s, "Watching started · every \(Int(s.every)) s") }
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
            nonisolated(unsafe) var errors = ""
            let r = Result {
                try ToolExec.channel(t, cancel: cancel) {
                    try SSHCommand.run(t, command(payload), env: env, cancel: cancel, stdin: stdin, holdStdin: cancel,
                                       onErrors: { d in errors += String(decoding: d, as: UTF8.self) }) { chunk in
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
            case .success(let (status, said)): (said.isEmpty ? errors : said).split(whereSeparator: \.isNewline).first.map(String.init) ?? (status == 255 ? "connection lost" : "ended (exit \(status))")
            case .failure(let e): e.localizedDescription
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(key, why, cancel: cancel) } }
        }.start()
    }

    private func stop(_ s: Server, why: ToolGap) {
        s.channel?.cancel()
        s.channel = nil
        channelSources[s.key] = nil
        (s.retryAt, s.retries) = (nil, 0)
        if why == .notWatched { s.since = nil }
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
        let now = Date().addingTimeInterval(skew)
        for line in lines {
            guard let tagged = ToolPayload.watchLine(line), let t = s.tools[tagged.tool], let source = t.preset.stream ?? t.preset.poll else { continue }
            let p = t.preset
            for frame in t.frames.feed(tagged.line) {
                guard let sample = source.parse.sample(frame, at: now) else { continue }
                let values = t.history.add(sample, metrics: p.metrics ?? [:], now: now, states: p.list?.view.state)
                var fresh: [ToolEventRecord] = []
                for c in t.alerts.judge(values, alerts: p.alerts ?? [], metrics: p.metrics ?? [:], sample: sample, now: now) {
                    switch c {
                    case .worse(_, _, let level, let message): fresh.append(ToolEventRecord(at: now, id: "alert", level: level.name, message: message))
                    case .ok(let alert, let key, _, let since):
                        let what = (p.alerts ?? []).first { ($0.id ?? $0.metric) == alert }.flatMap { a in a.metric.flatMap { p.metrics?[$0]?.title } } ?? alert
                        fresh.append(ToolEventRecord(at: now, id: "ok", level: "ok", message: "Back to normal: \(what)\(key.isEmpty ? "" : " " + key) · after " + ToolAlerts.minutes(now.timeIntervalSince(since))))
                    }
                }
                fresh += ToolEvents.raised(p.events ?? [], in: sample, previous: t.history.previous, scope: app.tools.scope(p, on: s.saved, s.target))
                if let e = ToolEvents.scripted(sample) {
                    if t.budget.allows(now) { fresh.append(e) }
                    let held = t.budget.takeHeld()
                    if held > 0, fresh.isEmpty { fresh.append(ToolEventRecord(at: now, id: "more", level: "info", message: "\(p.title): \(held) more")) }
                }
                t.events = Array((fresh.reversed() + t.events).prefix(40))
            }
        }
        changed()
    }

    private func ended(_ key: String, _ why: String, cancel: CancelFlag?) {
        guard let s = servers[key], cancel == nil || s.channel === cancel else { return }
        s.channel = nil
        channelSources[key] = nil
        s.error = why
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

    private func note(_ s: Server, _ text: String, level: String = "info") {
        s.events = Array(([ToolEventRecord(at: Date().addingTimeInterval(s.skew), id: "watch", level: level, message: text)] + s.events).prefix(40))
    }

    /// Every second: retries due, intervals missed, "not answering" after `down` of them.
    private func tock() {
        let now = Date()
        for s in servers.values where s.wanted {
            if s.channel == nil, !s.needsLogin, let at = s.retryAt, at <= now {
                s.retryAt = nil
                start(s)
                continue
            }
            guard s.channel != nil, let last = s.lastLine else { continue }
            let missed = Int(now.timeIntervalSince(last) / s.every)
            guard missed > s.missed else { continue }
            s.missed = missed
            gap(s, .noAnswer)
            let grace = wokeAt.map { now.timeIntervalSince($0) < Self.wakeGrace } ?? false
            if missed >= s.downAfter, s.down == nil, online, !grace {
                s.down = last
                note(s, "Not answering — \(missed) checks in a row", level: "critical")
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
        guard let s = server(t), s.needsLogin else { return }
        s.needsLogin = false
        changed()
        let target = s.target, login = Self.login
        Task {
            guard await ServerLock.authorize(target, "connect to") else { s.needsLogin = true; return changed() }
            do {
                try await Blocking.run { try login(target, false) }
                app.noteLook(target)
                start(s)
            } catch {
                s.needsLogin = true
                s.error = error.localizedDescription
            }
            changed()
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
        if s.needsLogin { return (.off, "needs login") }
        let standing = s.tools.values.flatMap { t in t.alerts.standing.map { (level: $0.state.level!, text: $0.state.message ?? $0.alert) } }
        if let top = standing.max(by: { $0.level < $1.level }) {
            let n = standing.count
            return (top.level == .critical ? .critical : .warning, n == 1 ? top.text : "\(n) alerts")
        }
        if s.channel == nil { return (.off, s.retryAt == nil ? "" : "connecting…") }
        if s.missed > 0 { return (.off, "no answer \(s.missed) of \(s.downAfter)") }
        return (.ok, "")
    }

    /// The worst standing alert of one tool.
    func level(_ tool: String, on t: SFTPTarget) -> ToolLevel? { self.tool(tool, on: t)?.alerts.worst }

    /// WATCHED's order: problems first, then by name.
    var watched: [Server] {
        servers.values.filter(\.watched).sorted { a, b in
            let x = worst(a).state, y = worst(b).state
            func rank(_ s: State) -> Int { switch s { case .critical: 0; case .warning: 1; default: 2 } }
            return rank(x) != rank(y) ? rank(x) < rank(y) : a.saved.title.localizedStandardCompare(b.saved.title) == .orderedAscending
        }
    }

    /// A tool's `summary` on a server (§6.3): each item's value now — a bar's percentage, a count's label with
    /// `{ok}` / `{bad}` / `{all}`, a text — with the alert's thresholds for the bar.
    func summary(_ t: Tool) -> [(label: String, value: Double?, text: String, warn: Double?, crit: Double?, level: ToolLevel?)] {
        let p = t.preset
        return (p.summary ?? []).compactMap { item in
            guard let m = p.metrics?[item.metric] else { return nil }
            let latest = t.history.latest(item.metric)
            let alert = (p.alerts ?? []).first { $0.metric == item.metric }
            let level = alert.flatMap { t.alerts.states[$0.id ?? item.metric]?.values.compactMap(\.level).max() }
            switch item.as ?? "text" {
            case "count":
                let scope = ToolTemplate.Scope(inputs: Dictionary(uniqueKeysWithValues: latest.map { ($0.key, ToolValue.number($0.value)) }))
                return (m.title ?? item.metric, nil, item.label.map { ToolTemplate.text($0, scope) } ?? latest["all"].map { ToolValue.number($0).text } ?? "—", nil, nil, level)
            default:
                let values = Array(latest.values)
                let v: Double? = switch item.of ?? "max" {
                case "sum": values.isEmpty ? nil : values.reduce(0, +)
                case "min": values.min()
                case "avg": values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
                default: values.max()
                }
                return (item.label ?? m.title ?? item.metric, item.as == "bar" ? v : nil, v.map(m.text) ?? "—", alert?.warn, alert?.crit, level)
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
