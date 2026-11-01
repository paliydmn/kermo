import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Tools PR 6: levels (§7.5). An action with `output: "list"` shows its rows one level down on the same Picker or
// panel — the parent row's fields in its names, ⌫ / ⎋ back to the row it came from; one with no list of its own
// repeats the level it's on (D-155); `only` keeps an action off the rows it doesn't name.

/// `deep`: a list of things (`kind name`); Inside (⌘↓) lists a thing's files — the thing itself first, as `du -d1`
/// does — whose Show (↩) says the parent's name, and Again (⌘↓) repeats that level; Deploy only on an app. Scan… asks
/// a depth and changes something: its level's Zap can't be checked against a list that reading would change.
@MainActor private func deep(_ app: AppDelegate, _ bench: ToolsBench) throws {
    for (name, body) in [("deep-list", "printf 'app api\\nsite www\\n'"), ("deep-in", "[ \"$1\" = www ] || printf '%s 30\\n%s/a 10\\n%s/b 20\\n' \"$1\" \"$1\" \"$1\""),
                         ("deep-show", ":"), ("deep-deploy", ":")] {
        try Data("#!/bin/sh\necho \"\(name) $*\" >> \(bench.dir)/calls.log\n\(body)\n".utf8).write(to: URL(fileURLWithPath: bench.dir + "/bin/" + name))
        chmod(bench.dir + "/bin/" + name, 0o755)
    }
    try FileManager.default.createDirectory(atPath: bench.dir + "/own", withIntermediateDirectories: true)
    try Data(#"""
        { "schema": 1, "id": "deep", "title": "Deep",
          "list": { "command": "deep-list", "format": "regex", "pattern": "^(?<kind>\\w+) (?<name>\\S+)$", "key": "{name}", "title": "{name}", "detail": "{kind}" },
          "actions": [
            { "id": "inside", "title": "Inside", "key": "cmd+down", "readonly": true, "command": "deep-in {name}", "output": "list",
              "list": { "format": "regex", "pattern": "^(?<file>\\S+) (?<size>\\d+)$", "key": "{file}", "title": "{file}", "detail": "{size}", "empty": "Nothing in {name}" },
              "actions": [ { "id": "show", "title": "Show", "key": "return", "readonly": true, "command": "deep-show {name} {file}", "done": "Shown {file} of {name}" },
                           { "id": "again", "title": "Again", "key": "cmd+down", "readonly": true, "command": "deep-in {file}", "output": "list" } ] },
            { "id": "scan", "title": "Scan…", "command": "deep-in {name} {depth}", "output": "list", "inputs": [ { "name": "depth", "type": "text", "default": "1" } ],
              "list": { "format": "regex", "pattern": "^(?<file>\\S+) (?<size>\\d+)$", "key": "{file}", "title": "{file}" },
              "actions": [ { "id": "zap", "title": "Zap", "dangerous": true, "command": "deep-show zap {file}" } ] },
            { "id": "deploy", "title": "Deploy", "key": "f5", "only": { "kind": ["app"] }, "command": "deep-deploy {name}" } ] }
        """#.utf8).write(to: URL(fileURLWithPath: bench.dir + "/own/deep.json"))
    _ = app.tools.reload()
    app.tools.trust.trust(try #require(app.tools.library.tools.first { $0.preset.id == "deep" }))
}

private let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))

@MainActor @discardableResult private func key(_ p: Picker, _ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags) -> Bool {
    p.panel.onKey?(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                                    characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!) == true
}
@MainActor @discardableResult private func press(_ p: Picker, _ sel: Selector) -> Bool { p.control(p.field, textView: NSTextView(), doCommandBy: sel) }

extension ServerLockTests {
    /// In a Picker: ⌘↓ on a row lists what its action printed one level down — its chip the row, its names the row's
    /// and its parent's (↩ there says both), ⌘↓ again repeats the level; ⌫ and ⎋ go back up, each to the row it came
    /// from. A row there with the key of the one above (`du -d1 api` lists `api`) is a row of its own: a run on it
    /// leaves the row above alone. Deploy is only on the app's row.
    @Test func anActionsRowsAreALevelDownInAPicker() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        try deep(app, bench)
        let source = ToolListSource(app, try toolNamed(app, "deep"), SavedServer(target: .local()), .local())
        _ = try await source.read(CancelFlag())
        app.showInSearch(source)
        let p = try #require(Picker.current)
        #expect(p.rows.map(\.title) == ["api", "www"] && p.rows.map(\.detail) == ["app", "site"])
        #expect(p.rows[0].listActions?().contains { $0.title == "Deploy" } == true && p.rows[1].listActions?().contains { $0.title == "Deploy" } == false, "only: an app's")

        key(p, 125, down, .command)
        await toolsUntil { p.rows.count == 3 }
        #expect(p.rows.map(\.title) == ["api", "api/a", "api/b"] && p.scopeNames.suffix(2) == ["Deep", "api"], "\(p.rows.map(\.title)) \(p.scopeNames)")
        #expect(bench.calls.contains("deep-in api") && p.highlighted?.verb == "Show")
        #expect(p.rows[0].listActions?().map(\.title) == ["Show", "Again", "Copy", "Show deep.json"], "the level's actions, none of the tool's")
        p.highlighted?.run()   // ↩ Show on `api` down here
        await toolsUntil { p.said.contains("Shown") }
        #expect(p.said.hasPrefix("\u{FFFC} Shown api of api on localhost at ") && bench.calls.contains("deep-show api api"), "\(p.said)")

        p.field.stringValue = "a/a"
        p.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: p.field))
        #expect(p.highlighted?.title == "api/a")
        key(p, 125, down, .command)   // Again: the same level, its run on this row
        await toolsUntil { p.scopeNames.last == "api/a" && p.rows.count == 3 }
        #expect(p.rows.map(\.title) == ["api/a", "api/a/a", "api/a/b"] && bench.calls.contains("deep-in api/a"), "\(p.rows.map(\.title))")
        #expect(p.rows[0].listActions?().map(\.title).prefix(2) == ["Show", "Again"], "repeated: that level's actions")
        let reads = bench.calls.filter { $0 == "deep-in api/a" }.count
        p.reread()
        await toolsUntil { bench.calls.filter { $0 == "deep-in api/a" }.count == reads + 1 }
        #expect(bench.calls.filter { $0 == "deep-in api/a" }.count == reads + 1, "⌘R: this level's run again")

        press(p, #selector(NSResponder.deleteBackward(_:)))   // ⌫ on an empty field: up
        #expect(p.scopeNames.last == "api" && p.field.stringValue == "a/a" && p.highlighted?.title == "api/a", "as it was left: \(p.scopeNames)")
        press(p, #selector(NSResponder.cancelOperation(_:)))   // ⎋: up again
        #expect(p.scopeNames.last == "Deep" && p.highlighted?.title == "api" && p.rows.first?.detail == "app", "the row above as it was: \(p.rows.map(\.detail))")
    }

    /// In a panel: Inside shows its level in place of the list — the path bar's crumbs the tool and the row — and ⌫
    /// goes back to the list with the cursor on that row. A level that lists nothing says its own words, with the
    /// parent's name; Deploy, `only` an app's, isn't in a site's menu nor on its key.
    @Test func anActionsRowsAreALevelDownInAPanel() async throws {
        let (app, a, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        try deep(app, bench)
        let source = ToolListSource(app, try toolNamed(app, "deep"), SavedServer(target: .local()), .local())
        _ = try await source.read(CancelFlag())
        a.showList(source)
        app.window.makeFirstResponder(a.table)
        let list = try #require(a.list)
        #expect(list.cursor?.title == "api" && list.actions.contains { $0.title == "Deploy" })
        app.runList(try #require(list.actions.first { $0.title == "Inside" }), in: list)
        await toolsUntil { (a.list?.shown.count ?? 0) == 3 }
        let level = try #require(a.list)
        #expect(level !== list && level.shown.map(\.title) == ["api", "api/a", "api/b"] && a.pathBar.shownCrumbs == ["Deep", "api"], "\(a.pathBar.shownCrumbs)")
        a.goUp()
        #expect(a.list?.source === source && a.list?.cursor?.title == "api", "back on the row it came from")

        a.table.selectRowIndexes([1], byExtendingSelection: false)
        let site = try #require(a.list)
        #expect(site.cursor?.title == "www" && !site.actions.contains { $0.title == "Deploy" }, "only: not on a site")
        app.runList(try #require(site.actions.first { $0.title == "Inside" }), in: site)
        await toolsUntil { a.list?.source !== source && a.list?.content != nil }
        #expect(a.list?.shown.isEmpty == true && a.list?.content?.empty == "Nothing in www", "\(a.list?.content?.empty ?? "")")
    }

    /// A level's read is its action's run (§7.2): its form — Cancel goes back to the list — production's question, the
    /// production log; a locked server says so, as any list's read. A row's dangerous action down there isn't run
    /// unchecked when reading the level again would run its change.
    @Test func aLevelsReadAsksAsAnyRun() async throws {
        let (app, a, _, done) = try toolsApp()
        let bench = try ToolsBench(), auth = ServerLock.authenticate
        defer { bench.done(); done(); app.savedServers = []; ToolRunner.filling = nil; ServerLock.authenticate = auth }
        try deep(app, bench)
        var prod = SavedServer(target: .local())
        prod.prod = true
        app.savedServers = [prod]
        ServerLock.servers = { [prod] }
        let source = ToolListSource(app, try toolNamed(app, "deep"), prod, .local())
        _ = try await source.read(CancelFlag())
        a.showList(source)
        app.window.makeFirstResponder(a.table)
        var forms = 0, asked: [String] = []
        ToolRunner.filling = { _ in forms += 1; return nil }   // Cancel
        AppDelegate.answering = { m, _, _ in asked.append(m); return 0 }
        app.runList(try #require(a.list?.actions.first { $0.title == "Scan…" }), in: try #require(a.list))
        await toolsUntil { forms == 1 && a.list?.source === source }
        #expect(a.list?.source === source && a.list?.cursor?.title == "api" && asked.isEmpty && !bench.calls.contains("deep-in api 2"), "cancelled: back on its row")

        ToolRunner.filling = { _ in forms += 1; return ["depth": "2"] }
        app.runList(try #require(a.list?.actions.first { $0.title == "Scan…" }), in: try #require(a.list))
        await toolsUntil { a.list?.source !== source && a.list?.shown.count == 3 }
        #expect(asked == ["Scan on localhost?"] && bench.calls.contains("deep-in api 2"), "\(asked)")
        await toolsUntil { ((try? String(contentsOfFile: bench.dir + "/audit.jsonl", encoding: .utf8)) ?? "").contains("tool deep scan") }
        #expect(((try? String(contentsOfFile: bench.dir + "/audit.jsonl", encoding: .utf8)) ?? "").contains("tool deep scan"), "in the production log")
        let level = try #require(a.list)
        app.runList(try #require(level.actions.first { $0.title == "Zap" }), in: level)
        try await Task.sleep(for: .milliseconds(300))
        #expect(asked.count == 1 && !bench.calls.contains { $0.hasPrefix("deep-show zap") }, "not checked, not run: \(asked)")

        var locked = prod
        locked.locked = true
        ServerLock.servers = { [locked] }
        ServerLock.authenticate = { _ in false }
        let scan = try #require(level.source as? ToolListSource)
        do { _ = try await scan.read(CancelFlag()); Issue.record("read while locked") } catch { #expect(error is AppDelegate.Locked, "\(error)") }
    }
}
