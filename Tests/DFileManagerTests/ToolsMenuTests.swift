import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Tools PR 2: where tools show — Tools ▸ in a server's menus and a row each in its place — from one batch of
// `requires` over a connection that's up, never a login for a menu; Reload Config says what's wrong with a tool of
// yours, with its line.

extension ServerLockTests {
    /// Without a connection nothing is asked: Tools ▸ says to connect. Connected, the server is asked once, off the
    /// main thread; then its tools show — and stay, greyed with when they were known, once it's disconnected. Its place
    /// has a row each, with the rows its list had when last read. A server with none of them has no Tools ▸.
    @Test func toolsShowWhereTheServerHasThem() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        var up = false
        AppDelegate.connected = { _ in up }
        let t = SFTPTarget.local(), key = ServerRow.key(t)
        let first = try #require(app.toolsItem(for: t)?.submenu)
        #expect(first.items.map(\.title) == ["Connect to see tools"] && first.items.allSatisfy { !$0.isEnabled })
        #expect(bench.calls.isEmpty && app.tools.answers[key] == nil, "nothing asked")

        up = true
        #expect(app.toolsItem(for: t)?.submenu?.items.map(\.title) == ["Looking at what it has…"])
        await toolsUntil { app.tools.answers[key] != nil }
        let menu = try #require(app.toolsItem(for: t)?.submenu)
        #expect(menu.items.map(\.title) == ["Banned IPs (fail2ban)", "Firewall (ufw)"] && menu.items.allSatisfy(\.isEnabled))
        #expect(menu.items.map { $0.image != nil } == [true, true])
        let place = PlaceSource(app, SavedServer(target: t), t)
        #expect(place.content?.rows.filter { ["Banned IPs", "Firewall"].contains($0.title) }.map(\.subtitle) == ["—", "—"])
        _ = try await ToolListSource(app, try toolNamed(app, "ufw"), SavedServer(target: t), t).read(CancelFlag())
        #expect(place.content?.rows.first { $0.title == "Firewall" }?.subtitle == "3 rows" && place.content?.rows.first { $0.title == "Firewall" }?.into != nil)

        up = false
        let offline = try #require(app.toolsItem(for: t)?.submenu)
        #expect(offline.items.first?.title.hasPrefix("As of ") == true && offline.items.dropFirst().map(\.title) == ["Banned IPs (fail2ban)", "Firewall (ufw)"])
        #expect(offline.items.allSatisfy { !$0.isEnabled })
        #expect(place.content?.rows.first { $0.title == "Firewall" }?.subtitle == "—", "a count only while connected")

        _ = app.tools.reload()   // asked again: now it has neither
        up = true
        try FileManager.default.removeItem(atPath: bench.dir + "/bin/ufw")
        try FileManager.default.removeItem(atPath: bench.dir + "/bin/fail2ban-client")
        _ = app.toolsItem(for: t)
        await toolsUntil { app.tools.answers[key] != nil }
        #expect(app.toolsItem(for: t) == nil && place.content?.rows.contains { $0.title == "Firewall" } == false)
    }

    /// Reload Config reads your tools again and says what's wrong with one, with its line; a one-command tool of yours
    /// you trust is in Tools ▸, and runs into a window of its own.
    @Test func reloadConfigSaysWhatsWrongWithATool() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        let own = bench.dir + "/own"
        try FileManager.default.createDirectory(atPath: own, withIntermediateDirectories: true)
        try Data("{\n  \"schema\": 1,\n  \"id\": \"bad\",\n  \"titel\": \"Bad\"\n}\n".utf8).write(to: URL(fileURLWithPath: own + "/bad.json"))
        try Data(#"{ "schema": 1, "id": "hello", "title": "Hello", "command": "echo hello from {server}" }"#.utf8).write(to: URL(fileURLWithPath: own + "/hello.json"))
        let problems = app.tools.reload()
        #expect(problems.contains { $0.hasPrefix("tools/bad.json: line 4: ") }, "\(problems)")
        #expect(!app.tools.tools.contains { $0.preset.id == "hello" }, "not trusted yet")
        let hello = try #require(app.tools.library.tools.first { $0.preset.id == "hello" })
        app.tools.trust.trust(hello)
        AppDelegate.connected = { _ in true }
        _ = app.toolsItem(for: .local())
        await toolsUntil { app.tools.answers[ServerRow.key(.local())] != nil }
        let item = try #require(app.toolsItem(for: .local())?.submenu?.items.first { $0.title == "Hello" })
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        await toolsUntil { NSApp.windows.contains { $0.title == "Hello — localhost" && $0.isVisible } }
        let w = try #require(NSApp.windows.first { $0.title == "Hello — localhost" })
        #expect(((w.docFrame?.scroll.documentView as? NSTextView)?.string ?? "").hasPrefix("hello from localhost"))
        w.close()
    }
}
