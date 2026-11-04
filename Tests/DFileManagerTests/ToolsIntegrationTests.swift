import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Tools PR 9: a tool in Kermo's own places (protocol §11) — F2's actions on a server file its `context` names, the
// check its `validators` add to that file's save, and Send To… — an output window's text on an action's stdin. A tool
// of yours against stand-ins on this Mac (`ToolsBench`); the server is `.local()`.

/// `ctx`: units in `{base}/conf/*.yaml`, `base` found by a command (its default is nowhere); Show on any unit, Deploy
/// only on an app — both in F2 on a unit's file — and its check on save. `snd`: Count Errors takes text.
@MainActor private func tools(_ app: AppDelegate, _ bench: ToolsBench) throws -> String {
    let base = bench.dir + "/srv"
    try FileManager.default.createDirectory(atPath: base + "/conf", withIntermediateDirectories: true)
    for f in ["web.yaml", "api.yaml", "new.yaml"] { FileManager.default.createFile(atPath: base + "/conf/" + f, contents: Data("x: 1\n".utf8)) }
    for (name, body) in [("ctx-list", "printf 'web app\\napi site\\n'"), ("ctx-show", ":"), ("ctx-deploy", ":"), ("snd-count", "grep -c error")] {
        try Data("#!/bin/sh\necho \"\(name) $*\" >> \(bench.dir)/calls.log\n\(body)\n".utf8).write(to: URL(fileURLWithPath: bench.dir + "/bin/" + name))
        chmod(bench.dir + "/bin/" + name, 0o755)
    }
    try FileManager.default.createDirectory(atPath: bench.dir + "/own", withIntermediateDirectories: true)
    try Data(#"""
        { "schema": 1, "id": "ctx", "title": "Ctx",
          "vars": { "base": { "command": "printf '%s\\n' \#(base)", "default": "/nowhere" } },
          "list": { "command": "ctx-list", "format": "regex", "pattern": "^(?<unit>\\S+) (?<kind>\\S+)$", "key": "{unit}", "title": "{unit}", "detail": "{kind}" },
          "actions": [
            { "id": "show", "title": "Show", "key": "return", "readonly": true, "command": "ctx-show {unit}", "done": "Shown {unit}" },
            { "id": "deploy", "title": "Deploy…", "only": { "kind": ["app"] }, "command": "ctx-deploy {unit}" },
            { "id": "other", "title": "Other", "command": "ctx-show other" } ],
          "context": [ { "path": "{base}/conf/*.yaml", "row": "{stem}", "actions": ["show", "deploy"] } ],
          "validators": [ { "path": "{base}/conf/*.yaml", "check": "ctx-check {stem}", "when": "after" } ] }
        """#.utf8).write(to: URL(fileURLWithPath: bench.dir + "/own/ctx.json"))
    try Data(#"""
        { "schema": 1, "id": "snd", "title": "Snd",
          "toolActions": [ { "id": "count", "title": "Count Errors", "accepts": "text", "readonly": true, "command": "snd-count", "output": "window" },
                           { "id": "keep", "title": "Keep", "accepts": "text", "readonly": true, "command": "cat > \#(bench.dir)/kept", "done": "Kept" } ] }
        """#.utf8).write(to: URL(fileURLWithPath: bench.dir + "/own/snd.json"))
    _ = app.tools.reload()
    for id in ["ctx", "snd"] { app.tools.trust.trust(try #require(app.tools.library.tools.first { $0.preset.id == id })) }
    return base
}

/// The server's answer, asked once its connection is up: both tools, `snd` though Tools ▸ doesn't list it.
@MainActor private func connected(_ app: AppDelegate) async {
    AppDelegate.connected = { _ in true }
    app.tools.askAgain()
    await toolsUntil { app.tools.using(.local())?.tools.contains { $0.preset.id == "snd" } == true }
}

extension ServerLockTests {
    /// F4: a save of a tool's file gets its check once the tool's folder is known there — found by its var's command,
    /// not its default — with the file's stem as a variable; your validators.json's rule for that file comes first.
    @Test func aToolsValidatorChecksItsFilesOnSave() async throws {
        let (app, a, _, done) = try toolsApp()
        let bench = try ToolsBench(), was = AppDelegate.validatorsPath
        defer { bench.done(); done(); AppDelegate.validatorsPath = was }
        AppDelegate.validatorsPath = bench.dir + "/validators.json"
        let base = try tools(app, bench), file = base + "/conf/web.yaml"
        await connected(app)
        #expect(app.tools.using(.local())?.tools.map(\.preset.id).contains("ctx") == true && app.tools.here(.local())?.tools.map(\.preset.id).contains("snd") == false,
                "snd only helps: Tools ▸ doesn't list it")
        #expect(ToolsLibrary.rows(app, mine: true).map(\.id).sorted() == ["ctx", "snd"], "My Tools does: Use on Servers… is on its page")
        #expect(app.checkRule(for: file, on: .local()).rule == nil, "its folder isn't known yet: the default's is somewhere else")
        let near = await app.tools.near(file, on: .local(), in: a)
        #expect(near?.map(\.preset.id) == ["ctx"] && bench.calls.isEmpty, "its var's command ran, nothing of the tool's")
        let rule = try #require(app.checkRule(for: file, on: .local()).rule)
        #expect(rule.check == #"ctx-check "$K_stem""# && rule.setup == "K_stem=web" && rule.after && !rule.needsRoot)
        #expect(app.saveSays(.local(), file)?.hasPrefix("Saving checks it with ctx-check once it's there (the old text goes back if that fails)") == true)
        #expect(app.checkRule(for: base + "/conf/sub/web.yaml", on: .local()).rule == nil && app.checkRule(for: base + "/web.yaml", on: .local()).rule == nil)
        try Data(#"[ { "match": "\#(base)/conf/*", "check": "mine %f" } ]"#.utf8).write(to: URL(fileURLWithPath: AppDelegate.validatorsPath))
        #expect(app.checkRule(for: file, on: .local()).rule?.check == "mine %f", "yours first")
    }

    /// F2 on a unit's file: the list is read first, then the actions its context names that the unit's row offers —
    /// Deploy only on an app's — above your commands; one runs on that row, its line in the panel. A file with no row
    /// says so, and the menu has your commands only.
    @Test func f2OnAToolsFileOffersItsActions() async throws {
        let (app, a, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        let base = try tools(app, bench)
        await connected(app)
        func f2(_ name: String) async -> Picker? {
            Picker.dismiss()
            a.loadRemote(.local(), dir: base + "/conf", select: name)
            await toolsUntil { a.remoteCursor?.item.name == name }
            app.showUserMenu()
            await toolsUntil { Picker.current != nil }
            return Picker.current
        }
        var p = try #require(await f2("web.yaml"))
        #expect(Array(p.rows.map(\.title).prefix(3)) == ["Ctx: Show web", "Ctx: Deploy web…", "Disk usage"], "\(p.rows.map(\.title))")
        #expect(p.rows[0].subtitle == "ctx-show web" && bench.calls == ["ctx-list "], "\(bench.calls)")
        p.rows[0].run()
        await toolsUntil { bench.calls.contains("ctx-show web") && a.statusText.contains("Shown") }
        #expect(a.statusText.hasPrefix("Shown web on localhost at "), "\(a.statusText)")

        p = try #require(await f2("api.yaml"))
        #expect(p.rows.first?.title == "Ctx: Show api" && !p.rows.contains { $0.title.hasPrefix("Ctx: Deploy") }, "only: an app's")
        p = try #require(await f2("new.yaml"))
        #expect(p.rows.first?.title == "Disk usage" && a.statusText == "new.yaml: Ctx on localhost has no “new” in its list", "\(a.statusText)")

        // A locked server whose Touch ID is cancelled: nothing of the tool's runs, your commands are still there.
        var locked = SavedServer(address: "localhost")!
        locked.locked = true
        let auth = ServerLock.authenticate
        defer { ServerLock.authenticate = auth }
        (ServerLock.servers, ServerLock.authenticate) = ({ [locked] }, { _ in false })
        let before = bench.calls.count
        p = try #require(await f2("web.yaml"))
        #expect(p.rows.first?.title == "Disk usage" && bench.calls.count == before, "\(p.rows.prefix(2).map(\.title))")
    }

    /// Send To… (F2) in an output window about a server: the tools there that take text — the selection, else all of
    /// it, on the action's stdin, after a question that says how much goes where; what runs is shown (and logged) with
    /// how many lines went, not the text. A window with no such tool has no Send To….
    @Test func sendToPutsAnOutputWindowsTextOnAnActionsStdin() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench(), was = OutputWindow.app
        defer { bench.done(); done(); OutputWindow.app = was }
        OutputWindow.app = { app }
        _ = try tools(app, bench)
        OutputWindow.show("ok\nerror one\nerror two\n", errors: "", title: "Plain", status: 0, ok: true)
        let plain = try #require(NSApp.windows.first { $0.title == "Plain" })
        #expect(OutputWindow.keys(of: plain)?.contains { $0.title == "Send To…" } == false, "no server: nowhere to send")
        await connected(app)
        OutputWindow.show("ok\nerror one\nerror two\n", errors: "", title: "Log", status: 0, ok: true, target: .local())
        let log = try #require(NSApp.windows.first { $0.title == "Log" })
        defer { [plain, log].forEach { $0.close() } }
        let send = try #require(OutputWindow.keys(of: log)?.first { $0.title == "Send To…" })
        #expect(send.key == "F2")
        var asked: [String] = [], info = "", shown = ""
        AppDelegate.answering = { m, b, _ in
            asked.append(m)
            if asked.count == 1 { info = AppDelegate.answeredInfo; return b.firstIndex(of: "Show Exactly What Runs") ?? 9 }
            if m.hasPrefix("Exactly") { shown = AppDelegate.answeredInfo }
            return 0
        }
        send.run()
        let p = try #require(Picker.current)
        #expect(p.rows.map(\.title) == ["Snd: Count Errors", "Snd: Keep"] && p.rows[0].subtitle == "snd-count" && p.rows[0].detail == "localhost")
        p.rows[0].run()
        await toolsUntil { NSApp.windows.contains { $0.title == "Count Errors — localhost" } }
        let out = try #require(NSApp.windows.first { $0.title == "Count Errors — localhost" })
        defer { out.close() }
        #expect(((out.docFrame?.scroll.documentView as? NSTextView)?.string ?? "").hasPrefix("2"), "the text went to its stdin")
        #expect(asked == ["Count Errors on localhost?", "Exactly what runs on localhost", "Count Errors on localhost?"], "it always asks: the text leaves the window")
        #expect(info.contains("Sends 3 lines (") && info.contains("of that window's text to its input on localhost:\nok\nerror one\nerror two"), "\(info)")
        #expect(shown.contains("[3 lines of text]") && !shown.contains("error one"), "shown — and logged on production — as how much it was: \(shown)")

        // The selection only; a line's output in that window's status line.
        let tv = try #require(log.docFrame?.scroll.documentView as? NSTextView)
        tv.setSelectedRange(NSRange(location: 3, length: 9))   // "error one"
        AppDelegate.answering = { _, _, _ in info = AppDelegate.answeredInfo; return 0 }
        send.run()
        try #require(Picker.current).rows[1].run()
        await toolsUntil { log.docFrame?.text.hasPrefix("Kept on localhost at ") == true }
        #expect(log.docFrame?.text.hasPrefix("Kept on localhost at ") == true, "\(log.docFrame?.text ?? "")")
        #expect(info.contains("Sends 1 line (") && (try? String(contentsOfFile: bench.dir + "/kept", encoding: .utf8)) == "error one\n")
    }
}
