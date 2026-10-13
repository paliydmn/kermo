import Foundation
import Testing
@testable import DFMCore

/// The Forward field reads as `ssh -L` does; whatever else was typed says why it isn't one.
@Test func forwardReadsAsSshLDoes() {
    let base = Tunnel(name: "Postgres", localPort: 1, port: 1, on: true)
    func read(_ s: String) -> Tunnel? { try? base.reading(s).get() }
    func why(_ s: String) -> String? { if case .failure(let p) = base.reading(s) { p.message } else { nil } }
    #expect(read("5432") == Tunnel(name: "Postgres", localPort: 5432, port: 5432, on: true), "the rest stays as it was")
    #expect(read(" 15432:5432 ") == Tunnel(name: "Postgres", localPort: 15432, port: 5432, on: true))
    #expect(read("15432:db.internal:5432")?.host == "db.internal")
    #expect(read("15432:[::1]:5432").map { ($0.host, $0.port) } ?? ("", 0) == ("::1", 5432))
    #expect(read("15432:192.0.2.5:5432")?.host == "192.0.2.5")
    #expect(read("127.0.0.1:15432:db:5432")?.localPort == 15432, "the loopback is where it listens anyway")
    #expect(read("localhost:15432:db:5432")?.host == "db")
    #expect(why("0.0.0.0:15432:db:5432") == "Kermo listens on 127.0.0.1 only, never on “0.0.0.0”.")
    #expect(why("*:15432:db:5432") != nil)
    #expect(why("")?.hasPrefix("Enter a port") == true)
    #expect(why("15432:::1:5432")?.contains("brackets") == true)
    #expect(why("db:5432") == "“db” isn't a port.")
    #expect(why("15432:") == "“” isn't a port.")
    #expect(why("5432a") == "“5432a” isn't a port.")
    #expect(why("-5432") == "“-5432” isn't a port.")
    #expect(why("70000") == "The local port must be 1–65535.")
    #expect(why("15432:70000") == "The port must be 1–65535.")
    #expect(why("0:5432") == "The local port must be 1–65535.")
    #expect(why("15432:-oProxyCommand=x:5432") == "“-oProxyCommand=x” isn't a host name.")
    #expect(why("15432:me@db:5432") == "“me@db” isn't a host name.")
    #expect(why("15432:d b:5432") == "“d b” isn't a host name.")
    #expect(why("15432:[::1:5432") != nil)
    for s in ["5432", "15432:5432", "15432:db.internal:5432", "15432:[::1]:5432"] {
        #expect(read(s)?.forward == s, "the Edit field shows it as typed")
    }
}

/// Names, addresses and links a menu, the hint under the field and Copy Address show.
@Test func tunnelNamesAndAddresses() throws {
    let pg = Tunnel(localPort: 15432, port: 5432)
    #expect(pg.title == "Postgres" && pg.address == "localhost:15432" && pg.link == nil, "no URL for a database")
    #expect(pg.route(via: "db1") == "localhost:15432 → db1 → localhost:5432")
    #expect(Tunnel(localPort: 13000, port: 3000).link?.absoluteString == "http://localhost:13000")
    #expect(Tunnel(localPort: 18006, port: 8006).link?.absoluteString == "https://localhost:18006")
    #expect(Tunnel(localPort: 1, host: "::1", port: 7777).title == "[::1]:7777")
    #expect(Tunnel(name: "Mine", localPort: 1, port: 3000, url: "http://localhost:1/dash").link?.absoluteString == "http://localhost:1/dash")
    // servers.json by hand: the port alone is enough.
    let t = try JSONDecoder().decode(Tunnel.self, from: Data(#"{"port": 6379, "url": ""}"#.utf8))
    #expect(t == Tunnel(localPort: 6379, port: 6379) && t.title == "Redis" && !t.on)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Tunnel.self, from: Data(#"{"localPort": 1}"#.utf8)) }
    let back = try JSONDecoder().decode(Tunnel.self, from: JSONEncoder().encode(Tunnel(name: "x", localPort: 2, host: "h", port: 3, on: true)))
    #expect(back == Tunnel(name: "x", localPort: 2, host: "h", port: 3, on: true))
}

/// Ports 1–65535, a host that can't pass for ssh's options or a login, a web URL, a local port once per server.
@Test func tunnelProblems() {
    #expect(Tunnel(localPort: 15432, port: 5432).problem == nil)
    #expect(Tunnel(localPort: 15432, host: "", port: 5432).problem == "Enter a host.")
    #expect(Tunnel(localPort: 15432, host: "-W", port: 5432).problem == "“-W” isn't a host name.")
    #expect(Tunnel(localPort: 1, port: 3000, url: "file:///Applications/Calculator.app").problem == "The URL must start with http:// or https://.")
    #expect(Tunnel(localPort: 1, port: 3000, url: "HTTPS://x").problem == nil)
    let a = Tunnel(name: "A", localPort: 15432, port: 5432), b = Tunnel(name: "B", localPort: 15432, host: "db", port: 5432)
    #expect(Tunnel.problem([a, Tunnel(localPort: 16379, port: 6379)]) == nil)
    #expect(Tunnel.problem([a, b]) == "Two tunnels listen on port 15432: each needs a port of its own.")
    #expect(Tunnel.problem([a, Tunnel(name: "C", localPort: 0, port: 1)]) == "Tunnel “C”: The local port must be 1–65535.")
}

/// `ssh -W host:port` as one argument array: riding the master (its options), never becoming one (`ControlMaster=no`
/// first: ssh keeps the first value), the target's port and key, the target last behind `--`.
@Test func tunnelChildArguments() {
    let t = SFTPTarget(host: "me@web", port: 2222, identity: "/k")
    let a = Tunnel(localPort: 15432, host: "db.internal", port: 5432).arguments(t)
    #expect(Array(a.prefix(4)) == ["-o", "ControlMaster=no", "-o", "ControlMaster=auto"])
    #expect(a.contains("ControlPath=\(SFTP.controlDir)/%C"), "the same master as the panels")
    #expect(Array(a.suffix(10)) == ["-W", "db.internal:5432", "-p", "2222", "-i", "/k", "-o", "IdentitiesOnly=yes", "--", "me@web"])
    #expect(Tunnel(localPort: 1, host: "::1", port: 5432).arguments(SFTPTarget(host: "web")).suffix(4) == ["-W", "[::1]:5432", "--", "web"])
    #expect(!a.contains("-n") && !a.contains("-f") && !a.contains("-N"), "stdin is the client's socket")
}

/// What the master's log (or the child's stderr without a master) says, in plain words: the lines the test server's
/// master wrote for each reason (README §9.3), the mux client's own line, a login of its own.
@Test func tunnelFailuresInPlainWords() {
    let t = Tunnel(localPort: 15432, host: "db.internal", port: 5432)
    let mux = "Stdio forwarding request failed: Session open refused by peer"
    #expect(t.failure("channel 2: open failed: connect failed: Connection refused\n", server: "web1")
            == "Nothing listens on db.internal:5432 (as seen from web1)")
    #expect(t.failure("channel 2: open failed: connect failed: Name or service not known\n" + mux, server: "web1")
            == "web1 can't resolve db.internal")
    #expect(t.failure("channel 3: open failed: administratively prohibited: open failed\n" + mux, server: "web1")
            == "web1 forbids port forwarding (AllowTcpForwarding / PermitOpen)")
    #expect(t.failure("channel 0: open failed: connect failed: Connection refused\nstdio forwarding failed", server: "web1")
            == "Nothing listens on db.internal:5432 (as seen from web1)", "without a master: the child says it")
    #expect(t.failure("channel 0: open failed: connect failed: Name does not resolve", server: "w") == "w can't resolve db.internal")
    #expect(t.failure("channel 4: open failed: connect failed: No route to host", server: "w") == "w can't reach db.internal:5432: No route to host")
    #expect(t.failure("channel 2: open failed: connect failed: Connection refused\nchannel 5: open failed: administratively prohibited: open failed",
                      server: "w") == "w forbids port forwarding (AllowTcpForwarding / PermitOpen)", "the latest one")
    #expect(t.failure(mux, server: "web1") == "web1 refused the connection to db.internal:5432", "nothing in the log")
    #expect(t.failure("Warning: Permanently added 'h' to the list of known hosts.\nme@h: Permission denied (publickey).", server: "w")
            == "me@h: Permission denied (publickey).", "a login: as ssh said it")
    #expect(t.failure("", server: "w") == nil && t.failure("\n \n", server: "w") == nil)
}

/// What a listener told, in order (its threads call in).
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [TunnelListener.Event] = []
    func add(_ e: TunnelListener.Event) { lock.withLock { all.append(e) } }
    var list: [TunnelListener.Event] { lock.withLock { all } }
}

/// A client connected to 127.0.0.1:`port`, or -1. Reads wait up to 10 s.
private func dial(_ port: Int) -> Int32 {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    var on: Int32 = 1, wait = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
    var a = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: UInt16(port).bigEndian,
                        sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    if r != 0 { close(s); return -1 }
    return s
}

private func send(_ fd: Int32, _ text: String) { _ = text.withCString { write(fd, $0, strlen($0)) } }

/// What comes until the end (or `count` bytes).
private func receive(_ fd: Int32, count: Int = .max) -> String {
    var out = Data(), buf = [UInt8](repeating: 0, count: 65536)
    while out.count < count {
        let n = read(fd, &buf, min(buf.count, count - out.count))
        if n <= 0 { break }
        out += buf[0..<n]
    }
    return String(decoding: out, as: UTF8.self)
}

private func waitUntil(_ seconds: TimeInterval = 10, _ done: () -> Bool) -> Bool {
    let end = Date() + seconds
    while !done() { if Date() > end { return false }; usleep(10_000) }
    return true
}

/// A client on [::1]:`port`, or -1.
private func dialV6(_ port: Int) -> Int32 {
    let s = socket(AF_INET6, SOCK_STREAM, 0)
    var wait = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
    var a = sockaddr_in6()
    a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    a.sin6_family = sa_family_t(AF_INET6)
    a.sin6_port = UInt16(port).bigEndian
    a.sin6_addr = in6addr_loopback
    let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
    if r != 0 { close(s); return -1 }
    return s
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ value: T) { v = value }
    var value: T { lock.withLock { v } }
    func update<R>(_ change: (inout T) -> R) -> R { lock.withLock { change(&v) } }
}

private let cat: @Sendable (CancelFlag) throws -> TunnelListener.Child = { _ in .init(executable: "/bin/cat") }

// These run processes: in the one serialized suite with the rest (`SudoPasswordTests`).
extension SudoPasswordTests {

/// The master logs to a file of its server (`-E`): what it says once in the background — a tunnel's refused channel —
/// has nowhere else to go. Its login errors are read from there, word for word as ssh said them on stderr before; with
/// no master after all the file goes at once (a stale one, too). One that runs: `aTunnelRidesTheServersMaster`.
@Test func theMasterLogsToAFileOfItsServer() throws {
    let t = SFTPTarget(host: "dfm-no-such-host.invalid", port: 2222)
    let log = SFTP.masterLog(t)
    #expect(log == SFTP.controlDir + "/log-dfm-no-such-host.invalid_2222")
    #expect(SFTP.masterArguments(t) == ["-E", log, "-o", "LogLevel=INFO", "-f", "-N"], "a refusal is logged at INFO, whatever ~/.ssh/config says")
    #expect(SFTP.masterLog(SFTPTarget(host: "me@fe80::1%en0")) == SFTP.controlDir + "/log-me@fe80__1_en0_22")
    #expect(SFTP.masterLog(SFTPTarget(host: "a/../b c")) == SFTP.controlDir + "/log-a_.._b_c_22", "never outside the folder")
    try Data("stale\n".utf8).write(to: URL(fileURLWithPath: log))
    let e = try #require(throws: SFTPError.self) { try SFTP.startMaster(t, env: [:]) }
    #expect(e.connection)
    #expect(e.message.hasPrefix("ssh: Could not resolve hostname dfm-no-such-host.invalid") && !e.message.contains("stale"), "got: \(e.message)")
    #expect(!FileManager.default.fileExists(atPath: log))

    try Data("left from before\n".utf8).write(to: URL(fileURLWithPath: log))   // a new master's: afresh and owner-only
    chmod(log, 0o644)
    let h = SFTP.freshLog(t)
    try h.write(contentsOf: Data("new\n".utf8))
    try h.close()
    var st = stat()
    #expect(lstat(log, &st) == 0 && st.st_mode & 0o777 == 0o600 && st.st_size == 4)
    unlink(log)
}

/// Each connection gets a child of its own with the socket as its stdin and stdout (`cat` here: an echo): the bytes go
/// both ways, the client sees the end once it closed its half, and each connection counts while it lasts.
@Test func aTunnelGivesEachConnectionAChild() throws {
    let events = Events()
    let l = try TunnelListener(port: 0, child: cat, onEvent: events.add)
    defer { l.stop() }
    let a = dial(l.port), b = dial(l.port)
    defer { close(a); close(b) }
    #expect(waitUntil { l.connections == 2 && events.list.count == 2 })
    send(a, "one")
    shutdown(a, SHUT_WR)
    #expect(receive(a) == "one")
    #expect(waitUntil { l.connections == 1 })
    send(b, "two")
    shutdown(b, SHUT_WR)
    #expect(receive(b) == "two")
    #expect(waitUntil { l.connections == 0 })
    #expect(events.list == [.opened, .opened, .closed(failure: nil), .closed(failure: nil)], "told before counted")
}

/// `stop`: the port closes and the children go, so clients see their connections end; the port can be listened on
/// again at once (their TIME_WAIT doesn't hold it); nothing is told after. `keepConnections` (the screen locked): the
/// port closes, the connections live on — and no child holds the port (close-on-exec). A login under way gives up.
@Test func stoppingATunnelClosesItsPortAndItsConnections() throws {
    let events = Events()
    let l = try TunnelListener(port: 0, child: cat, onEvent: events.add)
    let a = dial(l.port)
    defer { close(a) }
    send(a, "x")
    #expect(receive(a, count: 1) == "x", "the child runs")
    l.stop()
    #expect(receive(a) == "", "its connection ends")
    #expect(waitUntil { l.connections == 0 })
    #expect(dial(l.port) == -1 && TunnelListener.isFree(l.port))
    for _ in 0..<20 {   // free when `stop` returns: Turn Off, then On at once, or an edit listening anew
        let again = try TunnelListener(port: l.port, child: cat, onEvent: { _ in })
        again.stop()
    }
    #expect(events.list == [.opened], "nothing after stop")

    let k = try TunnelListener(port: 0, child: cat, onEvent: { _ in })
    let c = dial(k.port)
    defer { close(c) }
    send(c, "y")
    #expect(receive(c, count: 1) == "y")
    k.stop(keepConnections: true)
    #expect(dial(k.port) == -1 && TunnelListener.isFree(k.port), "no child keeps the port")
    send(c, "z")
    #expect(receive(c, count: 1) == "z", "the connection lives on")
    shutdown(c, SHUT_WR)
    #expect(receive(c) == "")
    #expect(waitUntil { k.connections == 0 })

    let logins = Events()
    let w = try TunnelListener(port: 0, child: { cancel in
        while !cancel.isCancelled { usleep(10_000) }
        throw CancellationError()
    }, onEvent: logins.add)
    let d = dial(w.port)
    defer { close(d) }
    #expect(waitUntil { w.connections == 1 })
    w.stop()
    #expect(receive(d) == "")
    #expect(waitUntil { w.connections == 0 })
    #expect(logins.list == [.opened])
}

/// A taken port fails at once and says so, and the next free one is found — also when someone listens on every
/// address (a local Postgres on *:5432): quietly taking localhost from it would send its clients to the server.
@Test func aTakenPortSaysSoAndTheNextFreeOne() throws {
    let a = try TunnelListener(port: 0, child: cat, onEvent: { _ in })
    defer { a.stop() }
    #expect(throws: Tunnel.Problem(message: "Port \(a.port) is in use on this Mac")) { try TunnelListener(port: a.port, child: cat, onEvent: { _ in }) }
    #expect(!TunnelListener.isFree(a.port))
    let next = try #require(TunnelListener.freePort(after: a.port))
    #expect(next > a.port && TunnelListener.isFree(next))
    #expect(TunnelListener.freePort(after: 65535) == nil)

    let s = socket(AF_INET, SOCK_STREAM, 0)   // as servers listen: every address, SO_REUSEADDR
    defer { close(s) }
    var on: Int32 = 1
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                           sin_addr: in_addr(s_addr: INADDR_ANY), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) } }
    #expect(listen(s, 1) == 0)
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
    let p = Int(UInt16(bigEndian: addr.sin_port))
    #expect(!TunnelListener.isFree(p))
    #expect(throws: Tunnel.Problem(message: "Port \(p) is in use on this Mac")) { try TunnelListener(port: p, child: cat, onEvent: { _ in }) }
}

/// A connection whose child can't start (the login failed) ends at once and says why; one whose child failed says what
/// `failure` made of its exit status and stderr.
@Test func aFailedConnectionSaysWhy() throws {
    let events = Events()
    let l = try TunnelListener(port: 0, child: { _ in throw Tunnel.Problem(message: "me@h: Permission denied (publickey).") }, onEvent: events.add)
    defer { l.stop() }
    let a = dial(l.port)
    defer { close(a) }
    #expect(receive(a) == "")
    #expect(waitUntil { events.list.count == 2 })
    #expect(events.list == [.opened, .closed(failure: "me@h: Permission denied (publickey).")])

    let failed = Events()
    let m = try TunnelListener(port: 0, child: { _ in
        .init(executable: "/bin/sh", arguments: ["-c", "echo refused >&2; exit 255"]) { status, said in "\(status): \(said)" }
    }, onEvent: failed.add)
    defer { m.stop() }
    let b = dial(m.port)
    defer { close(b) }
    #expect(receive(b) == "")
    #expect(waitUntil { failed.list.count == 2 })
    #expect(failed.list == [.opened, .closed(failure: "255: refused\n")])
}

/// Through a real master (the test's sshd, the master started as `startMaster` starts one): the bytes go both ways and
/// the end comes through, ten connections at once; a refusal reads from the master's log in plain words — nothing
/// listens there, forwarding not allowed (PermitOpen); `::1` reaches ssh in brackets.
@Test(.timeLimit(.minutes(1))) func aTunnelRidesTheServersMaster() throws {
    let echo = try TunnelListener(port: 0, child: cat, onEvent: { _ in })   // the service on the "server" (this Mac)
    defer { echo.stop() }
    let nobody = freeTCPPort()
    try withTestSSHD(config: "PermitOpen 127.0.0.1:\(echo.port) 127.0.0.1:\(nobody)") { t, _, _ in
        func tunnel(_ host: String, _ port: Int) throws -> (TunnelListener, Events) {
            let events = Events()
            let child = Tunnel(localPort: 0, host: host, port: port).child(on: t, env: [:], server: "test")
            return (try TunnelListener(port: 0, child: child, onEvent: events.add), events)
        }
        var st = stat()
        #expect(lstat(SFTP.masterLog(t), &st) == 0 && st.st_mode & 0o777 == 0o600, "the master's log is owner-only")
        let (ok, okEvents) = try tunnel("127.0.0.1", echo.port)
        defer { ok.stop() }
        let a = dial(ok.port)
        send(a, "through the master")
        shutdown(a, SHUT_WR)
        #expect(receive(a) == "through the master")
        close(a)
        #expect(waitUntil { okEvents.list == [.opened, .closed(failure: nil)] }, "\(okEvents.list)")
        let ten = (0..<10).map { _ in dial(ok.port) }
        for (i, c) in ten.enumerated() { send(c, "\(i)") }
        #expect(ten.enumerated().allSatisfy { receive($1, count: 1) == "\($0)" })
        #expect(ok.connections == 10)
        ten.forEach { close($0) }
        #expect(waitUntil { ok.connections == 0 })

        let (none, noneEvents) = try tunnel("127.0.0.1", nobody)
        defer { none.stop() }
        let b = dial(none.port)
        #expect(receive(b) == "")
        close(b)
        #expect(waitUntil { noneEvents.list.count == 2 })
        #expect(noneEvents.list.last == .closed(failure: "Nothing listens on 127.0.0.1:\(nobody) (as seen from test)"))

        let (v6, v6Events) = try tunnel("::1", echo.port)
        defer { v6.stop() }
        let c = dial(v6.port)
        #expect(receive(c) == "")
        close(c)
        #expect(waitUntil { v6Events.list.count == 2 })
        #expect(v6Events.list.last == .closed(failure: "test forbids port forwarding (AllowTcpForwarding / PermitOpen)"))
    }
}

/// The port is localhost's both ways, as `ssh -L` listens: ::1 too (most clients try it first), so a program there
/// can't take the tunnel's clients — and one already there makes the port taken. A child that inherits every open file
/// (a terminal's shell, forked) still never keeps the port: the sockets are close-on-exec.
@Test func aTunnelListensOnBothLoopbacks() throws {
    let l = try TunnelListener(port: 0, child: cat, onEvent: { _ in })
    let c = dialV6(l.port)
    #expect(c >= 0)
    send(c, "v6")
    #expect(receive(c, count: 2) == "v6")
    close(c)

    var pid: pid_t = 0
    let words: [String] = ["/bin/sleep", "30"]
    let args: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
    defer { args.forEach { free($0) } }
    #expect(posix_spawn(&pid, "/bin/sleep", nil, nil, args, environ) == 0, "no POSIX_SPAWN_CLOEXEC_DEFAULT: inherits all but close-on-exec")
    defer { kill(pid, SIGKILL); waitpid(pid, nil, 0) }
    l.stop()
    #expect(TunnelListener.isFree(l.port), "the child holds no socket of the port")

    let s = socket(AF_INET6, SOCK_STREAM, 0)   // someone on [::1]:port alone
    defer { close(s) }
    var on: Int32 = 1
    setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
    var a = sockaddr_in6()
    a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    a.sin6_family = sa_family_t(AF_INET6)
    a.sin6_addr = in6addr_loopback
    var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
    _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) } }
    #expect(listen(s, 1) == 0)
    _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
    let p = Int(UInt16(bigEndian: a.sin6_port))
    #expect(!TunnelListener.isFree(p))
    #expect(throws: Tunnel.Problem(message: "Port \(p) is in use on this Mac")) { try TunnelListener(port: p, child: cat, onEvent: { _ in }) }
}

/// One login at a time for a tunnel's connections; when it fails, those that waited for it fail with it — a client
/// opening several at once doesn't get the password dialog again for each — and a connection after that tries anew.
@Test func connectionsWaitingForAFailedLoginFailWithIt() throws {
    let gate = LoginGate(), logins = Locked(0), errors = Locked([String]())
    struct Refused: Error { let n: Int }
    func connection(_ delay: TimeInterval) -> Thread {
        let came = Date()
        let t = Thread {
            do {
                try gate.pass(since: came) {
                    let n = logins.update { $0 += 1; return $0 }
                    Thread.sleep(forTimeInterval: delay)
                    throw Refused(n: n)
                }
            } catch let e as Refused { errors.update { $0.append("login \(e.n)") } } catch {}
        }
        t.start()
        return t
    }
    let first = connection(0.3)
    usleep(50_000)
    let queued = [connection(0), connection(0)]
    for t in [first] + queued { while !t.isFinished { usleep(10_000) } }
    #expect(logins.value == 1 && errors.value == ["login 1", "login 1", "login 1"])
    let later = connection(0)
    while !later.isFinished { usleep(10_000) }
    #expect(logins.value == 2, "a connection after the failure tries again")
}

/// A refused connection that left nothing to read (LogLevel QUIET in ~/.ssh/config) still isn't a clean end.
@Test func aSilentRefusalStillSaysSo() throws {
    let spec = try Tunnel(localPort: 1, port: 5432).child(on: .local(), env: [:], server: "web1")(CancelFlag())
    #expect(spec.executable == "/usr/bin/ssh")
    #expect(spec.failure(255, "") == "web1 refused the connection to localhost:5432")
    #expect(spec.failure(0, "") == nil)
}

}
