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
    }

    /// The screen locks: a locked server's tunnels stop listening, their connections live on; the unlocked server's go
    /// on. Back at the Mac, the status line names them — once.
    @Test func lockingTheScreenTurnsLockedServersTunnelsOff() async throws {
        let p = try freePorts(2)
        let vault = server("vault", locked: true, [Tunnel(localPort: p[0], port: 8200)]), db = server("db1", [Tunnel(localPort: p[1], port: 5432)])
        defer { tunnels.stopAll() }
        tunnels.start(vault.tunnels[0], of: vault)
        tunnels.start(db.tunnels[0], of: db)
        let c = dial(p[0])
        defer { close(c) }
        await waitUntil { tunnels.connections(vault.tunnels[0], of: vault) == 1 }
        tunnels.relock([vault, db])
        #expect(!tunnels.isListening(vault.tunnels[0], of: vault) && tunnels.isListening(db.tunnels[0], of: db))
        #expect(dial(p[0]) == -1)
        _ = "still".withCString { write(c, $0, 5) }
        var buf = [UInt8](repeating: 0, count: 5)
        #expect(read(c, &buf, 5) == 5 && String(decoding: buf, as: UTF8.self) == "still", "its connection lives on")
        #expect(said.lines.isEmpty, "said once the Mac is back")
        tunnels.sayHeldNote()
        tunnels.sayHeldNote()
        #expect(said.lines == ["Locked servers' tunnels turned off: localhost:8200 (vault)"] && said.errors == [false])
    }

    /// Saved servers changed: a tunnel deleted, or its server, stops; a new port, host or server address listens anew;
    /// a new name just shows. Quitting asks only about tunnels with connections open.
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
        #expect(tunnels.described(db.tunnels.map { ($0, db) }) == "Postgres (1 connection), Redis")

        db.tunnels[0].name = "Main DB"
        tunnels.sync([db])
        #expect(tunnels.state(db.tunnels[0], of: db)?.tunnel.name == "Main DB" && tunnels.connections(db.tunnels[0], of: db) == 1, "a name: nothing restarts")
        db.tunnels[0].host = "db.internal"
        tunnels.sync([db])
        #expect(tunnels.isListening(db.tunnels[0], of: db) && tunnels.state(db.tunnels[0], of: db)?.tunnel.host == "db.internal")
        var b: UInt8 = 0
        #expect(read(c, &b, 1) == 0, "listening anew ended the old way's connections")
        db.tunnels.removeLast()
        tunnels.sync([db])
        #expect(dial(p[1]) == -1 && tunnels.states.count == 1)
        tunnels.sync([])
        #expect(tunnels.states.isEmpty && dial(p[0]) == -1 && tunnels.inUse.isEmpty)
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
