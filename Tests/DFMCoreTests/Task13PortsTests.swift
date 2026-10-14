import Foundation
import Testing
@testable import DFMCore

// What servers print, made up after real ones (Ubuntu 24.04's iproute2 and net-tools, Alpine's busybox): each quirk once.

/// `ss -Hltnp` as a user: columns padded with spaces, the interface after "%", "*" for every address (dual-stack), IPv6
/// in brackets, the process only for the user's own (its comm, which may hold a space).
let ssSample = """
    LISTEN 0      4096   127.0.0.53%lo:53    0.0.0.0:*
    LISTEN 0      4096      127.0.0.54:53    0.0.0.0:*
    LISTEN 0      4096         0.0.0.0:22    0.0.0.0:*
    LISTEN 0      200          0.0.0.0:5432  0.0.0.0:*
    LISTEN 0      5          127.0.0.1:18090 0.0.0.0:* users:(("python3",pid=4242,fd=3))
    LISTEN 0      128       192.0.2.10:8000  0.0.0.0:* users:(("tmux: server",pid=77,fd=5),("tmux: server",pid=78,fd=5))
    LISTEN 0      5              [::1]:18090    [::]:* users:(("python3",pid=4243,fd=3))
    LISTEN 0      511                *:80          *:*
    LISTEN 0      4096            [::]:22       [::]:*
    LISTEN 0      200             [::]:5432     [::]:*

    """

/// net-tools `netstat -ltnp` as a user: two header lines, `tcp6` with IPv6 unbracketed, no "%lo", "-" for others' processes.
let netstatSample = """
    Active Internet connections (only servers)
    Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name
    tcp        0      0 127.0.0.53:53           0.0.0.0:*               LISTEN      -
    tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN      -
    tcp        0      0 127.0.0.1:18090         0.0.0.0:*               LISTEN      4242/python3
    tcp6       0      0 ::1:18090               :::*                    LISTEN      4243/python3
    tcp6       0      0 :::80                   :::*                    LISTEN      -
    tcp6       0      0 :::22                   :::*                    LISTEN      -

    """

/// busybox `netstat -ltnp`: `tcp` for IPv6 too; the program is busybox's own applet.
let busyboxSample = """
    Active Internet connections (only servers)
    Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name
    tcp        0      0 127.0.0.1:18092         0.0.0.0:*               LISTEN      10/busybox
    tcp        0      0 ::1:18093               :::*                    LISTEN      3/busybox
    tcp        0      0 :::18094                :::*                    LISTEN      11/busybox

    """

/// Each format reads to the same rows: one per port, its IPv4 and IPv6 together, by port; where it listens said once —
/// every address, localhost, or the address itself (where a tunnel then goes); the process where the server shows it.
@Test func listeningPortsReadFromEachFormat() {
    #expect(ListeningPorts.parse(ssSample) == [
        ListeningPort(port: 22, addresses: ["*"]),
        ListeningPort(port: 53, addresses: ["127.0.0.53", "127.0.0.54"]),
        ListeningPort(port: 80, addresses: ["*"]),
        ListeningPort(port: 5432, addresses: ["*"]),
        ListeningPort(port: 8000, addresses: ["192.0.2.10"], process: "tmux: server"),
        ListeningPort(port: 18090, addresses: ["localhost"], process: "python3"),
    ])
    #expect(ListeningPorts.parse(netstatSample) == [
        ListeningPort(port: 22, addresses: ["*"]),
        ListeningPort(port: 53, addresses: ["127.0.0.53"]),
        ListeningPort(port: 80, addresses: ["*"]),
        ListeningPort(port: 18090, addresses: ["localhost"], process: "python3"),
    ])
    #expect(ListeningPorts.parse(busyboxSample) == [
        ListeningPort(port: 18092, addresses: ["localhost"], process: "busybox"),
        ListeningPort(port: 18093, addresses: ["localhost"], process: "busybox"),
        ListeningPort(port: 18094, addresses: ["*"], process: "busybox"),
    ])
    #expect(ListeningPorts.parse(ssSample.replacingOccurrences(of: " users:((\"python3\",pid=4242,fd=3))", with: ""))
        .first { $0.port == 18090 }?.process == "python3", "the IPv6 socket's name serves the port")
}

/// Where it goes and what the row says.
@Test func aListeningPortSaysWhereItListens() {
    let all = ListeningPort(port: 80, addresses: ["*", "localhost"])
    #expect(all.host == "localhost" && all.reach == "all addresses")
    let local = ListeningPort(port: 5432, addresses: ["localhost"])
    #expect(local.host == "localhost" && local.reach == "localhost only")
    let resolver = ListeningPort(port: 53, addresses: ["127.0.0.53", "127.0.0.54"])
    #expect(resolver.host == "127.0.0.53" && resolver.reach == "127.0.0.53, 127.0.0.54 only", "nobody on localhost:53 there")
    let both = ListeningPort(port: 8080, addresses: ["192.0.2.10", "localhost"])
    #expect(both.host == "localhost" && both.reach == "192.0.2.10, localhost only")
}

/// What isn't a listening socket is passed over: headers (ss's without -H too), a login script's words, other states,
/// broken lines, ports out of range, an empty answer.
@Test func listeningPortsPassOverTheRest() {
    let noise = """
        Welcome to the server!
        State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
        LISTEN 0      128    0.0.0.0:22         0.0.0.0:*
        ESTAB  0      0      192.0.2.10:22      198.51.100.7:51234
        tcp        0      0 192.0.2.10:22           198.51.100.7:51234      ESTABLISHED -
        udp        0      0 0.0.0.0:68              0.0.0.0:*
        LISTEN 0      128
        LISTEN 0      128    0.0.0.0:http       0.0.0.0:*
        LISTEN 0      128    0.0.0.0:70000      0.0.0.0:*
        tcp        0      0 no-port-here            0.0.0.0:*               LISTEN      -
        (Not all processes could be identified, non-owned process info
         will not be shown, you would have to be root to see it all.)
        """
    #expect(ListeningPorts.parse(noise) == [ListeningPort(port: 22, addresses: ["*"])])
    let scoped = "LISTEN 0 128 [fe80::1]%eth0:2222 [::]:*\nLISTEN 0 128 [::]%eth0:2223 [::]:*\n"   // ss: the interface after the brackets
    #expect(ListeningPorts.parse(scoped) == [ListeningPort(port: 2222, addresses: ["fe80::1"]), ListeningPort(port: 2223, addresses: ["*"])])
    #expect(ListeningPorts.parse("").isEmpty && ListeningPorts.parse("\r\n\n").isEmpty)
    #expect(ListeningPorts.parse("LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\r\n") == [ListeningPort(port: 22, addresses: ["*"])], "CRLF")
}

/// What the server's run comes to: the ports after the tool's line (a login script's words before it don't count); a
/// failed login as ssh said it; a server without either tool, or one that failed, in plain words — netstat's warning
/// with exit 0 is no failure.
@Test func aPortsLookSaysWhatWentWrong() {
    func said(_ status: Int32, _ output: String, _ errors: String = "") -> String {
        switch ListeningPorts.outcome(status: status, output: output, errors: errors, server: "db1") {
        case .success(let ports): ports.map { "\($0.port)" }.joined(separator: " ")
        case .failure(let e): e.message
        }
    }
    #expect(said(0, "Welcome!\nkermo-ss\n" + ssSample) == "22 53 80 5432 8000 18090")
    #expect(said(0, "kermo-netstat\n" + netstatSample, "(Not all processes could be identified, non-owned process info") == "22 53 80 18090")
    #expect(said(0, "kermo-ss\n") == "", "nothing listens")
    #expect(said(0, "kermo-none\n") == "db1 has neither ss nor netstat to tell its ports")
    #expect(said(1, "kermo-ss\n", "Cannot open netlink socket: Permission denied") == "ss failed on db1: Cannot open netlink socket: Permission denied")
    #expect(said(2, "kermo-netstat\n") == "netstat failed on db1: exit 2")
    #expect(said(255, "", "me@db1: Permission denied (publickey).") == "me@db1: Permission denied (publickey).", "a login's words as they are")
    #expect(said(127, "") == "Couldn't look at the ports of db1 (exit 127)")
}

extension SudoPasswordTests {

/// One ssh command runs the look (`.local()`: this Mac's sh), with stand-in `ss` and `netstat` first in PATH — the Mac's
/// own netstat speaks BSD: ss when there is one, else netstat (its warning on stderr is no failure), each asked for
/// listening TCP ports, numbers and processes.
@Test func portsAreReadWithSsElseNetstat() throws {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-ports-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: d) }
    func fake(_ name: String, _ output: String, stderr: String = "") throws {
        let body = "#!/bin/sh\n[ \"$*\" = -ltnp ] || { echo \"wrong options: $*\" >&2; exit 9; }\n"
            + "echo '\(stderr)' >&2\ncat <<'END'\n\(output)END\n"
        try Data(body.utf8).write(to: URL(fileURLWithPath: d + "/" + name))
        chmod(d + "/" + name, 0o755)
    }
    let env = ["PATH": d + ":/usr/bin:/bin"]
    try fake("netstat", netstatSample, stderr: "(Not all processes could be identified, non-owned process info")
    #expect(try ListeningPorts.read(on: .local(), server: "db1", env: env).map(\.port) == [22, 53, 80, 18090], "no ss here: netstat")
    try fake("ss", ssSample)
    let ports = try ListeningPorts.read(on: .local(), server: "db1", env: env)
    #expect(ports.map(\.port) == [22, 53, 80, 5432, 8000, 18090] && ports.last?.process == "python3")
    try Data("#!/bin/sh\necho 'Cannot open netlink socket: Permission denied' >&2\nexit 1\n".utf8).write(to: URL(fileURLWithPath: d + "/ss"))
    let e = try #require(throws: SFTPError.self) { try ListeningPorts.read(on: .local(), server: "db1", env: env) }
    #expect(e.message == "ss failed on db1: Cannot open netlink socket: Permission denied")
}

}
