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
    app.panels = [PanelViewController(tabs: [dir], index: 0, showHidden: false), PanelViewController(tabs: [dir], index: 0, showHidden: false)]
    app.panels.forEach { $0.loadViewIfNeeded() }
    return app
}

extension ServerLockTests {   // swap `ServerLock.servers` and `authenticate`
    private var box: SFTPTarget { .local(port: 1) }

    /// A session on a saved server "box" (this Mac's sftp-server) with a folder of its own; `asked` hears every
    /// question's title, `answers` are given in turn (0: the action; none left: Cancel).
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
        #expect(await s.call("copy", [:]).text.contains("isn't available yet"))

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
        unlock = true
        answer([0])
        r = await s.call(writes, args, run: run)
        #expect(!r.isError && ran == 1 && touch.count == 2)
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
}
