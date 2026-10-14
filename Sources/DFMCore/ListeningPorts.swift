import Foundation

/// A TCP port a server listens on, as `ss -ltnp` or `netstat -ltnp` (net-tools, busybox) say it: what Forward Port…
/// lists. Its IPv4 and IPv6 sockets are one port.
public struct ListeningPort: Equatable, Sendable {
    public var port: Int
    /// Where it listens: "*" for every address, "localhost" for 127.0.0.1 and ::1, else the address as the server
    /// wrote it (no brackets, no %interface) — in the order seen.
    public var addresses: [String]
    /// Its program, where the server shows it: `ss -p` and `netstat -p` show a user's own processes only.
    public var process: String?

    public init(port: Int, addresses: [String], process: String? = nil) {
        (self.port, self.addresses, self.process) = (port, addresses, process)
    }

    /// Where a tunnel to it goes, as the server sees it (`ssh -W`): localhost, unless it listens on another address alone.
    public var host: String { addresses.contains("*") || addresses.contains("localhost") ? "localhost" : addresses[0] }
    /// "all addresses", "localhost only", "192.0.2.10 only".
    public var reach: String { addresses.contains("*") ? "all addresses" : addresses.joined(separator: ", ") + " only" }
}

public enum ListeningPorts {
    /// The ports in `ss -ltn[p]`'s or `netstat -ltn[p]`'s output, by port. A line counts only if it starts with ss's
    /// `LISTEN` or netstat's `tcp` / `tcp6` (busybox writes `tcp` for IPv6 too): headers, warnings and whatever a login
    /// script printed are passed over.
    public static func parse(_ text: String) -> [ListeningPort] {
        var ports: [Int: ListeningPort] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let process: String?
            if words.first == "LISTEN", words.count >= 5 {   // State Recv-Q Send-Q Local Peer [users:(("name",pid=1,fd=3))]
                process = line.range(of: "users:((\"").flatMap { at in line[at.upperBound...].split(separator: "\"", maxSplits: 1).first.map(String.init) }
            } else if ["tcp", "tcp6"].contains(words.first), words.count >= 6, words[5] == "LISTEN" {   // Proto Recv-Q Send-Q Local Foreign State [PID/Program]
                let program = words.dropFirst(6).joined(separator: " ")
                process = program.firstIndex(of: "/").map { String(program[program.index(after: $0)...]) }.flatMap { $0.isEmpty ? nil : $0 }
            } else {
                continue
            }
            guard let (address, port) = local(words[3]) else { continue }
            var p = ports[port] ?? ListeningPort(port: port, addresses: [])
            if !p.addresses.contains(address) { p.addresses.append(address) }
            p.process = p.process ?? process
            ports[port] = p
        }
        return ports.values.sorted { $0.port < $1.port }
    }

    /// "127.0.0.53%lo:53", "*:80", "[::1]:631", ":::22" (netstat's IPv6, no brackets): the port after the last ":".
    static func local(_ s: Substring) -> (String, Int)? {
        guard let colon = s.lastIndex(of: ":"), let port = Int(s[s.index(after: colon)...]), (1...65535).contains(port) else { return nil }
        var host = String(s[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }
        switch host {
        case "*", "0.0.0.0", "::", "": return ("*", port)
        case "127.0.0.1", "::1": return ("localhost", port)
        default: return (host, port)
        }
    }
}
