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

/// A command whose shell says it ended with N ≠ 0 (OSC 133 `D;N`) and that printed something is told with its text;
/// "Explain · exit N" then shows at the tab's lower right till the next command. One end a mark: nothing for `D;0`, an
/// empty ↩ (with a two-line prompt and a right prompt too), a second end of the same mark (⌃C at the prompt), output
/// with no mark, ⌃C's 130, a remote shell's last command ended by the local shell's end of `ssh` — nor while the app
/// doesn't watch, which takes a button that shows away. A ✨ shown late — after the next command, or after a later
/// failure's — isn't.
@MainActor @Test func aFailedCommandsEndShowsExplainTillTheNext() async throws {
    _ = NSApplication.shared
    #expect(DropTerminalView.exitCode(Array("D;1".utf8)) == 1 && DropTerminalView.exitCode(Array("D;2;aid=7".utf8)) == 2)
    #expect(["D", "A", "D;x", "C;1", ""].allSatisfy { DropTerminalView.exitCode(Array($0.utf8)) == nil })
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    w.contentView!.addSubview(v)
    var told: [String] = [], clicked = 0, shows: [DropTerminalView.ShowExplain] = [], later = false
    v.onFailed = { _, text, show in
        told.append(text)
        shows.append(show)
        if !later { show { clicked += 1 } }
    }
    var remote = false
    v.remoteNow = { remote }
    v.watchExits(true)
    // Each OSC event reaches the view, then this probe — both hop to the main queue in that order: once the probe's
    // hop has run, the view's has.
    final class Count: @unchecked Sendable { var n = 0 }
    let count = Count()
    let probe = v.observeOscEvents { _ in DispatchQueue.main.async { count.n += 1 } }
    defer { probe.cancel() }
    var fed = 0
    func end(_ osc: String, then prompt: String = "") async {
        fed += 1
        v.feed(text: "\u{1b}]133;\(osc)\u{07}" + prompt)
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
    #expect(told.isEmpty, "no mark: no command of the user's")
    v.feed(text: "$ ")
    await run("make", printing: "error: boom\r\n", "D;2")
    #expect(told == ["$ make\nerror: boom\n[exit 2]"], "\(told)")
    let b = try #require(shown)
    #expect(b.title == "Explain · exit 2" && b.frame.maxX > v.bounds.midX && b.frame.minY < v.bounds.midY, "\(b.frame)")
    _ = (b.target as? NSObject)?.perform(b.action, with: b)
    #expect(clicked == 1 && shown == nil)
    await end("D;1")
    #expect(told.count == 1, "the same mark's second end (⌃C at the prompt)")
    await run("true", printing: "ok\r\n", "D;0")
    v.typed(ret)
    v.feed(text: "\r\n")
    await end("D;1", then: "$ ")
    await run("ping", printing: "64 bytes\r\n^C\r\n", "D;130")
    #expect(told.count == 1, "exit 0, an empty ↩, the user's own ⌃C: \(told)")
    // A two-line prompt with a clock at the right: an empty ↩ under it isn't a command, though the prompt's upper line
    // came after the mark.
    let right = { (t: String) in "\u{1b}[s\u{1b}[60G\(t)\u{1b}[u" }   // as zsh's RPROMPT: drawn at the right, the cursor back
    v.feed(text: "~/p on main\r\n❯ " + right("10:03"))
    v.typed(ret)
    v.feed(text: "\r\n")
    await end("D;1", then: "~/p on main\r\n❯ " + right("10:04"))
    #expect(told.count == 1, "\(told)")
    v.feed(text: "\r\n$ ")
    // `ssh` in a local tab: the remote shell's last command, then ⌃D — the local shell's end of `ssh` isn't that command's.
    remote = true
    v.feed(text: "root@prod:~# systemctl status app")
    v.typed(ret)
    v.feed(text: "\r\napp.service: failed\r\n")
    remote = false
    await end("D;3", then: "$ ")
    #expect(told.count == 1, "\(told)")

    await run("ls nope", printing: "ls: nope: No such file\r\n", "D;1")
    #expect(shown?.title == "Explain · exit 1")
    v.feed(text: "pwd")
    v.typed(ret)
    #expect(shown == nil, "the next command: gone")
    shows.last? {}
    #expect(shown == nil, "shown late, after the next command: not")
    v.feed(text: "\r\n/tmp\r\n$ ")
    later = true   // where the first ran is still being learned when the second fails
    await run("cat a", printing: "cat: a: No such file\r\n", "D;1")
    await run("cat b", printing: "cat: b: No such file\r\n", "D;4")
    shows.last? { clicked += 10 }
    shows[shows.count - 2]({ clicked += 100 })
    #expect(shown?.title == "Explain · exit 4", "the later failure's stays")
    if let b = shown { _ = (b.target as? NSObject)?.perform(b.action, with: b) }
    #expect(clicked == 11, "\(clicked)")
    later = false
    await run("ls nope", printing: "ls: nope: No such file\r\n", "D;1")
    #expect(shown != nil)
    v.watchExits(false)
    #expect(!v.watchesExits && shown == nil, "not watched: its ✨ goes")
    shows.last? {}
    #expect(shown == nil, "shown late, once not watched: not")
    await run("ls nope", printing: "ls: nope: No such file\r\n", "D;1")
    #expect(shown == nil && told.count == 5, "not watched: nothing")
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
        let c = AppDelegate.checkFailure(e, name: "site.conf", path: "/etc/nginx/sites-enabled/site.conf", on: web.target.asRoot())
        #expect(c.title == "“nginx” on site.conf · shop" && c.server == web.target.asUser && c.server.map(SavedServer.isProd) == true)
        let said = await text(c)
        #expect(said.hasPrefix("“nginx -t” checked /etc/nginx/sites-enabled/site.conf as it was being saved, and failed (exit 1):\nline 1\n") && said.contains("line 40"), "\(said)")

        // A command's own line says where its text is from: an `ssh` to a production server there makes it that one's —
        // after it ended too (a terminal's ✨, an output window's). `ssh -G` is a stand-in: no config of yours.
        let wasG = ServerLock.sshG
        ServerLock.sshG = { t in "user me\nhostname \(t.host)\nport 22\n" }
        defer { ServerLock.sshG = wasG }
        let typed = EmbeddedTerminal.Tab.ran("me@mac ~ % ssh -p 2222 me@web.invalid 'systemctl status nginx'")
        #expect(typed.unsure && EmbeddedTerminal.Tab.production(typed.ssh, named: []) == web.target.asUser)
        #expect(EmbeddedTerminal.Tab.ran("me@mac ~ % ls -la").ssh.isEmpty && !EmbeddedTerminal.Tab.ran("ls").unsure)
        for line in ["me@mac ~ % cd /etc/ssh; ssh shop df", "ssh devbox.invalid a && ssh shop b", "me@mac ssh % echo $(ssh shop cat .env)"] {
            #expect(EmbeddedTerminal.Tab.production(EmbeddedTerminal.Tab.ran(line).ssh, named: []) == web.target.asUser, "\(line)")
        }
        let tab = EmbeddedTerminal.Tab(kind: .shell, view: DropTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300)))
        let chip = await AIPanel.terminal(tab, "me@mac ~ % ssh shop uptime\nload: 99\n[exit 1]", what: "Command")
        #expect(chip.server == web.target.asUser && chip.title.hasSuffix("as whoever is logged in"), "by its saved name: \(chip.title)")
        #expect(await AIPanel.terminal(tab, "me@mac ~ % ls nope\nls: nope\n[exit 1]", what: "Command").server == nil)
        #expect(await AIPanel.terminal(tab, "ssh shop", what: "Selection").server == nil, "a selection's words aren't a command it ran")
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
            for _ in 0..<300 where got.isEmpty { try await Task.sleep(for: .milliseconds(10)) }   // after a look where an `ssh` in it goes
            #expect(got.map(\.title) == ["echo oops; exit 3 · this Mac"] && got.first?.server == nil, "\(got.map(\.title))")
            let said = try await text(#require(got.first))
            #expect(said.hasPrefix("$ echo oops; exit 3\noops\n") && said.contains("[exit 3]"), "\(said)")
            let ok = try await ran("echo fine")
            defer { ok.close() }
            #expect(ok.docFrame?.actions.isEmpty == true, "it went well")

            // A command that names `ssh` to a production server: that one's (no ssh runs: `false &&`).
            var shop = SavedServer()
            (shop.host, shop.name, shop.prod) = ("shop.invalid", "shop", true)
            let wasG = ServerLock.sshG
            (ServerLock.servers, ServerLock.sshG) = ({ [shop] }, { t in "user me\nhostname \(t.host)\nport 22\n" })
            defer { (ServerLock.servers, ServerLock.sshG) = ({ [] }, wasG) }
            got = []
            let viaSSH = try await ran("false && ssh shop uptime; exit 5")
            defer { viaSSH.close() }
            try #require(viaSSH.docFrame?.actions.first).1()
            for _ in 0..<300 where got.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            #expect(got.first?.server == shop.target.asUser && got.first?.server.map(SavedServer.isProd) == true, "\(got.map(\.title))")
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
