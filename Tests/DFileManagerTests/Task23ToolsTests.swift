import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 23 PR 2a: the assistant's tools through the gate — one chain for every call, no model, no network.

@MainActor private var keptApps: [AppDelegate] = []

@MainActor private func aiApp(_ dir: String) -> AppDelegate {
    _ = NSApplication.shared
    let app = AppDelegate()
    keptApps.append(app)
    app.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    app.window.contentView = host
    app.terminal = EmbeddedTerminal(covering: host)
    app.ops = OpsController(window: app.window) { [unowned app] in app.jobFinished($0) }
    app.panels = [PanelViewController(tabs: [dir], index: 0, showHidden: false), PanelViewController(tabs: [dir], index: 0, showHidden: false)]
    app.panels.forEach { $0.loadViewIfNeeded() }
    return app
}

extension ServerLockTests {   // swap `ServerLock.servers` and `authenticate`
    private var box: SFTPTarget { .local(port: 1) }

    /// A session on a saved server "box" (this Mac's sftp-server) with a folder of its own; `asked` hears every
    /// question's title, `answers` are given in turn (0: the action; none left: Cancel).
    private func aiAnswering(locked: Bool = false, prod: Bool = false) async throws -> (session: AISession, dir: String, asked: () -> [String], answer: ([Int]) -> Void) {
        let (session, dir, asked, answer) = try aiSetUp()
        // "box" that answers: this Mac's sftp-server and /bin/sh, as a panel shows it — the saved one is only its
        // name and tags (an address read back from the list is a real ssh's).
        var saved = SavedServer(target: .local(port: 2))
        (saved.name, saved.locked, saved.prod) = ("box", locked, prod)
        ServerLock.servers = { [saved] }
        let panel = session.app.panels[1]
        panel.loadRemote(.local(port: 2), dir: dir, select: nil)
        for _ in 0..<300 where panel.remote?.dir != dir { try? await Task.sleep(for: .milliseconds(10)) }
        try #require(panel.remote?.dir == dir)
        return (session, dir, asked, answer)
    }

    private func aiSetUp(locked: Bool = false, prod: Bool = false) throws -> (session: AISession, dir: String, asked: () -> [String], answer: ([Int]) -> Void) {
        let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t23-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var s = SavedServer(target: box)
        (s.name, s.locked, s.prod) = ("box", locked, prod)
        ServerLock.servers = { [s] }
        final class Heard { var titles: [String] = [], answers: [Int] = [] }
        let heard = Heard()
        let session = AISession(app: aiApp(dir)) { c, _ in
            heard.titles.append(c.title)
            return heard.answers.isEmpty ? c.buttons.count - 1 : heard.answers.removeFirst()
        }
        return (session, dir, { heard.titles }, { heard.answers = $0 })
    }

    private func aiTearDown(_ s: AISession, _ dir: String) {
        ServerLock.servers = { [] }
        ServerLock.relock()
        s.app.panels.forEach { $0.shutdown() }
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// A tool that would write `path` on `server`; its runner only counts.
    private var writes: AITool {
        AITool(name: "test_write", about: "", kind: .write, params: [.init(name: "server", about: ""), .init(name: "path", about: "")],
               places: [.init(server: "server", path: "path", access: .write)])
    }

    /// Outside the scope: asked to allow; in it, writing over what may be there asks each time; a Cancel at either
    /// leaves the runner unrun. What doesn't fit the tool is refused without a question.
    @Test func everyCallGoesThroughTheScopeAndTheGate() async throws {
        let (s, dir, asked, answer) = try aiSetUp()
        defer { aiTearDown(s, dir) }
        var ran = 0
        let run: AISession.Runner = { _, _, _ in ran += 1; return AIResult("done") }
        let args: [String: ToolValue] = ["server": "box", "path": .string(dir + "/a.txt")]

        var r = await s.call(writes, args, run: run)   // Cancel on "Allow…"
        #expect(r.isError && ran == 0 && asked().count == 1 && asked()[0].hasPrefix("Allow the assistant") && s.scope.grants.isEmpty)
        #expect(s.journal.last?.decision == "not allowed")
        let (unfit, none) = (await s.call("copy", [:]).text, await s.call("move", [:]).text)
        #expect(unfit.contains("doesn't fit") && none.contains("no tool"))
        #expect(AITools.all.allSatisfy { AISession.runners[$0.name] != nil || AISession.looks[$0.name] != nil }, "every tool told to a model can be called")

        answer([0])   // allowed for the task, then Cancel on "write over"
        r = await s.call(writes, args, run: run)
        #expect(r.isError && ran == 0 && asked().count == 3 && asked()[2].contains("write over"), "\(asked())")
        #expect(s.scope.grants.count == 1 && s.journal.last?.decision == "asked: overwrites, cancelled")

        answer([0])   // in scope now: only the overwrite question
        r = await s.call(writes, args, run: run)
        #expect(r == AIResult("done") && ran == 1 && asked().count == 4 && s.journal.last?.decision == "asked: overwrites, allowed")
        #expect(s.hasRead && s.journal.last?.afterRead == false)   // a server answered: every later call is marked

        // Refused in words, nobody asked, nothing run: a relative path, `..`, `~` on a server, a server nobody knows,
        // an argument the tool doesn't have, and a change from a tool that says it only reads.
        let before = asked().count
        for bad: [String: ToolValue] in [["server": "box", "path": "a.txt"], ["server": "box", "path": .string(dir + "/../x")], ["server": "box", "path": "~/x"],
                                         ["server": "nobody", "path": "/x"], ["server": "box", "path": "/x", "more": "1"], ["server": "box"]] {
            r = await s.call(writes, bad, run: run)
            #expect(r.isError && s.journal.last?.decision.hasPrefix("refused") == true && s.journal.last?.afterRead == true, "\(bad) \(r.text) \(String(describing: s.journal.last))")
        }
        var liar = writes
        liar.kind = .read
        answer([0, 0])
        r = await s.call(liar, args, run: run)
        #expect(r.isError && s.journal.last?.decision == "refused: unclear")
        #expect(ran == 1 && asked().count == before, "\(ran) \(asked())")
        #expect(await s.call("no_such_tool", [:]).isError)

        // Stopped while the question was up, then answered: nothing runs.
        s.asker = { _, _ in withUnsafeCurrentTask { $0?.cancel() }; return 0 }
        r = await Task { await s.call(writes, args, run: run) }.value
        #expect(r.isError && ran == 1 && s.journal.last?.decision == "stopped")

        // A name is one server or nobody: two saved under it aren't; a server called "mac" goes by its address.
        var twin = SavedServer(address: "me@192.0.2.42")!, mac = SavedServer(address: "me@192.0.2.43")!
        (twin.name, mac.name) = ("box", "mac")
        let saved = ServerLock.servers()
        ServerLock.servers = { saved + [twin, mac] }
        r = await s.call(writes, args, run: run)
        #expect(r.isError && ran == 1 && s.journal.last?.decision == "refused: unknown server", "\(r.text)")
        #expect(AISession.label(mac.target) == "me@192.0.2.43" && AISession.label(twin.target) == "box" && AISession.label(.local(port: 2201)).hasSuffix(":2201"))
    }

    /// A locked server asks Touch ID before anything; refused, the runner hasn't run. A production server asks for
    /// every change, whatever the chat was allowed — and its Cancel is the end of it.
    @Test func aLockedServerAndProductionAskTheAssistantToo() async throws {
        var (s, dir, asked, answer) = try aiSetUp(locked: true)
        var touch: [String] = [], unlock = false, ran = 0
        ServerLock.authenticate = { touch.append($0); return unlock }
        let run: AISession.Runner = { _, _, _ in ran += 1; return AIResult("done") }
        let args: [String: ToolValue] = ["server": "box", "path": .string(dir + "/a.txt")]
        answer([0])
        var r = await s.call(writes, args, run: run)
        #expect(r.isError && ran == 0 && touch.count == 1 && touch[0].contains("box") && s.journal.last?.decision == "locked", "\(touch)")
        #expect(asked().count == 1)   // the scope's question; the overwrite one never came
        var looks = 0   // a tool that looks first: a locked server isn't looked at either
        r = await s.call(writes, args, look: { _, _, _ in looks += 1; return .go(overwrites: false, run) })
        #expect(r.isError && looks == 0 && ran == 0 && touch.count == 2 && s.journal.last?.decision == "locked")
        unlock = true
        answer([0])
        r = await s.call(writes, args, run: run)
        #expect(!r.isError && ran == 1 && touch.count == 3)
        aiTearDown(s, dir)

        (s, dir, asked, answer) = try aiSetUp(prod: true)
        defer { aiTearDown(s, dir) }
        answer([0])
        r = await s.call("request_scope", ["server": "box", "level": "all", "why": "a test"])
        #expect(!r.isError && s.scope.grants.values.first?.level == .all)
        r = await s.call(writes, args, run: run)   // Cancel
        #expect(r.isError && ran == 1 && asked().last?.contains("production") == true, "\(asked())")
        answer([0])
        r = await s.call(writes, args, run: run)
        #expect(!r.isError && ran == 2)
    }

    /// list_folder and read_file on a server and on this Mac: asked once to read there, then free; secrets masked,
    /// a long file cut, what isn't a text file refused in words.
    @Test func theAssistantReadsFoldersAndFiles() async throws {
        let (s, dir, asked, answer) = try aiSetUp()
        defer { aiTearDown(s, dir) }
        // A server that answers: this Mac's sftp-server, not saved (a saved "localhost" would be every other suite's
        // too) — known to the session as what a panel shows.
        ServerLock.servers = { [] }
        let panel = s.app.panels[1], box = SavedServer.name(for: .local())
        panel.loadRemote(.local(), dir: dir, select: nil)
        for _ in 0..<300 where panel.remote?.dir != dir { try? await Task.sleep(for: .milliseconds(10)) }
        try #require(panel.remote?.dir == dir)
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        try Data(("pass" + "word: hunter22\nname: web\n").utf8).write(to: URL(fileURLWithPath: dir + "/app.conf"))
        try Data([0xff, 0xfe, 0x00, 0x80]).write(to: URL(fileURLWithPath: dir + "/blob"))
        try Data(("a" + String(repeating: "é", count: AISession.textLimit)).utf8).write(to: URL(fileURLWithPath: dir + "/long.txt"))   // the cut falls inside an é
        // The FIFO in a folder no panel shows: a panel's own look at its folder isn't this test's.
        let aside = dir + "-aside"
        try FileManager.default.createDirectory(atPath: aside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: aside) }
        #expect(mkfifo(aside + "/pipe", 0o600) == 0)

        var r = await s.call("list_folder", ["server": .string(box), "path": .string(dir)])   // Cancel: not allowed to read there
        #expect(r.isError && asked().count == 1 && !s.hasRead)
        for server in ["mac", box] {   // this Mac first: reading it marks nothing
            answer([0])
            r = await s.call("list_folder", ["server": .string(server), "path": .string(dir)])
            #expect(!r.isError && r.text.contains("app.conf\t29\t") && r.text.contains("sub/\t\t"), "\(server): \(r.text)")
            r = await s.call("read_file", ["server": .string(server), "path": .string(dir + "/app.conf")])
            #expect(!r.isError && r.text.contains("name: web") && !r.text.contains("hunter22") && r.text.contains("1 secret hidden"), "\(server): \(r.text)")
            r = await s.call("read_file", ["server": .string(server), "path": .string(dir + "/long.txt")])
            #expect(!r.isError && r.text.contains("Only the beginning is here") && r.text.count < AISession.textLimit, "\(server) \(r.text.suffix(200))")
            for (name, why) in [("blob", "isn't text"), ("sub", "isn't a file"), ("none", "Couldn't read"), ("dev/x", "a device")] {
                r = await s.call("read_file", ["server": .string(server), "path": .string(dir + "/" + name)])
                #expect(r.isError && r.text.contains(why), "\(server): \(r.text)")
            }
            r = await s.call("read_file", ["server": .string(server), "path": .string(aside + "/pipe")])
            #expect(r.isError && r.text.contains("isn't a file"), "\(server): \(r.text)")
            #expect(s.hasRead == (server == box))
        }
        #expect(asked().count == 3 && s.scope.grants.count == 2 && s.scope.grants.values.allSatisfy { $0.level == .view })
        r = await s.call("terminal_output", ["server": .string(box)])
        #expect(r.isError && r.text.contains("No terminal tab of \(box)"), "\(r.text)")
        #expect(s.journal.last?.afterRead == true && s.journal.first?.afterRead == false)
    }

    /// focus: where the panels stand is told always, their names only where the chat may read; request_scope grants
    /// what the user allowed and nothing on a Cancel or a request that makes no sense.
    @Test func focusTellsOnlyWhatTheChatMayRead() async throws {
        let (s, dir, asked, answer) = try aiSetUp()
        defer { aiTearDown(s, dir) }
        FileManager.default.createFile(atPath: dir + "/seen.txt", contents: nil)
        let panel = s.app.panels[0]
        panel.navigate(to: dir, select: "seen.txt")
        for _ in 0..<300 where panel.cursorURL?.lastPathComponent != "seen.txt" { try? await Task.sleep(for: .milliseconds(10)) }
        try #require(panel.cursorURL?.lastPathComponent == "seen.txt")

        var r = await s.call("focus", [:])
        #expect(!r.isError && r.text.contains("Active panel: mac \(dir)") && r.text.contains("not in this chat's scope") && !r.text.contains("seen.txt"), "\(r.text)")
        for bad: [String: ToolValue] in [["server": "mac", "level": "work", "why": "x"], ["server": "mac", "level": "view", "folder": "/tmp", "why": "x"],
                                         ["server": "mac", "level": "work", "folder": "tmp", "why": "x"], ["server": "nobody", "level": "view", "why": "x"]] {
            #expect(await s.call("request_scope", bad).isError, "\(bad)")
        }
        #expect(asked().isEmpty, "\(asked())")
        r = await s.call("request_scope", ["server": "mac", "level": "view", "why": "to see the folder"])   // Cancel
        #expect(r.isError && s.scope.grants.isEmpty && asked().count == 1)
        answer([0])
        r = await s.call("request_scope", ["server": "mac", "level": "work", "folder": .string(dir), "commands": true, "why": "to see the folder"])
        #expect(!r.isError && s.scope.grants[.mac] == AIScope.Grant(level: .work, folders: [dir], commands: true))
        r = await s.call("focus", [:])
        #expect(r.text.contains("cursor: seen.txt") && !s.hasRead, "\(r.text)")
    }

    /// A long text is masked before it is cut: the end kept of a terminal's output never starts inside a secret.
    @Test func textIsMaskedBeforeItIsCut() {
        let text = "DB_PASS" + "WORD=abcdefghijklmnopqrstuvwxyz\n" + String(repeating: "x", count: 10)
        let r = AISession.handOver(text, limit: 20, keepEnd: true)
        #expect(!r.text.contains("uvwxyz") && r.text.contains("Only the end is here") && r.text.contains("1 secret hidden"), "\(r.text)")
    }

    /// focus in words: a parked tab says its server, a root panel says so, the editor's and the terminal's text only
    /// where the chat may read.
    @Test func focusInWords() {
        let web = SFTPTarget(host: "web-01"), db = SFTPTarget(host: "db-01")
        let c = AIContext(active: .init(server: web.asRoot(), dir: "/etc", cursor: "hosts", targets: ["hosts", "fstab"], folder: .init(server: web.asRoot(), dir: "/etc")),
                          other: .init(dir: "/Users/me", folder: nil, parked: .init(server: db, dir: "/srv")),
                          editor: .init(server: db, path: "/srv/app.env", unsaved: true, selection: (3...4, "KEY=1\nB=2")),
                          terminal: .init(server: web, command: "$ tail log", selection: "error 42"))
        let all = AISession.focus(c, name: \.host) { _ in true }
        #expect(all == """
            Active panel: web-01 (as root) /etc
              cursor: hosts
              marked (2): hosts, fstab
            Other panel: a tab of db-01 at /srv, not connected
            Editor: db-01 /srv/app.env (unsaved changes)
              selection, lines 3–4:
            KEY=1
            B=2
            Terminal: a tab opened as web-01 — who is logged in there now isn't known
              last command line: $ tail log
              selection:
            error 42
            """, "\(all)")
        let none = AISession.focus(c, name: \.host) { _ in false }
        #expect(none == """
            Active panel: web-01 (as root) /etc
              names: not in this chat's scope
            Other panel: a tab of db-01 at /srv, not connected
            Editor: db-01 /srv/app.env (unsaved changes)
              selection, lines 3–4: not in this chat's scope
            Terminal: a tab opened as web-01 — who is logged in there now isn't known
              its text: not in this chat's scope
            """, "\(none)")
    }

    /// A production server under an ssh alias, saved as a server of its own and not learned yet: the grant asked
    /// through the alias is the server's own, and a change through either name asks as production.
    @Test func aProductionServersAliasIsTheSameServerToTheAssistant() async throws {
        let (s, dir, asked, answer) = try aiSetUp()
        let config = dir + "/config", sshG = ServerLock.sshG
        try "Host t23alias\n  HostName 192.0.2.41\n  User root\n".write(toFile: config, atomically: true, encoding: .utf8)
        var prod = SavedServer(address: "root@192.0.2.41")!, alias = SavedServer(target: SFTPTarget(host: "t23alias"))
        (prod.name, prod.prod, alias.name) = ("db", true, "alias")
        ServerLock.sshG = { SFTP.sshG($0, config: config) }
        ServerLock.servers = { [prod, alias] }
        defer { ServerLock.sshG = sshG; aiTearDown(s, dir) }
        var ran = 0
        let run: AISession.Runner = { _, _, _ in ran += 1; return AIResult("done") }
        answer([0])   // the scope; then Cancel on production
        var r = await s.call(writes, ["server": "alias", "path": "/srv/a"], run: run)
        #expect(r.isError && ran == 0 && asked().count == 2 && asked()[1].contains("production"), "\(asked())")
        r = await s.call(writes, ["server": "db", "path": "/srv/a"], run: run)   // in scope by the alias's grant; Cancel on production
        #expect(r.isError && ran == 0 && asked().count == 3 && asked()[2].contains("production") && s.scope.grants.count == 1, "\(asked())")
    }

    /// The production log in a file of the test's own; `lines` reads it once the writes are through.
    private func aiAudit(_ dir: String) -> (lines: () -> [[String: Any]], restore: () -> Void) {
        let was = AuditLog.path, off = UserDefaults.standard.object(forKey: "auditLog")
        AuditLog.path = dir + "-audit.jsonl"
        UserDefaults.standard.removeObject(forKey: "auditLog")
        let path = AuditLog.path
        return ({
            Config.flush()
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }, {
            AuditLog.path = was
            UserDefaults.standard.set(off, forKey: "auditLog")
            try? FileManager.default.removeItem(atPath: path)
        })
    }

    /// run_command: a command that only reads needs the place, one that changes needs commands allowed; it runs in
    /// its folder or not at all, has no terminal, and is waited for only so long. Never on this Mac.
    @Test func theAssistantRunsACommand() async throws {
        let (s, dir, asked, answer) = try await aiAnswering()
        let audit = aiAudit(dir), seconds = AISession.commandSeconds
        defer { aiTearDown(s, dir); audit.restore(); AISession.commandSeconds = seconds }
        func run(_ command: String, in folder: String? = dir, on server: String = "box") async -> AIResult {
            await s.call("run_command", ["server": .string(server), "command": .string(command)].merging(folder.map { ["folder": .string($0)] } ?? [:]) { $1 })
        }
        var r = await run("touch made", on: "mac")
        #expect(r.isError && r.text.contains("servers only") && asked().isEmpty, "this Mac: said before anything is asked")

        r = await run("touch made")   // Cancel at "Allow…"
        #expect(r.isError && asked().count == 1 && !FileManager.default.fileExists(atPath: dir + "/made"))
        answer([0])
        r = await run("ls -a")   // reading: the place is enough
        #expect(!r.isError && r.text.hasPrefix("exit 0\n") && s.scope.grants.values.first?.commands == false, "\(r.text)")
        answer([0])
        r = await run("touch made; echo pass" + "word: hunter22; echo oops >&2; exit 3")
        #expect(r.isError && r.text.hasPrefix("exit 3\n") && r.text.contains("[stderr]\noops") && !r.text.contains("hunter22"), "\(r.text)")
        #expect(FileManager.default.fileExists(atPath: dir + "/made") && asked().count == 3)

        r = await run("touch there", in: dir + "/none")   // no such folder: the command doesn't run somewhere else
        #expect(r.isError && !r.text.hasPrefix("exit 0") && !FileManager.default.fileExists(atPath: dir + "/there"), "\(r.text)")
        r = await run("pwd; echo it\\'s \"$PAGER\"", in: nil)
        #expect(!r.isError && r.text.contains("it's cat"), "\(r.text)")
        r = await run("read line; echo got-$line")   // nothing to read: it doesn't wait for a key
        #expect(r.text.contains("got-"), "\(r.text)")

        let stopped = Task { await run("sleep 20") }
        try await Task.sleep(for: .milliseconds(300))
        stopped.cancel()
        r = await stopped.value
        #expect(r.isError && r.text.hasPrefix("Stopped"), "\(r.text)")
        r = await run("head -c \(AISession.textLimit * 2) /dev/zero | tr '\\0' x")
        #expect(r.isError && r.text.contains("printed more than") && r.text.count < AISession.textLimit + 500, "\(r.text.prefix(200))")
        AISession.commandSeconds = 1
        let mark = "dfm-t23-follow-" + UUID().uuidString
        try Data("line\n".utf8).write(to: URL(fileURLWithPath: dir + "/" + mark))
        let began = Date()
        r = await run("tail -f \(mark)")
        #expect(r.isError && r.text.contains("No end after 1 s") && r.text.contains("line") && Date().timeIntervalSince(began) < 10, "\(r.text)")
        let left = Process()
        (left.executableURL, left.arguments, left.standardOutput) = (URL(fileURLWithPath: "/usr/bin/pgrep"), ["-f", mark], FileHandle.nullDevice)
        try left.run()
        left.waitUntilExit()
        #expect(left.terminationStatus == 1, "nothing of it left running here")
        #expect(audit.lines().isEmpty, "not a production server: no line")
        #expect(s.journal.allSatisfy { !$0.args.contains("hunter22") })
    }

    /// On a production server a command that changes asks each time, and each one run — a reading one too — is in the
    /// production log as the assistant's. server_info says the home folder: paths there are absolute.
    @Test func theAssistantsCommandsOnProductionAreLogged() async throws {
        let (s, dir, asked, answer) = try await aiAnswering(prod: true)
        let audit = aiAudit(dir)
        defer { aiTearDown(s, dir); audit.restore() }
        answer([0])   // allowed to run commands; the production question: Cancel
        var r = await s.call("run_command", ["server": .string("box"), "command": .string("touch made"), "folder": .string(dir)])
        #expect(r.isError && asked() == ["Allow the assistant this, until the chat ends?", "Let the assistant change a production server?"], "\(asked())")
        #expect(!FileManager.default.fileExists(atPath: dir + "/made") && audit.lines().isEmpty, "said no: nothing run, nothing logged")
        answer([0])
        r = await s.call("run_command", ["server": .string("box"), "command": .string("touch made"), "folder": .string(dir)])
        #expect(!r.isError && FileManager.default.fileExists(atPath: dir + "/made") && asked().count == 3, "\(r.text)")
        r = await s.call("run_command", ["server": .string("box"), "command": .string("ls")])
        #expect(!r.isError && asked().count == 3, "reading asks nothing more")
        let lines = audit.lines()
        #expect(lines.count == 2 && lines.allSatisfy { $0["by"] as? String == "ai" && $0["action"] as? String == "command" && $0["exit"] as? Int == 0 }, "\(lines)")
        #expect(lines.first?["command"] as? String == "touch made" && lines.first?["paths"] as? [String] == [dir])

        r = await s.call("server_info", ["server": .string("box")])
        #expect(!r.isError && r.text.hasPrefix("home folder: /"), "\(r.text)")
        r = await s.call("server_info", ["server": .string("mac")])
        #expect(r.isError && audit.lines().count == 3 && audit.lines().last?["command"] as? String == "server info", "what it ran on production is logged too")
    }

    /// A call of a real tool with something happening right after its look — before the question, and the write.
    private func aiCall(_ s: AISession, _ name: String, _ args: [String: ToolValue], afterLook: @escaping () -> Void) async -> AIResult {
        await s.call(AITools.all.first { $0.name == name }!, args, look: { s, args, targets in
            let looked = await AISession.looks[name]!(s, args, targets)
            afterLook()
            return looked
        })
    }

    private func aiNames(_ dir: String) -> [String] { ((try? FileManager.default.subpathsOfDirectory(atPath: dir)) ?? []).sorted() }
    private func aiText(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    /// write_file on a server and on this Mac: a new file needs only the folder; one that is there asks each time;
    /// a file that appeared or changed after the look isn't written over; a Cancel anywhere changes nothing.
    @Test func theAssistantWritesAFile() async throws {
        let (s, dir, asked, answer) = try await aiAnswering()
        let audit = aiAudit(dir)
        defer { aiTearDown(s, dir); audit.restore() }
        let temps = { ((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter { $0.hasPrefix("dfm-ai-") }.count }
        for server in ["box", "mac"] {
            let at = dir + "/" + server
            try FileManager.default.createDirectory(atPath: at, withIntermediateDirectories: true)
            func write(_ name: String, _ text: String) async -> AIResult { await s.call("write_file", ["server": .string(server), "path": .string(at + "/" + name), "text": .string(text)]) }
            answer([])
            let before = asked().count
            var r = await write("new.conf", "one\n")   // Cancel at "Allow…"
            #expect(r.isError && aiNames(at).isEmpty && asked().count == before + 1, "\(server): \(r.text)")
            answer([0])
            r = await write("new.conf", "one\n")
            #expect(!r.isError && aiText(at + "/new.conf") == "one\n" && asked().count == before + 2, "\(server): a new file asks nothing more: \(r.text)")
            r = await write("new.conf", "two\n")   // there now: Cancel
            #expect(r.isError && aiText(at + "/new.conf") == "one\n" && asked().last == "Let the assistant write over what is there?", "\(server): \(r.text)")
            answer([0])
            r = await write("new.conf", "two\n")
            #expect(!r.isError && aiText(at + "/new.conf") == "two\n", "\(server): \(r.text)")

            // After the look: a file appears where none was (no question was due), another changes under a yes.
            answer([0])   // each path is allowed on its own
            r = await aiCall(s, "write_file", ["server": .string(server), "path": .string(at + "/raced"), "text": .string("mine")]) {
                FileManager.default.createFile(atPath: at + "/raced", contents: Data("theirs".utf8))
            }
            #expect(r.isError && r.text.contains("Nothing was written") && aiText(at + "/raced") == "theirs", "\(server): \(r.text)")
            answer([0])
            r = await aiCall(s, "write_file", ["server": .string(server), "path": .string(at + "/new.conf"), "text": .string("mine")]) {
                FileManager.default.createFile(atPath: at + "/new.conf", contents: Data("theirs, longer".utf8))
            }
            #expect(r.isError && r.text.contains("Nothing was written") && aiText(at + "/new.conf") == "theirs, longer", "\(server): \(r.text)")

            // A link is never written through: not the file's own name, not a folder on the way — it would lead
            // out of the folder the user allowed.
            let out = dir + "/out-" + server
            for d in [at + "/sub", out] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
            try FileManager.default.createSymbolicLink(atPath: at + "/link", withDestinationPath: at + "/new.conf")
            try FileManager.default.createSymbolicLink(atPath: at + "/way", withDestinationPath: out)
            for (name, why) in [("sub", "isn't a text file"), ("link", "isn't a text file"), ("way/planted", "through a link: it is \(out)")] {
                answer([0, 0])   // allowed; and whatever is asked after
                r = await write(name, "x")
                #expect(r.isError && r.text.contains(why), "\(server) \(name): \(r.text)")
            }
            #expect(aiText(at + "/new.conf") == "theirs, longer" && aiNames(out).isEmpty)
            #expect(aiNames(at) == ["link", "new.conf", "raced", "sub", "way"], "\(server): nothing else left there: \(aiNames(at))")
        }
        #expect(temps() == 0 && audit.lines().isEmpty)
    }

    /// On a production server a write asks each time, a new file too, and is in the production log as the assistant's.
    @Test func theAssistantsWritesOnProductionAreLogged() async throws {
        let (s, dir, asked, answer) = try await aiAnswering(prod: true)
        let audit = aiAudit(dir)
        defer { aiTearDown(s, dir); audit.restore() }
        let args: [String: ToolValue] = ["server": .string("box"), "path": .string(dir + "/app.conf"), "text": .string("a\n")]
        answer([0])   // allowed to write there; production: Cancel
        var r = await s.call("write_file", args)
        #expect(r.isError && aiNames(dir).isEmpty && asked().last == "Let the assistant change a production server?" && audit.lines().isEmpty, "\(r.text)")
        answer([0])
        r = await s.call("write_file", args)
        #expect(!r.isError && aiText(dir + "/app.conf") == "a\n" && asked().count == 3, "one question, not the save's own too: \(r.text)")
        var notes: [String?] = []
        let asker = s.asker
        s.asker = { c, w in notes.append(c.note); return await asker!(c, w) }
        answer([0])
        r = await s.call("write_file", args.merging(["text": .string("b\n")]) { $1 })
        #expect(!r.isError && notes == ["It writes over the file that is there."] && aiText(dir + "/app.conf") == "b\n", "\(notes)")
        s.asker = asker
        try Data("src\n".utf8).write(to: URL(fileURLWithPath: dir + "-src"))
        defer { try? FileManager.default.removeItem(atPath: dir + "-src") }
        answer([0, 0])   // to read this Mac; production
        r = await s.call("copy", ["from_server": .string("mac"), "from_path": .string(dir + "-src"), "to_server": .string("box"), "to_folder": .string(dir)])
        #expect(!r.isError && aiText(dir + "/" + (dir as NSString).lastPathComponent + "-src") == "src\n", "\(r.text)")
        let lines = audit.lines()
        #expect(lines.map { $0["action"] as? String } == ["save", "save", "copy"] && lines.allSatisfy { $0["by"] as? String == "ai" && $0["exit"] as? Int == 0 }, "\(lines)")
    }

    /// copy: what isn't there yet is copied without a question; a taken name asks, and only that name is written
    /// over — inside a merged folder, and for a name taken after the look, what is there stays and is told.
    @Test func theAssistantCopies() async throws {
        let (s, dir, asked, answer) = try await aiAnswering()
        defer { aiTearDown(s, dir) }
        let src = dir + "/src", dst = dir + "/dst", fm = FileManager.default
        for d in [src + "/tree", dst] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        for (name, text) in [("one.txt", "one"), ("tree/a", "a"), ("tree/b", "b new")] { try Data(text.utf8).write(to: URL(fileURLWithPath: src + "/" + name)) }
        func copy(_ name: String, from: String = "mac", to: String = "box", into: String = dst) async -> AIResult {
            await s.call("copy", ["from_server": .string(from), "from_path": .string(src + "/" + name), "to_server": .string(to), "to_folder": .string(into)])
        }
        var r = await copy("one.txt")   // Cancel at "Allow…"
        #expect(r.isError && aiNames(dst).isEmpty && asked().count == 1, "\(r.text)")
        answer([0])
        r = await copy("one.txt")
        #expect(!r.isError && r.text.contains("1 of 1 file copied") && aiText(dst + "/one.txt") == "one" && asked().count == 2, "\(r.text)")
        try Data("one, newer".utf8).write(to: URL(fileURLWithPath: src + "/one.txt"))
        r = await copy("one.txt")   // taken: Cancel
        #expect(r.isError && aiText(dst + "/one.txt") == "one" && asked().last == "Let the assistant write over what is there?", "\(r.text)")
        answer([0])
        r = await copy("one.txt")
        #expect(!r.isError && aiText(dst + "/one.txt") == "one, newer", "\(r.text)")

        // A folder of that name there, a link, a folder reached through a link, the item's own folder: not copied.
        try fm.createDirectory(atPath: dst + "/tree", withIntermediateDirectories: true)
        try Data("b old".utf8).write(to: URL(fileURLWithPath: dst + "/tree/b"))
        try fm.createDirectory(atPath: dir + "/out", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: dst + "/way", withDestinationPath: dir + "/out")
        answer([0])
        r = await copy("tree")
        #expect(r.isError && r.text.contains("isn't a file") && aiNames(dst + "/tree") == ["b"] && aiText(dst + "/tree/b") == "b old", "\(r.text)")
        answer([0])
        r = await copy("one.txt", into: dst + "/way")
        #expect(r.isError && r.text.contains("through a link") && aiNames(dir + "/out").isEmpty, "\(r.text)")
        answer([0])
        r = await copy("one.txt", to: "mac", into: src)
        #expect(r.isError && r.text.contains("already") && aiNames(src).count == 4, "\(r.text)")
        try fm.removeItem(atPath: dst + "/way")

        try Data("mine".utf8).write(to: URL(fileURLWithPath: src + "/raced"))
        r = await aiCall(s, "copy", ["from_server": .string("mac"), "from_path": .string(src + "/raced"), "to_server": .string("box"), "to_folder": .string(dst)]) {
            fm.createFile(atPath: dst + "/raced", contents: Data("theirs".utf8))
        }
        #expect(r.isError && r.text.contains("left as they were") && aiText(dst + "/raced") == "theirs", "\(r.text)")

        answer([0])   // the other way: into a folder of this Mac
        try fm.createDirectory(atPath: dir + "/back", withIntermediateDirectories: true)
        r = await copy("tree", from: "box", to: "mac", into: dir + "/back")
        #expect(!r.isError && aiNames(dir + "/back") == ["tree", "tree/a", "tree/b"], "\(r.text)")
        r = await copy("none")
        #expect(r.isError && aiNames(dst) == ["one.txt", "raced", "tree", "tree/b"], "\(r.text)")

        // Stopped on its way: no file cut short stays.
        let big = src + "/big.bin"
        fm.createFile(atPath: big, contents: Data(count: 48 << 20))
        let call = Task { await copy("big.bin") }
        try await Task.sleep(for: .milliseconds(60))
        call.cancel()
        r = await call.value
        let left = (try fm.contentsOfDirectory(atPath: dst)).filter { !["one.txt", "raced", "tree"].contains($0) }
        #expect(left.isEmpty || (left == ["big.bin"] && !r.isError), "\(left) \(r.text)")
    }

    /// propose_edit only says whether the change fits: its text once in the file. open_in_editor refuses in words
    /// what the editor wouldn't open.
    @Test func theAssistantProposesAnEdit() async throws {
        let (s, dir, _, answer) = try await aiAnswering()
        defer { aiTearDown(s, dir) }
        try Data("a = 1\nb = 2\nc = 1\n".utf8).write(to: URL(fileURLWithPath: dir + "/app.conf"))
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        for server in ["mac", "box"] {
            answer([0])
            func edit(_ old: String, _ new: String) async -> AIResult {
                await s.call("propose_edit", ["server": .string(server), "path": .string(dir + "/app.conf"), "old_text": .string(old), "new_text": .string(new)])
            }
            var r = await edit("b = 2", "b = 3\nd = 4")
            #expect(!r.isError && r.text.contains("at line 2: 1 line(s) become 2") && aiText(dir + "/app.conf") == "a = 1\nb = 2\nc = 1\n", "\(server): \(r.text)")
            r = await edit("= 1", "= 9")
            #expect(r.isError && r.text.contains("2 times"), "\(server): \(r.text)")
            r = await edit("z = 0", "z = 1")
            #expect(r.isError && r.text.contains("isn't in"), "\(server): \(r.text)")
            r = await edit("b = 2", "b = 2")
            #expect(r.isError)
            for name in ["sub", "none"] {
                r = await s.call("open_in_editor", ["server": .string(server), "path": .string(dir + "/" + name)])
                #expect(r.isError, "\(server) \(name): \(r.text)")
            }
        }
    }

    // MARK: Task 23 PR 3: one call at a time; an outside agent over MCP

    /// A client may call side by side; the session takes one call at a time, in the order they came. One stopped
    /// while it waits asks nothing and runs nothing, and stopping one doesn't stop the next.
    @Test func aSessionTakesOneCallAtATime() async throws {
        let (s, dir, asked, answer) = try aiSetUp()
        defer { aiTearDown(s, dir) }
        let reads = AITool(name: "test_read", about: "", kind: .read, params: [.init(name: "server", about: ""), .init(name: "path", about: "")],
                           places: [.init(server: "server", path: "path", access: .read)])
        answer([0])
        _ = await s.call(reads, ["server": "mac", "path": .string(dir)], run: { _, _, _ in AIResult("") })   // the Mac allowed
        var inside = 0, most = 0, order: [String] = []
        let run: AISession.Runner = { _, args, _ in
            inside += 1
            most = max(most, inside)
            if case .string(let p)? = args["path"] { order.append((p as NSString).lastPathComponent) }
            try? await Task.sleep(for: .milliseconds(60))
            inside -= 1
            return AIResult("done")
        }
        let calls = ["a", "b", "c", "d"].map { name in Task { await s.call(reads, ["server": "mac", "path": .string(dir + "/" + name)], run: run) } }
        try await Task.sleep(for: .milliseconds(20))   // a runs, the rest wait
        calls[0].cancel()   // the one running: its runner's to notice
        calls[2].cancel()   // one waiting its turn
        var results: [AIResult] = []
        for c in calls { results.append(await c.value) }
        #expect(most == 1 && order == ["a", "b", "d"], "\(most) at once, ran \(order)")
        #expect(results.map(\.text) == ["done", "done", "Stopped. Nothing was done.", "done"] && asked().count == 1)
        #expect(s.journal.suffix(4).map(\.decision).sorted() == ["allowed", "allowed", "allowed", "stopped"])

        // Two writes of one new file, side by side: the second sees the first's file and asks — it isn't a race to lose.
        let path = dir + "/same.txt"
        answer([0])   // "Allow…" for the first; the second's "write over" gets a Cancel
        async let one = s.call("write_file", ["server": "mac", "path": .string(path), "text": "one\n"])
        async let two = s.call("write_file", ["server": "mac", "path": .string(path), "text": "two\n"])
        let (r1, r2) = await (one, two)
        #expect(!r1.isError && r2.isError && aiText(path) == "one\n" && asked().last == "Let the assistant write over what is there?", "\(r1.text) / \(r2.text)")
    }

    /// The agent's side of the socket: lines out, answers by id.
    private final class StubAgent: @unchecked Sendable {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        private let lock = NSLock()
        private var lines: [[String: ToolValue]] = [], ended = false
        private var taken: Bool?
        /// Off the main thread: the app decides there who gets in.
        init(_ path: String) {
            Thread { [self] in
                let ok = Askpass.withAddress(path, { connect(fd, $0, $1) }) == 0 && Askpass.read(fd, 1) == Data("K".utf8)
                lock.withLock { taken = ok }
                MCP.lines(fd) { l in if case .object(let m)? = try? JSONDecoder().decode(ToolValue.self, from: l) { lock.withLock { lines.append(m) } } }
                lock.withLock { ended = true }
            }.start()
        }
        var gone: Bool { lock.withLock { ended } }
        var admitted: Bool {
            get async {
                for _ in 0..<500 where lock.withLock({ taken }) == nil { try? await Task.sleep(for: .milliseconds(10)) }
                return lock.withLock { taken } == true
            }
        }
        func call(_ id: Int, _ tool: String, _ args: [String: ToolValue] = [:]) async -> (text: String, isError: Bool)? {
            let r = await ask(id, "tools/call", ["name": .string(tool), "arguments": .object(args)])
            guard case .object(let result)? = r?["result"], case .array(let c)? = result["content"], case .object(let first)? = c.first,
                  case .string(let text)? = first["text"] else { return nil }
            return (text, result["isError"] == true)
        }
        func ask(_ id: Int, _ method: String, _ params: ToolValue = [:]) async -> [String: ToolValue]? {
            MCP.write(fd, MCP.line(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]))
            for _ in 0..<500 {
                if let a = lock.withLock({ lines.first { $0["id"] == .number(Double(id)) } }) { return a }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }
    }

    /// An agent over the socket gets the registry's tools and no other way to them than the session's chain: asked
    /// as any call is, its scope shown and taken back, its journal kept; hung up on when it leaves or the switch
    /// goes off. One no tab started is turned away with nothing read.
    @Test func anAgentOverMCPCallsThroughTheSameChain() async throws {
        let (s, dir, _, _) = try aiSetUp()   // the app, the folder
        let app = s.app, path = "/tmp/dfm-mcp-" + String(UUID().uuidString.prefix(8))
        mkdir(path, 0o700)
        defer { aiTearDown(s, dir); try? FileManager.default.removeItem(atPath: path); AppDelegate.answering = nil }
        try "hello\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        var asked: [String] = [], answers: [Int] = []
        AppDelegate.answering = { title, buttons, _ in asked.append(title); return answers.isEmpty ? buttons.count - 1 : answers.removeFirst() }
        var tabs: [String?] = ["zsh"]
        let agents = try #require(AIAgents(app, at: path + "/mcp.sock") { _ in tabs.isEmpty ? nil : tabs.removeFirst() })
        app.agents = agents
        defer { agents.stop(); app.agents = nil }
        #expect(AIAgents.socket == path + "/mcp.sock" && agents.chip == nil && agents.menuItems().map(\.title) == ["No agent connected"])

        let agent = StubAgent(path + "/mcp.sock")
        try #require(await agent.admitted)
        let hello = await agent.ask(1, "initialize", ["protocolVersion": "2025-11-25", "clientInfo": ["name": "Stub Code"]])
        #expect(MCP.object(hello?["result"])?["protocolVersion"] == "2025-11-25")
        try #require(agents.all.count == 1)
        let session = agents.all[0].session
        #expect(agents.chip == "Stub Code" && agents.menuItems().map(\.title).prefix(2) == ["Stub Code — tab “zsh”", "Nothing allowed yet: it asks first"])

        var r = await agent.call(2, "focus")
        #expect(r?.isError == false && r?.text.contains("Active panel: mac") == true && asked.isEmpty)
        r = await agent.call(3, "read_file", ["server": "mac", "path": .string(dir + "/a.txt")])   // Cancel at "Allow…"
        #expect(r?.isError == true && r?.text.contains("didn't allow") == true && asked.count == 1)
        answers = [0]
        r = await agent.call(4, "read_file", ["server": "mac", "path": .string(dir + "/a.txt")])
        #expect(r?.isError == false && r?.text == "hello\n" && asked.count == 2)
        #expect(agents.chip == "Stub Code · this Mac View" && agents.menuItems().map(\.title).contains("this Mac: read"))
        r = await agent.call(5, "read_file", ["server": "mac", "path": .string(dir + "/a.txt")])
        #expect(r?.text == "hello\n" && asked.count == 2, "allowed till it hangs up")

        // Taken back (Window ▸ AI Scope ▸ Take Away): the next call asks again.
        session.takeAway(.mac)
        #expect(session.granted.isEmpty)
        r = await agent.call(6, "read_file", ["server": "mac", "path": .string(dir + "/a.txt")])
        #expect(r?.isError == true && asked.count == 3)

        // What isn't a tool's call isn't the session's — and every call that is, is in its journal: no way past it.
        let no = await agent.ask(7, "tools/call", ["name": "rm_everything", "arguments": [:]])
        #expect(MCP.object(no?["error"])?["code"] == -32602 && session.journal.map(\.tool) == ["focus", "read_file", "read_file", "read_file", "read_file"])
        #expect(session.journalText.contains("read_file(path: \(dir)/a.txt, server: mac) — not allowed") && session.journalText.contains("— allowed"))

        // Another process — not from a tab: closed before a byte is read; the first agent stays.
        tabs = []
        let stranger = StubAgent(path + "/mcp.sock")
        #expect(await !stranger.admitted && agents.all.count == 1)

        // The agent leaves: off the list. The switch off: no socket, the one still there hung up on.
        tabs = ["two"]
        let second = StubAgent(path + "/mcp.sock")
        try #require(await second.admitted)
        _ = await second.ask(1, "ping")
        #expect(agents.all.count == 2)
        close(agent.fd)
        for _ in 0..<300 where agents.all.count != 1 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(agents.all.map(\.tab) == ["two"])
        agents.stop()
        for _ in 0..<300 where !second.gone { try? await Task.sleep(for: .milliseconds(10)) }
        var st = stat()
        #expect(second.gone && agents.all.isEmpty && AIAgents.socket == nil && lstat(path + "/mcp.sock", &st) != 0)
    }
}
