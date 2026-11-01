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
        #expect(ToolRunner.refusal(ToolAction(run: ToolRun(command: .one("open {url}"), where: .mac), spec: .init(id: "open")), of: try toolNamed(app, "ufw").preset,
                                   ToolTemplate.Scope(rows: [["url": "file:///etc/passwd"]])) == "{url}: open takes only http:// and https:// addresses")
        let open = ToolAction(run: ToolRun(command: .one("open {url}"), where: .mac), spec: .init(id: "open")), ufw = try toolNamed(app, "ufw").preset
        #expect(ToolRunner.refusal(open, of: ufw, ToolTemplate.Scope(rows: [["url": "https://example.com/search?q=a&page=2#top"]])) == nil, "a web address's query and fragment")
        #expect(ToolRunner.refusal(open, of: ufw, ToolTemplate.Scope(rows: [["url": "https://example.com/?a=1;b"]])) != nil && ToolRunner.refusal(open, of: ufw, ToolTemplate.Scope(rows: [["url": "x?y&z"]])) != nil)
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

    /// ufw's list, read, in a panel.
    @MainActor private func ufw(_ app: AppDelegate, _ a: PanelViewController, on s: SavedServer = SavedServer(target: .local())) async throws -> ListPanel {
        let source = ToolListSource(app, try toolNamed(app, "ufw"), s, .local())
        _ = try await source.read(CancelFlag())
        a.showList(source)
        app.window.makeFirstResponder(a.table)
        return try #require(a.list)
    }

    /// A form (§7.4) checks as you type: empty where it may not be, the `pattern` on the whole value, a value that
    /// would be an option; "Will run:" follows, and an empty optional field drops its part. Cancel: nothing runs.
    @Test func aFormChecksAsYouTypeAndRunsWithItsValues() async throws {
        let (app, a, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done(); ToolRunner.filling = nil }
        let l = try await ufw(app, a)
        let allow = try #require(l.content?.primary)
        var seen: [String] = []
        ToolRunner.filling = { form in
            let port = form.inputs.first { $0.info.name == "port" }!
            seen.append(form.problem(port) ?? "ok")
            form.set("port", "http")
            seen.append(form.problem(port) ?? "ok")
            form.set("port", "-1")
            seen.append(form.problem(port) ?? "ok")
            form.set("port", "8080")
            seen.append(form.problem(port) ?? "ok")
            seen.append(form.willRun)
            form.set("comment", "")
            seen.append(form.willRun)
            #expect(form.ready && form.values["proto"] == "tcp" && form.values["source"] == "any")
            return form.values
        }
        _ = allow.run(false)
        await toolsUntil { !l.resultLines.isEmpty }
        #expect(seen == ["Port is empty", "doesn't look right: like 8080 or 6000:6010", "doesn't look right: like 8080 or 6000:6010", "ok",
                         "ufw allow proto tcp from any to any port 8080 comment 'added in Kermo'", "ufw allow proto tcp from any to any port 8080"])
        #expect(bench.calls.contains("ufw allow proto tcp from any to any port 8080"), "the comment's part left out")
        #expect(l.resultLines.first?.hasPrefix("\u{FFFC} Allowed tcp 8080 from any on localhost at ") == true, "\(l.resultLines)")

        ToolRunner.filling = { _ in nil }
        let before = bench.calls.count
        _ = allow.run(false)
        await toolsUntil { l.resultLines.first?.contains("cancelled") == true }
        #expect(l.resultLines == ["Allow Port: cancelled — nothing ran"] && bench.calls.count == before)
    }

    /// A `choice-from` input reads its choices from the server as the form opens; one that can't be read says why in
    /// its field, and the form won't run.
    @Test func choicesComeFromTheServer() async throws {
        let (app, a, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done(); ToolRunner.filling = nil }
        let l = try await fail2ban(app, a)
        let ban = try #require(l.content?.primary)
        #expect(ban.title == "Ban Address…")
        ToolRunner.filling = { form in
            await form.loading?.value
            guard case .ready(let jails)? = form.choices["jail"] else { Issue.record("no jails"); return nil }
            #expect(jails == ["sshd"] && form.values["jail"] == "sshd" && !form.ready)
            form.set("ip", "203.0.113.9")
            #expect(form.ready && form.willRun == "fail2ban-client set sshd banip 203.0.113.9")
            return form.values
        }
        await ban.run(false)?.value
        #expect(bench.calls.contains("fail2ban-client set sshd banip 203.0.113.9") && l.resultLines.last?.contains("Banned 203.0.113.9 in sshd") == true)

        bench.flag("f2b-down")
        var why: String?
        ToolRunner.filling = { form in
            await form.loading?.value
            why = form.problem(form.inputs.first { $0.info.name == "jail" }!)
            #expect(!form.ready)
            return nil
        }
        await ban.run(false)?.value
        #expect(why == "✕ Failed to access socket path: /var/run/fail2ban/fail2ban.sock. Is fail2ban running?", "\(why ?? "")")
    }

    /// A secret goes into the payload only (a heredoc): never the command line, the question, Show Exactly What Runs,
    /// the production log or what a failure shows.
    @Test func aSecretNeverShows() async throws {
        let (app, a, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done(); ToolRunner.filling = nil }
        let own = bench.dir + "/own"
        try FileManager.default.createDirectory(atPath: own, withIntermediateDirectories: true)
        try Data(#"""
            { "schema": 1, "id": "vault", "title": "Vault", "list": { "command": "echo one" },
              "toolActions": [ { "id": "unseal", "title": "Unseal…", "key": "cmd+u", "command": "echo \"sealed: {key}\" >&2; exit 1",
                                 "inputs": [ { "name": "key", "type": "secret", "title": "Key" } ] } ] }
            """#.utf8).write(to: URL(fileURLWithPath: own + "/vault.json"))
        _ = app.tools.reload()
        app.tools.trust.trust(try #require(app.tools.library.tools.first { $0.preset.id == "vault" }))
        var prod = SavedServer(address: "localhost")!
        prod.prod = true
        ServerLock.servers = { [prod] }
        let source = ToolListSource(app, try toolNamed(app, "vault"), prod, .local())
        _ = try await source.read(CancelFlag())
        a.showList(source)
        let l = try #require(a.list)
        var preview = ""
        ToolRunner.filling = { form in
            form.set("key", "hunter2-xyz")
            preview = form.willRun
            return form.values
        }
        var asked: [String] = [], exactly = ""
        AppDelegate.answering = { m, b, _ in
            asked.append(m)
            if m.hasPrefix("Exactly") { exactly = AppDelegate.answeredInfo; return 0 }
            return asked.count == 1 ? b.firstIndex(of: "Show Exactly What Runs")! : 0
        }
        await l.actions.first { $0.title == "Unseal…" }?.run(false)?.value
        #expect(preview == #"echo "sealed: •••" >&2; exit 1"# && exactly.contains("•••") && !exactly.contains("hunter2"))
        #expect(l.resultLines.first?.contains("sealed: •••") == true && l.resultLines.first?.contains("hunter2") == false, "\(l.resultLines)")
        await toolsUntil { FileManager.default.fileExists(atPath: AuditLog.path) }
        let log = try String(contentsOfFile: AuditLog.path, encoding: .utf8)
        #expect(log.contains("tool vault unseal") && !log.contains("hunter2"))
    }

    /// On production a change asks, once — "Don't ask again for 10 minutes" lets the next ones of that tool there
    /// run without; one that can't be undone asks each time. A read-only server runs only what changes nothing.
    @Test func tenMinutesAndReadOnly() async throws {
        let (app, a, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done(); ToolRunner.ticks = false }
        var prod = SavedServer(address: "localhost")!
        prod.prod = true
        ServerLock.servers = { [prod] }
        let l = try await fail2ban(app, a, on: prod)
        var asked: [String] = []
        AppDelegate.answering = { m, _, _ in asked.append(m); return 0 }
        ToolRunner.ticks = true
        await try action(l, "203.0.113.7", "Unban").run(false)?.value
        await try action(l, "198.51.100.2", "Unban").run(false)?.value
        #expect(asked == ["Unban on localhost?"], "the second: not asked")
        let u = try await ufw(app, a, on: prod)
        await u.shown.first { $0.title == "Anywhere" }?.listActions?().first { $0.title == "Delete Rule…" }?.run(false)?.value
        #expect(asked.last == "Delete Rule on localhost?", "can't be undone: always")

        var ro = SavedServer(address: "localhost")!
        ro.readOnly = true
        let r = try await fail2ban(app, a, on: ro)
        #expect(try action(r, "203.0.113.7", "Unban").why == "localhost is read-only: Tools run only actions that change nothing there")
        #expect(try action(r, "203.0.113.7", "Who Is It?").why == nil)
    }

    /// fail2ban's log follows in a window of its own, its payload's output as it comes; closing the window ends it.
    @Test func aLogFollows() async throws {
        let (app, a, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        let l = try await fail2ban(app, a)
        let log = try #require(l.actions.first { $0.title == "fail2ban Log" })
        #expect(log.closes && log.followWindow != nil, "next door in a panel too")
        await log.run(false)?.value
        await toolsUntil { NSApp.windows.contains { $0.title == "fail2ban Log — localhost" && (($0.docFrame?.scroll.documentView as? NSTextView)?.string ?? "").contains("Ban 203.0.113.7") } }
        let w = try #require(NSApp.windows.first { $0.title == "fail2ban Log — localhost" })
        #expect(((w.docFrame?.scroll.documentView as? NSTextView)?.string ?? "").hasPrefix("2026-10-30 10:00:00,123 fail2ban.actions"))
        w.close()
    }
}
