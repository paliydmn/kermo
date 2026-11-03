import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Tools PR 8b: Install (protocol §10.6) from a tool's page — a tool of the test's own whose program isn't on the
// "server" (this Mac, the bench's stand-ins first on PATH, apt-get one of them): where installs are off, its checks,
// the question with the exact command, the job in Activity, installed.json; a script fetched (file:// here) and taken
// only with its sha256. Clean Up Kermo Files on the bench's HOME.

/// `thing`'s preset: not there till its apt-get stand-in makes it; `extra` goes into its `install`.
private func thing(_ extra: String = "") -> String {
    #"""
    { "schema": 1, "id": "thing", "title": "Thing", "tool": "thing", "requires": "command -v thing", "command": "thing status",
      "version": { "command": "thing --version", "pattern": "thing (?<v>\\S+)" },
      "install": { "apt": "apt-get install -y thing", "after": "thing starts off",
                   "leaves": { "services": ["thing"], "paths": ["/usr/bin/thing"] }\#(extra) } }
    """#
}

/// `#require` reflects what it's given, and an app's unowned references end the run when it fails: a plain guard.
private func need<T>(_ v: T?, _ what: String) throws -> T {
    guard let v else { Issue.record("no \(what)"); throw CancellationError() }
    return v
}

/// The bench with `thing` trusted, apt-get's stand-in, long jobs' HOME the bench's, notifications' stand-in.
@MainActor private final class InstallBench {
    let bench: ToolsBench
    let server = SavedServer(address: "localhost")!
    private let was = (command: ToolRunner.command, front: ToolJobs.front, notices: ToolJobs.notices)

    init(_ app: AppDelegate, preset: String = thing()) throws {
        bench = try ToolsBench()
        let dir = bench.dir
        try FileManager.default.removeItem(atPath: dir + "/bin/tail")   // fail2ban's log stand-in: a follow reads with the real one
        try Data("#!/bin/sh\necho \"apt-get $*\" >> \(dir)/calls.log\nprintf '#!/bin/sh\\necho thing 1.2\\n' > \(dir)/bin/thing; chmod +x \(dir)/bin/thing\necho Setting up thing\n".utf8)
            .write(to: URL(fileURLWithPath: dir + "/bin/apt-get"))
        chmod(dir + "/bin/apt-get", 0o755)
        try FileManager.default.createDirectory(atPath: dir + "/own", withIntermediateDirectories: true)
        try Data(preset.utf8).write(to: URL(fileURLWithPath: dir + "/own/thing.json"))
        _ = app.tools.reload()
        app.tools.trust.trust(try need(app.tools.library.tools.first { $0.preset.id == "thing" }, "thing"))
        app.savedServers = [server]
        AppDelegate.connected = { _ in true }
        let base = ToolRunner.command
        ToolRunner.command = { "export HOME=\(dir); " + base($0) }
        ToolJobs.front = { true }
        ToolJobs.notices = .init(allowed: { false }, ask: {}, post: { _, _, _, _ in })
    }

    func done(_ app: AppDelegate) {
        (ToolRunner.command, ToolJobs.front, ToolJobs.notices) = (was.command, was.front, was.notices)
        app.savedServers = []
        bench.done()
    }

    /// The server's facts and tools, asked once it's "connected" — at `.local()`: a saved localhost's own target is ssh's.
    func asked(_ app: AppDelegate) async throws -> ToolBatch.Answer {
        app.tools.askAgain()
        _ = app.tools.answer(.local())
        await toolsUntil { app.tools.answer(.local()) != nil }
        return try need(app.tools.answer(.local())?.answer, "an answer")
    }
}

extension ServerLockTests {
    /// Not there, and installs allowed: Install… asks with the exact command, as root, what stays, `after`; runs as a
    /// long job; at its end the server is asked again — thing is there — and installed.json keeps it with the version
    /// its `version` reads. Installs off (production's default), a read-only server: why not, and nothing runs.
    @Test func installRunsAsALongJobAndIsRemembered() async throws {
        let (app, _, _, done) = try toolsApp()
        let ib = try InstallBench(app)
        defer { ib.done(app); done() }
        let a = try await ib.asked(app)
        let tool = try toolNamed(app, "thing")
        #expect(a.facts.pkg == "apt-get" && !a.has(tool.preset), "\(a)")
        #expect(app.tools.whyNoInstall(tool, on: ib.server, .local()) == nil)
        var prod = ib.server
        prod.prod = true
        #expect(app.tools.whyNoInstall(tool, on: prod, .local()) == "installs are off for production (Edit Server…)")
        prod.installs = true
        #expect(app.tools.whyNoInstall(tool, on: prod, .local()) == nil, "turned on there")
        var ro = ib.server
        ro.readOnly = true
        #expect(await app.tools.install(tool, on: ro, .local()) == "Install thing: read-only: no installs — nothing ran")

        let page = ToolsTool(app, tool, from: "My Tools") {}
        #expect(page.buttons("Install…").count == 1, "its row: Install…")
        var asked: [String] = [], info = ""
        AppDelegate.answering = { m, _, _ in asked.append(m); info = AppDelegate.answeredInfo; return 0 }
        #expect(await app.tools.install(tool, on: ib.server, .local()) == nil)
        await toolsUntil { app.tools.jobs.jobs.first?.running == false }
        let j = try need(app.tools.jobs.jobs.first, "the job")
        #expect(asked == ["Install thing on localhost?"], "\(asked)")
        #expect(info.contains("apt-get install -y thing") && info.contains("Stays on the server after it: services thing; /usr/bin/thing.")
                && info.contains("thing starts off"), "\(info)")
        #expect(j.action == ToolInstall.actionID && j.ok && j.root && j.said == "thing starts off", "\(j)")
        #expect(ib.bench.calls.contains("apt-get install -y thing"))
        await toolsUntil { !app.tools.installed.isEmpty }
        let r = try need(app.tools.installed.first, "the record")
        #expect(r.server == ib.server.id.uuidString && r.tool == "thing" && r.version == "1.2" && r.command == "apt-get install -y thing", "\(r)")
        Config.flush()
        #expect(try String(contentsOfFile: ib.bench.dir + "/own/installed.json", encoding: .utf8).contains("\"version\" : \"1.2\""))
        #expect(app.tools.installedSaid(on: ib.server).first?.hasPrefix("thing 1.2, ") == true)
        await toolsUntil { app.tools.answer(.local())?.answer.has(tool.preset) == true }
        #expect(app.tools.answer(.local())?.answer.has(tool.preset) == true, "asked again: thing is there now")
        page.refresh()
        #expect(page.buttons("Install…").isEmpty)
    }

    /// A precheck that fails stops Install before the question, with its title and what it found.
    @Test func aFailedPrecheckStopsInstall() async throws {
        let (app, _, _, done) = try toolsApp()
        let ib = try InstallBench(app, preset: thing(#", "precheck": [ { "title": "Podman 4.8 or newer", "command": "echo podman 4.3", "pattern": "(?<v>\\d+\\.\\d+)", "min": "4.8" } ]"#))
        defer { ib.done(app); done() }
        _ = try await ib.asked(app)
        var asked = 0
        AppDelegate.answering = { _, _, _ in asked += 1; return 0 }
        #expect(await app.tools.install(try toolNamed(app, "thing"), on: ib.server, .local()) == "Install thing on localhost: Podman 4.8 or newer is needed (found 4.3) — nothing ran")
        #expect(asked == 0 && app.tools.jobs.jobs.isEmpty && !ib.bench.calls.contains { $0.hasPrefix("apt-get") })
    }

    /// Where the system has no command of the tool's, its script: fetched on this Mac, run only if its sha256 is the
    /// one the tool names — its text on stdin, its env as variables; another sha256: nothing runs.
    @Test func aScriptInstallRunsOnlyWithItsSha256() async throws {
        let (app, _, _, done) = try toolsApp()
        let script = "echo \"script $THING_VERSION\" >> \"$HOME/calls.log\"\n", sum = ToolCatalog.sum(Data(script.utf8))
        let ib = try InstallBench(app, preset: thing().replacingOccurrences(of: #""apt": "apt-get install -y thing", "#, with: ""))
        defer { ib.done(app); done() }
        let url = URL(fileURLWithPath: ib.bench.dir + "/install.sh")
        try Data(script.utf8).write(to: url)
        func preset(_ sha: String) -> String {
            thing(#", "script": { "url": "\#(url.absoluteString)", "env": { "THING_VERSION": "1.2" }, "sha256": "\#(sha)" }"#)
                .replacingOccurrences(of: #""apt": "apt-get install -y thing", "#, with: "")
        }
        func use(_ text: String) throws -> LoadedTool {
            try Data(text.utf8).write(to: URL(fileURLWithPath: ib.bench.dir + "/own/thing.json"))
            _ = app.tools.reload()
            app.tools.trust.trust(try need(app.tools.library.tools.first { $0.preset.id == "thing" }, "thing"))
            return try toolNamed(app, "thing")
        }
        var info = ""
        AppDelegate.answering = { _, _, _ in info = AppDelegate.answeredInfo; return 0 }
        _ = try await ib.asked(app)
        let wrong = try use(preset(String(repeating: "0", count: 64)))
        #expect(await app.tools.install(wrong, on: ib.server, .local())?.contains("isn't the one the tool names (sha256 \(sum.prefix(12))…") == true)
        #expect(app.tools.jobs.jobs.isEmpty)
        let right = try use(preset(sum))
        _ = try await ib.asked(app)
        #expect(await app.tools.install(right, on: ib.server, .local()) == nil)
        await toolsUntil { app.tools.jobs.jobs.first?.running == false }
        #expect(app.tools.jobs.jobs.first?.ok == true && ib.bench.calls.contains("script 1.2"), "\(ib.bench.calls)")
        #expect(info.contains("sh -s < \(url.absoluteString)") && info.contains("fetched on this Mac and checked: sha256 \(sum.prefix(12))…, with THING_VERSION=1.2"), "\(info)")
    }

    /// Clean Up Kermo Files: the folder's size, asked, then gone; nothing there — said so.
    @Test func cleanUpRemovesKermosFilesAsked() async throws {
        let (app, _, _, done) = try toolsApp()
        let ib = try InstallBench(app)
        defer { ib.done(app); done() }
        #expect(await app.tools.cleanUp(on: ib.server, .local(), window: nil).line == "No Kermo files on localhost")
        try FileManager.default.createDirectory(atPath: ib.bench.dir + "/.cache/kermo/runs", withIntermediateDirectories: true)
        try Data(repeating: 65, count: 5000).write(to: URL(fileURLWithPath: ib.bench.dir + "/.cache/kermo/runs/1-a.log"))
        var asked: [String] = []
        AppDelegate.answering = { m, b, _ in asked.append(m); return b.count - 1 }   // Cancel
        #expect(await app.tools.cleanUp(on: ib.server, .local(), window: nil).line == "Kermo's files on localhost: kept")
        AppDelegate.answering = { m, _, _ in asked.append(m); return 0 }
        let r = await app.tools.cleanUp(on: ib.server, .local(), window: nil)
        #expect(r.line.hasPrefix("Kermo's files on localhost are removed (") && !r.failed, "\(r)")
        #expect(asked == ["Remove Kermo's files on localhost?", "Remove Kermo's files on localhost?"])
        #expect(!FileManager.default.fileExists(atPath: ib.bench.dir + "/.cache/kermo"))
    }
}

private extension NSView {
    /// The buttons titled `title` in this view, at any depth.
    func buttons(_ title: String) -> [NSButton] {
        subviews.flatMap { ($0 as? NSButton).map { $0.title == title ? [$0] : [] } ?? $0.buttons(title) }
    }
}
