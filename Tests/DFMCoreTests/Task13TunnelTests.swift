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

// These run processes: in the one serialized suite with the rest (`SudoPasswordTests`).
extension SudoPasswordTests {

/// The master logs to a file of its server (`-E`): what it says once in the background — a tunnel's refused channel —
/// has nowhere else to go. Its login errors are read from there, word for word as ssh said them on stderr before; with
/// no master after all the file goes at once (a stale one, too). One that runs: `aTunnelRidesTheServersMaster`.
@Test func theMasterLogsToAFileOfItsServer() throws {
    let t = SFTPTarget(host: "dfm-no-such-host.invalid", port: 2222)
    let log = SFTP.masterLog(t)
    #expect(log == SFTP.controlDir + "/log-dfm-no-such-host.invalid_2222")
    #expect(SFTP.masterArguments(t) == ["-E", log, "-f", "-N"])
    #expect(SFTP.masterLog(SFTPTarget(host: "me@fe80::1%en0")) == SFTP.controlDir + "/log-me@fe80__1_en0_22")
    #expect(SFTP.masterLog(SFTPTarget(host: "a/../b c")) == SFTP.controlDir + "/log-a_.._b_c_22", "never outside the folder")
    try Data("stale\n".utf8).write(to: URL(fileURLWithPath: log))
    let e = try #require(throws: SFTPError.self) { try SFTP.startMaster(t, env: [:]) }
    #expect(e.connection)
    #expect(e.message.hasPrefix("ssh: Could not resolve hostname dfm-no-such-host.invalid") && !e.message.contains("stale"), "got: \(e.message)")
    #expect(!FileManager.default.fileExists(atPath: log))
}

}
