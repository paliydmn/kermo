import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

/// Tunnels live in servers.json with their server: a file from before them reads as none, a hand-written one may give
/// the port alone; a local port twice on one server, or a tunnel's own problem, is the server's (its sheet says so).
@Test func tunnelsAreSavedWithTheirServer() throws {
    let old = try JSONDecoder().decode(SavedServer.self, from: Data(#"{"host": "web", "prod": true}"#.utf8))
    #expect(old.tunnels.isEmpty && old.problem == nil && old.prod)
    let s = try JSONDecoder().decode(SavedServer.self, from: Data(#"""
        {"host": "db1", "tunnels": [{"port": 5432, "on": true}, {"name": "Grafana", "localPort": 13000, "port": 3000}]}
        """#.utf8))
    #expect(s.tunnels == [Tunnel(localPort: 5432, port: 5432, on: true), Tunnel(name: "Grafana", localPort: 13000, port: 3000)])
    #expect(try JSONDecoder().decode(SavedServer.self, from: JSONEncoder().encode(s)) == s)
    var twice = s
    twice.tunnels.append(Tunnel(name: "Other", localPort: 5432, host: "db2", port: 5432))
    #expect(twice.problem == "Two tunnels listen on port 5432: each needs a port of its own.")
    var bad = s
    bad.tunnels[0].host = "-oProxyCommand=x"
    #expect(bad.problem == "Tunnel “Postgres”: “-oProxyCommand=x” isn't a host name.")
}

/// What `Tunnels` told the status line.
@MainActor private final class Said {
    var lines: [String] = []
    var errors: [Bool] = []
    func add(_ s: String, _ error: Bool) { lines.append(s); errors.append(error) }
}

@MainActor private func waitUntil(_ done: () -> Bool) async {
    for _ in 0..<1000 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
}

/// A client connected to 127.0.0.1:`port` (-1: refused); reads wait up to 10 s.
private func dial(_ port: Int) -> Int32 {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    var wait = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
    var a = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: UInt16(port).bigEndian,
                        sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    if r != 0 { close(s); return -1 }
    return s
}

/// Sends `text` and reads it back (`cat` echoes).
private func echoes(_ fd: Int32, _ text: String) -> Bool {
    _ = text.withCString { write(fd, $0, strlen($0)) }
    var buf = [UInt8](repeating: 0, count: text.utf8.count)
    var got = 0
    while got < buf.count {
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, $0.count - got) }
        if n <= 0 { return false }
        got += n
    }
    return String(decoding: buf, as: UTF8.self) == text
}

/// The other end closed it.
private func ends(_ fd: Int32) -> Bool {
    var b: UInt8 = 0
    return read(fd, &b, 1) == 0
}

/// Ports nobody listens on now (the kernel's picks).
private func freePorts(_ n: Int) throws -> [Int] {
    let ls = try (0..<n).map { _ in try TunnelListener(port: 0, child: { _ in .init(executable: "/bin/cat") }, onEvent: { _ in }) }
    defer { ls.forEach { $0.stop() } }
    return ls.map(\.port)
}

/// Each `AppDelegate` keeps its own `Tunnels`; these make their own, with `cat` in ssh's place. They run processes and
/// open ports: one at a time.
@Suite(.serialized) @MainActor struct TunnelsTests {
    fileprivate let said = Said()
    let tunnels = Tunnels()

    init() {
        tunnels.child = { _, _ in { _ in .init(executable: "/bin/cat") } }
        tunnels.say = { [said] in said.add($0, $1) }
    }

    func server(_ name: String, locked: Bool = false, _ list: [Tunnel]) -> SavedServer {
        var s = SavedServer(address: "me@\(name).invalid")!
        s.name = name
        s.locked = locked
        s.tunnels = list
        return s
    }

    /// D-081: an edit moves a tunnel's server to an address not learned yet (`ssh -G` runs after the edit) while a
    /// locked server is saved: it may be that one's other spelling, so it's off until Turn On asks; once the address
    /// is learned as another server, an edit there listens anew as before.
    @Test func aTunnelMovedToAnAddressNotLearnedYetWaitsForTouchID() async throws {
        let p = try freePorts(2)
        var db = server("db1", [Tunnel(localPort: p[0], port: 5432)])
        let vault = server("vault", locked: true, [])
        defer { tunnels.stopAll() }
        tunnels.start(db.tunnels[0], of: db)
        db.host = "s5-not-learned-\(UUID().uuidString.prefix(8)).invalid"
        tunnels.sync([db, vault])
        #expect(!tunnels.isListening(db.tunnels[0], of: db))
        #expect(said.lines.last == "“\(db.tunnels[0].title)” turned off: “db1” is locked — Turn On asks for Touch ID")

        var web = server("web1", [Tunnel(localPort: p[1], port: 80)])
        tunnels.start(web.tunnels[0], of: web)
        web.host = "s5-learned-\(UUID().uuidString.prefix(8)).invalid"
        await ServerLock.learn([web.target])   // learned: another server than the vault
        tunnels.sync([web, vault])
        #expect(tunnels.isListening(web.tunnels[0], of: web))
    }

    /// At launch the tunnels that were on listen — not a locked server's, nor one at a locked server's address — without
    /// connecting; one that can't is named in a single status line with the next free port. Listening keeps its
    /// server in use (its connection stays up when its last panel closes).
    @Test func onTunnelsListenAtLaunchUnlessLocked() throws {
        let p = try freePorts(4)
        let db = server("db1", [Tunnel(localPort: p[0], port: 5432, on: true), Tunnel(localPort: p[1], port: 6379)])
        let vault = server("vault", locked: true, [Tunnel(localPort: p[2], port: 8200, on: true)])
        var twin = server("vault", [Tunnel(localPort: p[3], port: 80, on: true)])
        twin.name = "vault again"
        let taken = try TunnelListener(port: 0, child: { _ in .init(executable: "/bin/cat") }, onEvent: { _ in })
        defer { taken.stop(); tunnels.stopAll() }
        let busy = server("busy", [Tunnel(name: "B", localPort: taken.port, port: 1, on: true)])
        tunnels.startSaved([db, vault, twin, busy])
        #expect(tunnels.isListening(db.tunnels[0], of: db) && !tunnels.isListening(db.tunnels[1], of: db))
        #expect(!tunnels.isListening(vault.tunnels[0], of: vault) && !tunnels.isListening(twin.tunnels[0], of: twin))
        #expect(tunnels.listening(db) == [db.tunnels[0]] && tunnels.inUse == [ServerRow.key(db.target)])
        let next = try #require(TunnelListener.freePort(after: taken.port))
        #expect(said.lines == ["Tunnels not listening: “B” (busy): Port \(taken.port) is in use on this Mac — \(next) is free"] && said.errors == [true])
        #expect(tunnels.state(busy.tunnels[0], of: busy)?.error?.hasPrefix("Port \(taken.port) is in use") == true)
        #expect(dial(p[0]) != -1, "a client gets through")
    }

    /// A pool reconnecting to a tunnel that fails says its reason once in the status line, a new reason once more; the
    /// tunnel keeps listening, and a clean end clears the reason (the ● goes green again).
    @Test func eachNewReasonIsToldOnce() async throws {
        let reason = Locked(value: "Nothing listens on localhost:5432 (as seen from db1)")
        tunnels.child = { _, _ in { _ in
            .init(executable: "/bin/sh", arguments: ["-c", "read x; [ \"$x\" = ok ] || exit 255"]) { status, _ in status == 0 ? nil : reason.value }
        } }
        let db = server("db1", [Tunnel(localPort: try freePorts(1)[0], port: 5432)])
        defer { tunnels.stopAll() }
        #expect(tunnels.start(db.tunnels[0], of: db) == nil)
        var changes = 0
        tunnels.changed = { changes += 1 }
        func connect(_ line: String) async {
            let c = dial(db.tunnels[0].localPort)
            _ = line.withCString { write(c, $0, strlen($0)) }
            shutdown(c, SHUT_WR)
            var b: UInt8 = 0
            _ = read(c, &b, 1)   // the end
            close(c)
            await waitUntil { tunnels.connections(db.tunnels[0], of: db) == 0 }
        }
        for _ in 0..<3 { await connect("no\n") }
        await waitUntil { said.lines.count == 1 && tunnels.state(db.tunnels[0], of: db)?.error != nil }
        #expect(said.lines == ["Postgres: Nothing listens on localhost:5432 (as seen from db1)"] && said.errors == [true])
        reason.value = "db1 forbids port forwarding (AllowTcpForwarding / PermitOpen)"
        await connect("no\n")
        await waitUntil { said.lines.count == 2 }
        #expect(said.lines.last == "Postgres: db1 forbids port forwarding (AllowTcpForwarding / PermitOpen)")
        await connect("ok\n")
        await waitUntil { tunnels.state(db.tunnels[0], of: db)?.error == nil }
        #expect(tunnels.state(db.tunnels[0], of: db)?.error == nil && tunnels.isListening(db.tunnels[0], of: db))
        #expect(said.lines.count == 2)
        #expect(changes == 2, "the sidebar hears failed, then fine — not each retry")
    }

    /// The screen locks: a locked server's tunnels stop listening, their connections live on; the unlocked server's go
    /// on. Back at the Mac, the status line names them — once. What they keep is still Kermo's: quitting asks about it
    /// and ends it, and so does Disconnect.
    @Test func lockingTheScreenTurnsLockedServersTunnelsOff() async throws {
        let p = try freePorts(2)
        let vault = server("vault", locked: true, [Tunnel(localPort: p[0], port: 8200)]), db = server("db1", [Tunnel(localPort: p[1], port: 5432)])
        defer { tunnels.stopAll() }
        tunnels.start(vault.tunnels[0], of: vault)
        tunnels.start(db.tunnels[0], of: db)
        let c = dial(p[0]), d = dial(p[0])
        defer { close(c); close(d) }
        await waitUntil { tunnels.connections(vault.tunnels[0], of: vault) == 2 }
        tunnels.relock([vault, db])
        #expect(!tunnels.isListening(vault.tunnels[0], of: vault) && tunnels.isListening(db.tunnels[0], of: db))
        #expect(dial(p[0]) == -1)
        #expect(echoes(c, "still"), "its connection lives on")
        #expect(said.lines.isEmpty, "said once the Mac is back")
        tunnels.sayHeldNote()
        tunnels.sayHeldNote()
        #expect(said.lines == ["Locked servers' tunnels turned off: localhost:8200 (vault)"] && said.errors == [false])
        #expect(tunnels.quitNote() == "Tunnels: localhost:8200 (2 connections) — they close")
        #expect(tunnels.described(server: ServerRow.key(vault.target)) == "localhost:8200 (2 connections)")
        tunnels.endHeld(ServerRow.key(db.target))
        #expect(echoes(c, "on"), "another server's Disconnect leaves it")
        tunnels.endHeld(ServerRow.key(vault.target))   // its Disconnect
        #expect(ends(c) && ends(d) && tunnels.quitNote() == nil)
    }

    /// Saved servers changed: a tunnel deleted, or its server, stops; a new name just shows; a new way or server — the
    /// Lock box ticked too — listens anew, and the connections it had live on to where they went (quitting still ends
    /// them). Moved to a locked server's address it doesn't listen: that asks for Touch ID.
    @Test func editsReachTheListeningPorts() async throws {
        let p = try freePorts(3)
        var db = server("db1", [Tunnel(localPort: p[0], port: 5432), Tunnel(localPort: p[1], port: 6379)])
        defer { tunnels.stopAll() }
        db.tunnels.forEach { tunnels.start($0, of: db) }
        #expect(tunnels.quitNote() == nil, "listening alone: nothing to ask")
        let c = dial(p[0])
        defer { close(c) }
        await waitUntil { tunnels.connections(db.tunnels[0], of: db) == 1 }
        #expect(tunnels.quitNote() == "Tunnels: Postgres (1 connection) — they close")
        #expect(tunnels.described(server: ServerRow.key(db.target)) == "Postgres (1 connection), Redis")

        db.tunnels[0].name = "Main DB"
        tunnels.sync([db])
        #expect(tunnels.state(db.tunnels[0], of: db)?.tunnel.name == "Main DB" && tunnels.connections(db.tunnels[0], of: db) == 1, "a name: nothing restarts")
        db.tunnels[0].host = "db.internal"
        tunnels.sync([db])
        #expect(tunnels.isListening(db.tunnels[0], of: db) && tunnels.state(db.tunnels[0], of: db)?.tunnel.host == "db.internal")
        #expect(echoes(c, "kept"), "listening anew keeps the old way's connection")
        #expect(tunnels.quitNote() == "Tunnels: Main DB (1 connection) — they close")
        let c2 = dial(p[0])   // on the port listening anew
        defer { close(c2) }
        await waitUntil { tunnels.connections(db.tunnels[0], of: db) == 1 }
        tunnels.moving(db.tunnels[0], of: db)   // the sheet, saving another local port
        db.tunnels[0].localPort = p[2]
        tunnels.sync([db])
        tunnels.start(db.tunnels[0], of: db)
        #expect(dial(p[0]) == -1 && tunnels.isListening(db.tunnels[0], of: db) && echoes(c2, "moved") && echoes(c, "kept"),
                "another local port: the old one closes, its connection lives on")
        #expect(tunnels.described(server: ServerRow.key(db.target)) == "Main DB (2 connections), Redis", "one entry each, held ones counted in")
        #expect(tunnels.quitNote() == "Tunnels: Main DB (2 connections) — they close")
        db.locked = true   // the server's connection lingers 60 s now: listens anew for the next ones
        let token = tunnels.state(db.tunnels[0], of: db)?.token
        tunnels.sync([db])
        #expect(tunnels.isListening(db.tunnels[0], of: db) && tunnels.state(db.tunnels[0], of: db)?.token != token && echoes(c, "lock"))
        db.locked = false
        tunnels.sync([db])

        var vault = server("vault", locked: true, [])
        vault.host = "vault.invalid"
        var moved = db
        moved.host = vault.host   // to a locked server's address, by an edit of this unlocked one
        tunnels.sync([moved, vault])
        #expect(!tunnels.isListening(moved.tunnels[0], of: moved) && dial(p[2]) == -1 && echoes(c, "held"))
        #expect(said.lines.suffix(2).sorted() == ["“Main DB” turned off: “db1” is locked — Turn On asks for Touch ID",
                                                  "“Redis” turned off: “db1” is locked — Turn On asks for Touch ID"])
        tunnels.sync([db])
        db.tunnels.removeLast()
        tunnels.sync([db])
        #expect(dial(p[1]) == -1 && tunnels.states.isEmpty)
        tunnels.stopAll()
        #expect(ends(c) && tunnels.inUse.isEmpty)
    }

    /// A tunnel's item says its name, port and open connections, its state by a ● (and to VoiceOver), why it failed in
    /// its tooltip; its actions sit in a submenu — Open in Browser only with a URL. A production server's are red. The
    /// server's menu ends with New Tunnel…; Go ▸ Tunnels lists every server's under its name, built as it opens.
    @Test func tunnelMenusSayTheirState() async throws {
        let app = AppDelegate()
        app.tunnels.child = tunnels.child
        let p = try freePorts(2)
        var db = server("db1", [Tunnel(localPort: p[0], port: 5432), Tunnel(name: "Grafana", localPort: p[1], port: 3000)])
        db.prod = true
        let web = server("web", [Tunnel(localPort: 1, host: "-x", port: 80)])
        app.savedServers = [db, web, server("none", [])]
        defer { app.tunnels.stopAll() }
        app.tunnels.start(db.tunnels[0], of: db)
        app.tunnels.start(web.tunnels[0], of: web)
        let c = dial(p[0])
        defer { close(c) }
        await waitUntil { app.tunnels.connections(db.tunnels[0], of: db) == 1 }

        let pg = app.tunnelItem(db.tunnels[0], of: db)
        #expect(pg.title == "Postgres → \(p[0]) · 1" && pg.image?.accessibilityDescription == "listening")
        #expect(pg.toolTip == "localhost:\(p[0]) → db1 → localhost:5432")
        #expect(pg.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == SavedServer.color, "production")
        #expect(pg.submenu?.items.map(\.title) == ["Turn Off", "Copy Address", "", "Edit…", "Delete…"], "no URL for a database")
        let grafana = app.tunnelItem(db.tunnels[1], of: db)
        #expect(grafana.title == "Grafana → \(p[1])" && grafana.image?.accessibilityDescription == "off")
        #expect(grafana.submenu?.items.map(\.title) == ["Turn On", "Open in Browser", "Copy Address", "", "Edit…", "Delete…"])
        let bad = app.tunnelItem(web.tunnels[0], of: web)
        #expect(bad.image?.accessibilityDescription == "failed" && bad.toolTip == "“-x” isn't a host name." && bad.attributedTitle == nil)

        #expect(app.tunnelsItem(for: db, at: db.target).submenu?.items.map(\.title)
                == ["Postgres → \(p[0]) · 1", "Grafana → \(p[1])", "", "New Tunnel…", "Forward Port…"])
        #expect(app.tunnelsItem(for: server("none", []), at: server("none", []).target).submenu?.items.map(\.title) == ["New Tunnel…", "Forward Port…"])
        let go = try #require(app.goTunnelsItem().submenu)
        go.delegate?.menuNeedsUpdate?(go)
        #expect(go.items.map(\.title) == ["db1", "Postgres → \(p[0]) · 1", "Grafana → \(p[1])", "web", "-x:80 → 1", "", "New Tunnel…", "Forward Port…"])
        #expect(go.items[0].isSectionHeader && go.items[3].isSectionHeader)
    }

    /// Forward Port… is in every server row's menu, before its Tunnels ▸ (which has it too); server pickers say locked
    /// and production up front.
    @Test func forwardPortIsInEachServersMenu() {
        let app = AppDelegate()
        let row = ServerRow(target: SFTPTarget(host: "me@web.invalid"), saved: nil, title: "web")
        let titles = app.serverMenu(.server(row)).map(\.title)
        #expect(titles.firstIndex(of: "Forward Port…").map { titles[$0 + 1] } == "Tunnels", "\(titles)")
        var s = server("vault", locked: true, [])
        s.prod = true
        #expect(s.pickerTitle == "🔒 " + SavedServer.mark + "vault" && server("db1", []).pickerTitle == "db1")
    }

    /// U14: back with a taken port, ↩ takes "Use N", not the taken port again; ⎋ stays Cancel's.
    @Test func aTakenPortsSheetTakesTheFreeOneOnReturn() {
        let alert = NSAlert()
        ["Save & Turn On", "Save", "Use 15433", "Cancel"].forEach { alert.addButton(withTitle: $0) }
        AppDelegate.returnTakes(alert.buttons[2], in: alert)
        #expect(alert.buttons.map(\.keyEquivalent) == ["", "", "\r", "\u{1b}"])
    }

    /// The sidebar shows "⇄ 2" on a server's row while its tunnels listen; ⌘⇧P finds Tunnels… and New Tunnel….
    @Test func listeningTunnelsShowInTheSidebarAndSearch() {
        var list = ServerList(saved: [server("db1", [])])
        list.tunnels = [ServerRow.key(list.saved[0].target): ["Postgres", "Redis"]]
        list.failedTunnels = [ServerRow.key(list.saved[0].target): ["Redis: db1 can't resolve cache"]]
        #expect(SidebarModel.serverRows(list).first?.tunnels == ["Postgres", "Redis"])
        #expect(SidebarModel.serverRows(list).first?.failedTunnels == ["Redis: db1 can't resolve cache"])
        let hits = HeaderSearchModel.results("tunnel", commands: AppDelegate().makeCommands(), folders: [], files: [], recent: [])
        #expect(hits.first?.hits.prefix(2).map(\.title).sorted() == ["New Tunnel…", "Tunnels…"])
    }


    /// Forward Port's tunnels are temporary, on any server — one never saved too: saved servers changing (`sync`) leaves
    /// them be; they keep their server in use, quitting and Disconnect name and end them, the lock turns a locked
    /// address's off. Save makes one the server's own without closing its port — the one it was on, or that server saved
    /// since — and what its connections say is still heard.
    @Test func temporaryTunnelsLiveUntilTurnedOff() async throws {
        tunnels.child = { _, _ in { _ in
            .init(executable: "/bin/sh", arguments: ["-c", "read x; [ \"$x\" = ok ] && echo ok || exit 255"]) { status, _ in status == 0 ? nil : "refused" }
        } }
        let p = try freePorts(3)
        let db = server("db1", []), web = SavedServer(address: "me@web.invalid")!   // web: not saved
        let t = Tunnel(localPort: p[0], port: 5432), u = Tunnel(localPort: p[1], port: 80)
        defer { tunnels.stopAll() }
        #expect(tunnels.start(t, of: db, temporary: true) == nil && tunnels.start(u, of: web, temporary: true) == nil)
        let token = tunnels.state(t, of: db)?.token
        tunnels.sync([db])   // servers.json saved: no tunnel of theirs in it
        tunnels.sync([])
        #expect(tunnels.isListening(t, of: db) && tunnels.isListening(u, of: web) && tunnels.state(t, of: db)?.token == token)
        #expect(tunnels.isTemporary(t, of: db) && Set(tunnels.temporaries().map(\.tunnel.localPort)) == [p[0], p[1]])
        #expect(tunnels.temporaries(server: ServerRow.key(web.target)).map(\.tunnel) == [u])
        #expect(tunnels.inUse == [ServerRow.key(db.target), ServerRow.key(web.target)])
        let c = dial(p[1])
        defer { close(c) }
        await waitUntil { tunnels.connections(u, of: web) == 1 }
        #expect(tunnels.quitNote() == "Tunnels: localhost:80 (1 connection) — they close")
        #expect(tunnels.described(server: ServerRow.key(web.target)) == "localhost:80 (1 connection)")
        tunnels.stopTemporaries(server: ServerRow.key(web.target))   // Disconnect
        #expect(ends(c) && dial(p[1]) == -1 && tunnels.temporaries().map(\.tunnel) == [t])

        var saved = db
        saved.tunnels = [Tunnel(localPort: p[0], port: 5432, on: true)]
        tunnels.adopt(saved.tunnels[0], of: db, into: saved)
        tunnels.sync([saved])
        #expect(!tunnels.isTemporary(saved.tunnels[0], of: saved) && tunnels.state(saved.tunnels[0], of: saved)?.token == token)
        let d = dial(p[0])
        _ = "no\n".withCString { write(d, $0, 3) }
        #expect(ends(d))
        close(d)
        await waitUntil { tunnels.state(saved.tunnels[0], of: saved)?.error != nil }
        #expect(said.lines == ["Postgres: refused"], "its word is heard after Save")

        let v = Tunnel(localPort: p[1], port: 6379)
        tunnels.start(v, of: web, temporary: true)
        let since = tunnels.state(v, of: web)?.token
        let webSaved = server("web", [v])   // the same address, saved since
        tunnels.adopt(v, of: web, into: webSaved)
        #expect(tunnels.state(v, of: web) == nil && tunnels.state(v, of: webSaved)?.token == since && !tunnels.isTemporary(v, of: webSaved))
        let e = dial(p[1])   // under another key now: its word still found by the listener's token
        _ = "no\n".withCString { write(e, $0, 3) }
        #expect(ends(e))
        close(e)
        await waitUntil { tunnels.state(v, of: webSaved)?.error != nil }
        #expect(said.lines.last == "Redis: refused")
        tunnels.stop(v, of: webSaved)

        let w = Tunnel(localPort: p[2], port: 80)
        tunnels.start(w, of: web, temporary: true)
        tunnels.relock([server("web", locked: true, [])])   // a locked server at its address
        #expect(!tunnels.isListening(w, of: web) && tunnels.temporaries().isEmpty)
        #expect(tunnels.start(Tunnel(localPort: p[0], port: 1), of: web, temporary: true) != nil && tunnels.temporaries().isEmpty,
                "one that can't listen leaves nothing behind")
    }

    /// Forward Port's Picker (U2): a row a port — its usual name, process and where it listens, "→ localhost:L" where a
    /// tunnel of the server already goes there. ↩ forwards it by a temporary tunnel on the same port here, the next free
    /// one when that's taken (said, U3), and again says it's there already. Temporary ones show "· temporary" in the
    /// server's menu (Turn Off, Copy Address — Save only for a saved server), in Go ▸ Tunnels under their server (one not
    /// saved after the saved ones), and keep an unsaved server's sidebar row, with its ⇄.
    @Test func forwardPortMakesTemporaryTunnels() async throws {
        let app = AppDelegate()
        app.tunnels.child = tunnels.child
        app.tunnels.say = { [said] in said.add($0, $1) }
        let p = try freePorts(2)
        let taken = try TunnelListener(port: p[0], child: { _ in .init(executable: "/bin/cat") }, onEvent: { _ in })
        defer { taken.stop(); app.tunnels.stopAll() }
        let db = server("db1", [Tunnel(name: "Main", localPort: p[1], port: 6379)])
        app.savedServers = [db]
        let ports = [ListeningPort(port: p[0], addresses: ["*"], process: "nginx"), ListeningPort(port: 5432, addresses: ["localhost"]),
                     ListeningPort(port: 6379, addresses: ["localhost"], process: "redis-server")]
        var rows = app.portItems(ports, of: db)
        #expect(rows.map(\.title) == [":\(p[0])", ":5432 Postgres", ":6379 Redis"])
        #expect(rows.map(\.subtitle) == ["nginx · all addresses", "localhost only", "redis-server · localhost only"])
        #expect(rows.map(\.detail) == ["", "", ""], "Main isn't listening")
        #expect(rows[0].keys.keys.map(\.display).sorted() == ["⌘C", "⌘O", "⌘S"])

        rows[0].run()
        let next = try #require(app.tunnels.temporaries().first?.tunnel)
        #expect(next.localPort > p[0] && next.host == "localhost" && next.port == p[0] && next.title == "nginx")
        #expect(said.lines.last == "nginx: localhost:\(next.localPort) → db1:\(p[0]) (\(p[0]) is taken here) · listening" && said.errors.last == false)
        let c = dial(next.localPort)
        #expect(c != -1)
        defer { close(c) }
        await waitUntil { app.tunnels.connections(next, of: db) == 1 }
        rows = app.portItems(ports, of: db)
        #expect(rows[0].detail == "→ localhost:\(next.localPort) · temporary")
        rows[0].run()
        #expect(app.tunnels.temporaries().count == 1 && said.lines.last == "nginx: localhost:\(next.localPort) → db1:\(p[0]) · listening already")

        let item = app.tunnelItem(next, of: db)
        #expect(item.title == "nginx → \(next.localPort) · 1 · temporary" && item.submenu?.items.map(\.title) == ["Turn Off", "Copy Address", "Save"])
        #expect(app.tunnelsItem(for: db, at: db.target).submenu?.items.map(\.title)
                == ["Main → \(p[1])", "nginx → \(next.localPort) · 1 · temporary", "", "New Tunnel…", "Forward Port…"])

        let web = SavedServer(target: SFTPTarget(host: "me@web.invalid", port: 2222))   // not saved
        #expect(web.target == SFTPTarget(host: "me@web.invalid", port: 2222) && web.title == "me@web.invalid")
        app.forward(ListeningPort(port: 8080, addresses: ["192.0.2.10"]), of: web, .none)
        let w = try #require(app.tunnels.temporaries(server: ServerRow.key(web.target)).first?.tunnel)
        #expect(w.host == "192.0.2.10" && said.lines.last == "192.0.2.10:8080: localhost:\(w.localPort) → me@web.invalid → 192.0.2.10:8080"
                + (w.localPort == 8080 ? "" : " (8080 is taken here)") + " · listening")
        #expect(app.tunnelItem(w, of: web).submenu?.items.map(\.title) == ["Turn Off", "Open in Browser", "Copy Address"], "Save: not until it's saved")
        #expect(app.tunnelsItem(for: nil, at: web.target).submenu?.items.map(\.title) == ["192.0.2.10:8080 → \(w.localPort) · temporary", "", "Forward Port…"])
        let go = try #require(app.goTunnelsItem().submenu)
        go.delegate?.menuNeedsUpdate?(go)
        #expect(go.items.map(\.title) == ["db1", "Main → \(p[1])", "nginx → \(next.localPort) · 1 · temporary",
                                          "me@web.invalid", "192.0.2.10:8080 → \(w.localPort) · temporary", "", "New Tunnel…", "Forward Port…"])

        var list = ServerList(saved: [db], recents: (1...6).map { "me@r\($0).invalid" }, forwarded: [web.target])
        list.tunnels = [ServerRow.key(web.target): [w.title]]
        let row = try #require(SidebarModel.serverRows(list).first { $0.key == ServerRow.key(web.target) }, "kept past the five places")
        #expect(row.tunnels == [w.title] && row.saved == nil)
        app.tunnels.stop(w, of: web)   // Turn Off (its releaseIdleServers needs the window)
        #expect(app.tunnels.temporaries(server: ServerRow.key(web.target)).isEmpty && dial(w.localPort) == -1)
    }
}

/// A value the tests' child closures read off the main thread.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(value: T) { v = value }
    var value: T {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}
