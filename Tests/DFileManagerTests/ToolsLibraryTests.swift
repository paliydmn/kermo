import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Tools PR 4b: the library in the Tools window — a tool's page (what it runs, your servers), New Tool… from a starter
// into the editor, Problems as you type, Save → "Use the tool…?" → Use on Servers…, Test on a connected server (what
// runs by itself, never an action, never a login), Customize a built-in. Against `ToolsBench`'s stand-ins on this Mac.

@MainActor private func texts(_ v: NSView) -> [String] {
    ((v as? NSTextField).map { [$0.stringValue] } ?? []) + ((v as? NSButton).map { [$0.title] } ?? []) + v.subviews.flatMap(texts)
}
@MainActor private func press(_ b: NSButton?) { _ = (b?.target as? NSObject)?.perform(b?.action, with: b) }
@MainActor private func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
@MainActor private func closeAll() {
    ToolsWindow.main?.window.close()
    for w in NSApp.windows where w.windowController is Editor { w.close() }
}
/// The pane beside the open tool editor's text.
@MainActor private func pane(_ name: String) throws -> ToolEditor {
    let w = try #require(NSApp.windows.first { $0.windowController is Editor && $0.title == name && $0.isVisible }, "\(NSApp.windows.map(\.title))")
    return try #require(w.docFrame?.subviews.compactMap { $0 as? ToolEditor }.first)
}
@MainActor private func choose(_ w: ToolsWindow, _ row: ToolsWindow.Row) throws {
    w.sidebar.selectRowIndexes([try #require(w.rows.firstIndex(of: row))], byExtendingSelection: false)
}

extension ServerLockTests {
    /// A built-in's page: what it runs in the trust sheet's groups, root marked, a dangerous action red; each saved
    /// server found there or not, or not checked yet; Customize, not Edit. ↩ on a library row opens it.
    @Test func aToolsPageSaysWhatItRunsAndWhere() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { closeAll(); bench.done(); done(); app.savedServers = [] }
        app.savedServers = [SavedServer(address: "localhost")!, SavedServer(address: "web-01")!]
        AppDelegate.connected = { $0.host == "localhost" }
        _ = app.tools.answer(.local())
        await toolsUntil { app.tools.answers[ServerRow.key(.local())] != nil }
        ToolsWindow.show(app)
        let w = try #require(ToolsWindow.main)
        try choose(w, .library(mine: false))
        let lib = try #require(w.library)
        lib.table.selectRowIndexes([try #require(lib.tools.firstIndex { $0.preset.id == "ufw" })], byExtendingSelection: false)
        lib.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                           characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        let page = try #require(w.tool)
        let all = texts(page)
        #expect(all.contains("Firewall (ufw)") && all.contains("‹ Built into Kermo") && all.contains("Customize") && !all.contains("Edit"))
        #expect(page.facts.first == "built into Kermo" && page.facts.contains("trusted as part of Kermo"))
        let runs = try #require(app.tools.library.tools.first { $0.preset.id == "ufw" }).runs
        #expect(all.contains("Runs by itself") && all.contains("Runs when you choose"))
        #expect(all.contains(runs.itself[0].text.trimmingCharacters(in: .whitespaces)) && runs.itself[0].text.contains("requires: command -v ufw"))
        #expect(all.contains { $0.hasPrefix("header: ") && $0.hasSuffix("— as root") }, "ufw's header runs as root")
        func fields(_ v: NSView) -> [NSTextField] { ((v as? NSTextField).map { [$0] } ?? []) + v.subviews.flatMap(fields) }
        let red = fields(page.stack).filter { $0.textColor == Palette.fail }.map(\.stringValue)
        #expect(!red.isEmpty && red.allSatisfy { line in runs.chosen.contains { $0.dangerous && $0.text.trimmingCharacters(in: .whitespaces) == line } })
        #expect(all.contains("ufw found") && all.contains("not checked yet"), "localhost has ufw (the stand-in); web-01 was never connected: \(all)")
        press(buttons(page).first { $0.title == "‹ Built into Kermo" })
        #expect(w.tool == nil && lib.superview != nil)
    }

    /// New Tool…: the name makes the file's; a built-in's id or a file there already won't do. The starter opens in the
    /// editor and loads as it is; an unknown field is an error with its line, a click there selects it. Save writes it
    /// owner-only, asks "Use the tool…?", then Use on Servers…; and the server's check runs for it.
    @Test func aNewToolIsSavedTrustedAndUsed() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { closeAll(); ToolRunner.choosing = nil; bench.done(); done(); app.savedServers = [] }
        let here = SavedServer(address: "localhost")!
        app.savedServers = [here]
        AppDelegate.connected = { _ in true }
        ToolsWindow.show(app, server: .local())   // its rows look at the server as .local(), never over ssh
        let w = try #require(ToolsWindow.main)
        try choose(w, .newTool)
        let new = try #require(w.starter)
        for (name, ok) in [("", false), ("ufw", false), ("Disk Check", true)] {
            new.name.stringValue = name
            new.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            #expect(new.starters.allSatisfy { $0.isEnabled == ok } && (new.problem == nil) == ok, "\(name): \(new.file.stringValue)")
        }
        #expect(new.file.stringValue.hasSuffix("/tools/disk-check.json"))
        new.start(.list)
        let p = try pane("disk-check.json")
        let editor = try #require(p.editor)
        #expect(p.check().problems.isEmpty && p.check().tool?.preset.title == "Disk Check")
        #expect(!FileManager.default.fileExists(atPath: bench.dir + "/own/disk-check.json"), "nothing on disk before Save")

        let text = editor.textView.string
        editor.textView.string = text.replacingOccurrences(of: #""requires":"#, with: #""needs": "x", "requires":"#)
        p.recheck()
        let said = try #require(p.problems.textStorage).string
        let line = try #require(text.split(separator: "\n", omittingEmptySubsequences: false).firstIndex { $0.contains(#""requires":"#) }) + 1
        #expect(said.contains("Errors — it isn't loaded:") && said.contains("✕ line \(line): needs: unknown field") && !p.test.isEnabled, "\(said)")
        #expect(p.textView(p.problems, clickedOnLink: "line:\(line)", at: 0))
        #expect((editor.textView.string as NSString).substring(with: editor.textView.selectedRange()).contains(#""needs": "x""#))
        editor.textView.string = text
        p.recheck()

        var asked: [String] = []
        AppDelegate.answering = { m, _, _ in asked.append(m); return 0 }
        ToolRunner.choosing = { _, all in (onlyChecked: true, checked: Set(all.map(\.id.uuidString))) }
        #expect(await editor.save())
        await toolsUntil { app.tools.settings.only["disk-check"] != nil }
        #expect(asked == ["Use the tool “Disk Check”?"] && app.tools.settings.only["disk-check"] == [here.id.uuidString], "\(asked)")
        let tool = try toolNamed(app, "disk-check")
        #expect(!tool.builtIn && app.tools.trust.trusts(tool))
        var st = stat()
        #expect(stat(bench.dir + "/own/disk-check.json", &st) == 0 && st.st_mode & 0o777 == 0o600)
        #expect(stat(bench.dir + "/own", &st) == 0 && st.st_mode & 0o777 == 0o700)
        await toolsUntil { _ = app.tools.answer(.local()); return app.tools.state(tool, on: here) == "found" }
        #expect(app.tools.state(tool, on: here) == "found", "asked again once trusted: its check passed (df is here)")
        #expect(app.tools.here(.local())?.tools.contains { $0.preset.id == "disk-check" } == true)
    }

    /// Test runs what the tool runs by itself — the check, the header, the version, the list — on a server that's
    /// connected, after saying what goes; never one of its actions, never a login. The rows it made, the lines that
    /// didn't fit.
    @Test func testRunsWhatRunsByItselfOnlyWhereConnected() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { closeAll(); ToolEditor.connected = nil; bench.done(); done(); app.savedServers = [] }
        try FileManager.default.createDirectory(atPath: bench.dir + "/own", withIntermediateDirectories: true)
        try Data(#"""
            { "schema": 1, "id": "rules", "title": "Rules", "tool": "ufw", "sudo": true, "about": "Allowed ports.",
              "requires": "command -v ufw", "header": "ufw status verbose | head -1",
              "version": { "command": "ufw version", "pattern": "ufw (?<v>[\\d.]+)", "tested": ">=0.36" },
              "list": { "command": "ufw status numbered", "format": "regex",
                        "pattern": "^\\[\\s*(?<num>\\d+)\\]\\s+(?<dest>\\S+)\\s+ALLOW IN", "key": "{num}", "title": "{dest}" },
              "actions": [ { "id": "drop", "title": "Delete", "dangerous": true, "command": "ufw --force delete {num}" } ] }
            """#.utf8).write(to: URL(fileURLWithPath: bench.dir + "/own/rules.json"))
        _ = app.tools.reload()
        let here = SavedServer(address: "localhost")!
        app.savedServers = [here]
        var up = false
        AppDelegate.connected = { _ in up }
        ToolEditor.connected = { _ in up ? [(here, .local())] : [] }
        ToolEditor.edit(app, URL(fileURLWithPath: bench.dir + "/own/rules.json"))
        let p = try pane("rules.json")
        #expect(p.check().problems.isEmpty)
        p.runTest()
        #expect(p.output.string == "✕ No server is connected. Test never logs in: connect one first." && bench.trips == 0)

        up = true
        var asked: [String] = []
        AppDelegate.answering = { m, _, _ in asked.append(m); return 0 }
        p.runTest()
        await toolsUntil { p.output.string.contains("list:") }
        let out = p.output.string
        #expect(asked == ["Test Rules on localhost?"], "what goes is shown first")
        #expect(out.contains("✓ requires: passed") && out.contains("✓ header: Status: active") && out.contains("✓ version: 0.36.2 (tested with >=0.36)"), "\(out)")
        #expect(out.contains("✓ list: 2 rows") && out.contains("  22/tcp") && out.contains("fields: dest num"), "\(out)")
        #expect(out.contains("⚠ 4 lines didn't fit:") && out.contains("[ 3] Anywhere                   DENY IN     203.0.113.7"), "\(out)")
        #expect(!bench.calls.contains { $0.contains("delete") } && bench.calls.contains("ufw status numbered"), "\(bench.calls)")

        p.runTest()
        await toolsUntil { p.output.string.contains("list:") && !p.output.string.hasPrefix("Testing") }
        #expect(asked.count == 1, "asked once in an editor; production asks each time")
    }

    /// Customize: a built-in's file — and its scripts — become yours under its id; saved and trusted, yours takes its
    /// place. Yours with an error: the built-in is back, and My Tools lists your file as not loaded.
    @Test func customizedBuiltInTakesItsPlaceUnlessBroken() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { closeAll(); bench.done(); done() }
        let builtIn = try toolNamed(app, "sysinfo")
        #expect(builtIn.builtIn && !builtIn.scripts.isEmpty)
        ToolEditor.customize(app, builtIn)
        let p = try pane("sysinfo.json")
        #expect(p.check().problems.isEmpty, "its scripts are found in Kermo's folder till they're copied")
        let editor = try #require(p.editor)
        editor.textView.string = editor.textView.string.replacingOccurrences(of: #""title": "Server Info""#, with: #""title": "My Server Info""#)
        var asked: [String] = []
        AppDelegate.answering = { m, _, _ in asked.append(m); return 0 }
        #expect(await editor.save())
        await toolsUntil { !asked.isEmpty }
        let mine = try toolNamed(app, "sysinfo")
        #expect(!mine.builtIn && mine.preset.title == "My Server Info" && app.tools.trust.trusts(mine) && asked == ["Use the tool “My Server Info”?"])
        for s in builtIn.scripts.keys {
            var st = stat()
            #expect(stat(bench.dir + "/own/" + s, &st) == 0 && st.st_mode & 0o777 == 0o600, "\(s) copied next to it")
        }

        try Data(#"{ "schema": 1, "id": "sysinfo", "title": "Mine", "oops": 1 }"#.utf8).write(to: URL(fileURLWithPath: bench.dir + "/own/sysinfo.json"))
        _ = app.tools.reload()
        #expect(try toolNamed(app, "sysinfo").builtIn, "yours has an error: the built-in stays")
        #expect(await editor.reload())
        await toolsUntil { p.problems.string.contains("oops") }
        #expect(p.problems.string.contains("✕ line 1: oops: unknown field"), "read anew from disk, checked anew: \(p.problems.string)")
        #expect(app.tools.library.problems.contains { $0.hasPrefix("tools/sysinfo.json: line 1: oops") }, "\(app.tools.library.problems)")
        let lib = ToolsLibrary(app, mine: true)
        #expect(buttons(lib.broken).map(\.title).contains { $0.hasPrefix("✕ tools/sysinfo.json: line 1: oops") })
    }
}
