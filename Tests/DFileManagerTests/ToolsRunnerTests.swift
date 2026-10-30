import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Tools PR 2: the way an action goes (protocol §7.2–7.3) — who asks, what the question shows, what runs where, the
// production log, one change at a time, values that never reach a command. fail2ban's built-in preset against
// stand-ins on this Mac (`ToolsBench`).

extension ServerLockTests {
    /// fail2ban's list, read, in a panel.
    @MainActor private func fail2ban(_ app: AppDelegate, _ a: PanelViewController, on s: SavedServer = SavedServer(target: .local())) async throws -> ListPanel {
        let source = ToolListSource(app, try toolNamed(app, "fail2ban"), s, .local())
        _ = try await source.read(CancelFlag())
        a.showList(source)
        app.window.makeFirstResponder(a.table)
        return try #require(a.list)
    }

    @MainActor private func action(_ l: ListPanel, _ row: String, _ title: String) throws -> ListAction {
        try #require(l.shown.first { $0.title == row }?.listActions?().first { $0.title == title })
    }

    /// On production every action that isn't `readonly` asks (§7.3) — the command with its values, and Show Exactly
    /// What Runs: the payload, then the question again. The production log gets the tool, the action, the payload
    /// and the exit. A `readonly` one asks nothing there: Who Is It? runs on this Mac and opens its window.
    @Test func productionAsksAllButReadonlyAndLogsTheRun() async throws {
        let (app, a, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        var prod = SavedServer(address: "localhost")!
        prod.prod = true
        ServerLock.servers = { [prod] }
        let l = try await fail2ban(app, a, on: prod)
        #expect(l.shown.map(\.title) == ["203.0.113.7", "198.51.100.2"] && l.shown.first?.subtitle == "banned by sshd")
        #expect(l.content?.header == "jails: sshd · 1.0.2")
        let unban = try action(l, "203.0.113.7", "Unban")
        #expect(unban.asks == .prod && unban.command == "fail2ban-client set sshd unbanip 203.0.113.7" && !unban.dangerous)

        var asked: [String] = []
        AppDelegate.answering = { m, b, _ in asked.append(m); return asked.count == 1 ? b.firstIndex(of: "Show Exactly What Runs") ?? 9 : 0 }
        _ = unban.run(false)
        await toolsUntil { !l.resultLines.isEmpty }
        #expect(asked == ["Unban on localhost?", "Exactly what runs on localhost", "Unban on localhost?"])
        let shown = AppDelegate.answeredInfo
        #expect(shown.contains("K_ip=203.0.113.7") && shown.contains("K_jail=sshd") && shown.contains(#"fail2ban-client set "$K_jail" unbanip "$K_ip""#))
        #expect(l.resultLines.first?.hasPrefix("\u{FFFC} Unbanned 203.0.113.7 (sshd) on localhost at ") == true, "\(l.resultLines)")
        #expect(bench.calls.contains("fail2ban-client set sshd unbanip 203.0.113.7"))
        await toolsUntil { FileManager.default.fileExists(atPath: AuditLog.path) }
        let log = try String(contentsOfFile: AuditLog.path, encoding: .utf8)
        #expect(log.contains(#""action":"tool fail2ban unban""#) && log.contains(#""exit":0"#) && log.contains("K_ip=203.0.113.7"))

        asked = []
        let whois = try action(l, "203.0.113.7", "Who Is It?")
        #expect(whois.asks == .never && whois.closes && whois.runsOn == nil)
        _ = whois.run(false)
        await toolsUntil { NSApp.windows.contains { $0.title == "Who Is It? — this Mac" && $0.isVisible } }
        #expect(NSApp.windows.contains { $0.title == "Who Is It? — this Mac" })
        #expect(asked.isEmpty && bench.calls.contains("whois 203.0.113.7"))
        NSApp.windows.filter { $0.title == "Who Is It? — this Mac" }.forEach { $0.close() }
    }

    /// A value that would be an option (`-h`) or has a line break never reaches a command; on this Mac (`where: mac`)
    /// a server's value has only safe characters (S3). Said on the action, greyed: nothing runs.
    @Test func valuesThatWouldntBeOneArgumentAreRefused() async throws {
        let (app, a, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        bench.banned("-h evil.example 203.0.113.7;x")
        let l = try await fail2ban(app, a)
        #expect(try action(l, "-h", "Who Is It?").why == "Who Is It?: {ip}: it begins with “-”, so a command would take it for an option — nothing runs")
        #expect(try action(l, "-h", "Unban").why?.hasPrefix("Unban: {ip}: it begins with “-”") == true)
        #expect(try action(l, "203.0.113.7;x", "Who Is It?").why == "Who Is It?: {ip}: “203.0.113.7;x” has characters this Mac won't put into a command — nothing runs")
        #expect(try action(l, "203.0.113.7;x", "Unban").why == nil, "on the server it's one argument, whatever it holds")
        #expect(ToolRunner.refusal(ToolRun(command: .one("open {url}"), where: .mac), of: try toolNamed(app, "ufw").preset,
                                   ToolTemplate.Scope(rows: [["url": "file:///etc/passwd"]])) == "{url}: open takes only http:// and https:// addresses")
        _ = try action(l, "-h", "Unban").run(false)
        #expect(!bench.calls.contains { $0.contains("unbanip") })
    }

    /// One change of a tool on a server at a time (§2): while Unban runs, another row's Unban says what runs, and its
    /// own row waits; a `readonly` action runs alongside. A program missing there is said in words (exit 127).
    @Test func oneChangeOfAToolAtATime() async throws {
        let (app, a, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        bench.flag("slow")
        let l = try await fail2ban(app, a)
        let run = try action(l, "203.0.113.7", "Unban").run(false)
        await toolsUntil { l.shown.first { $0.title == "203.0.113.7" }?.busy == true }
        #expect(l.shown.first { $0.title == "203.0.113.7" }?.subtitle == "Unban…")
        #expect(try action(l, "198.51.100.2", "Unban").why == "Banned IPs on localhost is busy: Unban")
        #expect(try action(l, "203.0.113.7", "Unban").why == "203.0.113.7: Unban runs on it — wait for it")
        #expect(try action(l, "198.51.100.2", "Who Is It?").why == nil, "a look runs alongside")
        await run?.value
        #expect(try action(l, "198.51.100.2", "Unban").why == nil)

        try FileManager.default.removeItem(atPath: bench.dir + "/bin/fail2ban-client")
        let missing = try action(l, "198.51.100.2", "Unban").run(false)
        await missing?.value
        #expect(l.resultLines.last == "\u{FFFC} fail2ban-client isn't on localhost", "\(l.resultLines)")
    }
}
