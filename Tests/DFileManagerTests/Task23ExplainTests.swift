import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 23 PR 6b: ✨ Explain by what failed — a terminal's command (its shell's OSC 133 D), a save's check, an output
// window, a service, a Monitor alert (ToolsMonitorTests) — hands the chat a chip from where it failed, while ✨ shows.
// `AppDelegate.explaining` takes it: the tests' app has no chat, and nothing is sent anywhere.

/// ✨ shown — a model on this Mac: no key, no Keychain — or not (Settings › AI's row off) while `body` runs.
@MainActor func explainsWhile<T>(_ on: Bool, _ body: () async throws -> T) async rethrows -> T {
    let std = UserDefaults.standard, names = ["aiProvider", "aiAddress", "aiHints"], saved = names.map { ($0, std.object(forKey: $0)) }
    defer { for (k, v) in saved { if let v { std.set(v, forKey: k) } else { std.removeObject(forKey: k) } } }
    if on {
        std.set("openai", forKey: "aiProvider")
        std.set("http://127.0.0.1:9/v1", forKey: "aiAddress")
        std.removeObject(forKey: "aiHints")
    } else {
        std.set(false, forKey: "aiHints")
    }
    #expect(AISettings.explains(std) == on)
    return try await body()
}

@MainActor private func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
@MainActor private func press(_ b: NSButton) { _ = (b.target as? NSObject)?.perform(b.action, with: b) }   // not performClick: it ends a run
@MainActor private func text(_ c: AIPanel.Context) async -> String { await c.read().text }

/// A command whose shell says it ended with N ≠ 0 (OSC 133 `D;N`) and that printed something: "Explain · exit N" at the
/// tab's lower right till the next command; a click gives that command, its output and exit. One end a mark: nothing
/// for `D;0`, an empty ↩, a second end of the same mark (⌃C at the prompt), output with no mark, ⌃C's 130 — nor while
/// the app doesn't watch.
@MainActor @Test func aFailedCommandsEndShowsExplainTillTheNext() async throws {
    _ = NSApplication.shared
    #expect(DropTerminalView.exitCode(Array("D;1".utf8)) == 1 && DropTerminalView.exitCode(Array("D;2;aid=7".utf8)) == 2)
    #expect(["D", "A", "D;x", "C;1", ""].allSatisfy { DropTerminalView.exitCode(Array($0.utf8)) == nil })
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    w.contentView!.addSubview(v)
    var told: [String] = []
    v.onExplain = { told.append($0) }
    v.watchExits(true)
    // Each OSC event reaches the view, then this probe — both hop to the main queue in that order: once the probe's
    // hop has run, the view's has.
    final class Count: @unchecked Sendable { var n = 0 }
    let count = Count()
    let probe = v.observeOscEvents { _ in DispatchQueue.main.async { count.n += 1 } }
    defer { probe.cancel() }
    var fed = 0
    func end(_ osc: String) async {
        fed += 1
        v.feed(text: "\u{1b}]133;\(osc)\u{07}")
        for _ in 0..<500 where count.n < fed { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(count.n == fed)
    }
    let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                               characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    func run(_ command: String, printing out: String, _ osc: String) async {
        v.feed(text: command)
        v.typed(ret)
        v.feed(text: "\r\n" + out)
        await end(osc)
        v.feed(text: "$ ")
    }

    var shown: NSButton? { v.explainButton.flatMap { $0.superview == nil ? nil : $0 } }
    v.feed(text: "motd\r\n")
    await end("D;1")
    #expect(shown == nil, "no mark: no command of the user's")
    v.feed(text: "$ ")
    await run("make", printing: "error: boom\r\n", "D;2")
    let b = try #require(shown)
    #expect(b.title == "Explain · exit 2" && b.frame.maxX > v.bounds.midX && b.frame.minY < v.bounds.midY, "\(b.frame)")
    press(b)
    #expect(told == ["$ make\nerror: boom\n[exit 2]"] && shown == nil, "\(told)")
    await end("D;1")
    #expect(shown == nil, "the same mark's second end (⌃C at the prompt)")
    await run("true", printing: "ok\r\n", "D;0")
    #expect(shown == nil, "exit 0")
    v.typed(ret)
    v.feed(text: "\r\n")
    await end("D;1")
    v.feed(text: "$ ")
    #expect(shown == nil, "an empty ↩ printed nothing")
    await run("ping", printing: "64 bytes\r\n^C\r\n", "D;130")
    #expect(shown == nil, "the user's own ⌃C")
    await run("ls nope", printing: "ls: nope: No such file\r\n", "D;1")
    #expect(shown?.title == "Explain · exit 1")
    v.feed(text: "pwd")
    v.typed(ret)
    #expect(shown == nil, "the next command: gone")
    v.feed(text: "\r\n/tmp\r\n$ ")

    v.watchExits(false)
    #expect(!v.watchesExits)
    await run("ls nope", printing: "ls: nope: No such file\r\n", "D;1")
    #expect(shown == nil && told.count == 1, "not watched: nothing")
}

extension ServerLockTests {   // `UserDefaults.standard`'s AI settings, `AppDelegate.explaining`, one picker at a time
    /// The app's terminal watches its tabs' ends only while ✨ shows; «⋯» Explain Last Command is in View ▸ Terminal
    /// Pane. A save's check: Explain is the dialog's second button, ↩ stays OK; its chip is the server's, with the
    /// check's whole output.
    @Test func explainIsWatchedOnlyWhileItShowsAndACheckSaysAll() async throws {
        let app = AppDelegate()
        app.commands = app.makeCommands()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        app.terminal = EmbeddedTerminal(covering: host)
        try await explainsWhile(true) { app.aiChanged() }
        #expect(app.terminal.watchesExits)
        try await explainsWhile(false) { app.aiChanged() }
        #expect(!app.terminal.watchesExits)
        #expect(app.commands.first { $0.id == "term.output.explain" }.map { "\($0.menu ?? "") \($0.title)" } == "View/Terminal Pane Explain Last Command")

        #expect(AppDelegate.alert("m", info: "i", ["OK", "Explain"]).buttons.map(\.keyEquivalent) == ["\r", ""], "↩ is OK")
        var web = SavedServer()
        (web.host, web.user, web.name, web.prod) = ("web.invalid", "me", "shop", true)
        ServerLock.servers = { [web] }
        defer { ServerLock.servers = { [] } }
        let long = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let e = SFTPClient.CheckFailed(rule: ConfigCheck(match: "/etc/nginx/*", check: "nginx -t", when: .before), status: 1, output: long)
        let c = AppDelegate.checkWhy(e, name: "site.conf", path: "/etc/nginx/sites-enabled/site.conf", on: web.target.asRoot())
        #expect(c.title == "“nginx” on site.conf · shop" && c.server == web.target.asUser && c.server.map(SavedServer.isProd) == true)
        let said = await text(c)
        #expect(said.hasPrefix("“nginx -t” checked /etc/nginx/sites-enabled/site.conf as it was being saved, and failed (exit 1):\nline 1\n") && said.contains("line 40"), "\(said)")
    }

    /// An output window whose command failed has ✨ Explain in its status line while ✨ shows: the command and all it
    /// said, this Mac's. Not for one that went well, nor with ✨ off.
    @Test func anOutputWindowThatFailedHasExplain() async throws {
        _ = NSApplication.shared
        let app = AppDelegate(), was = OutputWindow.app
        OutputWindow.app = { app }
        var got: [AIPanel.Context] = []
        AppDelegate.explaining = { got += $0 }
        defer { (OutputWindow.app, AppDelegate.explaining) = (was, nil) }
        func ran(_ command: String) async throws -> NSWindow {
            var done = false
            let title = "t23x " + UUID().uuidString.prefix(6)
            Shell.run(command, in: NSTemporaryDirectory(), title: title) { _ in done = true }
            for _ in 0..<500 where !done { try await Task.sleep(for: .milliseconds(10)) }
            return try #require(NSApp.windows.first { $0.title == title })
        }
        try await explainsWhile(true) {
            let w = try await ran("echo oops; exit 3")
            defer { w.close() }
            let a = try #require(w.docFrame?.actions.first)
            #expect(a.0 == "✨ Explain" && w.docFrame?.actions.count == 1)
            a.1()
            #expect(got.map(\.title) == ["echo oops; exit 3 · this Mac"] && got.first?.server == nil, "\(got.map(\.title))")
            let said = try await text(#require(got.first))
            #expect(said.hasPrefix("$ echo oops; exit 3\noops\n") && said.contains("[exit 3]"), "\(said)")
            let ok = try await ran("echo fine")
            defer { ok.close() }
            #expect(ok.docFrame?.actions.isEmpty == true, "it went well")
        }
        try await explainsWhile(false) {
            let w = try await ran("exit 4")
            defer { w.close() }
            #expect(w.docFrame?.actions.isEmpty == true, "✨ off")
        }
    }

    /// A service's change that failed: ✨ Explain by its line under the list, while ✨ shows — the command, what it
    /// said and the line, from the server it ran on (as its user). Not with ✨ off.
    @Test func aFailedServiceHasExplainByItsLine() async throws {
        _ = NSApplication.shared
        let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t23x-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho 'Job for web.service failed.'\nexit 1\n".utf8).write(to: URL(fileURLWithPath: dir + "/bin/systemctl"))
        let sudo = dir + "/sudo"
        try Data("#!/bin/sh\n[ \"$1\" = -n ] && [ \"$2\" = -- ] || exit 2\nshift 2\nPATH=\(dir)/bin:$PATH exec \"$@\"\n".utf8).write(to: URL(fileURLWithPath: sudo))
        for f in [dir + "/bin/systemctl", sudo] { chmod(f, 0o755) }
        let t = SFTPTarget.local(sudo: sudo).asRoot(false)
        let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
        panel.loadViewIfNeeded()
        let app = AppDelegate()
        app.panels = [panel]
        ServerLock.servers = { [] }
        AppDelegate.unitState = { _, _, _, _, _ in .init(active: "failed", sub: "failed") }
        var got: [AIPanel.Context] = []
        AppDelegate.explaining = { got += $0 }
        defer {
            panel.shutdown()
            Picker.dismiss()
            AppDelegate.unitState = { try Services.state($0, on: $1, wait: $2, env: $3, cancel: $4) }
            AppDelegate.explaining = nil
            try? FileManager.default.removeItem(atPath: dir)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let unit = ServiceUnit(unit: "web.service", active: "active", sub: "running"), s = SavedServer(target: t)
        for on in [false, true] {
            try await explainsWhile(on) {
                let list = Picker.show(over: window, placeholder: "", items: [app.serviceItem(unit, on: t, of: s)])
                await app.change(.restart, unit, on: t, of: s).value
                #expect(list.said.contains("web: the restart failed"), "\(list.said)")
                let b = buttons(list.panel.contentView!).first { $0.title == "Explain" && !$0.isHidden }
                #expect((b != nil) == on)
                if let b { press(b) }
                Picker.dismiss()
            }
        }
        #expect(got.map(\.title) == ["systemctl restart -- web.service · \(AISession.label(t))"] && got.first?.server == t.asUser, "\(got.map(\.title))")
        let said = try await text(#require(got.first))
        #expect(said.hasPrefix("$ systemctl restart -- web.service\nJob for web.service failed.\n") && said.contains("the restart failed"), "\(said)")
    }
}
