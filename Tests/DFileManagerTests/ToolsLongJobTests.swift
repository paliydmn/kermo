import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Tools PR 3b: long jobs (protocol §7.6) in the app — a preset of the test's own (a launcher), run for real on this
// Mac against the bench (`ToolsBench`), HOME the bench's folder: Activity's card and its buttons, Stop…, Retry,
// "already running", a dropped follow, a relaunch reading tools/runs.json, and when the end is told by a notification.

private let deployer = #"""
    { "schema": 1, "id": "deployer", "title": "Deployer",
      "toolActions": [
        { "id": "deploy", "title": "Deploy…", "long": true, "output": "line",
          "inputs": [ { "name": "version", "type": "text", "title": "Version", "default": "v1" } ],
          "command": "echo start {version}; sleep 1; echo '{\"pct\": 50, \"step\": \"building\"}'; [ -f \"$HOME/hold\" ] && sleep 30; sleep 1; echo '{\"pct\": 100, \"release\": \"v13\"}'",
          "progress": { "percent": "pct", "text": "{step}" }, "format": "jsonl", "done": "deployed {release}" },
        { "id": "fail", "title": "Fail", "long": true, "output": "line", "command": "echo broken >&2; exit 2" },
        { "id": "partly", "title": "Partly", "long": true, "output": "line", "exitOk": [0, 3], "command": "echo some left; exit 3" },
        { "id": "unseal", "title": "Unseal", "long": true, "output": "line", "command": "echo key {key}",
          "inputs": [ { "name": "key", "type": "secret", "title": "Key" } ] }
      ] }
    """#

/// The bench with the deployer trusted, its runs in a HOME of the bench's, and macOS notifications' stand-in.
@MainActor private final class LongBench {
    let bench: ToolsBench
    let ops: OpsController
    var asked = 0, posted: [String] = []
    var allowed: Bool?
    private let was = (command: ToolRunner.command, front: ToolJobs.front, notices: ToolJobs.notices)

    init(_ app: AppDelegate) throws {
        bench = try ToolsBench()
        try FileManager.default.removeItem(atPath: bench.dir + "/bin/tail")   // fail2ban's log stand-in: a follow reads with the real one
        let own = bench.dir + "/own"
        try FileManager.default.createDirectory(atPath: own, withIntermediateDirectories: true)
        try Data(deployer.utf8).write(to: URL(fileURLWithPath: own + "/deployer.json"))
        _ = app.tools.reload()
        app.tools.trust.trust(try #require(app.tools.library.tools.first { $0.preset.id == "deployer" }))
        let base = ToolRunner.command, home = bench.dir
        ToolRunner.command = { "export HOME=\(home); " + base($0) }
        ToolJobs.front = { true }
        ops = OpsController(window: app.window) { _ in }
        ToolJobs.notices = .init(allowed: { [unowned self] in allowed }, ask: { [unowned self] in asked += 1; allowed = false },
                                 post: { [unowned self] _, title, body, _ in posted.append("\(title): \(body)") })
        ops.toolJobs = app.tools.jobs
        ToolRunner.filling = { $0.values }
    }

    func done() {
        (ToolRunner.command, ToolJobs.front, ToolJobs.notices) = (was.command, was.front, was.notices)
        ToolRunner.filling = nil
        bench.done()
    }

    var runs: String { bench.dir + "/.cache/kermo/runs" }
}

extension ServerLockTests {
    /// The deployer's launcher in a panel, read.
    @MainActor private func launcher(_ app: AppDelegate, _ a: PanelViewController, on s: SavedServer = SavedServer(target: .local())) async throws -> ListPanel {
        let source = ToolListSource(app, try toolNamed(app, "deployer"), s, .local())
        _ = try await source.read(CancelFlag())
        a.showList(source)
        return try #require(a.list)
    }

    @MainActor private func run(_ l: ListPanel, _ title: String) -> Task<Void, Never>? {
        l.shown.first { $0.title == title }?.listActions?().first { $0.title == title }?.run(false)
    }

    /// A long job starts and comes back at once: the line under the list says so, its row spins, Activity's ring counts
    /// it, its card shows the progress the log says; runs.json keeps it (0600). Its end: ✓ with `done` from the last
    /// record of the log, the row still, the line saying how it went. The first one asks macOS for notifications.
    @Test func aLongJobRunsInActivity() async throws {
        let (app, a, _, done) = try toolsApp()
        let lb = try LongBench(app)
        defer { lb.done(); done() }
        let l = try await launcher(app, a)
        await run(l, "Deploy…")?.value
        let jobs = app.tools.jobs
        let j = try #require(jobs.jobs.first)
        #expect(j.running && j.name == "Deploy" && j.values == ["version": "v1"] && j.pid > 0 && j.place == "localhost")
        #expect(l.resultLines.first?.contains("Deploy: started on localhost at ") == true, "\(l.resultLines)")
        #expect(l.shown.first { $0.title == "Deploy…" }?.busy == true, "its row spins while it runs")
        #expect(lb.ops.toolbarItem.toolTip?.contains("1 running") == true, "\(lb.ops.toolbarItem.toolTip ?? "")")
        #expect(lb.asked == 1, "the first long job asks for notifications")
        let file = lb.bench.dir + "/own/runs.json"
        await toolsUntil { FileManager.default.fileExists(atPath: file) }   // written off the main thread (`Config.writes`)
        #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int) == 0o600)

        await toolsUntil { jobs.state(j.id)?.fraction == 0.5 }
        #expect(jobs.state(j.id)?.line == "building")
        await toolsUntil { jobs.job(j.id)?.running == false }
        let end = try #require(jobs.job(j.id))
        #expect(end.exit == 0 && end.said == "deployed v13" && end.unseen == nil, "\(end)")
        #expect(l.shown.first { $0.title == "Deploy…" }?.busy == false)
        #expect(l.resultLines.last == "✓ Deploy on localhost: deployed v13", "\(l.resultLines)")
        #expect(FileManager.default.fileExists(atPath: lb.runs + "/\(j.id).log"))
        #expect(lb.posted.isEmpty, "in front, and quick: no notification")

        await run(l, "Fail")?.value
        await toolsUntil { jobs.jobs.first?.running == false && jobs.jobs.first?.action == "fail" }
        let failed = try #require(jobs.jobs.first)
        #expect(failed.exit == 2 && failed.said == "exit 2: broken" && failed.unseen == true, "\(failed)")
        #expect(lb.ops.toolbarItem.toolTip?.contains("finished") == true, "a failure: red, as a copy's errors")
        lb.ops.showActivity(entry: nil)
        #expect(jobs.unseen == 0)

        await run(l, "Partly")?.value   // its exitOk: 3 is ✓ too
        await toolsUntil { jobs.jobs.first?.running == false && jobs.jobs.first?.action == "partly" }
        let partly = try #require(jobs.jobs.first)
        #expect(partly.exit == 3 && partly.ok && partly.unseen == nil && l.resultLines.last?.hasPrefix("✓ Partly on localhost") == true, "\(partly) \(l.resultLines)")

        ToolRunner.filling = { form in form.set("key", "hunter2-xyz"); return form.values }
        await run(l, "Unseal")?.value
        await toolsUntil { jobs.jobs.first?.running == false && jobs.jobs.first?.action == "unseal" }
        let sealed = try #require(jobs.jobs.first)
        #expect(sealed.values.isEmpty && String(decoding: jobs.state(sealed.id)?.text ?? Data(), as: UTF8.self) == "key •••\n")
        #expect(!(try String(contentsOfFile: file, encoding: .utf8)).contains("hunter2"), "runs.json keeps no secret")
    }

    /// A folder input (§7.4): packed on this Mac and uploaded before its job starts — the command gets the upload's path
    /// under the home folder, from `/`, without what's left out (`node_modules`) — and gone once the job ends. The folder
    /// is remembered on that server (the next form starts with it), and a Retry gets it, not the upload's path. A file
    /// last changed a month ago isn't swept as a week old by its own start; a folder that can't be packed (a repository
    /// with nothing committed) runs nothing.
    @Test func aFolderIsUploadedBeforeItsJob() async throws {
        let (app, a, _, done) = try toolsApp()
        let lb = try LongBench(app)
        let home = lb.bench.dir
        defer { app.savedServers = []; lb.done(); done() }
        let src = home + "/src", fm = FileManager.default
        try fm.createDirectory(atPath: src + "/node_modules/x", withIntermediateDirectories: true)
        try Data("a".utf8).write(to: URL(fileURLWithPath: src + "/a.txt"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: src + "/node_modules/x/y.js"))
        try Data("#!/bin/sh\ncd \(home) || exit 1\nexec /usr/libexec/sftp-server\n".utf8).write(to: URL(fileURLWithPath: home + "/sftp-server"))
        chmod(home + "/sftp-server", 0o755)
        try Data(#"""
            { "schema": 1, "id": "shipper", "title": "Shipper",
              "toolActions": [ { "id": "ship", "title": "Ship…", "long": true, "output": "line", "done": "shipped",
                "inputs": [ { "name": "src", "type": "folder", "title": "Folder", "remember": true } ],
                "command": "echo {src}; tar -tzf {src} | sort | tr '\n' ' '" },
              { "id": "note", "title": "Note…", "long": true, "output": "line", "command": "cat {note}",
                "inputs": [ { "name": "note", "type": "file", "title": "File" } ] } ] }
            """#.utf8).write(to: URL(fileURLWithPath: home + "/own/shipper.json"))
        _ = app.tools.reload()
        app.tools.trust.trust(try #require(app.tools.library.tools.first { $0.preset.id == "shipper" }))
        let t = SFTPTarget.local(server: home + "/sftp-server"), server = try #require(SavedServer(address: "localhost"))
        app.savedServers = [server]
        let source = ToolListSource(app, try toolNamed(app, "shipper"), server, t)
        _ = try await source.read(CancelFlag())
        a.showList(source)
        let l = try #require(a.list)
        var offered: String?
        ToolRunner.filling = { form in offered = form.values["src"]; form.set("src", src); return form.values }
        await run(l, "Ship…")?.value
        let jobs = app.tools.jobs, j = try #require(jobs.jobs.first)
        #expect(offered == "" && j.values == ["src": src], "\(j.values)")
        await toolsUntil { jobs.job(j.id)?.running == false }
        let log = String(decoding: jobs.state(j.id)?.text ?? Data(), as: UTF8.self)
        #expect(log.hasPrefix("\(home)/.cache/kermo/upload/\(j.id).src.tar.gz\n") && log.contains("./a.txt") && !log.contains("node_modules"), "\(log)")
        let uploads = try fm.contentsOfDirectory(atPath: home + "/.cache/kermo/upload")
        #expect(jobs.job(j.id)?.exit == 0 && uploads.isEmpty, "the upload went with its job: \(uploads)")
        #expect(app.tools.settings.remembered("shipper", on: server.id.uuidString, row: nil) == ["src": src])

        await run(l, "Ship…")?.value
        #expect(offered == src, "the folder chosen last time on this server")
        await toolsUntil { jobs.jobs.first?.running == false }
        #expect(jobs.jobs.count == 2 && jobs.jobs.first?.exit == 0)
        #expect(ToolRunner.Upload(input: "src", local: src, remote: "x", folder: true).said == "Uploads \(src) first, without .git, node_modules and .DS_Store.")

        let old = home + "/old.txt"
        try Data("old\n".utf8).write(to: URL(fileURLWithPath: old))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: old)
        ToolRunner.filling = { form in form.set("note", old); return form.values }
        await run(l, "Note…")?.value
        let n = try #require(jobs.jobs.first)
        await toolsUntil { jobs.job(n.id)?.running == false }
        #expect(jobs.job(n.id)?.exit == 0 && String(decoding: jobs.state(n.id)?.text ?? Data(), as: UTF8.self) == "old\n", "kept till its command read it")

        let empty = home + "/empty"
        try fm.createDirectory(atPath: empty, withIntermediateDirectories: true)
        let git = Process()
        (git.executableURL, git.arguments) = (URL(fileURLWithPath: "/usr/bin/git"), ["-C", empty, "init", "-q"])
        try git.run()
        git.waitUntilExit()
        var said = ToolRunner.Upload(input: "src", local: empty, remote: "x", folder: true)
        said.repository = true
        #expect(said.said == "Uploads \(empty) as committed (git archive HEAD).", "nothing uncommitted: nothing to warn of")
        said.uncommitted = 3
        #expect(said.said == "Uploads \(empty) as committed (git archive HEAD). ⚠ 3 changes not committed stay here.")
        ToolRunner.filling = { form in form.set("src", empty); return form.values }
        await run(l, "Ship…")?.value
        #expect(jobs.jobs.count == 3, "nothing started")
        #expect(l.resultLines.last?.contains("Ship: empty wasn't uploaded: ") == true && l.resultLines.last?.hasSuffix("nothing ran") == true, "\(l.resultLines)")
    }

    /// A long job on a list's row: once it's over the list is read again, as after any change — the row shows what the
    /// job left, with no Refresh. A tool's own long job (no row: the first deploy to an empty list) too.
    @Test func aListIsReadAgainWhenItsJobEnds() async throws {
        let (app, a, _, done) = try toolsApp()
        let lb = try LongBench(app)
        defer { lb.done(); done() }
        let home = lb.bench.dir
        try Data("api old\n".utf8).write(to: URL(fileURLWithPath: home + "/units"))
        try Data(#"""
            { "schema": 1, "id": "units", "title": "Units",
              "list": { "command": "cat \"$HOME/units\"", "format": "regex", "pattern": "^(?<unit>\\S+) (?<v>\\S+)$", "key": "{unit}", "title": "{unit}", "subtitle": "{v}" },
              "actions": [ { "id": "bump", "title": "Bump", "key": "f5", "long": true, "output": "line", "command": "echo \"{unit} new\" > \"$HOME/units\"" } ],
              "toolActions": [ { "id": "add", "title": "Add", "long": true, "output": "line", "command": "echo \"web v1\" >> \"$HOME/units\"" } ] }
            """#.utf8).write(to: URL(fileURLWithPath: home + "/own/units.json"))
        _ = app.tools.reload()
        app.tools.trust.trust(try #require(app.tools.library.tools.first { $0.preset.id == "units" }))
        let source = ToolListSource(app, try toolNamed(app, "units"), SavedServer(target: .local()), .local())
        _ = try await source.read(CancelFlag())
        a.showList(source)
        let l = try #require(a.list)
        #expect(l.shown.map(\.subtitle) == ["old"])
        await l.shown.first?.listActions?().first { $0.title == "Bump" }?.run(false)?.value
        let jobs = app.tools.jobs, j = try #require(jobs.jobs.first)
        await toolsUntil { jobs.job(j.id)?.running == false }
        await toolsUntil { l.shown.first?.subtitle == "new" }
        #expect(l.shown.map(\.subtitle) == ["new"] && jobs.job(j.id)?.exit == 0, "\(l.shown.map(\.subtitle))")

        await l.content?.actions?().first { $0.title == "Add" }?.run(false)?.value
        await toolsUntil { l.shown.count == 2 }
        #expect(l.shown.map(\.title) == ["api", "web"], "\(l.shown.map(\.title))")
    }

    /// One at a time on a row: a second Deploy says it runs and shows Activity. Stop… ends it (exit 143, "stopped");
    /// Retry runs it again with the form filled in as before.
    @Test func stopRetryAndAlreadyRunning() async throws {
        let (app, a, _, done) = try toolsApp()
        let lb = try LongBench(app)
        defer { lb.done(); done() }
        lb.bench.flag("hold")
        let l = try await launcher(app, a)
        ToolRunner.filling = { form in form.set("version", "v7"); return form.values }
        await run(l, "Deploy…")?.value
        let jobs = app.tools.jobs, j = try #require(jobs.jobs.first)
        await toolsUntil { jobs.state(j.id)?.fraction == 0.5 }

        _ = run(l, "Deploy…")
        #expect(app.active.statusText == "Deploy is already running on localhost — Activity (⌥⌘J) follows it", "\(app.active.statusText)")
        #expect(jobs.jobs.count == 1)

        jobs.stop(j)
        await toolsUntil { jobs.job(j.id)?.running == false }
        #expect(jobs.job(j.id)?.exit == 143 && jobs.job(j.id)?.said == "stopped", "\(String(describing: jobs.job(j.id)))")

        var offered = ""
        ToolRunner.filling = { form in offered = form.values["version"] ?? ""; return form.values }
        lb.bench.flag("hold", false)
        jobs.retry(try #require(jobs.job(j.id)))
        await toolsUntil { jobs.jobs.count == 2 }
        #expect(offered == "v7" && jobs.jobs.first?.values == ["version": "v7"])
        await toolsUntil { jobs.jobs.first?.running == false }
        #expect(jobs.jobs.first?.said == "deployed v13")
    }

    /// The connection goes mid-job: the card says the job runs on; once a connection is up again it's followed from where
    /// it was left — the log whole, nothing twice.
    @Test func aDroppedFollowReattaches() async throws {
        let (app, a, _, done) = try toolsApp()
        let lb = try LongBench(app)
        defer { lb.done(); done(); ToolRunner.hasMaster = { _ in true } }
        let l = try await launcher(app, a)
        await run(l, "Deploy…")?.value
        let jobs = app.tools.jobs, j = try #require(jobs.jobs.first)
        await toolsUntil { jobs.state(j.id)?.line == "start v1" || jobs.state(j.id)?.fraction != nil }
        ToolRunner.hasMaster = { _ in false }
        jobs.state(j.id)?.follow?.cancel()
        await toolsUntil { jobs.state(j.id)?.lost == true }
        #expect(jobs.job(j.id)?.running == true)
        ToolRunner.hasMaster = { _ in true }
        for _ in 0..<5 { await toolsUntil { jobs.job(j.id)?.running == false } }   // the next look (every 5 s)
        let text = String(decoding: jobs.state(j.id)?.text ?? Data(), as: UTF8.self)
        #expect(jobs.job(j.id)?.said == "deployed v13" && text.components(separatedBy: "start v1").count == 2, "\(text)")
    }

    /// A relaunch: the jobs come from tools/runs.json; one still running is followed once its server's connection is up —
    /// never a login for it — and ends as ever. It took over a minute and Kermo isn't in front: a notification, or where
    /// they're off, the Dock's badge.
    @Test func aRelaunchFollowsAgainAndTellsTheEnd() async throws {
        let (app, a, _, done) = try toolsApp()
        let lb = try LongBench(app)
        defer { lb.done(); done(); ToolRunner.hasMaster = { _ in true } }
        let l = try await launcher(app, a)
        await run(l, "Deploy…")?.value
        let j = try #require(app.tools.jobs.jobs.first)
        let file = URL(fileURLWithPath: lb.bench.dir + "/own/runs.json")
        var saved = try JSONDecoder().decode([ToolJob].self, from: Data(contentsOf: file))
        saved[0].started = Date().addingTimeInterval(-120)
        try JSONEncoder().encode(saved).write(to: file)

        ToolRunner.hasMaster = { _ in false }
        ToolJobs.front = { false }
        lb.allowed = false
        ToolJobs.loaded = { _ in .local() }
        defer { ToolJobs.loaded = { $0 } }
        let relaunched = ToolJobs(app)
        lb.ops.toolJobs = relaunched
        #expect(relaunched.job(j.id)?.running == true && relaunched.state(j.id)?.follow == nil, "not connected: not followed")
        ToolRunner.hasMaster = { _ in true }
        for _ in 0..<5 { await toolsUntil { relaunched.job(j.id)?.running == false } }
        let end = try #require(relaunched.job(j.id))
        #expect(end.said == "deployed v13", "the last of the log read after the relaunch: \(end)")
        await toolsUntil { relaunched.unseen == 1 }
        #expect(relaunched.unseen == 1 && lb.posted.isEmpty, "notifications off: the Dock's badge")

        #expect(ToolJobs.notice(took: 61, front: false, allowed: true) == .notification)
        #expect(ToolJobs.notice(took: 61, front: true, allowed: true) == .none && ToolJobs.notice(took: 59, front: false, allowed: true) == .none)
        #expect(ToolJobs.notice(took: 61, front: false, allowed: nil) == .badge)
    }

    /// On production a long job asks as any change; Show Exactly What Runs shows its start — the job
    /// put in a session of its own, its log under ~/.cache/kermo/runs — with the id the job then has.
    @Test func exactlyWhatRunsIsTheJobsStart() async throws {
        let (app, a, _, done) = try toolsApp()
        let lb = try LongBench(app)
        defer { lb.done(); done() }
        var prod = SavedServer(address: "localhost")!
        prod.prod = true
        ServerLock.servers = { [prod] }
        let l = try await launcher(app, a, on: prod)
        var asked: [String] = [], exactly = ""
        AppDelegate.answering = { m, b, _ in
            asked.append(m)
            if m.hasPrefix("Exactly") { exactly = AppDelegate.answeredInfo; return 0 }
            if asked.count == 1 { return b.firstIndex(of: "Show Exactly What Runs")! }
            return 0
        }
        await run(l, "Fail")?.value
        #expect(asked == ["Fail on localhost?", "Exactly what runs on localhost", "Fail on localhost?"], "\(asked)")
        let j = try #require(app.tools.jobs.jobs.first)
        #expect(exactly.contains("setsid") && exactly.contains(".cache/kermo/runs/\(j.id).log") && exactly.contains("exit 2"), "\(exactly)")
    }
}

/// A row's long subtitle (a launcher's command) stays on its line, cut in the middle, and a long detail gives way
/// before the title does.
@MainActor @Test func aPickerRowStaysOneLine() {
    let cell = PickerCell()
    cell.show(title: "Upgrade Packages…", subtitle: String(repeating: "for i in $(seq 1 14); do echo step; done; ", count: 4), detail: "⌘U")
    let style = cell.title.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    #expect(style?.lineBreakMode == .byTruncatingMiddle)
    #expect(cell.detail.contentCompressionResistancePriority(for: .horizontal) < cell.title.contentCompressionResistancePriority(for: .horizontal))
}
