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
