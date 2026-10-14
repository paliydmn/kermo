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
    #expect(ListeningPorts.parse("").isEmpty && ListeningPorts.parse("\r\n\n").isEmpty)
    #expect(ListeningPorts.parse("LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\r\n") == [ListeningPort(port: 22, addresses: ["*"])], "CRLF")
}
