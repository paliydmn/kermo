import AppKit
import DFMCore
import UserNotifications

/// A long job (protocol §7.6) as `tools/runs.json` keeps it: where it runs and what — the form's values without its
/// secrets, the row it acts on — its pid, the server's clock, how it ended. Kept till it's removed, or a week after.
struct ToolJob: Codable, Equatable {
    /// Its files' name on the server (`ToolLong.newID`).
    var id: String
    /// The saved server's `SavedServer.id` ("" for one not saved), the login it runs as (root's only around the
    /// command: `root`), the server's name then.
    var server: String
    var target: SFTPTarget
    var place: String
    var tool: String, action: String, title: String
    var row: String?
    /// The list row it runs on (`ToolListSource.rowID`): its spinner, and the line under the list says how it went.
    var rowID: String
    var record: ToolRecord?
    var values: [String: String]
    var root: Bool
    var pid: Int32
    var started: Date
    /// The server's clock minus this Mac's at the start.
    var skew: Double?
    var exit: Int32?
    var ended: Date?
    /// How it went, as the card and the line under the list say it.
    var said: String?
    var stopped: Bool?
    /// A failure, or an end Kermo wasn't in front for and couldn't tell (no notifications): a Dock badge till Activity
    /// is looked at.
    var unseen: Bool?

    var running: Bool { ended == nil }
    var ok: Bool { exit == 0 }   // ponytail: `exitOk` of the action isn't kept; 0 is ✓
    /// "Upgrade dpl", "Deploy api": the action, its row.
    var name: String { title.replacingOccurrences(of: "…", with: "") + (row.map { " \($0)" } ?? "") }
}

/// The long jobs Kermo started (§7.6): each one's follow — one channel of its server's while it runs — its card in
/// Activity, Stop… and Retry, and after a dropped connection, a sleep or a relaunch, the follow again once a
/// connection to its server is up: never a login for it (§10.5).
@MainActor final class ToolJobs {
    unowned let app: AppDelegate
    /// Activity (`OpsController.toolJobs` sets it).
    weak var ops: OpsController?
    private(set) var jobs: [ToolJob] = []
    /// What a running job has here: its follow, how much of its log came (nil: not known — after a relaunch a follow
    /// reads its last 64 KB), the last MB of it for Show, the progress and the last line, its log windows.
    final class Live {
        var follow: CancelFlag?
        var offset: Int?
        var text = Data(), pending = Data()
        var fraction: Double?
        var line = ""
        var lost = false
        var windows: [OutputWindow] = []
        init(offset: Int? = nil) { self.offset = offset }
    }
    private var live: [String: Live] = [:]
    private var timer: Timer?, looking = false

    /// Tests: whether Kermo is in front, and macOS notifications' stand-in.
    nonisolated(unsafe) static var front: @MainActor () -> Bool = { NSApp.isActive }
    nonisolated(unsafe) static var notices = Notices.system
    /// Tests: a target as runs.json gives it back — a local test server's way of running isn't kept there.
    nonisolated(unsafe) static var loaded: @Sendable (SFTPTarget) -> SFTPTarget = { $0 }

    init(_ app: AppDelegate) {
        self.app = app
        let week = Date().addingTimeInterval(-7 * 86_400)
        jobs = (ToolRunner.own.flatMap { try? Config.load("runs.json", as: [ToolJob].self, in: $0.path) } ?? []).filter { ($0.ended ?? Date()) > week }
        for i in jobs.indices { jobs[i].target = Self.loaded(jobs[i].target) }
        lookAgain()
    }

    private func save() { if let dir = ToolRunner.own?.path { Config.save("runs.json", jobs, in: dir) } }

    func job(_ id: String) -> ToolJob? { jobs.first { $0.id == id } }
    func state(_ id: String) -> Live? { live[id] }
    /// The job running on that row now.
    func running(rowID: String) -> ToolJob? { jobs.first { $0.running && $0.rowID == rowID } }
    var unseen: Int { jobs.filter { $0.unseen == true }.count }
    func markSeen() {
        guard unseen > 0 else { return }
        for i in jobs.indices { jobs[i].unseen = nil }
        save()
    }

    /// A job just started: kept, followed from its first byte.
    func add(_ j: ToolJob, show: Bool) {
        jobs.insert(j, at: 0)
        live[j.id] = Live(offset: 0)
        save()
        attach(j)
        if show { self.show(j) }
        spin(j.rowID)
    }

    /// Off the list (a finished one's ✕). Nothing on the server changes.
    func remove(_ id: String) {
        live[id]?.follow?.cancel()
        live[id] = nil
        jobs.removeAll { $0.id == id }
        save()
        changed()
    }

    /// Activity's Clear: the finished ones go from the list.
    func removeFinished() {
        jobs.filter { !$0.running }.forEach { live[$0.id] = nil }
        jobs.removeAll { !$0.running }
        save()
    }

    private func changed() { ops?.changed() }

    /// Each list showing the job's row (a launcher's too): its spinner as the job is.
    func spin(_ rowID: String) {
        let busy = running(rowID: rowID) != nil || app.serviceRuns[rowID]?.isEmpty == false
        for list in app.rowLists(rowID) {
            guard var it = ((list as? ListPanel)?.shown ?? (list as? Picker)?.rows ?? []).first(where: { $0.id == rowID }), it.busy != busy else { continue }
            it.busy = busy
            list.update(it)
        }
        changed()
    }

    // MARK: Following

    /// Every 5 s while a running job has no follow: those whose server has a connection up get one.
    private func lookAgain() {
        guard timer == nil, jobs.contains(where: { $0.running && live[$0.id]?.follow == nil }) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.look() } }
        look()
    }

    private func look() {
        let waiting = jobs.filter { $0.running && live[$0.id]?.follow == nil }
        guard !waiting.isEmpty else { timer?.invalidate(); timer = nil; return }
        guard !looking else { return }
        looking = true
        let targets = waiting.map(\.target), has = ToolRunner.hasMaster
        Task {
            let up = await Blocking.run { Set(targets.filter(has).map(ServerRow.key)) }
            looking = false
            for j in waiting where up.contains(ServerRow.key(j.target)) { if let now = job(j.id), now.running { attach(now) } }
        }
    }

    /// The job's log as it grows, from where Kermo left it, till its exit comes (`ToolLong.follow`), on a channel of its
    /// server's connection.
    private func attach(_ j: ToolJob) {
        let l = live[j.id] ?? Live()
        live[j.id] = l
        guard l.follow == nil else { return }
        let cancel = CancelFlag(), p = ToolLong.follow(id: j.id, from: l.offset ?? -65_536)
        (l.follow, l.lost) = (cancel, false)
        // ponytail: from the last 64 KB again, a log window left open gets them twice; a follow that said its offset wouldn't
        if l.offset == nil { (l.text, l.pending) = (Data(), Data()) }
        let t = j.target, env = SSHAskpass.env, command = ToolRunner.command, stdin = p.stdin(), id = j.id
        Thread { [weak self] in
            var reader = ToolRunOutput(nonce: p.nonce)
            let r = Result {
                try ToolExec.channel(t, cancel: cancel) {
                    try SSHCommand.run(t, command(p), env: env, cancel: cancel, stdin: stdin, holdStdin: cancel) { chunk in
                        let d = reader.feed(chunk)
                        if !d.isEmpty { DispatchQueue.main.async { MainActor.assumeIsolated { self?.got(d, id) } } }
                    }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.followed(id, r.map { ToolLong.end($0.errors, nonce: p.nonce) }, cancel) } }
        }.start()
        changed()
    }

    private func got(_ d: Data, _ id: String) {
        guard let l = live[id], let j = job(id) else { return }
        l.offset = l.offset.map { $0 + d.count }
        l.text += d
        if l.text.count > 1 << 20 { l.text = Data(l.text.suffix(1 << 20)) }
        l.windows.forEach { $0.add(d) }
        // Whole lines (a `\r` ends one: a progress bar redraws its line) for `progress`; the last one, or the one being
        // written, for the card.
        l.pending += d
        let cut = l.pending.lastIndex { $0 == 0x0A || $0 == 0x0D }
        let whole = cut.map { Data(l.pending[..<$0]) } ?? Data(), open = cut.map { Data(l.pending[($0 + 1)...]) } ?? l.pending
        l.pending = Data(open.suffix(65_536))
        let progress = action(j)?.spec.progress
        for line in ToolParse.lines(String(decoding: whole, as: UTF8.self)) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            l.line = line
            if let progress, let p = ToolLong.progress(progress, line: line) { (l.fraction, l.line) = (p.fraction, p.text ?? line) }
        }
        if let now = ToolParse.lines(String(decoding: open, as: UTF8.self)).last, !now.trimmingCharacters(in: .whitespaces).isEmpty { l.line = now }
        changed()
    }

    /// The follow is over: the job ended — or the connection went (or the follow was stopped), and it runs on.
    private func followed(_ id: String, _ r: Result<ToolLong.End?, Error>, _ cancel: CancelFlag) {
        guard let l = live[id], l.follow === cancel else { return }
        l.follow = nil
        switch r {
        case .success(.exit(let code)?): finish(id, exit: code)
        case .success(.lost?): finish(id, exit: nil, said: "it ended without saying how — the server may have restarted")
        case .success(.gone?): finish(id, exit: nil, said: "its log is gone from the server")
        default:
            l.lost = true
            l.windows.forEach { $0.said("connection lost — the job runs on") }
            lookAgain()
            changed()
        }
    }

    private func finish(_ id: String, exit: Int32?, said: String? = nil) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        var j = jobs[i]
        let l = live[id]
        (j.exit, j.ended) = (exit, Date())
        if let said { j.said = said } else if j.ok {
            j.said = done(j, log: l?.text ?? Data())
        } else {
            let last = l?.line.isEmpty == false ? ": " + l!.line : ""
            j.said = j.stopped == true ? "stopped" : "exit \(exit ?? -1)" + last
        }
        let took = j.ended!.timeIntervalSince(j.started), front = Self.front()
        j.unseen = j.ok ? nil : true   // a failure: red, as a copy's errors
        jobs[i] = j
        save()
        spin(j.rowID)
        l?.windows.forEach { $0.said((j.ok ? "done" : j.said ?? "") + " · " + Activity.duration(took)) }
        let line = "\(j.ok ? "✓" : "✕") \(j.name) on \(j.place): \(j.said ?? "")"
        for list in app.rowLists(j.rowID) {
            let text = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
            list.said(text, about: j.rowID, failed: !j.ok, output: nil)
        }
        Task {
            let allowed = await Self.notices.allowed()
            switch Self.notice(took: took, front: front, allowed: allowed) {
            case .notification: Self.notices.post(id, "\(j.name) on \(j.place)", j.ok ? "✓ " + (j.said ?? "done") : "✕ " + (j.said ?? "failed"))
            case .badge:
                guard let k = jobs.firstIndex(where: { $0.id == id }) else { return }
                jobs[k].unseen = true
                save()
            case .none: break
            }
            changed()
        }
        changed()
    }

    /// The action's `done` (§6.1) with the form's values, the row's fields, Kermo's names and — with `format` — the last
    /// record of the log (§7.6); else "done".
    private func done(_ j: ToolJob, log: Data) -> String {
        guard let a = action(j), let text = a.spec.done, let p = app.tools.library.tools.first(where: { $0.preset.id == j.tool })?.preset else { return "done" }
        let last = a.spec.format.flatMap { ToolLong.last(log, format: $0) }
        var scope = app.tools.scope(p, on: app.savedServer(at: j.target) ?? SavedServer(target: j.target), j.target, rows: [last, j.record].compactMap { $0 })
        scope.levels[0] = j.values.mapValues { .string($0) }
        return ToolTemplate.text(text, scope)
    }

    /// Whether a job's end is told by a macOS notification (§8.7, Q18): it took over a minute and ended while Kermo wasn't
    /// in front — where notifications are off, the Dock's badge and the card tell it.
    enum Notice { case none, notification, badge }
    static func notice(took: TimeInterval, front: Bool, allowed: Bool?) -> Notice {
        guard took > 60, !front else { return .none }
        return allowed == true ? .notification : .badge
    }

    func action(_ j: ToolJob) -> ToolAction? {
        guard let p = app.tools.library.tools.first(where: { $0.preset.id == j.tool })?.preset else { return nil }
        return p.allActions.first { $0.action.spec.id == j.action }?.action ?? (j.action == "command" ? p.commandAction : nil)
    }

    // MARK: Show, Stop…, Retry

    /// The job's log in a window: what came of it, more as it comes. Over and not followed this run (a relaunch): read
    /// from the server, where a connection is up.
    func show(_ j: ToolJob) {
        let l = live[j.id] ?? Live()
        live[j.id] = l
        if let w = l.windows.first(where: { $0.window?.isVisible == true }) { return w.showWindow(nil) }
        let title = "\(j.name) — \(j.place)"
        guard j.running || !l.text.isEmpty else {
            let t = j.target, p = ToolLong.read(id: j.id), has = ToolRunner.hasMaster, env = SSHAskpass.env, command = ToolRunner.command
            Task {
                let r = await Blocking.run { () -> ToolExec.Ran? in
                    guard has(t) else { return nil }
                    return try? ToolExec.run({ _ in p }, on: t, timeout: 30, cancel: CancelFlag(), env: env, command: command)
                }
                guard let r, r.started else { return app.active.flash("Connect to \(j.place) to see the log: ~/.cache/kermo/runs/\(j.id).log there") }
                OutputWindow.show(r.text, errors: r.errors, title: title, status: j.exit ?? 0, ok: j.ok, save: "\(j.place)-\(j.id).log")
            }
            return
        }
        let status = !j.running ? (j.ok ? "done" : j.said ?? "") : l.follow != nil ? "running…"
            : l.lost ? "connection lost — the job runs on" : "connect to \(j.place) to see how it goes"
        l.windows = l.windows.filter { $0.window?.isVisible == true } + [OutputWindow.log(l.text, title: title, status: status)]
    }

    /// Stop… (§7.6): asked on production; the job's group killed — root's through sudo. The follow then says how it ended.
    func stop(_ j: ToolJob) {
        Task {
            let t = j.target
            if SavedServer.isProd(t) {
                var c = Confirm("Stop \(j.name) on \(j.place)?", on: t, action: "Stop")
                c.note = "Its whole process group is killed — what it changed so far stays."
                guard await app.confirm(c, on: nil) == 0 else { return }
            }
            let has = ToolRunner.hasMaster, env = SSHAskpass.env, command = ToolRunner.command, sudo = ToolRunner.sudoProgram, root = j.root
            let up = await Blocking.run { has(t) }
            guard up else { return app.active.flash("Connect to \(j.place) to stop \(j.name): it runs on there", error: true) }
            if let i = jobs.firstIndex(where: { $0.id == j.id }) { jobs[i].stopped = true }
            let r = await Blocking.run { Result { try ToolLong.run(root: root, on: t, cancel: CancelFlag(), env: env, command: command) { ToolLong.stop(id: j.id, root: $0, sudoProgram: sudo) } } }
            AuditLog.write(t, "tool \(j.tool) \(j.action) stop", paths: [], command: "kill the job \(j.id)", exit: (try? r.get())?.status)
            switch r {
            case .success(let ran) where ran.status == 0: return
            case .success(let ran): app.active.flash("\(j.name) wasn't stopped: " + (ran.errors.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(ran.status)"), error: true)
            case .failure(is ToolExec.NoPassword): app.active.flash("\(j.name) wasn't stopped: no sudo password")
            case .failure(let e): app.showError(e)
            }
            if let i = jobs.firstIndex(where: { $0.id == j.id }) { jobs[i].stopped = nil }   // it runs on
        }
    }

    /// Retry: the same action with the same values, on the same row, asked as any run (a secret asked again).
    func retry(_ j: ToolJob) {
        guard let tool = app.tools.tools.first(where: { $0.preset.id == j.tool }), let a = action(j) else {
            return app.active.flash("\(j.name) can't run again: \(j.tool) isn't in use any more", error: true)
        }
        let s = app.savedServer(at: j.target) ?? SavedServer(target: j.target)
        let row = j.record.flatMap { r in tool.preset.list?.view.row(r, app.tools.scope(tool.preset, on: s, j.target)) }
        app.tools.perform(a, of: tool, row: row, onRow: row != nil, id: j.rowID, from: nil, on: s, j.target, values: j.values)
    }

    // MARK: Notifications

    /// macOS notifications — or tests' stand-in: whether they're allowed (nil: never asked), asking, posting one.
    struct Notices {
        var allowed: @MainActor () async -> Bool?
        var ask: @MainActor () -> Void
        var post: @MainActor (_ id: String, _ title: String, _ body: String) -> Void

        /// Only a bundled Kermo has notifications: a bare binary has no bundle to ask for (and a copy in /tmp, one that
        /// LaunchServices doesn't know, is refused unasked — S1).
        static var bundled: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

        static let system = Notices(
            allowed: {
                guard bundled else { return false }
                // What macOS says now: `requestAuthorization`'s own answer can be wrong (S1).
                let status = await withCheckedContinuation { (c: CheckedContinuation<UNAuthorizationStatus, Never>) in
                    UNUserNotificationCenter.current().getNotificationSettings { c.resume(returning: $0.authorizationStatus) }
                }
                switch status {
                case .authorized, .provisional, .ephemeral: return true
                case .denied: return false
                default: return nil
                }
            },
            ask: { if bundled { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } } },
            post: { id, title, body in
                guard bundled else { return }
                let c = UNMutableNotificationContent()
                (c.title, c.body, c.sound) = (title, body, .default)
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "job-" + id, content: c, trigger: nil))
            })
    }

    /// The first long job asks macOS for notifications (a choice of the user's at a moment they started something);
    /// never again once it's answered.
    func askToNotify() {
        Task { if await Self.notices.allowed() == nil { Self.notices.ask() } }
    }

    /// A notification clicked: Kermo in front, Activity showing — once, though a click brings both this and a reopen (S1).
    final class Clicks: NSObject, UNUserNotificationCenterDelegate {
        nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                                withCompletionHandler done: @escaping () -> Void) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let app = NSApp.delegate as? AppDelegate else { return }
                    NSApp.activate()
                    app.window.makeKeyAndOrderFront(nil)
                    if app.ops?.activityShown != true { app.ops?.showActivity(entry: nil) }
                }
            }
            done()
        }
        nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
            done([.banner, .sound])
        }
    }
    static let clicks = Clicks()
}
